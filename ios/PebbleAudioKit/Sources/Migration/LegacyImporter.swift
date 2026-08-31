import AppDB
import Foundation
import GRDB
import Intelligence
import SegmentStore
import Transcription

// M8 first-launch migration importer (plan Part 4.8 / 6.4, Q19).
//
// The RELEASE bundle id (`dev.audiocompanion.app`) installs OVER the old KMP app and inherits
// its container and standard defaults in place — nothing is copied or moved. The importer's
// job is to validate + normalize + index what is already there:
//
//  - segments (`segments/*.spxlog` + `*.meta.json`): SegmentStore recovery, a startTime clamp
//    for pre-1e5db02 anchors, and a `recordedTimeZone` backfill;
//  - transcripts (`transcription/transcripts/*.transcript.json`): verified readable, left in
//    place (they ARE the durable store);
//  - DB bootstrap: conversations from ConversationGrouper, `transcription_tasks` rows for the
//    untranscribed backlog;
//  - identity + settings: `receiver_id_v1` and both API keys move standard-defaults → Keychain
//    (deleting the defaults entries), surviving settings copy into the app-group suite.
//
// Marker version 2 adds three more phases, each independently idempotent and each able to run
// on a container that ALREADY finished the version-1 migration (a v1 marker is upgraded in
// place — the finished phases stay finished and only the new ones run; see `MigrationState`):
//
//  - **quarantine recovery** (phase 4): orphan `.spxlog` files whose sidecar was lost are
//    restored to `segments/` with reconstructed metadata (`QuarantineRecovery.swift`).
//  - **terminal queue rows** (phase 5): a segment that arrived already transcribed got no
//    `transcription_tasks` row at all, and `ConversationQueries.aggregateLifecycle` reads a
//    missing row as Pending — so every fully-transcribed migrated conversation rendered
//    "Captured · waiting to transcribe", with a Transcribe now button, above its own finished
//    transcript. Terminal rows (Complete/NoSpeech, carrying the transcript's own provider and
//    model) restore the state the runtime would have left behind.
//  - **`ai/outputs`** (phase 6): past Ask answers and template notes (`LegacyAiOutputs.swift`).
//
// Everything else in the legacy container — `queue/`, `uploads/`, `bodies/`, `receiver_state`,
// and the rest of the `ai/` tree — is deliberately ignored (Q19: AI artifacts regenerate; the
// old queue's state is re-derived from the segment metas). A NEW background-URLSession
// identifier is a runtime concern; nothing session-related is migrated.
// `Documents/PebbleAudioExports` is left untouched.

/// Counters for one import run — persisted into the completion marker so a later launch can
/// report what the migration did.
public struct LegacyImportStats: Codable, Equatable, Sendable {
    public var segmentsIndexed: Int = 0
    public var startTimesClamped: Int = 0
    public var timeZonesBackfilled: Int = 0
    public var conversationsFormed: Int = 0
    public var transcriptsVerified: Int = 0
    public var transcriptsUnreadable: Int = 0
    /// Segments whose meta said Complete but whose transcript file is missing — requeued.
    public var completeMissingTranscriptRequeued: Int = 0
    /// Total Pending `transcription_tasks` rows created (includes the requeued ones).
    public var tasksEnqueued: Int = 0
    public var receiverIdMigrated: Bool = false
    /// Old-defaults keys that were acted on (settings copied, secrets moved to Keychain).
    public var settingsKeysMigrated: [String] = []

    // ── v2 phases ────────────────────────────────────────────────────────────
    /// Terminal (Complete/NoSpeech) `transcription_tasks` rows written for segments that
    /// arrived already transcribed, so the Library stops calling them "waiting to transcribe".
    public var terminalTasksBackfilled: Int = 0
    /// Orphan `.spxlog` files restored from `quarantine/` to `segments/`.
    public var quarantineRecovered: Int = 0
    /// Of those, the ones whose sidecar was quarantined alongside them (real gap records kept).
    public var quarantineSidecarsRestored: Int = 0
    /// Recovered segments that already had a durable transcript — never re-transcribed.
    public var quarantineAlreadyTranscribed: Int = 0
    /// Recovered segments queued for transcription (behind everything already queued).
    public var quarantineQueuedForTranscription: Int = 0
    /// Frames restored, and the audio they represent.
    public var quarantineFramesRecovered: Int64 = 0
    public var quarantineAudioMs: Int64 = 0
    /// Files in `quarantine/` skipped because the name is not a segment id (truncated names
    /// from interrupted copies, stray files).
    public var quarantineSkippedMalformed: Int = 0
    /// Orphan logs that could not be scanned into a single valid record.
    public var quarantineSkippedUnreadable: Int = 0
    /// Ask answers and notes imported from `ai/outputs`.
    public var askEntriesImported: Int = 0
    public var notesImported: Int = 0
    public var aiOutputsUnplaceable: Int = 0
    public var aiOutputCitationsDropped: Int = 0
    /// Staged multipart upload bodies holding audio for a segment that exists nowhere else,
    /// written out as WAV under `Documents/PebbleAudioExports/recovered/`.
    public var uploadBodiesExported: Int = 0
    public var uploadBodyAudioMs: Int64 = 0

    public var elapsedMs: Int64 = 0

    public init() {}
}

public enum LegacyImportOutcome: Equatable, Sendable {
    /// This run performed (or resumed) the migration.
    case completed(LegacyImportStats)
    /// The marker said the migration already finished; nothing was touched.
    case alreadyComplete(LegacyImportStats)

    public var stats: LegacyImportStats {
        switch self {
        case .completed(let stats), .alreadyComplete(let stats): return stats
        }
    }
}

/// `migration_state.json` in the container root: records which phases completed so a partial
/// failure resumes safely. Every phase is independently idempotent, so a stale marker only
/// means idempotent work is redone — never data loss.
struct MigrationState: Codable, Equatable {
    static let currentVersion = 2

    var version: Int = MigrationState.currentVersion
    var segmentsDone = false
    var databaseDone = false
    var settingsDone = false
    /// v2 phases (see the file header). Absent from a v1 marker, hence the lenient decode.
    var terminalTasksDone = false
    var quarantineDone = false
    var aiOutputsDone = false
    var completedAtMs: Int64?
    var stats: LegacyImportStats?

