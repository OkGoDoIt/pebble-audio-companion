import Foundation

// Port of `app/src/commonMain/.../CloudHealth.kt` (the KMP class lived in the app module; here
// it sits beside the router that feeds it).

public enum CloudHealthStatus: Sendable, Equatable {
    /// No test run yet and no cloud attempt observed.
    case unknown

    /// An explicit connectivity test is in flight.
    case checking

    /// The cloud provider was reached and accepted the credentials / a real attempt succeeded.
    case ok

    /// The last cloud attempt or test failed; `CloudHealth.message` explains why.
    case failed

    /// No API key configured for the selected provider.
    case notConfigured
}

/// The app-wide "is cloud transcription actually working" signal. Written both by an explicit
/// Settings connectivity test and by real transcription attempts (via the router), so a silent
/// local fallback can no longer hide a failing cloud provider from the user.
public struct CloudHealth: Sendable, Equatable {
    public var status: CloudHealthStatus
    public var message: String?
    public var checkedAtMs: Int64?

    public init(
        status: CloudHealthStatus = .unknown,
        message: String? = nil,
        checkedAtMs: Int64? = nil
    ) {
        self.status = status
        self.message = message
        self.checkedAtMs = checkedAtMs
    }
}

/// Owns `CloudHealth` so the router (built before the runtime) and the runtime can share one
/// observable value.
///
/// Cloud providers (e.g. Soniox realtime) hit intermittent, self-healing errors — a request
/// timeout, a dropped socket — that the streaming paths retry automatically. So a single
/// `report` of a `CloudConnectivityResult.failed` is *not* surfaced to the user: failures are
/// held back until `failureThreshold` of them land in a row with no intervening success, at
/// which point the failure looks persistent ("repeated unrecoverable failure") and the banner
/// is shown. Any success — or any user-initiated probe via `reportImmediate` — resets the
/// streak. `CloudConnectivityResult.notConfigured` is a standing, actionable state (no API
/// key) and is always surfaced at once.
public final class CloudHealthMonitor: @unchecked Sendable {
    /// Consecutive automatic failures before a transient cloud error is shown as persistent.
    public static let defaultFailureThreshold = 3

    private let nowMs: @Sendable () -> Int64
    private let failureThreshold: Int

    private let lock = NSLock()
    private var _state = CloudHealth()

    /// Consecutive automatic failures with no intervening success; resets on any
    /// `CloudConnectivityResult.ok`.
    private var consecutiveFailures = 0
    private var continuations: [UUID: AsyncStream<CloudHealth>.Continuation] = [:]

    public init(
        nowMs: @escaping @Sendable () -> Int64,
        failureThreshold: Int = CloudHealthMonitor.defaultFailureThreshold
    ) {
        self.nowMs = nowMs
        self.failureThreshold = failureThreshold
    }

    public var state: CloudHealth {
        lock.withLock { _state }
    }

    /// StateFlow-style observation: yields the current value immediately, then every change.
    public func updates() -> AsyncStream<CloudHealth> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                continuations[id] = continuation
                continuation.yield(_state)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func reportChecking() {
        setState { current in
            var next = current
            next.status = .checking
            return next
        }
    }

    /// Records the outcome of an *automatic* cloud attempt (transcription router, live
    /// socket). Transient failures are retried upstream, so they are debounced here and only
    /// flip the banner to `CloudHealthStatus.failed` once `failureThreshold` of them occur
    /// back-to-back.
    public func report(_ result: CloudConnectivityResult) {
        switch result {
        case .ok(let detail):
            lock.withLock { consecutiveFailures = 0 }
            publish(.ok, detail)
        case .notConfigured(let message):
            lock.withLock { consecutiveFailures = 0 }
            publish(.notConfigured, message)
        case .failed(let message):
            let surfaced = lock.withLock {
                consecutiveFailures += 1
                return consecutiveFailures >= failureThreshold
            }
            if surfaced {
                publish(.failed, message)
            }
            // Otherwise hold back: the streaming path is retrying and this blip may self-heal.
        }
    }

    /// Records a *user-initiated* probe ("Test connection" in Settings). The user asked, so
    /// the verdict is shown immediately rather than debounced; a failure also primes the
    /// streak so a subsequent automatic failure keeps it visible.
    public func reportImmediate(_ result: CloudConnectivityResult) {
        switch result {
        case .ok(let detail):
            lock.withLock { consecutiveFailures = 0 }
            publish(.ok, detail)
        case .notConfigured(let message):
            lock.withLock { consecutiveFailures = 0 }
            publish(.notConfigured, message)
        case .failed(let message):
            lock.withLock { consecutiveFailures = failureThreshold }
            publish(.failed, message)
        }
    }

    private func publish(_ status: CloudHealthStatus, _ message: String?) {
        setState { _ in CloudHealth(status: status, message: message, checkedAtMs: nowMs()) }
    }

    private func setState(_ transform: (CloudHealth) -> CloudHealth) {
        let (next, observers) = lock.withLock {
            () -> (CloudHealth, [AsyncStream<CloudHealth>.Continuation]) in
            _state = transform(_state)
            return (_state, Array(continuations.values))
        }
        for continuation in observers {
            continuation.yield(next)
        }
    }
}
