import Foundation
import Receiver

// Small shared primitives for the runtime layer. Everything here is platform-free and clock
// injected, so the whole runtime runs on virtual time in tests.

/// The runtime reuses `Receiver.ReceiverClock` as its single time seam (`nowMs` + `sleep`), so
/// `Tests/ReceiverTests/TestClock.swift`'s virtual-time discipline covers the runtime too.
public typealias RuntimeClock = ReceiverClock

/// Conflated wake channel (port of the KMP `Channel<Unit>(CONFLATED)`): many signals collapse to
/// one pending wake, and a waiter returns as soon as a signal exists or the timeout elapses.
///
/// This is what makes pacing EVENT-DRIVEN (plan Part 3): store/queue events, config changes and
/// foreground entry all `signal()`; the adaptive schedule only governs the FALLBACK timeout.
public final class WakeChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    /// Records a wake. Conflated: a second signal before anyone waits is a no-op.
    public func signal() {
        var resumed: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        if waiters.isEmpty {
            pending = true
        } else {
            resumed = Array(waiters.values)
            waiters.removeAll()
            pending = false
        }
        lock.unlock()
        resumed.forEach { $0.resume() }
    }

    /// Returns when a signal arrives or `timeoutMs` of *clock* time elapses, whichever is first.
    /// A pending signal returns immediately.
    public func wait(timeoutMs: Int64, clock: RuntimeClock) async {
        let alreadyPending: Bool = lock.withLock {
            if pending {
                pending = false
                return true
            }
            return false
        }
        if alreadyPending { return }
        if timeoutMs <= 0 { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in await self.park() }
            group.addTask { try? await clock.sleep(ms: timeoutMs) }
            await group.next()
            group.cancelAll()
        }
        // Cancelling the parked waiter leaves no residue: `park` removes itself on cancel.
    }

    private func park() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if pending {
                    pending = false
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume()
        }
    }
}

/// A once-only async gate used for "recover exactly once" and "import exactly once" startup work.
actor OnceGate {
    private var done = false

    /// Runs `body` the first time only; later calls return without running it.
    /// Returns true when this call performed the work.
    @discardableResult
    func runOnce(_ body: () async throws -> Void) async rethrows -> Bool {
        if done { return false }
        done = true
        try await body()
        return true
    }

    var hasRun: Bool { done }
}

/// Non-fatal background failure logging. Background work must never take the process down for a
/// transient storage/network error, but it must never fail silently either.
public struct RuntimeLog: Sendable {
    public let write: @Sendable (String) -> Void

    public init(write: @escaping @Sendable (String) -> Void = { _ in }) {
        self.write = write
    }

    public static let silent = RuntimeLog()

    public static let console = RuntimeLog { message in
        print("audio-companion: \(message)")
    }

    func failure(_ label: String, _ error: Error) {
        write("\(label) failed: \(error)")
    }
}
