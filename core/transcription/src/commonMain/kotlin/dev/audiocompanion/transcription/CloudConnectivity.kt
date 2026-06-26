package dev.audiocompanion.transcription

/**
 * Outcome of a lightweight authenticated probe against a cloud transcription backend, or of a real
 * transcription attempt reported by the router. Doubles as the app-wide "is the cloud working"
 * signal so Settings (explicit test) and the rest of the app (real attempts) share one vocabulary.
 */
sealed interface CloudConnectivityResult {
    /** Reachable and the credentials were accepted. */
    data class Ok(val detail: String? = null) : CloudConnectivityResult

    /** Reachable but rejected (bad key, quota), or unreachable. [message] is user-facing. */
    data class Failed(val message: String) : CloudConnectivityResult

    /** Nothing to test yet — no API key configured for the selected provider. */
    data class NotConfigured(val message: String) : CloudConnectivityResult
}

/** A cloud provider that can self-test its credentials/connectivity without transcribing audio. */
interface CloudConnectivityCheck {
    suspend fun checkConnectivity(): CloudConnectivityResult
}
