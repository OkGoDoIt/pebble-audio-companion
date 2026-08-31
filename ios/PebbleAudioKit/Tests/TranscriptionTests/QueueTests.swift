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
        try q.markNoSpeech("seg-1")
        try q.markDisabled("seg-2")
        #expect(try q.load("seg-1")?.state == .noSpeech)
        #expect(try q.load("seg-2")?.state == .disabled)
        #expect(try q.nextRunnable() == nil)
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