    var isComplete: Bool {
        segmentsDone && databaseDone && settingsDone
            && terminalTasksDone && quarantineDone && aiOutputsDone
    }

    /// Brings an older marker up to `currentVersion` WITHOUT discarding the work it records.
    ///
    /// This matters concretely: Roger's phone already finished the v1 migration (438 segments,
    /// 20 conversations, 331 transcripts, both API keys in the Keychain). Resetting to a blank
    /// state would re-run the segment normalization and the whole database bootstrap on an
    /// already-migrated container — idempotent, but minutes of pointless work and a stats
    /// record that lies about what this run did. Carrying the finished flags forward means a
    /// new phase is exactly that: new work, on a live container, with nothing to wipe.
    mutating func upgradedToCurrentVersion() {
        guard version < MigrationState.currentVersion else { return }
        version = MigrationState.currentVersion
        // v1 knew nothing about the v2 phases, so they are simply outstanding.
    }

    // Lenient decode: a v1 marker has no `terminalTasksDone`/`quarantineDone`/`aiOutputsDone`
    // keys, and synthesized Codable would reject it — which would silently degrade into "no
    // marker at all" and re-run every phase.
    private enum CodingKeys: String, CodingKey {
        case version, segmentsDone, databaseDone, settingsDone
        case terminalTasksDone, quarantineDone, aiOutputsDone
        case completedAtMs, stats
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        segmentsDone = try c.decodeIfPresent(Bool.self, forKey: .segmentsDone) ?? false
        databaseDone = try c.decodeIfPresent(Bool.self, forKey: .databaseDone) ?? false
        settingsDone = try c.decodeIfPresent(Bool.self, forKey: .settingsDone) ?? false
        terminalTasksDone = try c.decodeIfPresent(Bool.self, forKey: .terminalTasksDone) ?? false
        quarantineDone = try c.decodeIfPresent(Bool.self, forKey: .quarantineDone) ?? false
        aiOutputsDone = try c.decodeIfPresent(Bool.self, forKey: .aiOutputsDone) ?? false
        completedAtMs = try c.decodeIfPresent(Int64.self, forKey: .completedAtMs)
        stats = try c.decodeIfPresent(LegacyImportStats.self, forKey: .stats)
    }
}

/// The first-launch importer. Safe to call on every launch: the `migration_state.json` marker
/// short-circuits completed runs, and each phase is idempotent so an interrupted run resumes.
///
/// `UserDefaults` is documented thread-safe; the remaining stored properties are value types
/// or Sendable, hence the @unchecked conformance.
public struct LegacyImporter: @unchecked Sendable {
    public static let markerFileName = "migration_state.json"

    /// Clock-skew tolerance for a segment whose anchored start lands AFTER its receive time.
    /// Observed watch-vs-phone skew in the real container is ~1 s; 60 s is generous.
    public static let futureToleranceMs: Int64 = 60_000
    /// How far BEFORE its receive time a segment's anchored start may plausibly land. Received
    /// audio can genuinely predate receipt by the spool backlog drained after a reconnect —
    /// the worst case observed in the real container is ~10 minutes — but never by hours.
    public static let pastToleranceMs: Int64 = 60 * 60_000

    private let containerRoot: URL
    /// Where `Documents/PebbleAudioExports` lives. Injected so tests never write into the
    /// developer's real Documents folder; nil resolves the app's own Documents directory.
    private let documentsRoot: URL?
    private let database: AppDatabase
    private let oldDefaults: UserDefaults
    private let newDefaults: UserDefaults
    private let keychain: MigrationKeychain
    private let timeZoneID: String
    private let nowMs: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void

