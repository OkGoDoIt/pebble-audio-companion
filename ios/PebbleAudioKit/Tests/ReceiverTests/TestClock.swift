import Foundation
import Receiver
import Testing

// Deterministic virtual time for the receiver port — the Swift stand-in for
// kotlinx-coroutines-test's TestScheduler. Session code sleeps on this clock; nothing in a test
// ever waits on real time.
//
// The hard part is not virtual time, it is knowing when the session has finished reacting to a
// stimulus. This harness answers that with an explicit ledger of parked tasks rather than by
// yielding a hopeful number of times:
//
//   * every suspension point the harness owns (`TestClock.sleep`, `TrackedByteChannel.receive`)
//     reports the parking task's identity, and
//   * every wake the harness performs (delivering a message, releasing a sleeper) records that
//     the woken task now owes us a re-park.
//
// `settle()` therefore returns when the ledger says every woken task has parked again — a fact,
// not a guess. `Task.yield()` alone cannot express this: it only re-enqueues the *calling* task,
// so a starved cooperative pool can satisfy any number of yields without ever running the task
// we are actually waiting for. That is what made the ported suite fail roughly one run in three
// when ~96 suites shared the machine.

/// Identity of the task running right now. Used to pair a wake with the matching re-park.
struct TaskId: Hashable {
    let raw: Int

    static var current: TaskId {
        withUnsafeCurrentTask { TaskId(raw: $0?.hashValue ?? 0) }
    }
}

/// Shared bookkeeping for the harness-owned suspension points of one fixture.
///
/// One lock guards the ledger *and* the clock's and channels' own state, so a wake and the
/// matching park can never interleave into a lost or phantom park.
final class TestScheduler: @unchecked Sendable {
    let lock = NSLock()

    /// Tasks the harness has woken that have not parked again.
    private var runnable: Set<TaskId> = []

    /// Monotonic count of everything the harness observed the session do. `settle()` uses it to
    /// tell "nothing is happening" from "something is still in flight".
    private var eventCounter: UInt64 = 0

    /// Messages handed to a channel that no consumer has taken yet. A notification pushed before
    /// its consumer loop exists (STREAM_START arriving in the same breath as the AUTH_RESULT that
    /// starts the data task) is queued rather than delivered, so there is no wake to pair with —
    /// but the session is plainly not finished, and `settle()` must not call it quiet.
    private var pendingMessages = 0

    // --- ledger; every one of these requires `lock` to be held ---------------------------------

    /// Records session-visible activity that is not itself a park/wake (a fake link write, a sink
    /// call, a buffered message).
    func noteEventLocked() {
        eventCounter &+= 1
    }

    /// `id` is about to suspend inside a harness-owned primitive: it can make no further progress
    /// until the harness resumes it.
    func markParkedLocked(_ id: TaskId) {
        eventCounter &+= 1
        runnable.remove(id)
    }

    /// The harness is resuming a parked task, so it owes us a re-park before the world is quiet.
    /// Cancellation resumes are deliberately NOT marked: a cancelled consumer unwinds and dies
    /// rather than parking again, and waiting for a park that never comes would hang.
    func markRunnableLocked(_ id: TaskId) {
        eventCounter &+= 1
        runnable.insert(id)
    }

    func messageBufferedLocked() {
        eventCounter &+= 1
        pendingMessages += 1
    }

    func messageTakenFromBufferLocked() {
        eventCounter &+= 1
        pendingMessages -= 1
    }

    // --- reads ---------------------------------------------------------------------------------

    func noteEvent() {
        lock.withLock { noteEventLocked() }
    }

    var events: UInt64 { lock.withLock { eventCounter } }

    /// True when the ledger knows of no work left to do: nothing the harness woke still owes a
    /// re-park, and no pushed notification is still sitting in a channel undelivered.
    var isQuiescent: Bool { lock.withLock { runnable.isEmpty && pendingMessages == 0 } }

    /// Drops ledger entries for tasks that were woken and then exited instead of parking again
    /// (a keepalive that gives up and resyncs, a one-shot reconcile task). Task termination is
    /// not observable from outside, so `settle()` only calls this after the session has been
    /// provably idle across many real scheduling barriers.
    func forgetRunnable() {
        lock.withLock { runnable.removeAll() }
    }
}

