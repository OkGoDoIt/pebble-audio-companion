package dev.audiocompanion.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
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
    val errorMessage: String? = null,
)

class LocalTranscriptionModelManager(
    modelName: String,
    modelVersion: String,
    private val isDownloaded: () -> Boolean,
    private val ensureDownloaded: suspend () -> Unit,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
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
            _state.value = _state.value.copy(
                downloaded = downloaded,
                downloading = false,
                errorMessage = null,
            )
        }
    }

    fun download() {
        if (_state.value.downloading) return
        scope.launch {
            _state.value = _state.value.copy(downloading = true, errorMessage = null)
            try {
                ensureDownloaded()
                _state.value = _state.value.copy(
                    downloaded = true,
                    downloading = false,
                    errorMessage = null,
                )
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    downloaded = runCatching { isDownloaded() }.getOrDefault(false),
                    downloading = false,
                    errorMessage = e.message ?: e::class.simpleName ?: "model download failed",
                )
            }
        }
    }
}
