import AppDB
import Foundation
import Testing

@testable import Transcription

// Port of `core/transcription/src/jvmTest/.../FileTranscriptionQueueTest.kt` — all 14 cases,
// same names. Persistence is the AppDB `transcription_tasks` table (plan Part 3 / 4.4) instead
// of task JSON files, so "a fresh instance" means a second queue over the same database, and
// the atomic-writes case asserts transactional consistency instead of temp-file hygiene.
@Suite struct QueueTests {

    private let clock = ClockBox(1_000)
    private let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func queue() -> TranscriptionQueue {
        TranscriptionQueue(database: db, nowMs: { [clock] in clock.now })
    }

    private func routed(
        _ text: String = "text",
        modeUsed: TranscriptionMode = .localOnly,
        providerId: String = "local",
        modelUsed: String? = nil
    ) -> RoutedTranscription {
        RoutedTranscription(
            text: text, modeUsed: modeUsed, providerId: providerId, modelUsed: modelUsed)
    }

    @Test func enqueueIsIdempotentAndDurable() throws {
        let q = queue()
        let task = try q.enqueue("seg-1")
        #expect(task.state == .pending)
        clock.now += 5
        #expect(try q.enqueue("seg-1") == task, "second enqueue must not reset the task")

        // Visible from a fresh instance (process restart).
        #expect(try queue().load("seg-1") == task)
    }

    @Test func lifecyclePendingRunningComplete_recordsProvenance() throws {
        let q = queue()
        try q.enqueue("seg-1")

        let running = try #require(try q.markRunning("seg-1"))
        #expect(running.state == .running)
        #expect(running.attempts == 1)

        let result = routed(
            "hello", modeUsed: .remoteOnly, providerId: "cloud", modelUsed: "model-v2")
        let complete = try #require(try q.markComplete("seg-1", result: result))
        #expect(complete.state == .complete)
        #expect(complete.modeUsed == .remoteOnly)
        #expect(complete.providerId == "cloud")
        #expect(complete.modelUsed == "model-v2")
        #expect(try q.nextRunnable() == nil)
    }

    @Test func failedRetryableTasksAreRunnable_afterBackoff_nonRetryableAreNot() throws {
        let q = queue()
        try q.enqueue("seg-1")
        try q.markRunning("seg-1")
        try q.markFailed("seg-1", error: "timeout", retryable: true)

        // Inside the backoff window the failed task is NOT runnable (no hot retry loop).
        #expect(try q.nextRunnable() == nil)
        #expect(
            try q.nextRetryAtMs() == clock.now + TranscriptionQueue.retryBackoffMs(attempts: 1))

        clock.now += TranscriptionQueue.retryBackoffMs(attempts: 1)
        #expect(try q.nextRunnable()?.segmentId == "seg-1")

