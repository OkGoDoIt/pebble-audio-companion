import AppDB
import BackgroundTasks
import CompanionRuntime
import Foundation
import Intelligence
import LiveAudio
import Migration
import Receiver
import SearchKit
import SegmentStore
import StatusUI
import Transcription
import UIKit

// The app's composition root. Built exactly once, at launch, from `PebbleAudioApp`.
//
// Everything real lives here: the App Group database, the segment spool, the transcription
// queue and its providers, the AI layer, the receiver, the runtime actor, and the lifecycle
// plumbing. The screens never construct any of it — they read the three `*.current` data-source
// holders, which this file flips from the mock world to the live one at the end of `bootstrap`.
//
// The mock holders are left in place for `#Preview` blocks: a preview never runs `bootstrap`,
// so it still renders the approved artboard content.

@MainActor
final class AppComposition {
    /// The one graph. Nil in previews and until `bootstrap` runs.
    private(set) static var shared: AppComposition?

    // --- infrastructure ---------------------------------------------------------------------

    let settings: AppSettings
    let clock: RuntimeClock
    let containerRoot: URL
    let database: AppDatabase
    let store: SegmentStore
    /// Synchronous, actor-free view of the spool (the kit's sync reader seams need one).
    let files: SegmentFileReader
    let retention: RetentionManager
    let transcripts: FileTranscriptStore

    // --- stores -----------------------------------------------------------------------------

    let tags: TagStore
    let followUps: FollowUpStore
    let askHistory: AskHistoryStore
    let notes: NotesStore
    let people: PeopleStore
    let pauseJournal: PauseJournal
    let customTemplates: CustomTemplateStore
    let annotations: AnnotationStore
    let aiOutputs: AiOutputStore
    let recapStore: DailyRecapStore
    let personalContext: FilePersonalContextStore

    // --- pipeline ---------------------------------------------------------------------------

    let queue: TranscriptionQueue
    let cloudHealth: CloudHealthMonitor
    let localModel: LocalModelManager
    let aiRouter: AiModeRouter
    let index: TranscriptIndex
    let donator: SpotlightDonator
    let askRetriever: AskRetriever
    let monitor: LiveAudioMonitor
    let liveTap: LiveAudioTap
    let openSegment: OpenSegmentTracker
    /// Live preview producers, held so the Live screen can read their rolling text (the
    /// `LiveAudioService` facade only drives their passes).
    let localLive: LiveTranscriber
    let cloudLive: CloudLiveTranscriber
    let runtime: CompanionRuntime
    /// The background `URLSession` transport, held so `handleEventsForBackgroundURLSession` can
    /// hand it the system completion handler.
    private let backgroundUploader: URLSessionBackgroundUploader

    // --- lifecycle --------------------------------------------------------------------------

    private let lifecycle: AppLifecycleCoordinator
    private let lifecycleObserver: UIApplicationLifecycleObserver
    private var didRegisterBackgroundTask = false
    private var todaySource: LiveTodayDataSource?

    // MARK: - Bootstrap

    /// Builds the graph, installs the live data sources, and starts the runtime. Safe to call
    /// more than once — the second call returns the existing graph.
    @discardableResult
    static func bootstrap(
        settings: AppSettings,
        nativeSurfaces: NativeSurfaceCoordinator
    ) -> AppComposition? {
        if let shared { return shared }
        do {
            let composition = try AppComposition(settings: settings)
            shared = composition
            composition.install(nativeSurfaces: nativeSurfaces)
            return composition
        } catch {
            // A database that will not open is fatal to everything downstream, but the app must
            // still launch and say something calm rather than crash on the splash screen. The
            // mock holders stay in place; the failure goes to the diagnostics log.
            AppRuntimeLog.shared.record("composition failed: \(error)")
            return nil
        }
    }

