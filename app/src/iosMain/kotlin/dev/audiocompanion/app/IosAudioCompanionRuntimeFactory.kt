@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package dev.audiocompanion.app

import dev.audiocompanion.adapter.ble.IosAudioGattLink
import dev.audiocompanion.ai.AiModeRouter
import dev.audiocompanion.ai.FileAiOutputStore
import dev.audiocompanion.ai.FileSegmentAnnotationStore
import dev.audiocompanion.ai.OpenAiChatAiProvider
import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.storage.FileReceiverResumeStore
import dev.audiocompanion.storage.FreeSpaceProvider
import dev.audiocompanion.storage.RetentionManager
import dev.audiocompanion.storage.SegmentStore
import dev.audiocompanion.transcription.CactusLocalTranscriptionProvider
import dev.audiocompanion.transcription.CactusModelPathProvider
import dev.audiocompanion.transcription.FileTranscriptStore
import dev.audiocompanion.transcription.FileTranscriptionQueue
import dev.audiocompanion.transcription.OpenAiTranscriptionProvider
import dev.audiocompanion.transcription.SpeexFrameDecoder
import dev.audiocompanion.transcription.TranscriptionException
import dev.audiocompanion.transcription.TranscriptionModeRouter
import dev.audiocompanion.transcription.TranscriptionProcessor
import dev.audiocompanion.transport.ReceiverConfig
import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import kotlinx.coroutines.flow.flow
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSFileSystemFreeSize
import platform.Foundation.NSNumber
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSUserDefaults
import platform.Foundation.NSUserDomainMask
import kotlin.random.Random

class IosAudioCompanionRuntimeFactory(
    private val defaults: NSUserDefaults = NSUserDefaults.standardUserDefaults,
    private val filesRoot: String = defaultFilesRoot(),
) {
    fun create(
        link: IosAudioGattLink,
        settingsRepository: AudioCompanionSettingsRepository,
        modelProvider: CactusModelPathProvider = IosCactusModelPathProvider(),
    ): AudioCompanionRuntime {
        val root = Path(filesRoot, "audio-companion")
        val nowMs = { (kotlin.time.Clock.System.now().toEpochMilliseconds()) }
        val store = SegmentStore(SystemFileSystem, root, nowMs)
        val retention = RetentionManager(
            store = store,
            freeSpace = IosFreeSpaceProvider(filesRoot),
            nowMs = nowMs,
        )
        val transcriptionQueue = FileTranscriptionQueue(SystemFileSystem, root, nowMs)
        val transcriptStore = FileTranscriptStore(SystemFileSystem, root, nowMs)
        val localProvider = CactusLocalTranscriptionProvider(modelProvider = modelProvider)
        val remoteProvider = OpenAiTranscriptionProvider(
            client = HttpClient(Darwin),
            apiKey = { settingsRepository.settings.value.openAiApiKey },
            cloudConsent = { settingsRepository.settings.value.cloudTranscriptionConsent },
        )
        val router = TranscriptionModeRouter(
            local = localProvider,
            remote = remoteProvider,
            mode = { settingsRepository.settings.value.transcriptionMode },
        )
        val aiRouter = AiModeRouter(
            local = null, // No local LLM yet; LocalOnly/LocalFirst surface as unavailable.
            remote = OpenAiChatAiProvider(
                client = HttpClient(Darwin),
                apiKey = { settingsRepository.settings.value.openAiApiKey },
                remoteConsent = { settingsRepository.settings.value.remoteAiConsent },
            ),
            mode = { settingsRepository.settings.value.aiMode },
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
                transcriptStore = transcriptStore,
            ),
            transcriptStore = transcriptStore,
            aiOutputStore = FileAiOutputStore(SystemFileSystem, root, nowMs),
            annotationStore = FileSegmentAnnotationStore(SystemFileSystem, root, nowMs),
            receiverConfig = ReceiverConfig(
                receiverId = loadOrCreateReceiverId(),
                receiverName = "Audio Companion iOS",
            ),
            nowMs = nowMs,
            aiRouter = aiRouter,
            liveMonitor = LiveAudioMonitor(decoder = SpeexLiveFrameDecoder(), nowMs = nowMs),
            playback = SegmentPlaybackController(
                playerFactory = { IosPcmAudioPlayer() },
                decoder = SpeexLiveFrameDecoder(),
                frameSource = { segmentId -> store.readFrames(segmentId).map { it.payload } },
            ),
        )
    }

    private fun loadOrCreateReceiverId(): ByteArray {
        defaults.stringForKey(KEY_RECEIVER_ID)?.hexToByteArrayOrNull()?.let { decoded ->
            if (decoded.size == ProtocolConstants.RECEIVER_ID_BYTES) return decoded
        }
        val id = Random.nextBytes(ProtocolConstants.RECEIVER_ID_BYTES)
        defaults.setObject(id.toHex(), forKey = KEY_RECEIVER_ID)
        return id
    }

    private class IosFreeSpaceProvider(
        private val path: String,
    ) : FreeSpaceProvider {
        override fun freeBytes(): Long {
            val attributes = NSFileManager.defaultManager.attributesOfFileSystemForPath(path, null)
            val free = attributes?.get(NSFileSystemFreeSize) as? NSNumber
            return free?.longLongValue ?: 0L
        }
    }

    companion object {
        private const val KEY_RECEIVER_ID = "receiver_id_v1"

        private fun defaultFilesRoot(): String {
            val root = NSSearchPathForDirectoriesInDomains(
                NSApplicationSupportDirectory,
                NSUserDomainMask,
                true,
            ).first() as String
            NSFileManager.defaultManager.createDirectoryAtPath(
                root,
                withIntermediateDirectories = true,
                attributes = null,
                error = null,
            )
            return root
        }
    }
}

private fun ByteArray.toHex(): String =
    joinToString(separator = "") { byte -> byte.toUByte().toString(16).padStart(2, '0') }

private fun String.hexToByteArrayOrNull(): ByteArray? {
    if (length % 2 != 0) return null
    return runCatching {
        ByteArray(length / 2) { index ->
            substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }.getOrNull()
}
