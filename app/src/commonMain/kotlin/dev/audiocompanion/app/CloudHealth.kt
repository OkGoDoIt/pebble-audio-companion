package dev.audiocompanion.app

import dev.audiocompanion.transcription.CloudConnectivityResult
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class CloudHealthStatus {
    /** No test run yet and no cloud attempt observed. */
    Unknown,

    /** An explicit connectivity test is in flight. */
    Checking,

    /** The cloud provider was reached and accepted the credentials / a real attempt succeeded. */
    Ok,

    /** The last cloud attempt or test failed; [CloudHealth.message] explains why. */
    Failed,

    /** No API key configured for the selected provider. */
    NotConfigured,
}

/**
 * The app-wide "is cloud transcription actually working" signal. Written both by an explicit
 * Settings connectivity test and by real transcription attempts (via the router), so a silent local
 * fallback can no longer hide a failing cloud provider from the user.
 */
data class CloudHealth(
    val status: CloudHealthStatus = CloudHealthStatus.Unknown,
    val message: String? = null,
    val checkedAtMs: Long? = null,
)

/** Owns [CloudHealth] so the router (built before the runtime) and the runtime can share one flow. */
class CloudHealthMonitor(private val nowMs: () -> Long) {
    private val _state = MutableStateFlow(CloudHealth())
    val state: StateFlow<CloudHealth> = _state.asStateFlow()

    fun reportChecking() {
        _state.value = _state.value.copy(status = CloudHealthStatus.Checking)
    }

    fun report(result: CloudConnectivityResult) {
        _state.value = when (result) {
            is CloudConnectivityResult.Ok ->
                CloudHealth(CloudHealthStatus.Ok, result.detail, nowMs())
            is CloudConnectivityResult.Failed ->
                CloudHealth(CloudHealthStatus.Failed, result.message, nowMs())
            is CloudConnectivityResult.NotConfigured ->
                CloudHealth(CloudHealthStatus.NotConfigured, result.message, nowMs())
        }
    }
}
