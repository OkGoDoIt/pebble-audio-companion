import Foundation

// Concurrency and time primitives backing the receiver session port.
//
// The KMP session runs on kotlinx-coroutines with StateFlow/Channel/CompletableDeferred and an
// injected `nowMs` so its tests execute on virtual time. These are the minimal Swift equivalents:
// - `ReceiverClock` bundles now + sleep so tests substitute a deterministic manual clock.
// - `StateSubject` is a StateFlow: current value + conflated update streams, equality-skipping.
// - `OneShot` is a CompletableDeferred: complete-once, awaitable, cancellation-aware.
// - `ByteChannel` is a Channel<ByteArray>.receiveAsFlow(): buffered, each element to one receiver.

/// Injected time source. Production uses `SystemClock`; tests use a manual/virtual clock so no
/// test ever waits on real time.
public protocol ReceiverClock: Sendable {
    /// Monotonic-enough wall time in milliseconds (only differences and injected values matter).
    var nowMs: Int64 { get }

    /// Suspends for `ms` on this clock's timeline. Throws `CancellationError` when cancelled.
    func sleep(ms: Int64) async throws
}

/// Real-time clock for production use.
public struct SystemClock: ReceiverClock {
    public init() {}

    public var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    public func sleep(ms: Int64) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
    }
}

/// StateFlow port: thread-safe current value plus conflated change streams. Setting an equal
/// value does not emit (StateFlow's equality conflation); each subscriber's stream starts with
/// the value current at subscription time.
public final class StateSubject<Value: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value
    private var subscribers: [UUID: AsyncStream<Value>.Continuation] = [:]

    public init(_ initial: Value) {
        current = initial
    }

    public var value: Value {
        get { lock.withLock { current } }
        set {
            lock.lock()
            guard newValue != current else {
                lock.unlock()
                return
            }
            current = newValue
            let continuations = Array(subscribers.values)
            lock.unlock()
            for continuation in continuations {
                continuation.yield(newValue)
            }
        }
    }

    /// A conflated stream of values beginning with the current one. Slow consumers only ever see
    /// the newest value (matching StateFlow), which is exactly what `collectLatest` loops need.
    public func stream() -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock()
            subscribers[id] = continuation
            let snapshot = current
            lock.unlock()
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }
}

/// CompletableDeferred port: completes at most once; `value()` returns nil when the awaiting
/// task is cancelled before completion (the caller treats that like a timeout).
public final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Value?
    private var done = false
    private var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]
    private var cancelledWaiters: Set<UUID> = []

    public init() {}

    public var isCompleted: Bool { lock.withLock { done } }

    @discardableResult
    public func complete(_ value: Value) -> Bool {
        lock.lock()
        guard !done else {
            lock.unlock()
            return false
        }
        done = true
        result = value
        let pending = waiters
        waiters = [:]
        lock.unlock()
        for (_, continuation) in pending {
            continuation.resume(returning: value)
        }
        return true
    }

    public func value() async -> Value? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                lock.lock()
                if done {
                    let value = result
                    lock.unlock()
                    continuation.resume(returning: value)
                    return
                }
                if cancelledWaiters.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let continuation = waiters.removeValue(forKey: id) {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                cancelledWaiters.insert(id)
                lock.unlock()
            }
        }
    }
}

/// Channel<ByteArray>(...) + receiveAsFlow() port: unbounded (or drop-oldest bounded) buffer,
/// each sent message delivered to exactly one receiver, receivers resumable across sequential
/// stream subscriptions, cancellation ends a pending receive with nil.
public final class ByteChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [[UInt8]] = []
    private var receiverOrder: [UUID] = []
    private var receivers: [UUID: CheckedContinuation<[UInt8]?, Never>] = [:]
    private var cancelledReceivers: Set<UUID> = []
    private let capacity: Int

    /// `capacity` bounds the buffer with drop-oldest overflow (Channel BufferOverflow.DROP_OLDEST).
    public init(capacity: Int = .max) {
        self.capacity = capacity
    }

    public func send(_ bytes: [UInt8]) {
        lock.lock()
        if let id = receiverOrder.first, let continuation = receivers.removeValue(forKey: id) {
            receiverOrder.removeFirst()
            lock.unlock()
            continuation.resume(returning: bytes)
            return
        }
        buffer.append(bytes)
        if buffer.count > capacity {
            buffer.removeFirst()
        }
        lock.unlock()
    }

    public func receive() async -> [UInt8]? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[UInt8]?, Never>) in
                lock.lock()
                if cancelledReceivers.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if !buffer.isEmpty {
                    let next = buffer.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: next)
                    return
                }
                receivers[id] = continuation
                receiverOrder.append(id)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let continuation = receivers.removeValue(forKey: id) {
                receiverOrder.removeAll { $0 == id }
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                cancelledReceivers.insert(id)
                lock.unlock()
            }
        }
    }

    /// One message per element; ends when the consuming task is cancelled.
    public func stream() -> AsyncStream<[UInt8]> {
        AsyncStream { [self] in await receive() }
    }
}

/// `withTimeoutOrNull` port: races `operation` against a clock sleep; nil on timeout. The loser
/// is cancelled, so `operation` (and the sleep) must be cancellation-aware.
func withReceiverTimeout<T: Sendable>(
    clock: ReceiverClock,
    ms: Int64,
    operation: @escaping @Sendable () async -> T?
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await clock.sleep(ms: ms)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
