package dev.audiocompanion.app

import androidx.compose.ui.window.ComposeUIViewController
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.audiocompanion.app.ui.AppActions
import dev.audiocompanion.app.ui.AudioCompanionTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okio.FileSystem
import okio.Path.Companion.toPath
import platform.Foundation.NSNotificationCenter
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSURL
import platform.UIKit.UIActivityViewController
import platform.UIKit.UIApplication
import platform.UIKit.UIApplicationDidEnterBackgroundNotification
import platform.UIKit.UIApplicationWillEnterForegroundNotification
import platform.UIKit.UIViewController

object IosAudioCompanionBootstrap {
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default + iosCoroutineExceptionHandler("bootstrap"),
    )
    private val handleMutex = Mutex()
    private val _handle = MutableStateFlow<IosAudioCompanionRuntimeHandle?>(null)
    val handleState: StateFlow<IosAudioCompanionRuntimeHandle?> = _handle.asStateFlow()
    private var maintenanceJob: kotlinx.coroutines.Job? = null

    private suspend fun ensureHandle(): IosAudioCompanionRuntimeHandle =
        handleMutex.withLock {
            _handle.value ?: IosAudioCompanionRuntimeHandle().also { _handle.value = it }
        }

    fun prepareForUi() {
        scope.launch { ensureHandle() }
    }

    fun applicationDidFinishLaunching(launchedInBackground: Boolean) {
        // The app uses the scene lifecycle (Info.plist UIApplicationSceneManifest), so UIKit does
        // NOT call the app delegate's applicationWillEnterForeground/applicationDidEnterBackground.
        // didFinishLaunching is still called, so register foreground/background observers here from
        // the always-delivered UIApplication notifications. Without this, a Core Bluetooth
        // background relaunch (which sets receive-only below) would leave the app stuck in
        // receive-only mode even after the user reopens it — transcription would never run.
        registerLifecycleObservers()
        scope.launch {
            val handle = ensureHandle()
            // Apply the receive-only policy before starting the receiver when we are launched
            // straight into the background (Core Bluetooth restoration), so no heavy foreground
            // transcription pass runs at the most jetsam-prone moment.
            if (launchedInBackground) {
                handle.runtime.setForeground(false)
            }
            if (handle.settingsRepository.settings.value.backgroundReceiverEnabled) {
                handle.startReceiver()
            } else {
                handle.connectWatch()
                handle.runtime.recoverDurableState()
            }
        }
    }

    private var lifecycleObserversRegistered = false

    /**
     * Subscribes to the UIApplication foreground/background notifications. These are delivered in
     * both the app-delegate and scene lifecycles, unlike the app delegate's
     * applicationWillEnterForeground/Background methods, which a scene-based app never receives.
     * The bootstrap is a process-lived singleton, so the observers never need removing.
     */
    private fun registerLifecycleObservers() {
        if (lifecycleObserversRegistered) return
        lifecycleObserversRegistered = true
        val center = NSNotificationCenter.defaultCenter
        center.addObserverForName(
            name = UIApplicationWillEnterForegroundNotification,
            `object` = null,
            queue = null,
        ) { _ -> applicationWillEnterForeground() }
        center.addObserverForName(
            name = UIApplicationDidEnterBackgroundNotification,
            `object` = null,
            queue = null,
        ) { _ -> applicationDidEnterBackground() }
    }

    fun applicationWillEnterForeground() {
        scope.launch {
            val handle = ensureHandle()
            handle.runtime.setForeground(true)
            if (handle.settingsRepository.settings.value.backgroundReceiverEnabled) {
                // start() is idempotent; this guarantees the processing loop is running so the
                // reconcile below has a consumer to drain the queue.
                handle.startReceiver()
            }
            // Explicitly re-queue anything that closed while backgrounded and wake the loop, so
            // reopening the app reliably resumes transcription (newest segment first).
            handle.runtime.reconcilePendingTranscriptions()
        }
    }

    fun applicationDidEnterBackground() {
        scope.launch {
            val handle = ensureHandle()
            // Keep receiving in the background, but switch processing to receive-only so a short
            // Core Bluetooth wake stays cheap and the app is not a jetsam target.
            if (handle.settingsRepository.settings.value.backgroundReceiverEnabled) {
                handle.startReceiver()
            }
            handle.runtime.setForeground(false)
        }
    }

    /** iOS jetsam pre-warning: drop the resident local model immediately. */
    fun applicationDidReceiveMemoryWarning() {
        scope.launch { ensureHandle().runtime.releaseLocalModel("memory warning") }
    }

    /**
     * iOS handed us background URL session events (an upload finished while suspended). Store the
     * system completion handler and ensure the runtime is up so its upload coordinator reconnects
     * to the session and processes the delivered outcomes.
     */
    fun handleBackgroundUrlSessionEvents(completion: () -> Unit) {
        IosBackgroundUploader.shared.backgroundEventsCompletion = completion
        scope.launch { ensureHandle().startReceiver() }
    }

    fun startReceiver() {
        scope.launch {
            val handle = ensureHandle()
            handle.settingsRepository.setBackgroundReceiverEnabled(true)
            handle.runtime.armWatchEnableRequest()
            handle.startReceiver()
        }
    }

    fun stopReceiver() {
        scope.launch {
            val handle = ensureHandle()
            handle.settingsRepository.setBackgroundReceiverEnabled(false)
            handle.stopReceiver()
        }
    }

    fun refreshDiagnostics() {
        scope.launch { ensureHandle().runtime.refreshDiagnostics() }
    }

    fun openLibrarySegment(segmentId: String) {
        scope.launch {
            ensureHandle().runtime.navigationState.openLibrarySegment(segmentId)
        }
    }

    fun testCloudConnection() {
        scope.launch { ensureHandle().runtime.testCloudConnection() }
    }

    /**
     * Runs one BGProcessingTask's worth of optional maintenance (retention cleanup + diagnostics),
     * then invokes [onComplete] so the host can call setTaskCompleted exactly once. Must never stop
     * the receiver or change the user's background-recording intent (plan: "Fix BGProcessing
     * usage"); on task expiration the host calls [cancelBackgroundMaintenance] instead.
     */
    fun runBackgroundMaintenance(onComplete: () -> Unit) {
        maintenanceJob?.cancel()
        maintenanceJob = scope.launch {
            try {
                val handle = ensureHandle()
                handle.runtime.runBackgroundMaintenance()
                // The BGProcessing window keeps us awake, so opportunistically catch up a bounded,
                // memory-gated batch of pending transcriptions. No-op in the foreground or when the
                // per-process memory budget is tight. Cancelled cleanly by the expiration handler.
                handle.runtime.runCatchUpBurst()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (t: Throwable) {
                logBackgroundFailure("background maintenance", t)
            } finally {
                onComplete()
            }
        }
    }

    /** Cancels in-flight [runBackgroundMaintenance] work without touching the receive path. */
    fun cancelBackgroundMaintenance() {
        maintenanceJob?.cancel()
        maintenanceJob = null
    }

    fun deleteAllLocalData() {
        scope.launch {
            val handle = ensureHandle()
            handle.stopReceiver()
            handle.runtime.deleteAllLocalData()
        }
    }

    fun revokeReceiverLocally() {
        scope.launch {
            val handle = ensureHandle()
            handle.stopReceiver()
            handle.runtime.revokeReceiverLocally()
        }
    }
}

