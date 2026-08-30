package dev.audiocompanion.app

import android.content.Context
import android.os.Build
import android.util.Base64
import androidx.core.content.edit
import dev.audiocompanion.ai.AiModeRouter
import dev.audiocompanion.ai.AiModels
import dev.audiocompanion.ai.FileActionItemStore
import dev.audiocompanion.ai.FileAiOutputStore
import dev.audiocompanion.ai.FileCustomTemplateStore
import dev.audiocompanion.ai.FileDailyDigestStore
import dev.audiocompanion.ai.FilePersonalContextStore
import dev.audiocompanion.ai.FileRuleStore
import dev.audiocompanion.ai.FileSegmentAnnotationStore
import dev.audiocompanion.ai.FileSpeakerIdentityStore
import dev.audiocompanion.search.createAndroidTranscriptIndex
import dev.audiocompanion.ai.OnDeviceAiProvider
import dev.audiocompanion.ai.OpenAiChatAiProvider
import dev.audiocompanion.ai.PersonalContextTermExtractor
import dev.audiocompanion.adapter.ble.AndroidAudioGattLink
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
import dev.audiocompanion.transcription.OpenAiRealtimeProvider
import dev.audiocompanion.transcription.SelectableCloudTranscriptionProvider
import dev.audiocompanion.transcription.SelectableStreamingTranscriptionProvider
import dev.audiocompanion.transcription.SonioxRealtimeProvider
import dev.audiocompanion.transcription.SonioxTranscriptionProvider
import dev.audiocompanion.transcription.SpeexFrameDecoder
import dev.audiocompanion.transcription.TranscriptionException
import dev.audiocompanion.transcription.TranscriptionMode
import dev.audiocompanion.transcription.TranscriptionModeRouter
import dev.audiocompanion.transcription.TranscriptionProcessor
import dev.audiocompanion.transport.ReceiverConfig
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.websocket.WebSockets
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
        modelProvider: CactusModelPathProvider = AndroidCactusModelPathProvider(
            appContext,
            selectedModelId = { settingsRepository.settings.value.localTranscriptionModelId },
        ),
    ): AudioCompanionRuntime {
        val root = Path(appContext.filesDir.absolutePath, "audio-companion")
        val nowMs = { System.currentTimeMillis() }
        val store = SegmentStore(SystemFileSystem, root, nowMs, log = ::println)
        val retention = RetentionManager(
            store = store,
            freeSpace = AndroidFreeSpaceProvider(appContext),
            nowMs = nowMs,
        )
        val transcriptionQueue = FileTranscriptionQueue(SystemFileSystem, root, nowMs)
        val transcriptStore = FileTranscriptStore(SystemFileSystem, root, nowMs)
        val localProvider = CactusLocalTranscriptionProvider(
            modelProvider = modelProvider,
            nowMs = nowMs,
        )
        val cloudHttpClient = HttpClient(OkHttp)
        val cloudConsent = { settingsRepository.settings.value.cloudTranscriptionEnabled }
        val diarizationEnabled = { settingsRepository.settings.value.speakerLabelsEnabled }
        val personalContextStore = FilePersonalContextStore(SystemFileSystem, root)
        var personalContextCoordinator: PersonalContextCoordinator? = null
        val personalContextText = { personalContextCoordinator?.transcriptionText() }
        val personalContextTerms = { personalContextCoordinator?.transcriptionTerms() ?: emptyList() }
        val sttPrompt = { personalContextCoordinator?.openAiSttPrompt() }
        val aiGrounding = { personalContextCoordinator?.aiGroundingBlock() }
        val remoteProvider = SelectableCloudTranscriptionProvider(
            selected = { settingsRepository.settings.value.cloudTranscriptionProvider },
            openAi = OpenAiTranscriptionProvider(
                client = cloudHttpClient,
                apiKey = { settingsRepository.settings.value.openAiApiKey },
                cloudConsent = cloudConsent,
                diarizationEnabled = diarizationEnabled,
                sttPrompt = sttPrompt,
            ),
            soniox = SonioxTranscriptionProvider(
                client = cloudHttpClient,
                apiKey = { settingsRepository.settings.value.sonioxApiKey },
                cloudConsent = cloudConsent,
                diarizationEnabled = diarizationEnabled,
                contextText = personalContextText,
                contextTerms = personalContextTerms,
            ),
        )
        val cloudHealthMonitor = CloudHealthMonitor(nowMs)
        val router = TranscriptionModeRouter(
            local = localProvider,
            remote = remoteProvider,
            mode = { settingsRepository.settings.value.transcriptionMode },
            onRemoteOutcome = cloudHealthMonitor::report,
        )
        val aiRouter = AiModeRouter(
            // On-device Gemini Nano (ML Kit GenAI). Reports unavailable on unsupported devices, so
            // LocalOnly/LocalFirst degrade gracefully.
            local = OnDeviceAiProvider(
                AndroidGeminiNanoLanguageModel(),
                grounding = aiGrounding,
            ),
            remote = OpenAiChatAiProvider(
                client = HttpClient(OkHttp),
                apiKey = { settingsRepository.settings.value.openAiApiKey },
                remoteConsent = { settingsRepository.settings.value.remoteAiEnabled },
                model = { AiModels.byId(settingsRepository.settings.value.aiModel).id },
                grounding = aiGrounding,
            ),
            mode = { settingsRepository.settings.value.aiMode },
        )
        personalContextCoordinator = PersonalContextCoordinator(
            store = personalContextStore,
            extractor = PersonalContextTermExtractor(aiRouter),
        )
        personalContextCoordinator.reloadFromDisk()
        val liveAudioTap = LiveAudioTap()
        val streamingClient = HttpClient(OkHttp) { install(WebSockets) }
        val cloudLiveTranscriber = CloudLiveTranscriber(
            tap = liveAudioTap,
            provider = SelectableStreamingTranscriptionProvider(
                selected = { settingsRepository.settings.value.cloudTranscriptionProvider },
                openAi = OpenAiRealtimeProvider(
                    client = streamingClient,
                    apiKey = { settingsRepository.settings.value.openAiApiKey },
                    cloudConsent = cloudConsent,
                ),
                soniox = SonioxRealtimeProvider(
                    client = streamingClient,
                    apiKey = { settingsRepository.settings.value.sonioxApiKey },
                    cloudConsent = cloudConsent,
                    diarizationEnabled = diarizationEnabled,
                    contextText = personalContextText,
                    contextTerms = personalContextTerms,
                ),
            ),
            enabled = { settingsRepository.settings.value.liveCloudTranscriptionEnabled },
            nowMs = nowMs,
            onOutcome = cloudHealthMonitor::report,
        )
        val digestStore = FileDailyDigestStore(SystemFileSystem, root, nowMs)
        val actionItemStore = FileActionItemStore(SystemFileSystem, root, nowMs)
        val customTemplateStore = FileCustomTemplateStore(SystemFileSystem, root, nowMs)
        val ruleStore = FileRuleStore(SystemFileSystem, root, nowMs)
        val speakerIdentityStore = FileSpeakerIdentityStore(SystemFileSystem, root, nowMs)
        val transcriptIndex = createAndroidTranscriptIndex(appContext)
        val transcriptIndexDonator = TranscriptIndexDonator(transcriptIndex)
        val askRetriever = AskRetriever(transcriptIndex)
        val ruleEvaluator = RuleEvaluator(
            ruleStore = ruleStore,
            segmentStore = store,
            transcriptStore = transcriptStore,
            aiRouter = aiRouter,
            nowMs = nowMs,
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
                receiverName = receiverName(),
            ),
            nowMs = nowMs,
            aiRouter = aiRouter,
            liveMonitor = LiveAudioMonitor(decoder = SpeexLiveFrameDecoder(), nowMs = nowMs),
            // Live preview is deliberately local-only: a cloud provider would be called once
            // per ~8 s chunk. Cloud-only users get their transcript when the segment closes.
            liveTranscriber = LiveTranscriber(
                openSegmentId = { store.openSegmentId },
                readMeta = store::readMeta,
                readFrames = store::readFrames,
                router = TranscriptionModeRouter(
                    local = localProvider,
                    remote = null,
                    mode = { TranscriptionMode.LocalOnly },
                ),
                nowMs = nowMs,
            ),
            playback = SegmentPlaybackController(
                playerFactory = { AndroidPcmAudioPlayer() },
                decoder = SpeexLiveFrameDecoder(),
                frameSource = { segmentId -> store.readFrames(segmentId).map { it.payload } },
            ),
            waveformBuilder = SegmentWaveformBuilder(decoder = SpeexLiveFrameDecoder()),
            exportManager = AudioExportManager(
                fileSystem = SystemFileSystem,
                exportRoot = AndroidExportRootProvider.exportRoot(appContext),
                listSegments = store::listSegments,
                readMeta = store::readMeta,
                readFrames = store::readFrames,
                decodePcm = { meta, frames ->
                    val decoder = SpeexFrameDecoder(
                        sampleRateHz = meta.sampleRateHz.toInt(),
                        bitRateBps = meta.bitRateBps.toInt(),
                        frameSamples = meta.frameSamples,
                    )
                    decoder.decode(flow { frames.forEach { emit(it.payload) } })
                },
            ),
            automaticWavExportEnabled = {
                settingsRepository.settings.value.automaticWavExportEnabled
            },
            desiredEnabled = {
                settingsRepository.settings.value.backgroundReceiverEnabled
            },
            localTranscriptionLifecycle = localProvider,
            cloudLiveTranscriber = cloudLiveTranscriber,
            liveAudioTap = liveAudioTap,
            cloudHealthMonitor = cloudHealthMonitor,
            cloudConnectivityCheck = remoteProvider,
            personalContextCoordinator = personalContextCoordinator,
            personalContextImporter = AndroidPersonalContextImporter(appContext),
            digestStore = digestStore,
            actionItemStore = actionItemStore,
            customTemplateStore = customTemplateStore,
            ruleStore = ruleStore,
            speakerIdentityStore = speakerIdentityStore,
            transcriptIndexDonator = transcriptIndexDonator,
            askRetriever = askRetriever,
            ruleEvaluator = ruleEvaluator,
        )
    }

    private fun loadOrCreateReceiverId(): ByteArray {
        prefs.getString(KEY_RECEIVER_ID, null)?.let { encoded ->
            val decoded = Base64.decode(encoded, Base64.NO_WRAP)
            if (decoded.size == ProtocolConstants.RECEIVER_ID_BYTES) return decoded
        }
        val id = ByteArray(ProtocolConstants.RECEIVER_ID_BYTES)
        secureRandom.nextBytes(id)
        prefs.edit {
            putString(KEY_RECEIVER_ID, Base64.encodeToString(id, Base64.NO_WRAP))
        }
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

    private object AndroidExportRootProvider {
        fun exportRoot(context: Context): Path {
            val external = context.getExternalFilesDir(android.os.Environment.DIRECTORY_MUSIC)
            val root = external ?: context.filesDir.resolve("exports")
            return Path(root.absolutePath, "PebbleAudioExports")
        }
    }

    companion object {
        private const val PREFS_NAME = "audio_companion_runtime"
        private const val KEY_RECEIVER_ID = "receiver_id_v1"
    }
}