    private init(settings: AppSettings) throws {
        self.settings = settings
        let clock = SystemClock()
        self.clock = clock
        let nowMs: @Sendable () -> Int64 = { clock.nowMs }
        let settingsBox = settings.runtimeSettings
        let keychain = settings.keychain

        // The container root is the OLD app's root on purpose: `LegacyImporter` indexes the
        // migrated spool in place, so the new store has to read the same directory.
        let containerRoot = try LegacyImporter.defaultContainerRoot()
        try FileManager.default.createDirectory(
            at: containerRoot, withIntermediateDirectories: true
        )
        self.containerRoot = containerRoot

        let database = try AppDatabase.open(at: AppDatabase.defaultDatabaseURL())
        self.database = database
        let store = SegmentStore(root: containerRoot, nowMs: nowMs)
        self.store = store
        let files = SegmentFileReader(root: containerRoot)
        self.files = files
        let transcripts = FileTranscriptStore(root: containerRoot, nowMs: nowMs)
        self.transcripts = transcripts

        let retention = RetentionManager(
            store: store,
            freeSpace: VolumeFreeSpace(),
            nowMs: nowMs,
            config: { retentionConfig(for: settingsBox) }
        )
        self.retention = retention

        tags = TagStore(db: database)
        let followUps = FollowUpStore(db: database)
        self.followUps = followUps
        askHistory = AskHistoryStore(db: database)
        notes = NotesStore(db: database)
        people = PeopleStore(db: database)
        let pauseJournal = PauseJournal(db: database)
        self.pauseJournal = pauseJournal
        customTemplates = CustomTemplateStore(db: database)
        let annotations = try AnnotationStore(db: database, nowMs: nowMs)
        self.annotations = annotations
        let aiOutputs = AiOutputStore(db: database, nowMs: nowMs)
        self.aiOutputs = aiOutputs
        let recapStore = DailyRecapStore(db: database, nowMs: nowMs)
        self.recapStore = recapStore
        let personalContext = FilePersonalContextStore(root: containerRoot)
        self.personalContext = personalContext

        let index = TranscriptIndex(database: database)
        self.index = index
        let donator = SpotlightDonator(index: index, spotlight: CoreSpotlightIndexer())
        self.donator = donator
        askRetriever = AskRetriever { query, limit in
            let hits = (try? index.search(query, limit: limit)) ?? []
            return hits.map { AskIndexHit(id: $0.id, score: Float($0.score)) }
        }

        let queue = TranscriptionQueue(database: database, nowMs: nowMs)
        self.queue = queue
        let cloudHealth = CloudHealthMonitor(nowMs: nowMs)
        self.cloudHealth = cloudHealth
        // Wi-Fi-only is a promise Settings makes in writing, so it is enforced where we can:
        // at download START. (The system asset transfer itself exposes no network constraint.)
        localModel = LocalModelManager(
            inventory: SystemSpeechAssetInventory(),
            wifiOnly: { true },
            isOnWiFi: { NetworkReachability.shared.isUnmetered }
        )

        // --- transcription providers ---------------------------------------------------------

        let transport = URLSessionHttpTransport()
        let openAiKey: @Sendable () -> String? = { keychain.string(for: .openAiApiKey) }
        let sonioxKey: @Sendable () -> String? = { keychain.string(for: .sonioxApiKey) }
        let cloudConsent: @Sendable () -> Bool = { settingsBox.cloudTranscriptionEnabled }
        let diarize: @Sendable () -> Bool = { settingsBox.speakerLabelsEnabled }
        // "About You" feeds transcription bias and AI grounding — budgeted by the kit, never
        // dumped whole into a prompt.
        let sonioxContext: @Sendable () -> String? = {
            PersonalContextFormatting.transcriptionText(personalContext.load())
        }
        let sttPrompt: @Sendable () -> String? = {
            PersonalContextFormatting.openAiSttPrompt(personalContext.load())
        }
        let contextTerms: @Sendable () -> [String] = {
            PersonalContextFormatting.transcriptionTerms(personalContext.load())
        }
        let aiGrounding: @Sendable () -> String? = {
            PersonalContextFormatting.aiGroundingBlock(personalContext.load())
        }

        let batchCloud = SelectableCloudTranscriptionProvider(
            selected: { settingsBox.cloudTranscriptionProvider },
            openAi: OpenAiTranscriptionProvider(
                transport: transport,
                apiKey: openAiKey,
                cloudConsent: cloudConsent,
                diarizationEnabled: diarize,
                sttPrompt: sttPrompt
            ),
            soniox: SonioxTranscriptionProvider(
                transport: transport,
                apiKey: sonioxKey,
                cloudConsent: cloudConsent,
                diarizationEnabled: diarize,
                contextText: sonioxContext,
                contextTerms: contextTerms
            )
        )
        // The local engine resolves per call from the persisted local-model selection: Apple
        // SpeechAnalyzer (the default, with the id read as its language) or a downloaded
        // Parakeet model.
        let localBatch = SelectableLocalTranscriptionProvider(
            selected: { settingsBox.localTranscriptionModelId }
        )
        let router = TranscriptionModeRouter(
            local: localBatch,
            remote: batchCloud,
            onRemoteOutcome: cloudOutcomeSink(cloudHealth),
            mode: { settingsBox.transcriptionMode }
        )
        let processor = TranscriptionProcessor(
            queue: queue,
            router: router,
            pcmSource: TranscriptionProcessor.segmentPcmSource(store: store),
            // Mirrors the task state onto the segment's own metadata. Without it
            // `enqueueClosedSegments` (which selects on `isFullyTranscribed`) sees every finished
            // segment as untranscribed and requeues it on every pass — an endless
            // re-transcription loop, and for a cloud user an endless re-upload of the same audio.
            // Detached because the seam is synchronous; the next pass is a pipeline sleep away,
            // so the write always lands first.
            onStateChanged: { segmentId, state in
                Task {
                    try? await store.updateTranscriptionState(
                        segmentId, segmentTranscriptionState(for: state)
                    )
                }
            },
            transcriptStore: transcripts,
            isSegmentOpen: { id in await store.openSegmentId == id }
        )

        // The suspension-proof cloud path (plan 4.4). Cloud-PRIMARY modes only: the coordinator
        // re-checks `cloudIsPrimaryTranscription` on every hand-off, so LocalOnly/LocalFirst audio
        // is never uploaded from the background.
        let backgroundUploader = URLSessionBackgroundUploader.shared
        self.backgroundUploader = backgroundUploader
        let uploadCoordinator = BackgroundUploadWiring.makeCoordinator(
            uploader: backgroundUploader,
            cloudProvider: batchCloud,
            queue: queue,
            transcripts: transcripts,
            store: store,
            files: files,
            root: containerRoot,
            settings: settingsBox,
            nowMs: nowMs,
            log: AppRuntimeLog.runtimeLog
        )

        let transcription = TranscriptionService(
            queue: queue,
            processor: processor,
            transcriptStore: transcripts,
            store: store,
            settings: settingsBox,
            clock: clock,
            cloudHealth: cloudHealth,
            // Without this the explicit Test Connection silently no-ops and the row spins
            // forever; the selectable provider forwards the probe to whichever cloud backend
            // the user picked.
            connectivityCheck: batchCloud,
            // Without this the background upload path is dead code: cloud-primary segments stop
            // transcribing the moment the app leaves the foreground and sit Pending until the
            // user opens it again.
            uploader: uploadCoordinator,
            // Real now that Parakeet can be the local engine: a resident multi-hundred-MB
            // model must be dropped on backgrounding, memory pressure and idle.
            modelLifecycle: localBatch,
            log: AppRuntimeLog.runtimeLog
        )

        // --- live audio ----------------------------------------------------------------------

        let liveTap = LiveAudioTap()
        self.liveTap = liveTap
        let monitor = LiveAudioMonitor(decoder: SpeexLiveFrameDecoder(), nowMs: nowMs)
        self.monitor = monitor
        let openSegment = OpenSegmentTracker()
        self.openSegment = openSegment

        let streamingCloud = SelectableStreamingTranscriptionProvider(
            selected: { settingsBox.cloudTranscriptionProvider },
            openAi: OpenAiRealtimeProvider(apiKey: openAiKey, cloudConsent: cloudConsent),
            soniox: SonioxRealtimeProvider(
                apiKey: sonioxKey,
                cloudConsent: cloudConsent,
                diarizationEnabled: diarize,
                contextText: sonioxContext,
                contextTerms: contextTerms
            )
        )
        // The kit's live/export/playback seams take SYNCHRONOUS readers (they decode on their
        // own executors), so they read the spool through `files` rather than awaiting the actor.
        //
        // The chunk-based preview goes through a router on the SAME mode as everything else, so
        // "Remote first" is remote here too. It is the fallback path: `LiveAudioService` stands
        // it down while the realtime socket below is delivering, so a remote mode does not pay
        // for the same audio twice. Its own router instance (not the durable one) keeps live
        // failures out of the durable path's cloud-health signal — a chunk boundary is a much
        // weaker signal than a whole segment.
        let liveRouter = TranscriptionModeRouter(
            local: localBatch,
            remote: batchCloud,
            mode: { settingsBox.transcriptionMode }
        )
        let localLive = LiveTranscriber(
            openSegmentId: { openSegment.value },
            readMeta: { files.readMeta($0) },
            readFrames: { files.readFrames($0) },
            router: liveRouter,
            nowMs: nowMs
        )
        self.localLive = localLive
        // The realtime socket is the PREFERRED live path in any remote mode. Its outcomes reach
        // cloud health like every other cloud attempt — without this a live socket that never
        // connects is invisible: the screen quietly shows the on-device fallback and nothing
        // anywhere says the cloud was even tried.
        let liveCloudOutcome = cloudOutcomeSink(cloudHealth)
        let cloudLive = CloudLiveTranscriber(
            tap: liveTap,
            provider: streamingCloud,
            enabled: { settingsBox.liveCloudEnabled },
            nowMs: nowMs,
            onOutcome: { outcome in
                switch outcome {
                case .ok(let detail): liveCloudOutcome(.ok(detail: detail))
                case .failed(let message): liveCloudOutcome(.failed(message: message))
                }
            },
            logFailure: { label, error in
                AppRuntimeLog.shared.record("\(label): \(error)")
            }
        )
        self.cloudLive = cloudLive
        let live = LiveAudioService(
            store: store,
            monitor: monitor,
            localLive: localLive,
            cloudLive: cloudLive,
            waveformBuilder: SegmentWaveformBuilder(decoder: SpeexLiveFrameDecoder()),
            exporter: AudioExportManager(
                exportRoot: AudioExportManager.defaultExportRoot(),
                listSegments: { files.listSegments() },
                readMeta: { files.readMeta($0) },
                readFrames: { files.readFrames($0) },
                decodePcm: LiveTranscriber.defaultDecodePcm
            ),
            playback: SegmentPlaybackController(
                playerFactory: { AVFoundationPcmPlayer() },
                decoder: SpeexLiveFrameDecoder(),
                frameSource: { files.readFrames($0).map(\.payload) }
            ),
            hasDurableTranscript: { transcripts.load($0) != nil },
            automaticWavExportEnabled: { settingsBox.automaticWavExportEnabled },
            log: AppRuntimeLog.runtimeLog
        )

        // --- AI ------------------------------------------------------------------------------

        let aiRouter = AiModeRouter(
            local: OnDeviceAiProvider(
                model: FoundationModelsLanguageModel(), grounding: aiGrounding
            ),
            remote: OpenAiChatAiProvider(
                transport: transport,
                apiKey: openAiKey,
                remoteConsent: { settingsBox.remoteAiEnabled },
                model: { settingsBox.aiModel },
                grounding: aiGrounding
            ),
            mode: { settingsBox.aiMode }
        )
        self.aiRouter = aiRouter

        let enrichment = EnrichmentService(
            worker: EnrichmentWorker(
                annotations: annotations, router: aiRouter, nowMs: nowMs
            ),
            annotations: annotations,
            store: store,
            database: database,
            pauseJournal: pauseJournal,
            transcriptOf: { transcripts.load($0) },
            donator: donator,
            clock: clock,
            log: AppRuntimeLog.runtimeLog
        )

        let recap = RecapService(
            engine: DailyRecapEngine(
                listSegments: { files.listSegments() },
                transcriptTextOf: { transcripts.load($0)?.text },
                store: recapStore,
                run: { request in try await aiRouter.run(request) },
                prompt: AiPromptTemplates.dailySummary,
                onRecapSaved: makeRecapDonationHook(donator: donator, clock: clock)
            ),
            store: recapStore
        )

        // --- receiver ------------------------------------------------------------------------

        let lossEvaluator = LossEventEvaluator(
            notifier: NativeSurfaceCoordinator.lossNotifier,
            captureIsActive: { settingsBox.captureIntent == .active }
        )
        let wake = WakeChannel()
        let foreground = RuntimeForegroundState()
        let diagnostics = DiagnosticsService(
            store: store,
            retention: retention,
            tasks: { (try? queue.all()) ?? [] },
            isForeground: { foreground.value },
            clock: clock
        )

        let receiver = ReceiverService(
            link: CoreBluetoothAudioGattLink(),
            store: store,
            retention: retention,
            resumeStore: FileReceiverResumeStore(root: containerRoot),
            config: ReceiverConfig(
                receiverId: AppComposition.receiverId(keychain: keychain),
                receiverName: AppComposition.receiverName
            ),
            clock: clock,
            initialIntent: settings.captureIntent,
            liveMonitor: monitor,
            liveAudioTap: liveTap,
            pauseJournal: pauseJournal,
            lossEvaluator: lossEvaluator,
            onStoreEvent: { wake.signal() },
            log: AppRuntimeLog.runtimeLog
        )

        let cascade = DeleteCascade(
            store: store,
            transcription: transcription,
            annotations: annotations,
            aiOutputs: aiOutputs,
            followUps: followUps,
            recaps: recap,
            enrichment: enrichment,
            index: index,
            donator: donator,
            lossEvaluator: lossEvaluator
        )
        let deferredDeletes = DeferredDeleteBuffer(cascade: cascade, clock: clock)

        let snapshots = CoverageSnapshotService(
            store: store,
            writer: CoverageSnapshotWriter(),
            clock: clock,
            statusOf: {
                // The widget's status line must be the SAME derivation the Today card shows —
                // one status engine, never a second vocabulary (including the 6.7 precedence:
                // transcripts-off only matters while capture is actually meant to be running).
                if !settingsBox.transcriptsConfigured, settingsBox.captureIntent != .off {
                    return .transcriptsOff
                }
                return statusModel(
                    state: receiver.state.value,
                    intent: settingsBox.captureIntent,
                    watchServiceStateRaw: receiver.watchServiceState.value
                )
            },
            pauseJournal: pauseJournal
        )

        let importer = LegacyImporter(
            containerRoot: containerRoot,
            database: database,
            log: { AppRuntimeLog.shared.record($0) }
        )
        let importRunner = LegacyImportRunner(
            importer: importer, log: AppRuntimeLog.runtimeLog
        )
        let startup = StartupSequencer(
            steps: StartupSteps(
                runLegacyImportIfNeeded: {
                    let imported = try await importRunner.runIfNeeded()
                    // The importer writes the migrated preferences into the App Group AFTER
                    // `AppSettings` was constructed. Without this re-read, a migrated user who
                    // finished onboarding long ago would be shown the gate for one launch.
                    await MainActor.run { settings.reloadFromDefaults() }
                    return imported
                },
                recoverStore: { try await store.recover() },
                recoverQueue: { try await transcription.recoverOnStart() },
                enforceRetention: { try await retention.enforce() },
                cascadeDeleted: { _ = await cascade.deleteSegment($0) },
                enqueueClosedSegments: { try await transcription.enqueueClosedSegments() },
                refreshDiagnostics: { await diagnostics.refresh() }
            ),
            log: AppRuntimeLog.runtimeLog
        )

        let runtime = CompanionRuntime(
            environment: CompanionRuntimeEnvironment(
                database: database,
                store: store,
                retention: retention,
                settings: settingsBox,
                clock: clock,
                receiver: receiver,
                transcription: transcription,
                enrichment: enrichment,
                recap: recap,
                live: live,
                diagnostics: diagnostics,
                library: LibraryStore(database: database, deferredDeletes: deferredDeletes),
                cascade: cascade,
                deferredDeletes: deferredDeletes,
                startup: startup,
                snapshots: snapshots,
                foreground: foreground,
                log: AppRuntimeLog.runtimeLog
            ),
            wake: wake
        )
        self.runtime = runtime
        let lifecycle = AppLifecycleCoordinator(runtime: runtime, log: AppRuntimeLog.runtimeLog)
        self.lifecycle = lifecycle
        lifecycleObserver = UIApplicationLifecycleObserver(coordinator: lifecycle)
    }

