import CompanionRuntime
import Foundation
import Receiver
import Testing

// The loop watchdog's promise is "if the old loop is stuck somewhere that ignores cancellation,
// start the new one anyway". On 2026-11-27 15:08 it decided a pass was wedged in recap and then
// took 4 min 16 s to restart the loop, because the wait it used was a task group, and a task
// group does not return until every child has, the stuck one included.

@Suite struct BoundedTaskWaitTests {

    /// A task that ignores cancellation until it is let go.
    private final class Stuck: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func hold() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if released { return true }
                    continuation = c
                    return false
                }
                if resumeNow { c.resume() }
            }
        }

        func release() {
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                released = true
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aTaskThatIgnoresCancellationDoesNotHoldTheWaiter() async throws {
        let stuck = Stuck()
        let task = Task { await stuck.hold() }
        // Let go well after the wait should have given up, so a wait that is held by the task
        // fails this test instead of hanging the suite.
        let letGo = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            stuck.release()
        }
        let started = ContinuousClock.now
        task.cancel()
        let finished = await BoundedTaskWait.finished(task, withinMs: 100, clock: SystemClock())
        let waited = ContinuousClock.now - started
        #expect(!finished)
        #expect(waited < .seconds(2), "the wait was held by the stuck task for \(waited)")
        stuck.release()
        letGo.cancel()
        await task.value
    }

    @Test func aTaskThatFinishesIsNotWaitedOnAnyLonger() async throws {
        let task = Task {}
        let started = ContinuousClock.now
        let finished = await BoundedTaskWait.finished(task, withinMs: 30_000, clock: SystemClock())
        #expect(finished)
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
