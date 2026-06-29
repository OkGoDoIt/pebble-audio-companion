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

/**
 * Owns [CloudHealth] so the router (built before the runtime) and the runtime can share one flow.
 *
 * Cloud providers (e.g. Soniox realtime) hit intermittent, self-healing errors — a request timeout,
 * a dropped socket — that the streaming paths now retry automatically. So a single [report] of a
 * [CloudConnectivityResult.Failed] is *not* surfaced to the user: failures are held back until
 * [failureThreshold] of them land in a row with no intervening success, at which point the failure
 * looks persistent ("repeated unrecoverable failure") and the banner is shown. Any success — or any
 * user-initiated probe via [reportImmediate] — resets the streak. [CloudConnectivityResult.NotConfigured]
 * is a standing, actionable state (no API key) and is always surfaced at once.
 */
class CloudHealthMonitor(
    private val nowMs: () -> Long,
    private val failureThreshold: Int = DEFAULT_FAILURE_THRESHOLD,
) {
    private val _state = MutableStateFlow(CloudHealth())
    val state: StateFlow<CloudHealth> = _state.asStateFlow()

    /** Consecutive automatic failures with no intervening success; resets on any [CloudConnectivityResult.Ok]. */
    private var consecutiveFailures = 0

    fun reportChecking() {
        _state.value = _state.value.copy(status = CloudHealthStatus.Checking)
    }

    /**
     * Records the outcome of an *automatic* cloud attempt (transcription router, live socket).
     * Transient failures are retried upstream, so they are debounced here and only flip the banner
     * to [CloudHealthStatus.Failed] once [failureThreshold] of them occur back-to-back.
     */
    fun report(result: CloudConnectivityResult) {
        when (result) {
            is CloudConnectivityResult.Ok -> {
                consecutiveFailures = 0
                publish(CloudHealthStatus.Ok, result.detail)
            }
            is CloudConnectivityResult.NotConfigured -> {
                consecutiveFailures = 0
                publish(CloudHealthStatus.NotConfigured, result.message)
            }
            is CloudConnectivityResult.Failed -> {
                consecutiveFailures++
                if (consecutiveFailures >= failureThreshold) {
                    publish(CloudHealthStatus.Failed, result.message)
                }
                // Otherwise hold back: the streaming path is retrying and this blip may self-heal.
            }
        }
    }

    /**
     * Records a *user-initiated* probe ("Test connection" in Settings). The user asked, so the
     * verdict is shown immediately rather than debounced; a failure also primes the streak so a
     * subsequent automatic failure keeps it visible.
     */
    fun reportImmediate(result: CloudConnectivityResult) {
        when (result) {
            is CloudConnectivityResult.Ok -> {
                consecutiveFailures = 0
                publish(CloudHealthStatus.Ok, result.detail)
            }
            is CloudConnectivityResult.NotConfigured -> {
                consecutiveFailures = 0
                publish(CloudHealthStatus.NotConfigured, result.message)
            }
            is CloudConnectivityResult.Failed -> {
                consecutiveFailures = failureThreshold
                publish(CloudHealthStatus.Failed, result.message)
            }
        }
    }

    private fun publish(status: CloudHealthStatus, message: String?) {
        _state.value = CloudHealth(status, message, nowMs())
    }

    companion object {
        /** Consecutive automatic failures before a transient cloud error is shown as persistent. */
        const val DEFAULT_FAILURE_THRESHOLD = 3
    }
}