fun MainViewController(): UIViewController {
    val bootstrap = IosAudioCompanionBootstrap
    return ComposeUIViewController {
        LaunchedEffect(Unit) {
            bootstrap.prepareForUi()
        }
        val handle by bootstrap.handleState.collectAsState()
        if (handle == null) {
            StartupScreen()
            return@ComposeUIViewController
        }
        val readyHandle = handle ?: return@ComposeUIViewController
        val runtime = readyHandle.runtime
        val settings = readyHandle.settingsRepository
        App(
            sessionState = runtime.state,
            diagnostics = runtime.diagnostics,
            watchServiceState = runtime.watchServiceState,
            settings = settings.settings,
            localModelState = readyHandle.localModelManager.state,
            liveTranscriptPreviews = runtime.liveTranscriptPreviews,
            waveformBars = runtime.liveMonitor?.bars
                ?: kotlinx.coroutines.flow.MutableStateFlow(emptyList()),
            waveformWindowMs = runtime.liveMonitor?.windowMs ?: 60_000,
            playbackState = runtime.playback?.state
                ?: kotlinx.coroutines.flow.MutableStateFlow(PlaybackUiState()),
            cloudHealth = runtime.cloudHealth,
            personalContext = runtime.personalContext,
            navigationRequest = runtime.navigationState.pending,
            actions = AppActions(
                pairWatch = {
                    // Goes through the bootstrap so the persisted enabled flag stays in sync
                    // with the actually-running receiver.
                    bootstrap.startReceiver()
                    bootstrap.refreshDiagnostics()
                },
                // iOS surfaces the Bluetooth permission dialog when the central first starts;
                // connecting is the permission request.
                requestPermissions = { readyHandle.connectWatch() },
                setOnboardingComplete = settings::setOnboardingComplete,
                startReceiver = bootstrap::startReceiver,
                stopReceiver = bootstrap::stopReceiver,
                setBackgroundReceiverEnabled = { enabled ->
                    if (enabled) {
                        bootstrap.startReceiver()
                    } else {
                        bootstrap.stopReceiver()
                    }
                },
                reconnect = { readyHandle.runtime.reconnect() },
                refreshDiagnostics = bootstrap::refreshDiagnostics,
                setWaveformActive = { active -> runtime.liveMonitor?.setActive(active) },
                playSegment = { segmentId -> runtime.playback?.play(segmentId) },
                pausePlayback = { runtime.playback?.pause() },
                stopPlayback = { runtime.playback?.stop() },
                seekPlayback = { segmentId, positionMs ->
                    runtime.playback?.seekTo(segmentId, positionMs)
                },
                cyclePlaybackSpeed = { runtime.playback?.cycleSpeed() },
                loadSegments = runtime::listSegmentsForUi,
                loadSegmentWaveform = { runtime.segmentWaveform(it) },
                loadTranscript = runtime::transcript,
                loadLiveTranscript = runtime::liveTranscript,
                loadLiveTranscriptPreview = runtime::liveTranscriptPreview,
                loadAnnotation = runtime::annotation,
                loadAiOutputs = runtime::listAiOutputs,
                reprocessSegment = runtime::reprocessSegment,
                deleteSegment = runtime::deleteSegmentData,
                deleteAiOutput = runtime::deleteAiOutput,
                deleteAll = bootstrap::deleteAllLocalData,
                revokeReceiver = bootstrap::revokeReceiverLocally,
                exportSupportReport = {
                    runtime.buildSupportReport(includeContent = false)
                },
                audioExportDirectory = { runtime.audioExportDirectory },
                exportSegmentAudio = { segmentId ->
                    runCatching { runtime.exportSegmentAudio(segmentId) }
                },
                exportAllAudio = {
                    runCatching { runtime.exportAllAudio() }
                },
                shareFile = ::shareFile,
                shareText = ::shareText,
                exportText = { text, filename ->
                    runCatching { exportTextToFile(text, filename) }
                },
                runAi = { template, segmentIds ->
                    runCatching {
                        runtime.runAi(
                            prompt = template,
                            segmentIds = segmentIds,
                            userConsentedToRemote = settings.settings.value.remoteAiEnabled,
                        )
                    }
                },
                runAsk = { question, segmentIds ->
                    runCatching {
                        runtime.runAsk(
                            question = question,
                            segmentIds = segmentIds,
                            userConsentedToRemote = settings.settings.value.remoteAiEnabled,
                        )
                    }
                },
                updateAiOutput = { id, text -> runtime.updateAiOutputText(id, text) },
                loadDailyDigests = runtime::listDailyDigests,
                loadActionItems = runtime::listActionItems,
                setActionItemDone = { id, done -> runtime.setActionItemDone(id, done) },
                loadCustomTemplates = runtime::listCustomTemplates,
                saveCustomTemplate = { title, prompt -> runtime.saveCustomTemplate(title, prompt) },
                openLibrarySegment = { segmentId ->
                    runtime.navigationState.openLibrarySegment(segmentId)
                },
                consumeNavigationRequest = {
                    runtime.navigationState.consumePending()
                },
                setRetentionDays = settings::setRetentionDays,
                setTranscriptionMode = {
                    settings.setTranscriptionMode(it)
                    runtime.notifyTranscriptionConfigChanged()
                },
                setLocalTranscriptionModel = {
                    settings.setLocalTranscriptionModel(it)
                    readyHandle.localModelManager.refreshSelection()
                    runtime.notifyTranscriptionConfigChanged()
                },
                setCloudTranscriptionProvider = {
                    settings.setCloudTranscriptionProvider(it)
                    runtime.notifyTranscriptionConfigChanged()
                },
                setOpenAiApiKey = {
                    settings.setOpenAiApiKey(it)
                    runtime.notifyTranscriptionConfigChanged()
                },
                setSonioxApiKey = {
                    settings.setSonioxApiKey(it)
                    runtime.notifyTranscriptionConfigChanged()
                },
                testCloudConnection = bootstrap::testCloudConnection,
                setAiMode = settings::setAiMode,
                setAiModel = settings::setAiModel,
                setRemoteAiConsent = settings::setRemoteAiConsent,
                setAutomaticWavExportEnabled = {
                    settings.setAutomaticWavExportEnabled(it)
                    runtime.notifyExportConfigChanged()
                },
                setPersonalContextProfileText = { text ->
                    runtime.setPersonalContextProfileText(text)
                },
                clearPersonalContext = { runtime.clearPersonalContext() },
                importPersonalContacts = { runtime.importContactsIntoPersonalContext() },
                importPersonalCalendar = { runtime.importCalendarIntoPersonalContext() },
                refreshLocalModel = readyHandle.localModelManager::refresh,
                downloadLocalModel = readyHandle.localModelManager::download,
                cancelModelDownload = readyHandle.localModelManager::cancelDownload,
            ),
        )
    }
}

