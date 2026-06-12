package dev.audiocompanion.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class LocalTranscriptionModelState(
    val modelName: String,
    val modelVersion: String,
    val downloaded: Boolean = false,
    val downloading: Boolean = false,
    /** Bytes received of the model archive; only meaningful while [downloading]. */
    val downloadedBytes: Long = 0,
    /** Total archive bytes, 0 while unknown. */
    val totalBytes: Long = 0,
    /** True when the download finished and the archive is being unpacked/verified. */
    val installing: Boolean = false,
    val errorMessage: String? = null,
)

/**
 * Owns the local STT model lifecycle for the Settings UI: presence check, explicit download
 * with real byte progress, and cancellation. The download is the only path that fetches the
 * model — transcription itself never downloads implicitly.
 */
class LocalTranscriptionModelManager(
    modelName: String,
    modelVersion: String,
    private val isDownloaded: () -> Boolean,
    private val download: suspend (onProgress: (Long, Long) -> Unit) -> Unit,
    /** Notified when installed-state changes (e.g. wakes the transcription loop). */
    private val onModelStateChanged: () -> Unit = {},
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var downloadJob: Job? = null

    private val _state = MutableStateFlow(
        LocalTranscriptionModelState(
            modelName = modelName,
            modelVersion = modelVersion,
        ),
    )
    val state: StateFlow<LocalTranscriptionModelState> = _state.asStateFlow()

    fun refresh() {
        scope.launch {
            if (_state.value.downloading) return@launch
            val downloaded = runCatching { isDownloaded() }.getOrDefault(false)
            val changed = downloaded != _state.value.downloaded
            _state.value = _state.value.copy(
                downloaded = downloaded,
                downloading = false,
                installing = false,
                errorMessage = null,
            )
            if (changed) onModelStateChanged()
        }
    }

    fun download() {
        if (_state.value.downloading) return
        downloadJob = scope.launch {
            // Already on disk: report the truth instead of pretending to download.
            if (runCatching { isDownloaded() }.getOrDefault(false)) {
                _state.value = _state.value.copy(
                    downloaded = true,
                    downloading = false,
                    installing = false,
                    errorMessage = null,
                )
                onModelStateChanged()
                return@launch
            }
            _state.value = _state.value.copy(
                downloading = true,
                installing = false,
                downloadedBytes = 0,
                totalBytes = 0,
                errorMessage = null,
            )
            try {
                download { received, total ->
                    _state.value = _state.value.copy(
                        downloadedBytes = received,
                        totalBytes = total,
                        // All bytes received: the remaining time is unpack/verify.
                        installing = total > 0 && received >= total,
                    )
                }
                _state.value = _state.value.copy(
                    downloaded = true,
                    downloading = false,
                    installing = false,
                    errorMessage = null,
                )
                onModelStateChanged()
            } catch (e: kotlin.coroutines.cancellation.CancellationException) {
                _state.value = _state.value.copy(
                    downloaded = runCatching { isDownloaded() }.getOrDefault(false),
                    downloading = false,
                    installing = false,
                    errorMessage = null,
                )
                throw e
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    downloaded = runCatching { isDownloaded() }.getOrDefault(false),
                    downloading = false,
                    installing = false,
                    errorMessage = e.message ?: e::class.simpleName ?: "model download failed",
                )
            }
        }
    }

    fun cancelDownload() {
        downloadJob?.cancel()
        downloadJob = null
    }
}
