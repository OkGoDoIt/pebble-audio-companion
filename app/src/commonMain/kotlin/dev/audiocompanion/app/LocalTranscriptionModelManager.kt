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
    val selectedModelId: String,
    val options: List<LocalTranscriptionModelOptionState>,
    val downloaded: Boolean = false,
    val downloading: Boolean = false,
    /** Bytes received of the model archive; only meaningful while [downloading]. */
    val downloadedBytes: Long = 0,
    /** Total archive bytes, 0 while unknown. */
    val totalBytes: Long = 0,
    /** True when the download finished and the archive is being unpacked/verified. */
    val installing: Boolean = false,
    val errorMessage: String? = null,
) {
    val selectedOption: LocalTranscriptionModelOptionState?
        get() = options.firstOrNull { it.model.id == selectedModelId }
}

data class LocalTranscriptionModelOptionState(
    val model: LocalTranscriptionModelSpec,
    val downloaded: Boolean,
)

/**
 * Owns the local STT model lifecycle for the Settings UI: presence check, explicit download
 * with real byte progress, and cancellation. The download is the only path that fetches the
 * model — transcription itself never downloads implicitly.
 */
class LocalTranscriptionModelManager(
    private val models: List<LocalTranscriptionModelSpec>,
    private val selectedModelId: () -> String,
    private val isDownloaded: (modelId: String) -> Boolean,
    private val download: suspend (modelId: String, onProgress: (Long, Long) -> Unit) -> Unit,
    /** Notified when installed-state changes (e.g. wakes the transcription loop). */
    private val onModelStateChanged: () -> Unit = {},
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var downloadJob: Job? = null

    private val _state = MutableStateFlow(
        buildState(),
    )
    val state: StateFlow<LocalTranscriptionModelState> = _state.asStateFlow()

    fun refresh() {
        scope.launch {
            if (_state.value.downloading) return@launch
            val previousDownloaded = _state.value.downloaded
            val refreshed = buildState()
            val downloaded = refreshed.downloaded
            val changed = downloaded != previousDownloaded
            _state.value = refreshed.copy(errorMessage = null)
            if (changed) onModelStateChanged()
        }
    }

    fun refreshSelection() {
        scope.launch {
            if (_state.value.downloading) return@launch
            _state.value = buildState(errorMessage = _state.value.errorMessage)
            onModelStateChanged()
        }
    }

    fun download() {
        if (_state.value.downloading) return
        val modelId = selectedModelId()
        downloadJob = scope.launch {
            if (runCatching { isDownloaded(modelId) }.getOrDefault(false)) {
                _state.value = buildState()
                onModelStateChanged()
                return@launch
            }
            val selected = selectedModel(modelId)
            _state.value = buildState().copy(
                downloading = true,
                installing = false,
                downloadedBytes = 0,
                totalBytes = selected.downloadBytes,
                errorMessage = null,
            )
            try {
                download(modelId) { received, total ->
                    val effectiveTotal = if (total > 0) total else selected.downloadBytes
                    _state.value = _state.value.copy(
                        downloadedBytes = received,
                        totalBytes = effectiveTotal,
                        // All bytes received: the remaining time is unpack/verify.
                        installing = effectiveTotal > 0 && received >= effectiveTotal,
                    )
                }
                _state.value = buildState()
                onModelStateChanged()
            } catch (e: kotlin.coroutines.cancellation.CancellationException) {
                _state.value = buildState()
                throw e
            } catch (e: Exception) {
                _state.value = buildState(
                    errorMessage = e.message ?: e::class.simpleName ?: "model download failed",
                )
            }
        }
    }

    fun cancelDownload() {
        downloadJob?.cancel()
        downloadJob = null
    }

    private fun buildState(errorMessage: String? = null): LocalTranscriptionModelState {
        val selected = selectedModel(selectedModelId())
        val options = models.map { model ->
            LocalTranscriptionModelOptionState(
                model = model,
                downloaded = runCatching { isDownloaded(model.id) }.getOrDefault(false),
            )
        }
        val selectedDownloaded = options.firstOrNull { it.model.id == selected.id }?.downloaded == true
        return LocalTranscriptionModelState(
            modelName = selected.modelNameForProvenance,
            modelVersion = selected.modelVersionForProvenance,
            selectedModelId = selected.id,
            options = options,
            downloaded = selectedDownloaded,
            downloading = false,
            downloadedBytes = 0,
            totalBytes = selected.downloadBytes,
            installing = false,
            errorMessage = errorMessage,
        )
    }

    private fun selectedModel(modelId: String): LocalTranscriptionModelSpec =
        models.firstOrNull { it.id == modelId }
            ?: models.firstOrNull { it.id == LocalTranscriptionModels.DEFAULT_MODEL_ID }
            ?: models.first()
}