@Composable
private fun StartupScreen() {
    AudioCompanionTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
                horizontalAlignment = Alignment.Start,
                verticalArrangement = Arrangement.Center,
            ) {
                Text(text = "Pebble Audio", style = MaterialTheme.typography.headlineMedium)
                Text(
                    text = "Opening your audio library...",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        }
    }
}

private fun shareFile(path: String) {
    val url = NSURL.fileURLWithPath(path)
    val controller = UIActivityViewController(
        activityItems = listOf(url),
        applicationActivities = null,
    )
    topViewController()?.presentViewController(controller, animated = true, completion = null)
}

private fun shareText(text: String, title: String) {
    val controller = UIActivityViewController(
        activityItems = listOf(text),
        applicationActivities = null,
    )
    topViewController()?.presentViewController(controller, animated = true, completion = null)
}

private fun exportTextToFile(text: String, filename: String): String {
    val safeName = filename.replace(Regex("[^a-zA-Z0-9._-]"), "_")
    val path = NSTemporaryDirectory() + safeName
    FileSystem.SYSTEM.write(path.toPath()) {
        writeUtf8(text)
    }
    return path
}

private fun topViewController(): UIViewController? {
    var controller = UIApplication.sharedApplication.keyWindow?.rootViewController
    while (controller?.presentedViewController != null) {
        controller = controller.presentedViewController
    }
    return controller
}