/// `Channel<ByteArray>.receiveAsFlow()` for the fake link, with park/wake reporting.
///
/// Semantics match `ByteChannel` in the production support layer: unbounded buffer, each message
/// delivered to exactly one receiver, a pending receive ends with nil when its task is cancelled.
final class TrackedByteChannel: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let task: TaskId
        let continuation: CheckedContinuation<[UInt8]?, Never>
    }

    private let scheduler: TestScheduler
    private var buffer: [[UInt8]] = []
    private var waiters: [Waiter] = []
    private var cancelledReceivers: Set<UUID> = []

    init(scheduler: TestScheduler) {
        self.scheduler = scheduler
    }

    func send(_ bytes: [UInt8]) {
        scheduler.lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            scheduler.markRunnableLocked(waiter.task)
            scheduler.lock.unlock()
            waiter.continuation.resume(returning: bytes)
            return
        }
        buffer.append(bytes)
        scheduler.messageBufferedLocked()
        scheduler.lock.unlock()
    }

    func receive() async -> [UInt8]? {
        let id = UUID()
        let task = TaskId.current
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[UInt8]?, Never>) in
                scheduler.lock.lock()
                if cancelledReceivers.remove(id) != nil {
                    scheduler.lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if !buffer.isEmpty {
                    let next = buffer.removeFirst()
                    scheduler.messageTakenFromBufferLocked()
                    // This consumer did not park, but it is now carrying a message: it owes us a
                    // re-park before the session can be called quiet.
                    scheduler.markRunnableLocked(task)
                    scheduler.lock.unlock()
                    continuation.resume(returning: next)
                    return
                }
                waiters.append(Waiter(id: id, task: task, continuation: continuation))
                scheduler.markParkedLocked(task)
                scheduler.lock.unlock()
            }
        } onCancel: {
            scheduler.lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index)
                scheduler.noteEventLocked()
                scheduler.lock.unlock()
                waiter.continuation.resume(returning: nil)
            } else {
                cancelledReceivers.insert(id)
                scheduler.lock.unlock()
            }
        }
    }

    /// One message per element; ends when the consuming task is cancelled.
    func stream() -> AsyncStream<[UInt8]> {
        AsyncStream { [self] in await receive() }
    }
}

final class TestClock: ReceiverClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let task: TaskId
        let deadline: Int64
        let continuation: CheckedContinuation<Void, Error>
    }

    let scheduler: TestScheduler

    private var _now: Int64 = 0
    private var sleepers: [Sleeper] = []
    private var cancelledIds: Set<UUID> = []

    init(scheduler: TestScheduler = TestScheduler()) {
        self.scheduler = scheduler
    }

    var nowMs: Int64 { scheduler.lock.withLock { _now } }

    func sleep(ms: Int64) async throws {
        let id = UUID()
        let task = TaskId.current
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                scheduler.lock.lock()
                if cancelledIds.remove(id) != nil {
                    scheduler.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if ms <= 0 {
                    scheduler.noteEventLocked()
                    scheduler.lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, task: task, deadline: _now + ms, continuation: continuation))
                scheduler.markParkedLocked(task)
                scheduler.lock.unlock()
            }
        } onCancel: {
            scheduler.lock.lock()
            if let index = sleepers.firstIndex(where: { $0.id == id }) {
                let sleeper = sleepers.remove(at: index)
                scheduler.noteEventLocked()
                scheduler.lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                cancelledIds.insert(id)
                scheduler.lock.unlock()
            }
        }
    }

    /// Advances virtual time, waking pending sleeps in deadline order (inclusive of the target,
    /// which matches the KMP tests' advanceTimeBy + runCurrent usage) and letting each woken task
    /// settle before the next fires.
    func advance(by ms: Int64) async {
        let target = scheduler.lock.withLock { _now + ms }
        while true {
            await settle()
            let next: Sleeper? = scheduler.lock.withLock {
                guard let index = sleepers.indices.min(by: { sleepers[$0].deadline < sleepers[$1].deadline }),
                      sleepers[index].deadline <= target
                else { return nil }
                let sleeper = sleepers.remove(at: index)
                _now = max(_now, sleeper.deadline)
                scheduler.markRunnableLocked(sleeper.task)
                return sleeper
            }
            guard let sleeper = next else { break }
            sleeper.continuation.resume()
        }
        scheduler.lock.withLock { _now = max(_now, target) }
        await settle()
    }

    /// `runCurrent()` equivalent: returns once every task the harness woke has parked again and
    /// the session has stopped doing anything the harness can see. All real waits go through this
    /// clock, so ready work needs only scheduling opportunities, never wall time.
    func settle() async {
        // Woken-but-never-reparked tasks are usually still in flight; only after this many
        // consecutive quiet barriers do we conclude they exited instead (see `forgetRunnable`).
        let exitedTaskThreshold = 96
        var quietBarriers = 0
        var barriers = 0

        while true {
            let before = scheduler.events
            await Self.poolBarrier()
            quietBarriers = scheduler.events == before ? quietBarriers + 1 : 0

            if scheduler.isQuiescent {
                // The ledger covers every task the harness itself woke. It cannot see a task the
                // session spawns while handling a message (the reconcile that follows AUTH_RESULT,
                // say), because nothing told us it exists — but such a task reaches a harness-owned
                // primitive almost immediately, which bumps the event counter. Requiring a run of
                // genuinely quiet barriers gives it far more scheduling opportunity than it needs.
                if quietBarriers >= 12 { return }
            } else if quietBarriers >= exitedTaskThreshold {
                scheduler.forgetRunnable()
                return
            }

            barriers += 1
            if barriers > 20_000 {
                Issue.record("TestClock.settle() never reached quiescence; the session kept producing work")
                return
            }
        }
    }

    /// A scheduling barrier that cannot be satisfied without the cooperative pool actually
    /// running work: it enqueues a batch of child tasks and awaits them all.
    ///
    /// This is the difference that matters under parallel load. `Task.yield()` only re-enqueues
    /// the calling task, so a starved pool can satisfy hundreds of yields while the task we are
    /// waiting on never runs. Awaiting freshly-enqueued children cannot complete until the pool
    /// has genuinely made progress, so the wait scales itself to how busy the machine is.
    private static func poolBarrier(width: Int = 4, depth: Int = 2) async {
        for _ in 0..<depth {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<width {
                    group.addTask { await Task.yield() }
                }
            }
        }
    }
}
