import Foundation

// Port of `core/transcription/.../CloudConnectivity.kt`.

/// Outcome of a lightweight authenticated probe against a cloud transcription backend, or of a
/// real transcription attempt reported by the router. Doubles as the app-wide "is the cloud
/// working" signal so Settings (explicit test) and the rest of the app (real attempts) share
/// one vocabulary.
public enum CloudConnectivityResult: Sendable, Equatable {
    /// Reachable and the credentials were accepted.
    case ok(detail: String?)

    /// Reachable but rejected (bad key, quota), or unreachable. `message` is user-facing.
    case failed(message: String)

    /// Nothing to test yet — no API key configured for the selected provider.
    case notConfigured(message: String)
}

/// A cloud provider that can self-test its credentials/connectivity without transcribing audio.
public protocol CloudConnectivityCheck: Sendable {
    func checkConnectivity() async -> CloudConnectivityResult
}
