import AppDB
import Foundation
import GRDB
import SegmentStore
import Testing
import Transcription

@testable import Migration

// M8 importer behavior on a synthetic legacy container (plan Part 4.8 / 6.4).

@Suite struct LegacyImporterTests {

    // MARK: - Identity (LOAD-BEARING)

    @Test func receiverIdMovesToKeychainAndLeavesDefaults() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let id = testReceiverId()
        env.old.set(id, forKey: MigratedSettingsKeys.oldReceiverId)

        let outcome = try await env.importer().run()

        #expect(env.keychain.string(for: .receiverId) == id)
        #expect(env.old.object(forKey: MigratedSettingsKeys.oldReceiverId) == nil)
        #expect(outcome.stats.receiverIdMigrated)
    }

    @Test func freshInstallCreatesNoReceiverId() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }

        let outcome = try await env.importer().run()

        // The importer never mints an id — the receiver service does that elsewhere.
        #expect(env.keychain.string(for: .receiverId) == nil)
        #expect(!outcome.stats.receiverIdMigrated)
    }

    @Test func existingKeychainIdIsNeverOverwritten() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let existing = testReceiverId("ff")
        env.keychain.set(existing, for: .receiverId)
        env.old.set(testReceiverId("ab"), forKey: MigratedSettingsKeys.oldReceiverId)

        _ = try await env.importer().run()

        // First writer wins: the Keychain id may be what the watch is bound to.
        #expect(env.keychain.string(for: .receiverId) == existing)
        #expect(env.old.object(forKey: MigratedSettingsKeys.oldReceiverId) == nil)
    }

    @Test func malformedReceiverIdIsLeftInPlace() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        env.old.set("not-a-hex-id", forKey: MigratedSettingsKeys.oldReceiverId)

        let outcome = try await env.importer().run()

        #expect(env.keychain.string(for: .receiverId) == nil)
        #expect(env.old.string(forKey: MigratedSettingsKeys.oldReceiverId) == "not-a-hex-id")
        #expect(!outcome.stats.receiverIdMigrated)
    }

    // MARK: - Settings

    @Test func settingsMigrateIntoAppGroupSuite() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        env.old.set(true, forKey: MigratedSettingsKeys.oldBackgroundEnabled)
        env.old.set("RemoteFirst", forKey: MigratedSettingsKeys.oldTranscriptionMode)
        env.old.set("parakeet-v3", forKey: MigratedSettingsKeys.oldLocalTranscriptionModel)
        env.old.set("Soniox", forKey: MigratedSettingsKeys.oldCloudTranscriptionProvider)
        env.old.set("sk-test-value", forKey: MigratedSettingsKeys.oldOpenAiApiKey)
        env.old.set("", forKey: MigratedSettingsKeys.oldSonioxApiKey)
        env.old.set("LocalOnly", forKey: MigratedSettingsKeys.oldAiMode)
        env.old.set("gpt-5.6-luna", forKey: MigratedSettingsKeys.oldAiModel)
        env.old.set(90, forKey: MigratedSettingsKeys.oldRetentionDays)
        env.old.set(true, forKey: MigratedSettingsKeys.oldAutomaticWavExport)
        env.old.set(true, forKey: MigratedSettingsKeys.oldOnboardingComplete)

        _ = try await env.importer().run()

        // background_enabled=true maps to the tri-state's "active".
        #expect(
            env.new.string(forKey: MigratedSettingsKeys.newCaptureIntent)
                == MigratedSettingsKeys.captureIntentActive)
        #expect(env.new.string(forKey: MigratedSettingsKeys.newTranscriptionMode) == "RemoteFirst")
        // A migrated mode counts as the Q14 choice already made.
        #expect(env.new.bool(forKey: MigratedSettingsKeys.newTranscriptsConfigured))
        #expect(
            env.new.string(forKey: MigratedSettingsKeys.newLocalTranscriptionModel) == "parakeet-v3")
        #expect(
            env.new.string(forKey: MigratedSettingsKeys.newCloudTranscriptionProvider) == "Soniox")
        #expect(env.new.string(forKey: MigratedSettingsKeys.newAiMode) == "LocalOnly")
        #expect(env.new.string(forKey: MigratedSettingsKeys.newAiModel) == "gpt-5.6-luna")
        #expect(env.new.integer(forKey: MigratedSettingsKeys.newRetentionDays) == 90)
        #expect(env.new.bool(forKey: MigratedSettingsKeys.newAutomaticWavExport))
        #expect(env.new.bool(forKey: MigratedSettingsKeys.newOnboardingComplete))

        // API keys: defaults → Keychain, defaults entries DELETED. The empty Soniox key just
        // gets its entry deleted.
        #expect(env.keychain.string(for: .openAiApiKey) == "sk-test-value")
        #expect(env.old.object(forKey: MigratedSettingsKeys.oldOpenAiApiKey) == nil)
        #expect(env.keychain.string(for: .sonioxApiKey) == nil)
        #expect(env.old.object(forKey: MigratedSettingsKeys.oldSonioxApiKey) == nil)
    }

    @Test func backgroundDisabledMapsToCaptureIntentOff() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        env.old.set(false, forKey: MigratedSettingsKeys.oldBackgroundEnabled)

        _ = try await env.importer().run()

        #expect(
            env.new.string(forKey: MigratedSettingsKeys.newCaptureIntent)
                == MigratedSettingsKeys.captureIntentOff)
    }

    @Test func absentOldSettingsWriteNothing() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }

        _ = try await env.importer().run()

        #expect(env.new.object(forKey: MigratedSettingsKeys.newCaptureIntent) == nil)
        #expect(env.new.object(forKey: MigratedSettingsKeys.newTranscriptionMode) == nil)
        #expect(env.new.object(forKey: MigratedSettingsKeys.newTranscriptsConfigured) == nil)
    }

    @Test func migrationNeverClobbersValuesAlreadyInNewSuite() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        env.new.set("LocalOnly", forKey: MigratedSettingsKeys.newTranscriptionMode)
        env.old.set("RemoteFirst", forKey: MigratedSettingsKeys.oldTranscriptionMode)

        _ = try await env.importer().run()

        #expect(env.new.string(forKey: MigratedSettingsKeys.newTranscriptionMode) == "LocalOnly")
    }

    // MARK: - startTimeMs clamp (pure rule)

    private let receivedAt: Int64 = migrationTestEpochMs

    @Test func clampAnchorsStartHoursBeforeReceipt() {
        // 5 h before receipt with no sample offset: outside any plausible spool backlog.
        let meta = makeLegacyMeta(
            id: "a", startTimeMs: UInt64(receivedAt - 5 * 3_600_000), receivedAtMs: receivedAt,
            logBytes: 0)
        #expect(LegacyImporter.clampedStartTimeMs(meta) == UInt64(receivedAt))
    }

    @Test func clampLeavesHealthyRotationSuccessorAlone() {
        // Pre-fix rotation successor: stream-birth startTimeMs 15 min back, but the large
        // firstSampleIndex anchors its first sample AT receipt — clamping raw startTimeMs
        // would break it, so the rule tests the anchored start.
        let meta = makeLegacyMeta(
            id: "b", startTimeMs: UInt64(receivedAt - 900_000), receivedAtMs: receivedAt,
            firstSampleIndex: 14_400_000, logBytes: 0)  // 900 s at 16 kHz
        #expect(LegacyImporter.clampedStartTimeMs(meta) == nil)
    }

    @Test func clampReanchorsFutureAnchoredStart() {
        // The real pre-1e5db02 breakage: fresh startTimeMs (≈ receipt) with stream-relative
        // sample indexes pushes the anchored start into the future.
        let firstSample: UInt64 = 26_557_440  // ≈ 27.7 min at 16 kHz
        let offset = Int64(firstSample * 1000 / 16_000)
        let meta = makeLegacyMeta(
            id: "c", startTimeMs: UInt64(receivedAt - 1_000), receivedAtMs: receivedAt,
            firstSampleIndex: firstSample, logBytes: 0)
        #expect(LegacyImporter.clampedStartTimeMs(meta) == UInt64(receivedAt - offset))
    }

    @Test func clampToleratesSmallClockSkew() {
        let meta = makeLegacyMeta(
            id: "d", startTimeMs: UInt64(receivedAt + 157), receivedAtMs: receivedAt,
            logBytes: 0)
        #expect(LegacyImporter.clampedStartTimeMs(meta) == nil)
    }

    // MARK: - Segment normalization end to end

    @Test func importClampsAndBackfillsTimeZone() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        try writeLegacySegment(
            root: env.root, id: "seg-clamp", startTimeMs: UInt64(receivedAt - 5 * 3_600_000),
            receivedAtMs: receivedAt)
        try writeLegacySegment(
            root: env.root, id: "seg-zoned", startTimeMs: UInt64(receivedAt + 600_000 - 500),
            receivedAtMs: receivedAt + 600_000, recordedTimeZone: "Europe/Berlin")

        let outcome = try await env.importer(timeZoneID: "America/New_York").run()

        let clamped = try readMetaFile(root: env.root, id: "seg-clamp")
        #expect(clamped.startTimeMs == UInt64(receivedAt))
        #expect(clamped.recordedTimeZone == "America/New_York")
        let zoned = try readMetaFile(root: env.root, id: "seg-zoned")
        #expect(zoned.recordedTimeZone == "Europe/Berlin")  // existing zone preserved
        #expect(outcome.stats.startTimesClamped == 1)
        #expect(outcome.stats.timeZonesBackfilled == 1)
        #expect(outcome.stats.segmentsIndexed == 2)
    }

    // MARK: - Transcripts + queue

    @Test func transcriptPresenceDrivesRequeue() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let base = receivedAt
        // A: Complete with a readable transcript — terminal, no queue row.
        try writeLegacySegment(
            root: env.root, id: "seg-a", streamId: 1, startTimeMs: UInt64(base),
            receivedAtMs: base, transcriptionState: .complete)
        try writeLegacyTranscript(root: env.root, segmentId: "seg-a")
        // B: Complete but the transcript file is MISSING — requeue.
        try writeLegacySegment(
            root: env.root, id: "seg-b", streamId: 2, startTimeMs: UInt64(base + 3_600_000),
            receivedAtMs: base + 3_600_000, transcriptionState: .complete)
        // C: NoSpeech — terminal, legitimately has no transcript.
        try writeLegacySegment(
            root: env.root, id: "seg-c", streamId: 3, startTimeMs: UInt64(base + 7_200_000),
            receivedAtMs: base + 7_200_000, transcriptionState: .noSpeech)
        // D: Pending backlog.
        try writeLegacySegment(
            root: env.root, id: "seg-d", streamId: 4, startTimeMs: UInt64(base + 10_800_000),
            receivedAtMs: base + 10_800_000, transcriptionState: .pending)

        let outcome = try await env.importer().run()

        let queue = TranscriptionQueue(database: env.db, nowMs: { [now = env.now] in now })
        // A and C are finished work, so they now get TERMINAL rows rather than no row at all.
        // A missing row reads as Pending downstream, which is what made every already-
        // transcribed migrated conversation claim "Captured · waiting to transcribe" above its
        // own finished transcript.
        #expect(try queue.load("seg-a")?.state == .complete)
        #expect(try queue.load("seg-b")?.state == .pending)
        #expect(try queue.load("seg-c")?.state == .noSpeech)
        #expect(try queue.load("seg-d")?.state == .pending)
        // The requeued segment's meta went back to Pending so files and queue agree.
        #expect(try readMetaFile(root: env.root, id: "seg-b").transcriptionState == .pending)
        #expect(try readMetaFile(root: env.root, id: "seg-a").transcriptionState == .complete)
        #expect(outcome.stats.transcriptsVerified == 1)
        #expect(outcome.stats.transcriptsUnreadable == 0)
        #expect(outcome.stats.completeMissingTranscriptRequeued == 1)
        #expect(outcome.stats.tasksEnqueued == 2)
    }

    @Test func unreadableTranscriptCountsAndRequeues() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        try writeLegacySegment(
            root: env.root, id: "seg-x", startTimeMs: UInt64(receivedAt),
            receivedAtMs: receivedAt, transcriptionState: .complete)
        let dir =
            env.root
            .appendingPathComponent("transcription", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: dir.appendingPathComponent("seg-x\(FileTranscriptStore.suffix)"))

        let outcome = try await env.importer().run()

        #expect(outcome.stats.transcriptsUnreadable == 1)
        #expect(outcome.stats.completeMissingTranscriptRequeued == 1)
        let queue = TranscriptionQueue(database: env.db, nowMs: { [now = env.now] in now })
        #expect(try queue.load("seg-x")?.state == .pending)
        // The unreadable file is left in place — it is never deleted by the importer.
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("seg-x\(FileTranscriptStore.suffix)").path))
    }

    // MARK: - Conversations

    @Test func grouperPopulatesConversations() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let base = receivedAt
        // Two same-stream segments chain into one conversation; a third, hours later on
        // another stream, forms its own.
        try writeLegacySegment(
            root: env.root, id: "seg-1", streamId: 7, startTimeMs: UInt64(base),
            receivedAtMs: base, frameCount: 8, closeKind: CloseReasonMeta.kindRotated)
        try writeLegacySegment(
            root: env.root, id: "seg-2", streamId: 7, startTimeMs: UInt64(base + 200),
            receivedAtMs: base + 200, firstSampleIndex: 2_560, frameCount: 8)
        try writeLegacySegment(
            root: env.root, id: "seg-3", streamId: 9, startTimeMs: UInt64(base + 7_200_000),
            receivedAtMs: base + 7_200_000, frameCount: 8)

        let outcome = try await env.importer().run()

        #expect(outcome.stats.conversationsFormed == 2)
        let conversations = try await env.db.reader.read { try ConversationGrouper.fetchAll($0) }
        #expect(conversations.count == 2)
        #expect(conversations.first?.memberSegmentIds == ["seg-1", "seg-2"])
        #expect(conversations.last?.memberSegmentIds == ["seg-3"])
        #expect(conversations.allSatisfy { $0.endMs >= $0.startMs })
    }

    // MARK: - Idempotence + gating

    @Test func secondRunIsANoOp() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        try writeLegacySegment(
            root: env.root, id: "seg-1", startTimeMs: UInt64(receivedAt - 5 * 3_600_000),
            receivedAtMs: receivedAt, transcriptionState: .complete)
        env.old.set(testReceiverId(), forKey: MigratedSettingsKeys.oldReceiverId)
        env.old.set("LocalFirst", forKey: MigratedSettingsKeys.oldTranscriptionMode)

        let first = try await env.importer().run()
        guard case .completed(let firstStats) = first else {
            Issue.record("first run should complete")
            return
        }
        let snapshot = try fileSnapshot(env.root)

        let second = try await env.importer().run()
        #expect(second == .alreadyComplete(firstStats))
        #expect(try fileSnapshot(env.root) == snapshot)
    }

    @Test func rerunAfterLostMarkerChangesNothing() async throws {
        // Partial-failure resume relies on every phase being idempotent: rerunning the whole
        // import against already-migrated data must leave files, queue, and defaults alone.
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        try writeLegacySegment(
            root: env.root, id: "seg-1", startTimeMs: UInt64(receivedAt - 5 * 3_600_000),
            receivedAtMs: receivedAt, transcriptionState: .complete)
        try writeLegacySegment(
            root: env.root, id: "seg-2", streamId: 2, startTimeMs: UInt64(receivedAt + 3_600_000),
            receivedAtMs: receivedAt + 3_600_000, transcriptionState: .noSpeech)
        env.old.set(testReceiverId(), forKey: MigratedSettingsKeys.oldReceiverId)

        _ = try await env.importer().run()
        let markerURL = env.root.appendingPathComponent(LegacyImporter.markerFileName)
        var snapshot = try fileSnapshot(env.root)
        snapshot["/\(LegacyImporter.markerFileName)"] = nil
        let queue = TranscriptionQueue(database: env.db, nowMs: { [now = env.now] in now })
        let tasksBefore = try queue.all()
        let keychainId = env.keychain.string(for: .receiverId)
        try FileManager.default.removeItem(at: markerURL)

        let rerun = try await env.importer().run()

        guard case .completed = rerun else {
            Issue.record("rerun without marker should perform a full (idempotent) import")
            return
        }
        var after = try fileSnapshot(env.root)
        after["/\(LegacyImporter.markerFileName)"] = nil
        #expect(after == snapshot)
        #expect(try queue.all() == tasksBefore)
        #expect(env.keychain.string(for: .receiverId) == keychainId)
    }

    @Test func emptyContainerCompletesWithZeroStats() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }

        let outcome = try await env.importer().run()

        guard case .completed(let stats) = outcome else {
            Issue.record("expected completion")
            return
        }
        #expect(stats.segmentsIndexed == 0)
        #expect(stats.conversationsFormed == 0)
        #expect(stats.tasksEnqueued == 0)
    }

    // MARK: - Exports stay untouched

    @Test func importIgnoresLegacySideTreesAndExports() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        // The legacy trees the importer must not touch (Q19) plus an exports stand-in.
        let queueDir = env.root.appendingPathComponent("queue", isDirectory: true)
        let aiDir = env.root.appendingPathComponent("ai", isDirectory: true)
        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: aiDir, withIntermediateDirectories: true)
        try Data("task".utf8).write(to: queueDir.appendingPathComponent("seg-1.task.json"))
        try Data("digest".utf8).write(to: aiDir.appendingPathComponent("digest.json"))
        try writeLegacySegment(
            root: env.root, id: "seg-1", startTimeMs: UInt64(receivedAt - 500),
            receivedAtMs: receivedAt)

        _ = try await env.importer().run()

        #expect(
            try Data(contentsOf: queueDir.appendingPathComponent("seg-1.task.json"))
                == Data("task".utf8))
        #expect(
            try Data(contentsOf: aiDir.appendingPathComponent("digest.json"))
                == Data("digest".utf8))
    }
}
