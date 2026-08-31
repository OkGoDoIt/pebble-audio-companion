import AppDB
import Foundation
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
// Everything else in the legacy container — `queue/`, `uploads/`, `bodies/`, `quarantine/`,
// `receiver_state`, and the whole `ai/` tree — is deliberately ignored (Q19: AI artifacts
// regenerate; the old queue's state is re-derived from the segment metas). A NEW background-
// URLSession identifier is a runtime concern; nothing session-related is migrated.
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
    static let currentVersion = 1

    var version: Int = MigrationState.currentVersion
    var segmentsDone = false
    var databaseDone = false
    var settingsDone = false
    var completedAtMs: Int64?
    var stats: LegacyImportStats?

    var isComplete: Bool { segmentsDone && databaseDone && settingsDone }
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
        oldDefaults: UserDefaults = .standard,
        newDefaults: UserDefaults =
            UserDefaults(suiteName: MigratedSettingsKeys.appGroupSuite) ?? .standard,
        keychain: MigrationKeychain = MigrationKeychain(),
        timeZoneID: String = TimeZone.current.identifier,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.containerRoot = containerRoot
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
        if state.version < MigrationState.currentVersion {
            state = MigrationState()  // future versions re-run the (idempotent) phases
        }
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

        stats.elapsedMs = nowMs() - startedAt
        state.stats = stats
        state.completedAtMs = nowMs()
        try writeState(state)
        log("audio-companion: migration complete — \(stats.segmentsIndexed) segments, "
            + "\(stats.conversationsFormed) conversations, \(stats.tasksEnqueued) tasks queued")
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
