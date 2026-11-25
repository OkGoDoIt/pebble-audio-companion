import AppDB
import Foundation
import GRDB
import Intelligence
import SegmentStore
import Testing
import Transcription

@testable import CompanionRuntime

// What one quiet pass of the AI stages costs on a real library: how many transcripts are decoded
// and how many files are looked at when nothing has changed. The AI is a fake that answers "no
// items" without sending anything.
//
// Gated: set PEBBLE_HISTORY_BACKUP to a backup root. The backup is only read (its database is
// copied and opened there), and nothing from it is printed but counts.

private let backupRoot: String? = ProcessInfo.processInfo.environment["PEBBLE_HISTORY_BACKUP"]

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n: [String: Int] = [:]
    func bump(_ key: String) { lock.withLock { n[key, default: 0] += 1 } }
    func take() -> [String: Int] {
        lock.withLock {
            defer { n = [:] }
            return n
        }
    }
}

private struct NoItems: AiProvider {
    let id = "none"
    let counter: Counter
    func isAvailable() async -> Bool { true }
    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        counter.bump("ai")
        return AiProviderResult(text: #"{"items":[]}"#, modelUsed: "none")
    }
}

@Suite(
    "a quiet pass over a real backup",
    .enabled(if: backupRoot.map { FileManager.default.fileExists(atPath: $0 + "/segments") } ?? false,
        "set PEBBLE_HISTORY_BACKUP to a backup root")
)
struct RealPassCostTests {
    @Test func followUpExtractionOverAnUnchangedLibrary() async throws {
        let root = URL(fileURLWithPath: backupRoot!)
        let metas = SegmentFileReader(root: root).listSegments()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pass-cost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for suffix in ["", "-wal", "-shm"] {
            let source = root.appendingPathComponent("db/companion.sqlite\(suffix)")
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("companion.sqlite\(suffix)"))
            }
        }
        let database = try AppDatabase.open(at: folder.appendingPathComponent("companion.sqlite"))
        let transcripts = FileTranscriptStore(root: root, nowMs: { 0 })
        let counter = Counter()
        let mask = AudioContentMask()
        let audio = AudioContentService(
            listSegments: { metas }, speechTimingsOf: { transcripts.loadSpeechTimings($0) },
            transcriptVersionOf: { transcripts.version($0) },
            store: AudioContentStore(db: database), mask: mask, nowMs: { 0 })
        try await audio.loadSaved()

        let byId = Dictionary(uniqueKeysWithValues: metas.map { ($0.segmentId, $0) })
        let rows = try await database.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT c.id AS id, c.state AS state, s.segmentId AS segmentId,
                           s.startMediaMs AS a, s.endMediaMs AS b
                    FROM conversations c JOIN conversation_segments s ON s.conversationId = c.id
                    ORDER BY c.id, s.ordinal
                    """
            ).map { ($0["id"] as String, $0["state"] as String, $0["segmentId"] as String, $0["a"] as Int64?, $0["b"] as Int64?) }
        }
        var pieces: [String: [ConversationMember]] = [:]
        var state: [String: String] = [:]
        for (id, s, segment, a, b) in rows where byId[segment] != nil {
            pieces[id, default: []].append(.init(segmentId: segment, startMediaMs: a, endMediaMs: b))
            state[id] = s
        }
        let inputs = pieces.map { id, list in
            EnrichmentConversation(
                conversationId: id, isOpen: state[id] != "closed",
                members: list.map { byId[$0.segmentId]! }, pieces: list)
        }.filter { c in !c.pieces.allSatisfy { mask.holdsConversation(in: $0) == false } || c.isOpen }
        let nowMs = metas.map(\.startWallMs).max()! + 600_000

        let provider = NoItems(counter: counter)
        func makeWorker() throws -> FollowUpWorker { FollowUpWorker(
            candidates: try FollowUpCandidateStore(db: database),
            state: try FollowUpExtractionStore(db: database),
            router: AiModeRouter(local: nil, remote: provider, mode: { .remoteOnly }),
            nowMs: { nowMs },
            transcriptVersionOf: {
                counter.bump("version")
                return "\(transcripts.version($0))#\(mask.aiFingerprint($0))"
            },
            measureEpoch: "test") }
        var worker = try makeWorker()
        let pieceOf: @Sendable (ConversationMember) -> SegmentTranscript? = { member in
            counter.bump("decode")
            return transcripts.load(member.segmentId)?.piece(member).withLoopedArtefactsCollapsed()
                .withStretchesWithheld(mask.aiRanges(member.segmentId))
        }
        print("pass-cost: \(metas.count) segments, \(inputs.count) conversations with talk")
        let clock = ContinuousClock()
        for pass in 1...8 {
            // A relaunch: nothing in memory, the same database.
            if pass == 5 { worker = try makeWorker() }
            let took = try await clock.measure { _ = try await worker.extract(inputs, pieceTranscriptOf: pieceOf) }
            print("pass-cost: pass \(pass)\(pass == 5 ? " (relaunched)" : "") \(took) \(counter.take())")
        }
    }
}
