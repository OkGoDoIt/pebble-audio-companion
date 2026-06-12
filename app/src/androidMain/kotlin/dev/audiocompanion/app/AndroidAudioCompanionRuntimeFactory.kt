package dev.audiocompanion.app

import android.content.Context
import android.os.Build
import android.util.Base64
import dev.audiocompanion.ai.FileAiOutputStore
import dev.audiocompanion.adapter.ble.AndroidAudioGattLink
import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.storage.FileReceiverResumeStore
import dev.audiocompanion.storage.FreeSpaceProvider
import dev.audiocompanion.storage.RetentionManager
import dev.audiocompanion.storage.SegmentStore
import dev.audiocompanion.transcription.FileTranscriptionQueue
import dev.audiocompanion.transcription.LocalPlaceholderTranscriptionProvider
import dev.audiocompanion.transcription.SpeexFrameDecoder
import dev.audiocompanion.transcription.TranscriptionException
import dev.audiocompanion.transcription.TranscriptionModeRouter
import dev.audiocompanion.transcription.TranscriptionProcessor
import dev.audiocompanion.transport.ReceiverConfig
import java.security.SecureRandom
import kotlinx.coroutines.flow.flow
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem

class AndroidAudioCompanionRuntimeFactory(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val secureRandom = SecureRandom()

    fun create(
        link: AndroidAudioGattLink,
        settingsRepository: AudioCompanionSettingsRepository,
    ): AudioCompanionRuntime {
        val root = Path(appContext.filesDir.absolutePath, "audio-companion")
        val nowMs = { System.currentTimeMillis() }
        val store = SegmentStore(SystemFileSystem, root, nowMs)
        val retention = RetentionManager(
            store = store,
            freeSpace = AndroidFreeSpaceProvider(appContext),
            nowMs = nowMs,
        )
        val transcriptionQueue = FileTranscriptionQueue(SystemFileSystem, root, nowMs)
        val localProvider = LocalPlaceholderTranscriptionProvider()
        val router = TranscriptionModeRouter(
            local = localProvider,
            remote = null,
            mode = { settingsRepository.settings.value.transcriptionMode },
        )
        return AudioCompanionRuntime(
            link = link,
            store = store,
            retention = retention,
            resumeStore = FileReceiverResumeStore(SystemFileSystem, root),
            transcriptionQueue = transcriptionQueue,
            transcriptionProcessor = TranscriptionProcessor(
                queue = transcriptionQueue,
                router = router,
                pcmSource = { segmentId ->
                    val meta = store.readMeta(segmentId)
                        ?: throw TranscriptionException.TranscriptionFailed(
                            "missing metadata for segment $segmentId",
                        )
                    val decoder = SpeexFrameDecoder(
                        sampleRateHz = meta.sampleRateHz.toInt(),
                        bitRateBps = meta.bitRateBps.toInt(),
                        frameSamples = meta.frameSamples,
                    )
                    decoder.decode(
                        flow {
                            for (record in store.readFrames(segmentId)) {
                                emit(record.payload)
                            }
                        },
                    )
                },
                onStateChanged = { segmentId, state ->
                    store.updateTranscriptionState(
                        segmentId,
                        AudioCompanionRuntime.segmentTranscriptionState(state),
                    )
                },
            ),
            aiOutputStore = FileAiOutputStore(SystemFileSystem, root, nowMs),
            receiverConfig = ReceiverConfig(
                receiverId = loadOrCreateReceiverId(),
                receiverName = receiverName(),
            ),
            nowMs = nowMs,
        )
    }

    private fun loadOrCreateReceiverId(): ByteArray {
        prefs.getString(KEY_RECEIVER_ID, null)?.let { encoded ->
            val decoded = Base64.decode(encoded, Base64.NO_WRAP)
            if (decoded.size == ProtocolConstants.RECEIVER_ID_BYTES) return decoded
        }
        val id = ByteArray(ProtocolConstants.RECEIVER_ID_BYTES)
        secureRandom.nextBytes(id)
        prefs.edit()
            .putString(KEY_RECEIVER_ID, Base64.encodeToString(id, Base64.NO_WRAP))
            .apply()
        return id
    }

    private fun receiverName(): String {
        val model = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android"
        val candidate = "Audio Companion $model"
        if (candidate.encodeToByteArray().size <= ProtocolConstants.MAX_RECEIVER_NAME_BYTES) {
            return candidate
        }
        var end = candidate.length
        while (end > 0) {
            val truncated = candidate.substring(0, end)
            if (truncated.encodeToByteArray().size <= ProtocolConstants.MAX_RECEIVER_NAME_BYTES) {
                return truncated
            }
            end -= 1
        }
        return "Audio Companion"
    }

    private class AndroidFreeSpaceProvider(
        private val context: Context,
    ) : FreeSpaceProvider {
        override fun freeBytes(): Long = context.filesDir.usableSpace
    }

    companion object {
        private const val PREFS_NAME = "audio_companion_runtime"
        private const val KEY_RECEIVER_ID = "receiver_id_v1"
    }
}