    /// The old KMP container root: `<Application Support>/audio-companion`
    /// (`IosAudioCompanionRuntimeFactory.defaultFilesRoot()` + `"audio-companion"`).
    public static func defaultContainerRoot() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("audio-companion", isDirectory: true)
    }

    public init(
        containerRoot: URL,
        database: AppDatabase,
        documentsRoot: URL? = nil,
        oldDefaults: UserDefaults = .standard,
        newDefaults: UserDefaults =
            UserDefaults(suiteName: MigratedSettingsKeys.appGroupSuite) ?? .standard,
        keychain: MigrationKeychain = MigrationKeychain(),
        timeZoneID: String = TimeZone.current.identifier,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.containerRoot = containerRoot
        self.documentsRoot = documentsRoot
        self.database = database
        self.oldDefaults = oldDefaults
        self.newDefaults = newDefaults
        self.keychain = keychain
        self.timeZoneID = timeZoneID
        self.nowMs = nowMs
        self.log = log
    }

    // MARK: - Run

    public func run() async throws -> LegacyImportOutcome {
        let startedAt = nowMs()
        var state = readState() ?? MigrationState()
        if state.version > MigrationState.currentVersion {
            // A newer app already migrated past us; never rewind its work.
            return .alreadyComplete(state.stats ?? LegacyImportStats())
        }
        state.upgradedToCurrentVersion()
        if state.isComplete {
            return .alreadyComplete(state.stats ?? LegacyImportStats())
        }

        var stats = state.stats ?? LegacyImportStats()

        // ── Phase 1: segments — normalize sidecars, then store recovery ─────
        // Normalization runs on the raw files BEFORE the store builds its index so recovery
        // reconciles against the corrected anchors. On a resumed run the normalize pass is
        // skipped (already done), but recovery always runs: it is idempotent and later phases
        // read through the store's index.
        if !state.segmentsDone {
            let normalized = try normalizeSidecars()
            stats.startTimesClamped = normalized.clamped
            stats.timeZonesBackfilled = normalized.backfilled
        }
        let store = SegmentStore(root: containerRoot, nowMs: nowMs, log: log)
        try await store.recover()
        if !state.segmentsDone {
            stats.segmentsIndexed = await store.listSegments().count
            state.segmentsDone = true
            state.stats = stats
            try writeState(state)
        }

        // ── Phase 2: transcripts + DB bootstrap ─────────────────────────────
        if !state.databaseDone {
            let transcripts = verifyTranscripts()
            stats.transcriptsVerified = transcripts.readable.count
            stats.transcriptsUnreadable = transcripts.unreadable

            let queued = try await seedTranscriptionQueue(
                store: store, readableTranscripts: transcripts.readable)
            stats.completeMissingTranscriptRequeued = queued.requeued
            stats.tasksEnqueued = queued.enqueued

            let metas = await store.listSegments()
            let grouped = try await ConversationGrouper.rebuild(
                segments: metas, pauses: [], openSegmentId: nil,
                fallbackTimeZoneID: timeZoneID, db: database)
            stats.conversationsFormed = grouped.count

            state.databaseDone = true
            state.stats = stats
            try writeState(state)
        }

        // ── Phase 3: identity + settings ────────────────────────────────────
        if !state.settingsDone {
            let identity = migrateIdentityAndSettings()
            stats.receiverIdMigrated = identity.receiverIdMigrated
            stats.settingsKeysMigrated = identity.migratedKeys
            state.settingsDone = true
            state.stats = stats
            try writeState(state)
        }

        // ── Phase 4 (v2): recover orphan audio from quarantine/ ─────────────
        if !state.quarantineDone {
            let recovered = try await recoverQuarantinedAudio(store: store)
            stats.quarantineRecovered = recovered.recovered
            stats.quarantineSidecarsRestored = recovered.sidecarsRestored
            stats.quarantineAlreadyTranscribed = recovered.alreadyTranscribed
            stats.quarantineQueuedForTranscription = recovered.queued
            stats.quarantineFramesRecovered = recovered.frames
            stats.quarantineAudioMs = recovered.audioMs
            stats.quarantineSkippedMalformed = recovered.skippedMalformed
            stats.quarantineSkippedUnreadable = recovered.skippedUnreadable
            let bodies = exportOrphanUploadBodies(store: store)
            stats.uploadBodiesExported = bodies.exported
            stats.uploadBodyAudioMs = bodies.audioMs
            if recovered.recovered > 0 {
                // The recovered segments have to become conversations before the outputs phase
                // maps old segment ids onto them.
                let metas = await store.listSegments()
                stats.conversationsFormed = try await ConversationGrouper.rebuild(
                    segments: metas, pauses: [], openSegmentId: nil,
                    fallbackTimeZoneID: timeZoneID, db: database
                ).count
            }
            state.quarantineDone = true
            state.stats = stats
            try writeState(state)
        }

        // ── Phase 5 (v2): terminal queue rows for already-transcribed audio ──
        // AFTER quarantine recovery, so a recovered segment that already had a transcript gets
        // its terminal row in the same run instead of reading as "waiting to transcribe".
        if !state.terminalTasksDone {
            stats.terminalTasksBackfilled = try await backfillTerminalTasks(store: store)
            state.terminalTasksDone = true
            state.stats = stats
            try writeState(state)
        }

        // ── Phase 6 (v2): ai/outputs — the only AI artifacts that never regenerate ──
        if !state.aiOutputsDone {
            let outputs = try await importAiOutputs()
            stats.askEntriesImported = outputs.askImported
            stats.notesImported = outputs.notesImported
            stats.aiOutputsUnplaceable = outputs.notesUnplaceable
            stats.aiOutputCitationsDropped = outputs.citationsDropped
            state.aiOutputsDone = true
            state.stats = stats
            try writeState(state)
        }

        stats.elapsedMs = nowMs() - startedAt
        state.stats = stats
        state.completedAtMs = nowMs()
        try writeState(state)
        log("audio-companion: migration complete — \(stats.segmentsIndexed) segments, "
            + "\(stats.conversationsFormed) conversations, \(stats.tasksEnqueued) tasks queued")
        if stats.quarantineRecovered > 0 {
            // Loud on purpose: this is audio the user thought was gone, it is exempt from the
            // retention age sweep, and most of it still has to be transcribed — which costs
            // money on a cloud provider. None of that should be a surprise found later.
            log("audio-companion: migration recovered \(stats.quarantineRecovered) orphan "
                + "segments from quarantine (\(stats.quarantineAudioMs / 60_000) min of audio); "
                + "\(stats.quarantineAlreadyTranscribed) already had transcripts, "
                + "\(stats.quarantineQueuedForTranscription) queued for transcription behind "
                + "the existing backlog; recovered audio is exempt from the retention age sweep")
        }
        if stats.askEntriesImported > 0 || stats.notesImported > 0 {
            log("audio-companion: migration imported \(stats.askEntriesImported) past Ask "
                + "answers and \(stats.notesImported) notes from ai/outputs "
                + "(\(stats.aiOutputCitationsDropped) unresolvable citations dropped)")
        }
        return .completed(stats)
    }

    // MARK: - Phase 1: sidecar normalization

    /// The wall-clock invariant (implied by `ConversationGrouper.segmentStartMs`): `startTimeMs`
    /// anchors sample index 0, so the segment's first persisted sample maps to
    /// `startTimeMs + firstSampleIndex·1000/rate`. Audio cannot be received before it is
    /// recorded, so that anchored start must not land after `receivedAtMs` (beyond clock skew),
    /// and the watch's bounded spool means received audio never predates receipt by hours.
    ///
    /// Pre-1e5db02 data violates this in one direction: a RESUME re-announcement carried a
    /// freshly recomputed `startTimeMs` (≈ send time) while the frames kept their stream-birth
    /// sample indexes, pushing the anchored start HOURS into the future. (Rotation successors
    /// with the true stream-birth `startTimeMs` are fine — their large `firstSampleIndex`
    /// anchors them correctly, which is why the clamp must test the ANCHORED start, not the
    /// raw field: clamping raw `startTimeMs` toward `receivedAtMs` would break every healthy
    /// rotation successor.)
    ///
    /// Clamp rule: when the anchored start is more than `futureToleranceMs` after or more than
    /// `pastToleranceMs` before `receivedAtMs`, re-anchor so the anchored start equals
    /// `receivedAtMs` exactly (`startTimeMs = receivedAtMs − firstSampleIndex·1000/rate`).
    /// This preserves all intra-segment relative timing (durations, gap offsets, transcript
    /// offsets) and matches what the fixed store writes for resume-minted segments.
    ///
    /// Returns the corrected value, or nil when the meta already satisfies the invariant.
    public static func clampedStartTimeMs(_ meta: SegmentMeta) -> UInt64? {
        let rate = meta.sampleRateHz > 0 ? UInt64(meta.sampleRateHz) : 16_000
        let offset = Int64((meta.firstSampleIndex ?? 0) * 1000 / rate)
        let anchored = Int64(clamping: meta.startTimeMs) + offset
        let received = meta.receivedAtMs
        guard anchored > received + futureToleranceMs || anchored < received - pastToleranceMs
        else { return nil }
        return UInt64(max(received - offset, 0))
    }

    private func normalizeSidecars() throws -> (clamped: Int, backfilled: Int) {
        let segmentsDir = containerRoot.appendingPathComponent("segments", isDirectory: true)
        guard FileManager.default.fileExists(atPath: segmentsDir.path) else { return (0, 0) }
        let entries = try FileManager.default.contentsOfDirectory(
            at: segmentsDir, includingPropertiesForKeys: nil)
        var clamped = 0
        var backfilled = 0
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.lastPathComponent.hasSuffix(SegmentStore.metaSuffix) {
            guard let data = try? Data(contentsOf: url),
                var meta = try? JSONDecoder().decode(SegmentMeta.self, from: data)
            else {
                // Undecodable sidecar: leave it; recover() quarantines the matching log.
                log("audio-companion: migration skipping unreadable sidecar \(url.lastPathComponent)")
                continue
            }
            var changed = false
            if let corrected = Self.clampedStartTimeMs(meta) {
                log("audio-companion: migration re-anchoring \(meta.segmentId) startTimeMs "
                    + "\(meta.startTimeMs) -> \(corrected) (receivedAtMs \(meta.receivedAtMs))")
                meta.startTimeMs = corrected
                clamped += 1
                changed = true
            }
            if meta.recordedTimeZone == nil {
                // Part 6.4: imported segments predate the field; the device's current zone is
                // an acknowledged approximation.
                meta.recordedTimeZone = timeZoneID
                backfilled += 1
                changed = true
            }
            if changed {
                try writeMetaAtomically(meta, in: segmentsDir)
            }
        }
        return (clamped, backfilled)
    }

    /// Same pattern as `SegmentStore.writeMetaAtomically` (temp file + POSIX rename, pretty
    /// + sorted keys); the store's writer is private and this runs before the store exists.
    /// A crash mid-write leaves a `.tmp` that `recover()` sweeps.
    private func writeMetaAtomically(_ meta: SegmentMeta, in segmentsDir: URL) throws {
        let final = segmentsDir.appendingPathComponent("\(meta.segmentId)\(SegmentStore.metaSuffix)")
        let tmp = segmentsDir.appendingPathComponent("\(meta.segmentId)\(SegmentStore.metaSuffix).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: tmp)
        try atomicMove(from: tmp, to: final)
    }

    // MARK: - Phase 2: transcripts + queue + conversations

    /// Verifies every `*.transcript.json` parses with `FileTranscriptStore`'s codable; files
    /// stay in place either way (they are the durable store — an unreadable one is only
    /// counted, so its segment falls into the requeue path below).
    private func verifyTranscripts() -> (readable: Set<String>, unreadable: Int) {
        let transcriptsDir =
            containerRoot
            .appendingPathComponent("transcription", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let store = FileTranscriptStore(root: containerRoot, nowMs: nowMs)
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: transcriptsDir, includingPropertiesForKeys: nil)) ?? []
        var readable: Set<String> = []
        var unreadable = 0
        for url in entries where url.lastPathComponent.hasSuffix(FileTranscriptStore.suffix) {
            let segmentId = String(
                url.lastPathComponent.dropLast(FileTranscriptStore.suffix.count))
            if store.load(segmentId) != nil {
                readable.insert(segmentId)
            } else {
                unreadable += 1
                log("audio-companion: migration found unreadable transcript for \(segmentId)")
            }
        }
        return (readable, unreadable)
    }

    /// Seeds `transcription_tasks` from the recovered metas (all closed after `recover()`).
    /// Mirrors the runtime contract (`TranscriptionProcessor.enqueueClosedSegments` is only
    /// fed closed, not-fully-transcribed segments — terminal-success segments get no row):
    ///
    ///  - Complete WITH a readable transcript, or NoSpeech: terminal success, no row.
    ///  - Complete WITHOUT a transcript: the durable artifact is missing — requeue (meta back
    ///    to Pending + a Pending row).
    ///  - Everything else (Pending / Failed / Disabled, and Running / Uploading orphaned by
    ///    the old app's death): a Pending row; the meta is normalized to Pending so the files
    ///    and the queue stay coherent (old failure/disabled verdicts came from the old app's
    ///    providers and are stale).
    private func seedTranscriptionQueue(
        store: SegmentStore, readableTranscripts: Set<String>
    ) async throws -> (requeued: Int, enqueued: Int) {
        let queue = TranscriptionQueue(database: database, nowMs: nowMs)
        var requeued = 0
        var enqueued = 0
        for meta in await store.listSegments() {
            switch meta.transcriptionState {
            case .complete where readableTranscripts.contains(meta.segmentId):
                continue
            case .noSpeech:
                continue
            case .complete:
                try await store.updateTranscriptionState(meta.segmentId, .pending)
                _ = try queue.enqueue(meta.segmentId)
                requeued += 1
                enqueued += 1
            case .pending, .running, .uploading, .failed, .disabled:
                if meta.transcriptionState != .pending {
                    try await store.updateTranscriptionState(meta.segmentId, .pending)
                }
                _ = try queue.enqueue(meta.segmentId)
                enqueued += 1
            }
        }
        return (requeued, enqueued)
    }

    // MARK: - Phase 5: terminal queue rows

    /// Writes the `transcription_tasks` row a terminal-success segment would have had if it had
    /// been transcribed by THIS app instead of arriving already done.
    ///
    /// Phase 2 deliberately creates no row for those segments (nothing needs doing), and that
    /// looked harmless — but the Library reads member state through
    /// `LEFT JOIN transcription_tasks`, and `aggregateLifecycle` counts a missing row as
    /// Pending. The result on a migrated library is every finished conversation showing
    /// "Captured · waiting to transcribe" with a Transcribe now button, forever, above its own
    /// complete transcript; the "Untranscribed" filter matches everything; and the conversation
    /// Details pane shows no provider or model. A Complete/NoSpeech row — carrying the
    /// transcript's own mode/provider/model, so provenance is real and not asserted — is exactly
    /// the state `TranscriptionProcessor` leaves behind, and costs one insert per segment.
    ///
    /// Idempotent: only segments with NO row are touched, so the untranscribed backlog phase 2
    /// queued is never disturbed.
    private func backfillTerminalTasks(store: SegmentStore) async throws -> Int {
        let queue = TranscriptionQueue(database: database, nowMs: nowMs)
        let transcripts = FileTranscriptStore(root: containerRoot, nowMs: nowMs)
        var backfilled = 0
        for meta in await store.listSegments() {
            guard meta.isFullyTranscribed, try queue.load(meta.segmentId) == nil else { continue }
            if meta.transcriptionState == .complete {
                guard let transcript = transcripts.load(meta.segmentId) else {
                    // Complete but no readable transcript: phase 2 already requeued it.
                    continue
                }
                _ = try queue.enqueue(meta.segmentId)
                _ = try queue.markComplete(
                    meta.segmentId,
                    result: RoutedTranscription(
                        text: transcript.text,
                        modeUsed: transcript.modeUsed,
                        providerId: transcript.providerId,
                        modelUsed: transcript.modelUsed
                    ))
            } else {
                _ = try queue.enqueue(meta.segmentId)
                _ = try queue.markNoSpeech(meta.segmentId)
            }
            backfilled += 1
        }
        return backfilled
    }

    // MARK: - Phase 4: quarantine recovery

    struct QuarantineRecoveryResult {
        var recovered = 0
        var sidecarsRestored = 0
        var alreadyTranscribed = 0
        var queued = 0
        var frames: Int64 = 0
        var audioMs: Int64 = 0
        var skippedMalformed = 0
        var skippedUnreadable = 0
    }

    /// Restores orphan `.spxlog` files from `quarantine/` into `segments/`.
    ///
    /// Order per file is deliberate: the LOG moves first, then its sidecar is written. A crash
    /// in between leaves an orphan log in `segments/`, which the next `recover()` sweeps back to
    /// `quarantine/` — the state we started from — so the phase is safe to interrupt and safe to
    /// re-run. The reverse order would leave a sidecar with no audio, which the store's index
    /// would happily serve as a segment.
    ///
    /// Ids are preserved exactly. They are the key transcripts are filed under, so a segment
    /// restored under its own id immediately reunites with a transcript that already exists —
    /// minting fresh ids would orphan that work and re-bill the cloud provider for it.
    private func recoverQuarantinedAudio(
        store: SegmentStore
    ) async throws -> QuarantineRecoveryResult {
        var result = QuarantineRecoveryResult()
        let quarantineDir = containerRoot.appendingPathComponent("quarantine", isDirectory: true)
        guard FileManager.default.fileExists(atPath: quarantineDir.path) else { return result }
        let segmentsDir = containerRoot.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)

        let entries = try FileManager.default.contentsOfDirectory(
            at: quarantineDir, includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        let codec = codecTemplate(store: store)
        let readableTranscripts = verifyTranscripts().readable
        let queue = TranscriptionQueue(database: database, nowMs: nowMs)
        var recoveredIds: [String] = []

        for url in entries {
            let name = url.lastPathComponent
            guard name.hasSuffix(SegmentStore.logSuffix) else {
                // Sidecars are consumed alongside their log below; anything else in here is a
                // truncated name from an interrupted copy (`.spxlo`, `.meta.j`) or a stray file.
                // Guessing what a truncated name meant is not recovery, it is invention.
                if !name.hasSuffix(SegmentStore.metaSuffix) { result.skippedMalformed += 1 }
                continue
            }
            let segmentId = String(name.dropLast(SegmentStore.logSuffix.count))
            guard let parsedId = ParsedSegmentId.parse(segmentId) else {
                result.skippedMalformed += 1
                continue
            }
            let destination = segmentsDir.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                continue  // already recovered by an earlier run
            }
            guard let data = try? Data(contentsOf: url),
                let scan = QuarantineFrameLog.scan(data, frameSamplesHint: codec.frameSamples)
            else {
                result.skippedUnreadable += 1
                continue
            }

            try atomicMove(from: url, to: destination)

            let quarantinedSidecar = quarantineDir.appendingPathComponent(
                "\(segmentId)\(SegmentStore.metaSuffix)")
            let transcribed = readableTranscripts.contains(segmentId)
            var meta: SegmentMeta
            if let sidecarData = try? Data(contentsOf: quarantinedSidecar),
                let stored = try? JSONDecoder().decode(SegmentMeta.self, from: sidecarData)
            {
                meta = QuarantineRecovery.adoptMeta(
                    stored, scan: scan, transcribed: transcribed,
                    timeZoneID: timeZoneID, nowMs: nowMs())
                result.sidecarsRestored += 1
            } else {
                meta = QuarantineRecovery.reconstructMeta(
                    segmentId: segmentId, parsedId: parsedId, scan: scan, codec: codec,
                    transcribed: transcribed, timeZoneID: timeZoneID, nowMs: nowMs())
            }
            // A restored sidecar can carry the pre-1e5db02 anchor bug that phase 1 clamps on
            // every other segment; three of the real container's do. Phase 1 has already run by
            // the time this audio exists, so the clamp is applied here instead of leaving those
            // segments filed hours into the future. Reconstructed metas satisfy it by
            // construction, so this is a no-op for them.
            if let corrected = Self.clampedStartTimeMs(meta) {
                log("audio-companion: migration re-anchoring recovered \(segmentId) startTimeMs "
                    + "\(meta.startTimeMs) -> \(corrected)")
                meta.startTimeMs = corrected
            }
            try writeMetaAtomically(meta, in: segmentsDir)
            try? FileManager.default.removeItem(at: quarantinedSidecar)

            result.recovered += 1
            result.frames += Int64(scan.frameCount)
            let rate = Int64(meta.sampleRateHz > 0 ? meta.sampleRateHz : 16_000)
            result.audioMs += Int64(scan.frameCount) * Int64(meta.frameSamples) * 1000 / rate
            if transcribed {
                result.alreadyTranscribed += 1
            } else {
                recoveredIds.append(segmentId)
            }
            log("audio-companion: migration recovered \(segmentId) from quarantine "
                + "(\(scan.frameCount) frames, \(scan.holes.count) unrecorded holes"
                + (transcribed ? ", transcript already on disk)" : ")"))
        }

        guard result.recovered > 0 else { return result }

        // Re-index so later phases (and the app) see the restored segments. Reconstructed metas
        // already agree with their logs, so this is an index rebuild, not a re-parse.
        try await store.recover()

        // Queued LAST and with a fresh timestamp, so the newest audio the user is actually
        // waiting on keeps its place at the head of the queue (`nextRunnable` orders by
        // createdAtMs) and the recovered backlog drains behind it. It shows up as an ordinary,
        // visible backlog — the queue counters in Diagnostics and the honest
        // "Captured · waiting to transcribe" rows — rather than as silent spend.
        let recoveredMetas = await store.listSegments()
            .reduce(into: [String: Int64]()) { $0[$1.segmentId] = $1.receivedAtMs }
        for segmentId in recoveredIds {
            // Stamped with the age of the audio, not of this run: `nextRunnable` takes the
            // NEWEST pending task, so months-old recovered audio drains behind everything the
            // user is actually waiting on rather than displacing it.
            _ = try queue.enqueue(segmentId, createdAtMs: recoveredMetas[segmentId])
            result.queued += 1
        }
        return result
    }

    /// Codec fields copied from a healthy sidecar (they are identical for every segment this
    /// product records); falls back to the Speex wideband configuration the firmware streams.
    private func codecTemplate(store: SegmentStore) -> CodecTemplate {
        let reader = SegmentFileReader(root: containerRoot)
        guard let sample = reader.listSegments().first(where: { $0.frameSamples > 0 }) else {
            return CodecTemplate()
        }
        return CodecTemplate(sample)
    }

    // MARK: - Phase 4b: staged upload bodies

    /// `upload-bodies/*.body` are multipart form bodies staged for a cloud transcription upload.
    /// Their audio is decoded PCM, not Speex frames, so it cannot become a segment: the store's
    /// durable unit is the frame log, and re-encoding phone-side would fabricate wire records
    /// that never existed. Where the body is the ONLY surviving copy of a segment's audio, the
    /// WAV is written out under `Documents/PebbleAudioExports/recovered/` so it is at least
    /// playable and shareable through Files, and reported rather than quietly discarded.
    private func exportOrphanUploadBodies(store: SegmentStore) -> (exported: Int, audioMs: Int64) {
        let bodiesDir = containerRoot.appendingPathComponent("upload-bodies", isDirectory: true)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: bodiesDir, includingPropertiesForKeys: nil)
        else { return (0, 0) }
        let segmentsDir = containerRoot.appendingPathComponent("segments", isDirectory: true)
        var exported = 0
        var audioMs: Int64 = 0
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "body" {
            let segmentId = url.deletingPathExtension().lastPathComponent
            let logPath = segmentsDir.appendingPathComponent(
                "\(segmentId)\(SegmentStore.logSuffix)"
            ).path
            guard !FileManager.default.fileExists(atPath: logPath) else { continue }
            guard let data = try? Data(contentsOf: url),
                let wav = Self.wavPayload(ofMultipartBody: data)
            else { continue }
            guard let destination = recoveredExportURL(segmentId: segmentId) else { continue }
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            do {
                try wav.data.write(to: destination)
                exported += 1
                audioMs += wav.durationMs
                log("audio-companion: migration exported \(segmentId) from a staged upload body "
                    + "(\(wav.durationMs / 1000) s of audio) to \(destination.lastPathComponent)"
                    + " — no frame log survives for it, so it cannot rejoin the library")
            } catch {
                log("audio-companion: migration could not write recovered WAV for \(segmentId)")
            }
        }
        return (exported, audioMs)
    }

    private func recoveredExportURL(segmentId: String) -> URL? {
        let resolved =
            documentsRoot
            ?? (try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        guard let documents = resolved else { return nil }
        let dir =
            documents
            .appendingPathComponent("PebbleAudioExports", isDirectory: true)
            .appendingPathComponent("recovered", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true))
            != nil
        else { return nil }
        return dir.appendingPathComponent("\(segmentId).wav")
    }

    /// Slices the `audio/wav` part out of a multipart body: the RIFF header through the end of
    /// its declared `data` chunk. Returns nil when the body holds no readable WAV.
    static func wavPayload(ofMultipartBody data: Data) -> (data: Data, durationMs: Int64)? {
        let bytes = [UInt8](data)
        let riff: [UInt8] = Array("RIFF".utf8)
        guard let start = firstIndex(of: riff, in: bytes), start + 44 <= bytes.count else {
            return nil
        }
        func u16(_ offset: Int) -> Int {
            Int(UInt16(bytes[start + offset]) | UInt16(bytes[start + offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(bytes[start + offset + $1]) << (8 * $1) }
        }
        let channels = max(u16(22), 1)
        let sampleRate = max(u32(24), 1)
        let bitsPerSample = max(u16(34), 8)
        let dataBytes = u32(40)
        let end = min(start + 44 + dataBytes, bytes.count)
        guard end > start + 44 else { return nil }
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let durationMs = Int64((end - start - 44) * 1000 / max(byteRate, 1))
        return (Data(bytes[start..<end]), durationMs)
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        // The WAV part sits within the first few hundred bytes of headers; bound the search.
        let limit = min(haystack.count - needle.count, 64 * 1024)
        for index in 0...max(limit, 0)
        where Array(haystack[index..<index + needle.count]) == needle {
            return index
        }
        return nil
    }

    // MARK: - Phase 6: ai/outputs

    /// Imports `ai/outputs/*.ai.json` — the only AI artifacts that never regenerate, because a
    /// person asked for each one. See `LegacyAiOutputs.swift` for the shape and the reasoning.
    private func importAiOutputs() async throws -> LegacyAiOutputStats {
        var stats = LegacyAiOutputStats()
        let dir =
            containerRoot
            .appendingPathComponent("ai", isDirectory: true)
            .appendingPathComponent("outputs", isDirectory: true)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return stats }

        // Old segment id → the conversation it now belongs to. Citations and note placement both
        // resolve through this; a segment that did not survive simply is not in it.
        let conversationBySegment: [String: String] = try await database.reader.read { db in
            var map: [String: String] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT segmentId, conversationId FROM conversation_segments")
            {
                map[row["segmentId"]] = row["conversationId"]
            }
            return map
        }
        let resolvable = Set(conversationBySegment.keys)

        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.lastPathComponent.hasSuffix(".ai.json") {
            stats.filesSeen += 1
            guard let data = try? Data(contentsOf: url),
                let output = try? JSONDecoder().decode(LegacyAiOutput.self, from: data)
            else {
                stats.filesUnreadable += 1
                log("audio-companion: migration skipping unreadable AI output "
                    + url.lastPathComponent)
                continue
            }
            let text = output.trimmedText
            guard !text.isEmpty else { continue }

            let allCited = parseGroundedAnswer(text, sourceIds: output.scope).citedSegmentIds
            let citations = LegacyAiOutputImport.citations(
                answerText: text, scopeSegmentIds: output.scope, resolvable: resolvable)
            stats.citationsDropped += allCited.count - citations.count
            let createdAtMs = output.createdAtMs ?? nowMs()
            let rowId = LegacyAiOutputImport.rowId(output.outputId)

            if output.isAsk {
                if try await insertAskEntry(
                    id: rowId, answerText: text, citations: citations, createdAtMs: createdAtMs)
                {
                    stats.askImported += 1
                } else {
                    stats.alreadyPresent += 1
                }
                continue
            }

            guard
                let placement = LegacyAiOutputImport.dominantConversation(
                    scopeSegmentIds: output.scope,
                    conversationBySegment: conversationBySegment)
            else {
                // Every segment this ran over is gone, so there is no conversation it could
                // honestly hang from. Dropping beats inventing a home for it.
                stats.notesUnplaceable += 1
                log("audio-companion: migration cannot place AI output \(output.outputId) — "
                    + "none of its \(output.scope.count) source segments survive")
                continue
            }
            if try await insertNote(
                id: rowId, conversationId: placement.conversationId,
                templateId: output.promptTemplateId ?? "imported",
                title: LegacyAiOutputImport.noteTitle(
                    output, conversationCount: placement.conversationCount),
                body: text, citations: citations, provider: output.providerId,
                model: output.modelUsed, createdAtMs: createdAtMs, editedAtMs: output.editedAtMs)
            {
                stats.notesImported += 1
            } else {
                stats.alreadyPresent += 1
            }
        }

        if stats.askImported > 0 { try await trimAskHistory() }
        return stats
    }

    /// Returns true when a row was inserted (false = already there, so a re-run adds nothing).
    private func insertAskEntry(
        id: String, answerText: String, citations: [AskCitation], createdAtMs: Int64
    ) async throws -> Bool {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO ask_history
                        (id, threadId, question, answerText, citations, scopeDescription,
                         createdAtMs)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                // The legacy app had no threading, so each imported answer is a thread of one.
                arguments: [
                    id, id, LegacyAiOutputImport.missingQuestionText, answerText,
                    LegacyAiOutputImport.citationsJson(citations),
                    LegacyAiOutputImport.importedScopeDescription, createdAtMs,
                ]
            )
            return db.changesCount > 0
        }
    }

    private func insertNote(
        id: String, conversationId: String, templateId: String, title: String, body: String,
        citations: [AskCitation], provider: String?, model: String?, createdAtMs: Int64,
        editedAtMs: Int64?
    ) async throws -> Bool {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO notes
                        (id, conversationId, templateId, title, body, citations, provider,
                         model, createdAtMs, editedAtMs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id, conversationId, templateId, title, body,
                    LegacyAiOutputImport.citationsJson(citations), provider, model,
                    createdAtMs, editedAtMs,
                ]
            )
            return db.changesCount > 0
        }
    }

    /// `AskHistoryStore` keeps exactly the newest `maxEntries` (Q18); the import honors the same
    /// invariant instead of leaving the table over its cap for the next save to discover.
    private func trimAskHistory() async throws {
        try await database.writer.write { db in
            try db.execute(
                // Trims whole threads, matching AskHistoryStore.save.
                sql: """
                    DELETE FROM ask_history WHERE threadId NOT IN
                        (SELECT threadId FROM ask_history
                         GROUP BY threadId
                         ORDER BY MAX(createdAtMs) DESC, MAX(rowid) DESC LIMIT ?)
                    """,
                arguments: [AskHistoryStore.maxEntries]
            )
        }
    }

    // MARK: - Phase 3: identity + settings

    /// Valid raw values for the old `ai_mode` key — the constant names of
    /// `Intelligence.AiProcessingMode` (Migration cannot depend on Intelligence; change
    /// together with `AiProvider.swift`).
    private static let aiModeNames: Set<String> = [
        "LocalOnly", "RemoteOnly", "LocalFirst", "RemoteFirst",
    ]

    private func migrateIdentityAndSettings() -> (receiverIdMigrated: Bool, migratedKeys: [String]) {
        var migratedKeys: [String] = []

        // receiver_id_v1 — LOAD-BEARING. The watch stores SHA-256(receiver_id); a regenerated
        // id fails closed until a watch-side Forget Receiver. Rules: never overwrite an id the
        // Keychain already holds (first writer wins — it may be what the watch is bound to);
        // never CREATE one here (a fresh install gets its id from the receiver service);
        // remove the defaults entry only once the Keychain verifiably holds a value.
        var receiverIdMigrated = false
        if let raw = oldDefaults.string(forKey: MigratedSettingsKeys.oldReceiverId) {
            if let normalized = Self.normalizedReceiverId(raw) {
                if keychain.string(for: .receiverId) == nil {
                    _ = keychain.set(normalized, for: .receiverId)
                }
                if keychain.string(for: .receiverId) != nil {
                    oldDefaults.removeObject(forKey: MigratedSettingsKeys.oldReceiverId)
                    receiverIdMigrated = true
                    migratedKeys.append(MigratedSettingsKeys.oldReceiverId)
                } else {
                    log("audio-companion: migration could not store receiver id in Keychain; "
                        + "leaving the defaults entry in place")
                }
            } else {
                log("audio-companion: migration found malformed receiver_id_v1; leaving it")
            }
        }

        // API keys: defaults → Keychain, then DELETE the defaults entries (B13). The old app
        // persisted empty strings for unset keys — those just get their entry deleted.
        let secretPairs: [(oldKey: String, key: MigrationKeychain.Key)] = [
            (MigratedSettingsKeys.oldOpenAiApiKey, .openAiApiKey),
            (MigratedSettingsKeys.oldSonioxApiKey, .sonioxApiKey),
        ]
        for (oldKey, key) in secretPairs {
            guard let value = oldDefaults.string(forKey: oldKey) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let stored = trimmed.isEmpty || keychain.set(trimmed, for: key)
            if stored {
                oldDefaults.removeObject(forKey: oldKey)
                migratedKeys.append(oldKey)
            } else {
                log("audio-companion: migration could not store \(oldKey) in Keychain; "
                    + "leaving the defaults entry in place")
            }
        }

        // Surviving settings, old standard defaults → new app-group suite. Each key copies
        // only when the old value is present/valid AND the new suite has no value yet — a
        // resumed run must never clobber a choice the user already made in the new app.
        func copyIfAbsent(_ oldKey: String, _ newKey: String, _ read: () -> Any?) {
            guard oldDefaults.object(forKey: oldKey) != nil,
                newDefaults.object(forKey: newKey) == nil,
                let value = read()
            else { return }
            newDefaults.set(value, forKey: newKey)
            migratedKeys.append(oldKey)
        }

        // background_enabled (Bool) → capture_intent: true → active, false → off.
        copyIfAbsent(MigratedSettingsKeys.oldBackgroundEnabled, MigratedSettingsKeys.newCaptureIntent) {
            oldDefaults.bool(forKey: MigratedSettingsKeys.oldBackgroundEnabled)
                ? MigratedSettingsKeys.captureIntentActive : MigratedSettingsKeys.captureIntentOff
        }
        copyIfAbsent(MigratedSettingsKeys.oldTranscriptionMode, MigratedSettingsKeys.newTranscriptionMode) {
            oldDefaults.string(forKey: MigratedSettingsKeys.oldTranscriptionMode)
                .flatMap { TranscriptionMode(rawValue: $0)?.rawValue }
        }
        // A configured old transcription mode means the Q14 choice was already made — without
        // this the migrated user would see the "Transcripts are off" first-run card.
        if newDefaults.string(forKey: MigratedSettingsKeys.newTranscriptionMode) != nil,
            newDefaults.object(forKey: MigratedSettingsKeys.newTranscriptsConfigured) == nil {
            newDefaults.set(true, forKey: MigratedSettingsKeys.newTranscriptsConfigured)
        }
        copyIfAbsent(
            MigratedSettingsKeys.oldLocalTranscriptionModel,
            MigratedSettingsKeys.newLocalTranscriptionModel
        ) {
            oldDefaults.string(forKey: MigratedSettingsKeys.oldLocalTranscriptionModel)
        }
        copyIfAbsent(
            MigratedSettingsKeys.oldCloudTranscriptionProvider,
            MigratedSettingsKeys.newCloudTranscriptionProvider
        ) {
            oldDefaults.string(forKey: MigratedSettingsKeys.oldCloudTranscriptionProvider)
                .flatMap { CloudProvider(rawValue: $0)?.rawValue }
        }
        copyIfAbsent(MigratedSettingsKeys.oldAiMode, MigratedSettingsKeys.newAiMode) {
            oldDefaults.string(forKey: MigratedSettingsKeys.oldAiMode)
                .flatMap { Self.aiModeNames.contains($0) ? $0 : nil }
        }
        copyIfAbsent(MigratedSettingsKeys.oldAiModel, MigratedSettingsKeys.newAiModel) {
            oldDefaults.string(forKey: MigratedSettingsKeys.oldAiModel)
        }
        // Copied raw; AppSettings coerces values outside its option list to its default.
        copyIfAbsent(MigratedSettingsKeys.oldRetentionDays, MigratedSettingsKeys.newRetentionDays) {
            let days = oldDefaults.integer(forKey: MigratedSettingsKeys.oldRetentionDays)
            return days > 0 ? days : nil
        }
        copyIfAbsent(MigratedSettingsKeys.oldAutomaticWavExport, MigratedSettingsKeys.newAutomaticWavExport) {
            oldDefaults.bool(forKey: MigratedSettingsKeys.oldAutomaticWavExport)
        }
        copyIfAbsent(MigratedSettingsKeys.oldOnboardingComplete, MigratedSettingsKeys.newOnboardingComplete) {
            oldDefaults.bool(forKey: MigratedSettingsKeys.oldOnboardingComplete)
        }

        return (receiverIdMigrated, migratedKeys)
    }

    /// A valid receiver id is 32 bytes as hex (64 hex digits). The old app wrote lowercase;
    /// case is normalized here because the watch binds to SHA-256 of the BYTES.
    static func normalizedReceiverId(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        guard lowered.count == 64, lowered.allSatisfy(\.isHexDigit) else { return nil }
        return lowered
    }

    // MARK: - Marker persistence

    private var markerURL: URL {
        containerRoot.appendingPathComponent(Self.markerFileName)
    }

    private func readState() -> MigrationState? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(MigrationState.self, from: data)
    }

    private func writeState(_ state: MigrationState) throws {
        try FileManager.default.createDirectory(
            at: containerRoot, withIntermediateDirectories: true)
        let tmp = containerRoot.appendingPathComponent("\(Self.markerFileName).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: tmp)
        try atomicMove(from: tmp, to: markerURL)
    }

    /// POSIX rename: atomically replaces `to` (same semantics as the stores).
    private func atomicMove(from: URL, to: URL) throws {
        if rename(from.path, to.path) != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: to.path])
        }
    }
}