    // MARK: - Install

    /// `-demo-data` keeps the screens on the artboard sample set instead of the live graph, so a
    /// populated Today/Library/Conversation can be reviewed — dark mode, Dynamic Type, layout —
    /// without a watch in the room. DEBUG only: the real graph is still built and started, only
    /// the three display holders are left pointing at the mocks.
    static var usesDemoData: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-demo-data")
        #else
        return false
        #endif
    }

    private func install(nativeSurfaces: NativeSurfaceCoordinator) {
        // Spotlight donation reuses this database connection rather than opening a second pool.
        nativeSurfaces.attachDatabase(database)

        // A settings change that could unblock work wakes the pipeline immediately.
        let runtime = self.runtime
        settings.onRuntimeSettingsChanged = { runtime.notifyConfigChanged() }

        // The screens' data-source holders, flipped from mocks to the live graph. Onboarding is
        // one of them: without this it would pair against `MockWatchPairingSource` and the first
        // real connection would only happen later, from Today's Start.
        let today = LiveTodayDataSource(composition: self)
        todaySource = today
        if !Self.usesDemoData {
            AppDataSources.current = AppDataSources(today: today, live: today)
            AskLibraryDataSources.current = LiveLibraryDataSources.make(composition: self)
            SettingsDataSources.current = LiveSettingsDataSources.make(composition: self)
            OnboardingDataSources.current = OnboardingDataSources(
                pairing: LiveWatchPairingSource(composition: self)
            )
        }

        registerBackgroundTask()

        // TRAP (scene manifest): app-delegate lifecycle callbacks never fire in this app, so the
        // coordinator is driven by NOTIFICATION observers plus the explicit events below.
        lifecycleObserver.start()
        let lifecycle = self.lifecycle
        Task { await lifecycle.handle(.didFinishLaunching) }
        today.start()
    }

    /// `handleEventsForBackgroundURLSession` — routed from the app delegate.
    ///
    /// The system completion handler is stored on the transport and invoked when the session
    /// reports its events drained, NOT here: iOS kills an app that returns from this callback
    /// without ever calling it, and calling it immediately lets the system re-suspend us before
    /// the finished uploads have been delivered.
    func handleBackgroundUrlSessionEvents(
        identifier: String, completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploadWiring.sessionIdentifier else {
            // Not our session — nothing here can drain it, so release the system immediately.
            completionHandler()
            return
        }
        backgroundUploader.addBackgroundEventsCompletion {
            // UIKit expects it on the main thread; the session delegate calls back on its own.
            DispatchQueue.main.async(execute: completionHandler)
        }
        Task { [lifecycle] in await lifecycle.handle(.backgroundUrlSessionEvents) }
    }

    /// Core Bluetooth relaunched us in the background: receive-only, before anything starts.
    func handleRestorationRelaunch() {
        Task { [lifecycle] in await lifecycle.handle(.restorationRelaunch) }
    }

    // MARK: - Background processing

    private func registerBackgroundTask() {
        guard !didRegisterBackgroundTask else { return }
        didRegisterBackgroundTask = true
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskPolicy.processingTaskIdentifier,
            using: nil
        ) { task in
            MainActor.assumeIsolated { AppComposition.shared?.run(backgroundTask: task) }
        }
        if !registered {
            AppRuntimeLog.shared.record("BGTaskScheduler registration refused")
        }
        scheduleBackgroundProcessing()
    }

    private func run(backgroundTask task: BGTask) {
        // Re-arm first: a window that ends without a follow-up request is the last one iOS ever
        // gives us.
        scheduleBackgroundProcessing()
        let lifecycle = self.lifecycle
        let work = Task {
            await lifecycle.handle(.backgroundProcessingStarted)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            Task {
                // Expiration cancels OPTIONAL work only — never the receiver, never the intent.
                await lifecycle.handle(.backgroundProcessingExpired)
                work.cancel()
            }
        }
    }

    func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(
            identifier: BackgroundTaskPolicy.processingTaskIdentifier
        )
        request.requiresNetworkConnectivity = BackgroundTaskPolicy.requiresNetworkConnectivity
        request.requiresExternalPower = BackgroundTaskPolicy.requiresExternalPower
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: BackgroundTaskPolicy.earliestBeginInterval
        )
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulators and unentitled builds refuse this; it is not worth alarming anyone.
            AppRuntimeLog.shared.record("BGProcessing submit failed: \(error)")
        }
    }

    // MARK: - Receiver identity

    /// The name the watch shows in its consent prompt.
    private static var receiverName: String {
        MainActor.assumeIsolated { UIDevice.current.name }
    }

    /// 32 random bytes, once per install. LOAD-BEARING: the watch stores SHA-256 of this value,
    /// so it is created once and then only ever read — never regenerated while a binding exists.
    /// (`LegacyImporter` seeds it from the old app's defaults before we ever get here.)
    private static func receiverId(keychain: KeychainStore) -> [UInt8] {
        if let hex = keychain.string(for: .receiverId), let bytes = bytes(fromHex: hex),
            bytes.count == 32
        {
            return bytes
        }
        var fresh = [UInt8](repeating: 0, count: 32)
        for index in fresh.indices { fresh[index] = UInt8.random(in: 0...255) }
        _ = keychain.set(fresh.map { String(format: "%02x", $0) }.joined(), for: .receiverId)
        return fresh
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let characters = Array(hex.lowercased())
        guard characters.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else {
                return nil
            }
            result.append(byte)
        }
        return result
    }
}

