import Foundation
import Transcription

// Deadlines for AI work that has none of its own.
//
// A cloud call has `URLSession`'s timers. An Apple model session has nothing: `respond` returns
// when the model is done, and a model that never is — Apple Intelligence paused mid-generation,
// assets reclaimed under memory pressure — holds the pipeline pass that awaited it until the
// loop watchdog decides the whole loop is wedged ten minutes later and restarts it, throwing
// away whatever else the pass had done. A deadline turns that into an ordinary, classified
// failure (`AiFailureKind.timedOut`) that the router can fall back from and the workers back
// off from.

public enum AiTimeout {
    /// Runs `operation`, and throws `timeout()` if it has not finished within `milliseconds`.
    ///
    /// Returns as soon as EITHER side finishes, without waiting for the other: the operation is
    /// cancelled when the deadline wins, but a framework that ignores cancellation must not be
    /// able to hold the caller anyway — which a task group, which awaits every child, would.
    /// The caller's own cancellation reaches the operation.
    public static func run<Value: Sendable>(
        milliseconds: Int64,
        timeout: @escaping @Sendable () -> Error,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = Race<Value>()
        let work = Task { try await operation() }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
            guard !Task.isCancelled else { return }
            race.finish(.failure(timeout()))
            work.cancel()
        }
        let watcher = Task {
            let result: Result<Value, Error>
            do { result = .success(try await work.value) } catch { result = .failure(error) }
            race.finish(result)
            timer.cancel()
        }
        return try await withTaskCancellationHandler {
            try await race.value()
        } onCancel: {
            work.cancel()
            timer.cancel()
            watcher.cancel()
            race.finish(.failure(CancellationError()))
        }
    }

    /// The first of two outcomes, delivered once.
    private final class Race<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<Value, Error>?
        private var waiter: CheckedContinuation<Value, Error>?

        func finish(_ result: Result<Value, Error>) {
            let resume: CheckedContinuation<Value, Error>? = lock.withLock {
                guard outcome == nil else { return nil }
                outcome = result
                defer { waiter = nil }
                return waiter
            }
            resume?.resume(with: result)
        }

        func value() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<Value, Error>? = lock.withLock {
                    if let outcome { return outcome }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        }
    }
}

/// The dedicated transport for AI requests.
///
/// `URLSession.shared` gives every request a 60-second IDLE timeout, and a non-streaming
/// Responses call sends no bytes at all while the model works: a long Ask over a big range, or a
/// reasoning model thinking before it writes, went silent past a minute and died with -1001
/// every time — and the transcription uploads' own session must not change to fix it. This one
/// waits `requestTimeoutSeconds` for the first byte and gives the whole exchange
/// `resourceTimeoutSeconds`.
public enum AiHttpTransport {
    /// Four minutes of silence before giving up — measured calls run 10–70 s, and a reasoning
    /// model on a large input is the long tail this exists for.
    public static let requestTimeoutSeconds: TimeInterval = 240
    /// Five minutes end to end.
    public static let resourceTimeoutSeconds: TimeInterval = 300

    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeoutSeconds
        configuration.timeoutIntervalForResource = resourceTimeoutSeconds
        // Fail fast offline: a First mode's fallback, or the worker's backoff, is the answer to
        // no connection — not a request parked for minutes waiting for one.
        configuration.waitsForConnectivity = false
        return configuration
    }

    public static func make() -> URLSessionHttpTransport {
        URLSessionHttpTransport(session: URLSession(configuration: sessionConfiguration()))
    }
}