        try q.markRunning("seg-1")
        try q.markFailed("seg-1", error: "decode error", retryable: false)
        clock.now += TranscriptionQueue.retryBackoffMs(attempts: 2)
        #expect(try q.nextRunnable() == nil)
        #expect(try q.nextRetryAtMs() == nil)
        #expect(try q.load("seg-1")?.attempts == 2)
        #expect(try q.load("seg-1")?.lastError == "decode error")
    }

    @Test func backoffGrowsExponentiallyAndCaps() {
        #expect(TranscriptionQueue.retryBackoffMs(attempts: 0) == 30_000)
        #expect(TranscriptionQueue.retryBackoffMs(attempts: 1) == 30_000)
        #expect(TranscriptionQueue.retryBackoffMs(attempts: 2) == 60_000)
        #expect(TranscriptionQueue.retryBackoffMs(attempts: 3) == 120_000)
        #expect(TranscriptionQueue.retryBackoffMs(attempts: 7) == 30 * 60_000)
        #expect(TranscriptionQueue.retryBackoffMs(attempts: 100) == 30 * 60_000)
    }

    @Test func retryableFlagDropsAtMaxAttempts() throws {
        let q = queue()
        try q.enqueue("seg-1")
        for _ in 0..<TranscriptionQueue.maxAttempts {
            try q.markRunning("seg-1")
            try q.markFailed("seg-1", error: "still broken", retryable: true)
        }
        let task = try #require(try q.load("seg-1"))
        #expect(task.attempts == TranscriptionQueue.maxAttempts)
        #expect(!task.retryable, "task must stop retrying after maxAttempts")
    }

    @Test func resetDisabledRequeuesOnlyDisabledTasks() throws {
        let q = queue()
        try q.enqueue("seg-disabled")
        try q.markDisabled("seg-disabled")
        try q.enqueue("seg-done")
        try q.markRunning("seg-done")
        try q.markComplete("seg-done", result: routed())

        #expect(try q.resetDisabled() == ["seg-disabled"])
        #expect(try q.load("seg-disabled")?.state == .pending)
        #expect(try q.load("seg-done")?.state == .complete)
        #expect(try q.nextRunnable()?.segmentId == "seg-disabled")
    }

    @Test func pendingIsPreferredOverRetryableFailed_newestFirst() throws {
        let q = queue()
        try q.enqueue("seg-old-failed")
        try q.markRunning("seg-old-failed")
        try q.markFailed("seg-old-failed", error: "x", retryable: true)
        clock.now += 10
        try q.enqueue("seg-a")
        clock.now += 10
        try q.enqueue("seg-b")

        // Pending beats retryable-Failed, and among Pending the newest (seg-b) goes first so
        // the user's most recent audio transcribes ahead of the older backlog.
        #expect(try q.nextRunnable()?.segmentId == "seg-b")
    }

    @Test func requeueForcesTerminalTaskBackToPending() throws {
        let q = queue()
        try q.enqueue("seg-1")
        try q.markRunning("seg-1")
        try q.markComplete("seg-1", result: routed())
        #expect(try q.load("seg-1")?.state == .complete)

        let requeued = try q.requeue("seg-1")
        #expect(requeued?.state == .pending)
        #expect(requeued?.attempts == 0, "re-transcribe resets the attempt count")
        #expect(try q.nextRunnable()?.segmentId == "seg-1")
    }

    @Test func requeueReturnsNullForUnknownSegment() throws {
        #expect(try queue().requeue("missing") == nil)
    }

    @Test func noSpeechAndDisabledAreTerminal() throws {
        let q = queue()
        try q.enqueue("seg-1")
        try q.enqueue("seg-2")
        try q.markNoSpeech("seg-1", decidedBy: "test")
        try q.markDisabled("seg-2")
        #expect(try q.load("seg-1")?.state == .noSpeech)
        #expect(try q.load("seg-2")?.state == .disabled)
        #expect(try q.nextRunnable() == nil)
    }

    /// Every verdict reached from 2026-09-30 on names its author; one with none is from before,
    /// when an interrupted model could settle a whole conversation as silence.
    @Test func noSpeechVerdictsKeepWhoReachedThem() throws {
        let q = queue()
        try q.enqueue("seg-1")
        try q.markNoSpeech("seg-1", decidedBy: "coreai-local: local model returned no speech")
        #expect(
            try q.load("seg-1")?.lastError
                == "no speech - coreai-local: local model returned no speech")
    }

    @Test func unattributedNoSpeechWithItsAudioIsHeardAgainOnce() throws {
        let q = queue()
        for id in ["old-with-audio", "old-without-audio", "attributed", "complete"] {
            try q.enqueue(id)
        }
        try q.markRunning("old-with-audio")
        // Verdicts from before provenance: state NoSpeech, no author — as the old code left them.
        try db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE transcription_tasks SET state = 'NoSpeech', lastError = NULL
                    WHERE segmentId IN ('old-with-audio', 'old-without-audio')
                    """)
        }
        try q.markNoSpeech("attributed", decidedBy: "silence floor: loudest second -70 dBFS")
        try q.markComplete(
            "complete",
            result: routed("hi"))

        let existing: Set<String> = ["old-with-audio", "attributed", "complete"]
        #expect(try q.requeueUnexplainedNoSpeech(among: existing) == ["old-with-audio"])
        let revived = try q.load("old-with-audio")
        #expect(revived?.state == .pending)
        #expect(revived?.attempts == 0, "a fresh budget")
        #expect(try q.load("old-without-audio")?.state == .noSpeech, "nothing left to hear")
        #expect(try q.load("attributed")?.state == .noSpeech)
        #expect(try q.load("complete")?.state == .complete)

        // Re-settled with an author, it is never picked up again.
        try q.markNoSpeech("old-with-audio", decidedBy: "coreai-local: local model returned no speech")
        #expect(try q.requeueUnexplainedNoSpeech(among: existing).isEmpty)
    }

    @Test func recoverOnStart_returnsRunningTasksToPending() throws {
        let q = queue()
        try q.enqueue("seg-1")
        try q.markRunning("seg-1")

        // Process death and restart.
        let q2 = queue()
        try q2.recoverOnStart()
        let task = try #require(try q2.load("seg-1"))
        #expect(task.state == .pending)
        #expect(task.attempts == 1, "attempts survive recovery")
        #expect(try q2.nextRunnable()?.segmentId == "seg-1")
    }

    @Test func deleteAllRemovesTasks() throws {
        let q = queue()
        try q.enqueue("seg-1")
        try q.enqueue("seg-2")

        try q.deleteAll()

        #expect(try q.all().isEmpty)
        #expect(try q.load("seg-1") == nil)
        #expect(try q.load("seg-2") == nil)
    }

    @Test func deleteRemovesSingleTask() throws {
        let q = queue()
        try q.enqueue("seg-1")
        try q.enqueue("seg-2")

        try q.delete("seg-1")

        #expect(try q.load("seg-1") == nil)
        #expect(try q.load("seg-2")?.segmentId == "seg-2")
    }

    @Test func atomicWrites_leaveNoTempFiles() throws {
        // DB port of the KMP temp-file check: writes are single transactions, so another
        // instance over the same database must observe each mutation fully applied or not at
        // all — never a partial task (the JSON port asserted no `.tmp` leftovers instead).
        let q = queue()
        try q.enqueue("seg-1")
        try q.markRunning("seg-1")
        try q.markFailed("seg-1", error: "x", retryable: true)

        let observed = try #require(try queue().load("seg-1"))
        #expect(try q.load("seg-1") == observed)
        #expect(observed.state == .failed)
        #expect(observed.attempts == 1)
        #expect(observed.lastError == "x")
    }
}

// A task stops retrying after `maxAttempts`, and the backoff ladder gets there in about an hour.
// That suits a burst of failures and badly misreads an OUTAGE: an hour on a plane, on the
// Underground, or with a key that expired overnight, and those recordings were dead — no automatic
// path back, and no manual one in the UI either. These pin the guarantee that everything is
// EVENTUALLY transcribed.
@Suite struct QueueRevivalTests {

    private let clock = ClockBox(1_000)
    private let db: AppDatabase

    init() throws { db = try AppDatabase.inMemory() }

    private func queue() -> TranscriptionQueue {
        TranscriptionQueue(database: db, nowMs: { [clock] in clock.now })
    }

    /// Drives a task all the way to "given up on".
    private func exhaust(_ q: TranscriptionQueue, _ id: String, error: String) throws {
        try q.enqueue(id)
        for _ in 0..<TranscriptionQueue.maxAttempts {
            _ = try q.markRunning(id)
            try q.markFailed(id, error: error, retryable: true)
        }
        #expect(try q.all().first { $0.segmentId == id }?.retryable == false)
    }

    @Test func anOutageDoesNotKillARecordingForever() throws {
        let q = queue()
        try exhaust(q, "seg-1", error: "The request never reached the provider")

        // Nothing runnable: it has been given up on.
        #expect(try q.nextRunnable() == nil)

        // Six hours later the safety net tries again, with the WHOLE ladder restored — a revived
        // task that failed once and died immediately would not be a fix.
        clock.now += 6 * 60 * 60 * 1000
        let revived = try q.reviveExhausted(notAttemptedWithinMs: 6 * 60 * 60 * 1000) { _ in true }
        #expect(revived == ["seg-1"])
        let task = try #require(try q.all().first { $0.segmentId == "seg-1" })
        #expect(task.state == .pending)
        #expect(task.attempts == 0)
        #expect(task.retryable)
        #expect(try q.nextRunnable()?.segmentId == "seg-1")
    }

    @Test func aRecentFailureIsLeftAloneToFinishItsBackoff() throws {
        let q = queue()
        try exhaust(q, "seg-1", error: "The request never reached the provider")

        // The sweep runs on every pass, so it must not undo the backoff it just went through.
        let revived = try q.reviveExhausted(notAttemptedWithinMs: 6 * 60 * 60 * 1000) { _ in true }
        #expect(revived.isEmpty)
    }

    @Test func stillRetryingTasksAreNotTouched() throws {
        let q = queue()
        try q.enqueue("seg-1")
        _ = try q.markRunning("seg-1")
        try q.markFailed("seg-1", error: "boom", retryable: true)

        clock.now += 24 * 60 * 60 * 1000
        // It has attempts left; the ordinary ladder owns it, not the safety net.
        #expect(try q.reviveExhausted(notAttemptedWithinMs: 0) { _ in true }.isEmpty)
    }

    @Test func theCallerChoosesWhatComesBack() throws {
        let q = queue()
        try exhaust(q, "network", error: "The request never reached the provider")
        try exhaust(q, "broken-audio", error: "failed to read audio for segment")
        clock.now += 24 * 60 * 60 * 1000

        // Audio that cannot be read will never succeed; retrying it forever spends battery and
        // money on nothing, so the policy leaves it failed and visible.
        let revived = try q.reviveExhausted(notAttemptedWithinMs: 0) { task in
            TranscriptionFailureKind.classify(task.lastError).isWorthRevisiting
        }
        #expect(revived == ["network"])
    }
}

// The taxonomy behind that choice: "the world was temporarily broken" comes back, "this audio is
// bad" does not.
@Suite struct FailureRevivalPolicyTests {

    @Test func environmentalFailuresComeBack() {
        for kind in [
            TranscriptionFailureKind.noConnection, .keyRejected, .keyNotPermitted, .rateLimited,
            .providerTrouble, .timedOut, .modelMissing, .localEngineFailed, .notConfigured,
        ] {
            #expect(kind.isWorthRevisiting, "\(kind) is fixable and must be retried")
        }
    }

    @Test func badAudioStaysFailed() {
        for kind in [
            TranscriptionFailureKind.audioUnreadable, .recordingTooLong, .providerRefusedAudio,
        ] {
            #expect(!kind.isWorthRevisiting, "\(kind) cannot succeed on a retry")
        }
    }

    @Test func everyKindHasAnAnswer() {
        // A new kind must be classified deliberately, not inherit a default.
        #expect(TranscriptionFailureKind.allCases.count == 15)
    }
}