// MARK: - Platform seams

/// Real device free space for the retention policy.
struct VolumeFreeSpace: FreeSpaceProvider {
    func freeBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard
            let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return .max }
        return Int64(capacity)
    }
}

/// The open segment id, published where the synchronous seams can read it without awaiting the
/// store actor. Refreshed by the Today source's poll (the same tick that rebuilds the snapshot).
final class OpenSegmentTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String?

    var value: String? { lock.withLock { current } }

    func set(_ segmentId: String?) { lock.withLock { current = segmentId } }
}

/// The local model's residency hooks. `SpeechAnalyzer` sessions are created per transcription
/// and torn down with them, so there is no long-lived model handle to drop — the honest
/// implementation is a no-op rather than a fake that pretends to free memory.
struct LocalModelLifecycle: LocalTranscriptionLifecycle {
    func releaseModel(reason: String) async {}
    func releaseModelIfIdle(nowMs: Int64, idleTimeoutMs: Int64) async {}
}

/// A small in-memory ring of runtime log lines, surfaced by Settings → Diagnostics →
/// Detailed Logs. Counters and state transitions only — never audio or transcript text.
final class AppRuntimeLog: @unchecked Sendable {
    static let shared = AppRuntimeLog()
    static let runtimeLog = RuntimeLog { shared.record($0) }

    private static let capacity = 200
    private let lock = NSLock()
    private var lines: [String] = []

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func record(_ message: String) {
        let line = "\(Self.stamp.string(from: Date()))  \(message)"
        lock.withLock {
            lines.append(line)
            if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
        }
        #if DEBUG
            print("[companion] \(line)")
        #endif
    }

    /// Newest first, for the log sheet.
    var recent: [String] { lock.withLock { lines.reversed() } }
}
