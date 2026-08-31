import Foundation
import Receiver

// Deterministic virtual-time clock — the Swift stand-in for kotlinx-coroutines-test's
// TestScheduler. Session code sleeps on this clock; nothing in a test ever waits on real time.
//
// `advance(by:)` releases pending sleeps in deadline order, letting each woken task run to its
// next suspension (a cooperative settle) before releasing the next — the same discipline
// kotlinx's scheduler applies while advancing virtual time. `TestClock.settle()` is the
// `runCurrent()` equivalent: it drains all ready (non-time-blocked) work by yielding the test
// task enough times for every pending continuation chain to run to quiescence.
final class TestClock: ReceiverClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: Int64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var _now: Int64 = 0
    private var sleepers: [Sleeper] = []
    private var cancelledIds: Set<UUID> = []

    var nowMs: Int64 { lock.withLock { _now } }

    func sleep(ms: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelledIds.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if ms <= 0 {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: _now + ms, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>?
            lock.lock()
            if let index = sleepers.firstIndex(where: { $0.id == id }) {
                continuation = sleepers.remove(at: index).continuation
            } else {
                continuation = nil
                cancelledIds.insert(id)
            }
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Advances virtual time, waking pending sleeps in deadline order (inclusive of the target,
    /// which matches the KMP tests' advanceTimeBy + runCurrent usage) and letting each woken
    /// task settle before the next fires.
    func advance(by ms: Int64) async {
        let target = lock.withLock { _now + ms }
        while true {
            await Self.settle()
            let next: Sleeper?
            lock.lock()
            if let index = sleepers.indices.min(by: { sleepers[$0].deadline < sleepers[$1].deadline }),
               sleepers[index].deadline <= target {
                let sleeper = sleepers.remove(at: index)
                _now = max(_now, sleeper.deadline)
                next = sleeper
            } else {
                next = nil
            }
            lock.unlock()
            guard let sleeper = next else { break }
            sleeper.continuation.resume()
        }
        lock.withLock { _now = max(_now, target) }
        await Self.settle()
    }

    /// Runs all currently-ready work to quiescence (`runCurrent()` equivalent): repeatedly
    /// yields the calling task so every resumed continuation, actor hop, and stream delivery in
    /// flight gets scheduled. All real waits go through this clock, so ready work needs only
    /// scheduling opportunities, never wall time.
    static func settle(yields: Int = 200) async {
        for _ in 0..<yields {
            await Task.yield()
        }
    }
}
