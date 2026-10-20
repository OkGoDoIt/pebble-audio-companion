import AppDB
import CompanionRuntime
import Foundation
import GRDB
import SegmentStore
import Transcription

/// One of the phone's Desktop backups (a copy of the app container's
/// `Library/Application Support/audio-companion`), opened the way the app opens its own
/// container, and never written.
///
/// - The database is copied to a scratch directory first, without its `-shm` (the wal-index is
///   rebuilt from the WAL on open). Opening the copy replays the WAL into it and runs the app's
///   own migrations, so a backup made by an older build reads exactly as that phone would read it
///   after updating. Everything the import writes (the migrations, the audio-content mask load,
///   the outbox it enumerates through) goes into that copy.
/// - The segment sidecars and transcripts are read where they are, through the app's own
///   `SegmentStore` and `FileTranscriptStore` read paths, which never write.
public final class BackupLibrary: Sendable {
    public let root: URL
    public let database: AppDatabase
    public let builder: ArchivePayloadBuilder
    /// When the backup's database was last written. It is every item's version: the same backup
    /// always sends the same versions (the server ignores the replay), a newer backup supersedes an
    /// older one, and the phone's own sync, whose versions are the time of each change, supersedes
    /// both.
    public let snapshotMs: Int64
    /// The zone of the backup's newest conversation: what "the phone's current zone" was when the
    /// backup was taken, for the payloads that fall back to it (a recap with no conversations, a
    /// day's coverage with none).
    public let zoneID: String
    /// The scratch directory holding the database copy.
    let scratch: URL

    public enum OpenError: Error, CustomStringConvertible {
        case noDatabase(URL)

        public var description: String {
            switch self {
            case .noDatabase(let url):
                return "There is no database at \(url.path). A backup holds db/companion.sqlite."
            }
        }
    }

    private init(
        root: URL, database: AppDatabase, builder: ArchivePayloadBuilder, snapshotMs: Int64,
        zoneID: String, scratch: URL
    ) {
        self.root = root
        self.database = database
        self.builder = builder
        self.snapshotMs = snapshotMs
        self.zoneID = zoneID
        self.scratch = scratch
    }

    public static func open(
        _ root: URL, nowMs: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000)
        }
    ) async throws -> BackupLibrary {
        let fm = FileManager.default
        let source = root.appendingPathComponent("db/companion.sqlite")
        guard fm.fileExists(atPath: source.path) else { throw OpenError.noDatabase(source) }
        let wal = URL(fileURLWithPath: source.path + "-wal")

        let scratch = fm.temporaryDirectory.appendingPathComponent(
            "archive-import-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        ScratchCleanup.shared.register(scratch)
        let copy = scratch.appendingPathComponent("companion.sqlite")
        try fm.copyItem(at: source, to: copy)
        if fm.fileExists(atPath: wal.path) {
            try fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
        }
        let snapshotMs = [source, wal].compactMap { url -> Int64? in
            guard let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            else { return nil }
            return Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        }.max() ?? nowMs()

        let database = try AppDatabase.open(at: copy)
        let store = SegmentStore(root: root, nowMs: nowMs)
        let transcripts = FileTranscriptStore(root: root, nowMs: nowMs)
        let contentStore = AudioContentStore(db: database)
        // The mask the app's AI layer reads is built by the first audio-content pass of a launch.
        // A budget of zero loads it from the stored spans and classifies nothing, so the
        // transcript export withholds exactly what the phone withheld when the backup was made.
        let content = AudioContentService(
            listSegments: { await store.listSegments() },
            speechTimingsOf: { transcripts.loadSpeechTimings($0) },
            transcriptVersionOf: { transcripts.version($0) },
            store: contentStore, nowMs: nowMs)
        try await content.classifyPass(budget: 0)

        let zoneID =
            try await database.reader.read { d in
                try String.fetchOne(
                    d, sql: "SELECT timezone FROM conversations ORDER BY startMs DESC LIMIT 1")
            } ?? TimeZone.current.identifier

        let builder = ArchivePayloadBuilder(
            sources: ArchivePayloadBuilder.Sources(
                database: database,
                readMeta: { await store.readMeta($0) },
                listSegments: { await store.listSegments() },
                transcript: { transcripts.loadWithoutWords($0) },
                transcriptVersion: { transcripts.version($0) },
                mask: content.mask,
                audioContent: contentStore,
                // Which boundaries may still move is a property of a live grouping pass and is
                // not stored. A backup has had none, as a phone has not before its first regroup;
                // the live conversation is sent as provisional regardless.
                provisionalIds: { [] },
                nowMs: nowMs,
                currentZoneID: { zoneID }
            )
        )
        return BackupLibrary(
            root: root, database: database, builder: builder, snapshotMs: snapshotMs,
            zoneID: zoneID, scratch: scratch)
    }

    /// Every entity the phone would send on linking, in the phone's own enumeration
    /// (`ArchiveOutbox.markEverything`, run on the scratch copy exactly as `didLink` runs it),
    /// each at the backup's version, in a fixed order: kind, then id.
    public func everything() async throws -> [ArchiveOutboxRow] {
        let outbox = ArchiveOutbox(db: database)
        // A backup of a linked phone carries its outbox; the import starts from none, as a link
        // does.
        try await outbox.setActive(false)
        try await outbox.setActive(true)
        try await outbox.markEverything()
        let rows = try await outbox.pending(limit: Int(Int32.max))
        let order = Dictionary(
            uniqueKeysWithValues: ArchiveEntityKind.allCases.enumerated().map { ($1, $0) })
        return rows.map { row in
            ArchiveOutboxRow(
                kind: row.kind, entityId: row.entityId, version: snapshotMs, op: .upsert,
                changedAtMs: snapshotMs, pending: true)
        }.sorted {
            (order[$0.kind] ?? 0, $0.entityId) < (order[$1.kind] ?? 0, $1.entityId)
        }
    }

    /// Removes the scratch copy of the database.
    public func close() {
        try? FileManager.default.removeItem(at: scratch)
        ScratchCleanup.shared.unregister(scratch)
    }
}

/// The scratch copies of the database, removed on Ctrl-C too: each is a copy of a person's whole
/// archive and should not outlive the run that made it.
public final class ScratchCleanup: @unchecked Sendable {
    public static let shared = ScratchCleanup()
    private let lock = NSLock()
    private var directories: Set<URL> = []
    private var sources: [DispatchSourceSignal] = []

    func register(_ url: URL) { lock.withLock { _ = directories.insert(url) } }
    func unregister(_ url: URL) { lock.withLock { _ = directories.remove(url) } }

    public func removeAll() {
        let all = lock.withLock { directories }
        for url in all { try? FileManager.default.removeItem(at: url) }
    }

    /// Ctrl-C and SIGTERM remove the scratch copies, then exit.
    public func installSignalHandlers() {
        for signo in [SIGINT, SIGTERM] {
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .main)
            source.setEventHandler { [weak self] in
                self?.removeAll()
                FileHandle.standardError.write(Data("\nStopped. What the server already holds is kept; run it again to continue.\n".utf8))
                exit(130)
            }
            source.resume()
            lock.withLock { sources.append(source) }
        }
    }
}
