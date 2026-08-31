import Foundation
import SegmentStore
import Transcription

@testable import LiveAudio

// Shared helpers for the LiveAudio suites (ports of the fixtures embedded in the KMP
// `app/src/commonTest` live-audio test files).

/// Mutable wall clock injected via `nowMs` closures; each test drives it explicitly.
final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64
    var now: Int64 {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    init(_ now: Int64) { _now = now }
}

/// Thread-safe mutable box for values test closures capture (the KMP tests captured `var`s).
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    init(_ value: Value) { _value = value }
    func mutate(_ transform: (inout Value) -> Void) {
        lock.withLock { transform(&_value) }
    }
}

/// A `CompletableDeferred<Unit>` stand-in: `wait()` suspends until `open()`.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            opened = true
            let value = waiters
            waiters = []
            return value
        }
        for waiter in toResume { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// Polls `condition` until it holds (bounded); the deterministic stand-in for the KMP tests'
/// `advanceUntilIdle()` — all injected backoffs are zero, so pending work only needs
/// scheduling opportunities, never wall time. The bounded 2 ms naps are a scheduler fairness
/// fallback, not a timing dependency.
func waitUntil(
    timeoutMs: Int64 = 5_000,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
    while Date() < deadline {
        if await condition() { return true }
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

func makeTempRoot(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Wraps an `AsyncStream<Data>` into the throwing shape the transcriber decode seams expect
/// (the KMP tests passed the encoded flow straight through).
func passthrough(_ encoded: AsyncStream<Data>) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            for await data in encoded { continuation.yield(data) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// Single-element PCM stream (the KMP `flowOf(ByteArray(n))`).
func flowOf(_ chunks: Data...) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }
}

/// Minimal broadcast hub for fake streaming providers (the KMP
/// `MutableSharedFlow(extraBufferCapacity = 1)`): subscribers registered synchronously,
/// emissions fan out to all current subscribers.
final class Broadcast<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    var subscriberCount: Int { lock.withLock { continuations.count } }

    func subscribe() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    @discardableResult
    func send(_ element: Element) -> Bool {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(element) }
        return true
    }
}
