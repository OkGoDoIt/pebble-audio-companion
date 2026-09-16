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
import SwiftUI
import Transcription
import UIKit
import WireProtocol

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
    let followUpCandidates: FollowUpCandidateStore
    let askHistory: AskHistoryStore
    let notes: NotesStore
    let people: PeopleStore
    let pauseJournal: PauseJournal
    let customTemplates: CustomTemplateStore
    let annotations: AnnotationStore
    let aiOutputs: AiOutputStore
    let recapStore: DailyRecapStore
    let personalContext: FilePersonalContextStore
    /// Produces `PersonalContext.derivedTerms` — the keyword list the OpenAI STT prompt is
    /// built from. Held so a surface that edits "About you" can ask for an immediate refresh
    /// instead of waiting for the next transcription to notice.
    let personalContextTerms: PersonalContextTermRefresher

    // --- pipeline ---------------------------------------------------------------------------

    /// The receive half, held so the status/diagnostics layer can read the watch's own refusal
    /// (`lastProtocolError`, `watchInfo`) synchronously — `runtime.environment` is actor-isolated
    /// and the status card is derived on the main actor without an await.
    let receiver: ReceiverService
    /// Held so Diagnostics can say whether the process is actually resident — the difference
    /// between recording in the background and only recording while the app is on screen.
    let residency: BackgroundResidency
    /// Held so foreground entry can drop it: in the foreground nothing can suspend us, and a
    /// leaked background task is a 0x8badf00d kill.
    let backgroundActivity: BackgroundActivityAssertion
    /// Held so the lifecycle observers can tell it whether anyone is watching — that decides
    /// whether a connect attempt gets the give-up watchdog.
    let gattLink: CoreBluetoothAudioGattLink
    /// Charger / Low Power / thermal, feeding `BackgroundWorkPolicy`.
    let devicePower = DevicePowerMonitor()
    /// The shared foreground+device-power object the pipeline pass closures read synchronously.
    private(set) var foregroundState: RuntimeForegroundState
    let queue: TranscriptionQueue
    let cloudHealth: CloudHealthMonitor
    let localModel: LocalModelManager
    let aiRouter: AiModeRouter
    /// The DURABLE transcription router (not the live-preview one). Held so Settings can read
    /// `lastFallback` and disclose that a "first" mode is being served by its fallback; nothing
    /// else needs it, because `TranscriptionProcessor` already owns the transcribing.
    let transcriptionRouter: TranscriptionModeRouter
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
    /// "Is startup recovery still running?", for the screens. See `StartupActivity`.
    let startup: StartupActivity
    /// The background `URLSession` transport, held so `handleEventsForBackgroundURLSession` can
    /// hand it the system completion handler.
    private let backgroundUploader: URLSessionBackgroundUploader

    // --- lifecycle --------------------------------------------------------------------------

    private let lifecycle: AppLifecycleCoordinator
    private let lifecycleObserver: UIApplicationLifecycleObserver
    /// Set at install; owns the Spotlight donation watermark the index rebuild has to clear.
    private(set) weak var nativeSurfaces: NativeSurfaceCoordinator?
    private var didRegisterBackgroundTask = false
    /// Set once a scene has actually come up — see `noteSceneActive()`. Latches true: a process
    /// that has ever shown a window is not one iOS started headless, and nothing after that point
    /// may apply receive-only to it.
    private static var sceneHasBeenActive = false
    private var todaySource: LiveTodayDataSource?
    /// The flight recorder's liveness pulse — see `startHeartbeat`.
    private var heartbeatTask: Task<Void, Never>?
    /// Per-heartbeat counters for the battery telemetry: how many Bluetooth notifications woke
    /// us and how much CPU we spent since the last line.
    private let telemetry = HeartbeatTelemetry()

    /// The CPU watchdog's verdict for the Diagnostics screen (see `HeartbeatTelemetry`).
    var powerWatchdogAlert: String? { telemetry.alertText }
    private var foregroundReleaseToken: NSObjectProtocol?
    private var backgroundMarkToken: NSObjectProtocol?

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
            scheduleBootstrapRetry(settings: settings, nativeSurfaces: nativeSurfaces)
            return nil
        }
    }

    /// A failed graph must never become permanent.
    ///
    /// EVERYTHING that keeps the receiver alive lives on the success path: the lifecycle
    /// observers, the BGTask registration, the cross-process listeners, and — worst — the
    /// `CoreBluetoothAudioGattLink` itself, which is constructed inside `init` and is what calls
    /// `prepareForRestoration()`. So a throw here left the process with no central manager at all,
    /// meaning no state restoration and no radio for its entire life, with nothing anywhere that
    /// would try again: `didBecomeActive` had no observer to fire, and `handleRestorationRelaunch`
    /// reaches `AppComposition.shared?` and silently no-ops on nil. The app looked launched and
    /// recorded nothing, forever, until it was killed and reopened.
    ///
    /// The most likely cause is also the most recoverable one: a background relaunch before the
    /// device's first unlock, where the database file is not readable yet. So retry on the two
    /// signals that say the reason may have passed — protected data becoming available, and the
    /// user bringing the app forward. Registered on the notification centre, which needs no graph.
    private static var bootstrapRetryTokens: [NSObjectProtocol] = []

    private static func scheduleBootstrapRetry(
        settings: AppSettings,
        nativeSurfaces: NativeSurfaceCoordinator
    ) {
        guard bootstrapRetryTokens.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.didBecomeActiveNotification,
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard shared == nil else { return }
                    AppRuntimeLog.shared.record("retrying composition after \(name.rawValue)")
                    _ = bootstrap(settings: settings, nativeSurfaces: nativeSurfaces)
                    if shared != nil {
                        bootstrapRetryTokens.forEach(center.removeObserver)
                        bootstrapRetryTokens = []
                    }
                }
            }
            bootstrapRetryTokens.append(token)
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

        // FIRST, before the database or anything else that can fail: a composition that throws
        // half way through used to leave no trace at all, and "the app records nothing and the
        // diagnostics screen is empty" is indistinguishable from a dozen other faults.
        let recorder = FlightRecorder(
            directory: containerRoot.appendingPathComponent("diagnostics")
        )
        AppRuntimeLog.shared.attach(recorder: recorder)
        recorder.recordLaunch(
            cause: Self.launchCause(),
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "?"
        )

        let database = try AppDatabase.open(at: AppDatabase.defaultDatabaseURL())
        self.database = database
        // The store's log is the ONLY explanation of why a RESUME reattach failed and a
        // recording was split into a new Library row. Without it the segment-churn question is
        // unanswerable from a support report.
        let store = SegmentStore(
            root: containerRoot, nowMs: nowMs,
            log: { AppRuntimeLog.shared.record($0) }
        )
        self.store = store
        let files = SegmentFileReader(root: containerRoot)
        self.files = files
        let transcripts = FileTranscriptStore(root: containerRoot, nowMs: nowMs)
        self.transcripts = transcripts

        let retention = RetentionManager(
            store: store,
            freeSpace: VolumeFreeSpace(),
            nowMs: nowMs,
            config: { retentionConfig(for: settingsBox) },
            // Retention is the one thing in the app that deletes a person's recordings without
            // being asked to. Both caps say what they took, so "where did my conversations go?"
            // has an answer in Detailed Logs and in a support report.
            log: { AppRuntimeLog.shared.record($0) }
        )
        self.retention = retention

        tags = TagStore(db: database)
        let followUps = FollowUpStore(db: database)
        self.followUps = followUps
        let followUpCandidates = FollowUpCandidateStore(db: database)
        self.followUpCandidates = followUpCandidates
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
        // Ask's index lookup is a QUESTION, not a search-box query: `.any` so its content words
        // recall on their own instead of every word having to appear in one transcript, and
        // conversations only, because a note or a recap id can never resolve to a recording.
        askRetriever = AskRetriever { query, limit in
            let hits =
                (try? index.search(
                    query, limit: limit, kinds: [.conversation], mode: .any)) ?? []
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
        //
        // The OpenAI keyword bias needs `derivedTerms`, which an AI extraction produces from the
        // pasted bio. That extractor needs `aiRouter`, built further down, so the read sites
        // reach the refresher through a handle: every transcription asks "are the terms still
        // in step with the bio?", and the refresher answers from a hash without a model call
        // unless the text actually changed.
        let termRefresh = PersonalContextTermRefreshHandle()
        let sonioxContext: @Sendable () -> String? = {
            PersonalContextFormatting.transcriptionText(personalContext.load())
        }
        let sttPrompt: @Sendable () -> String? = {
            termRefresh.nudge()
            return PersonalContextFormatting.openAiSttPrompt(personalContext.load())
        }
        let contextTerms: @Sendable () -> [String] = {
            termRefresh.nudge()
            return PersonalContextFormatting.transcriptionTerms(personalContext.load())
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
            selected: { settingsBox.localTranscriptionModelId },
            // Hand Apple's engine the same About You terms the two cloud providers already get.
            // `appleContextualStrings` shapes them to that API's contract (≤100 phrases, short);
            // the provider re-applies the ceiling itself. `termRefresh.nudge()` rides along the
            // way it does for the cloud paths, so the derived terms stay in step with the bio
            // without a timer — see `contextTerms` above.
            makeAppleSpeech: { locale in
                SpeechAnalyzerProvider(
                    locale: locale,
                    contextualStrings: {
                        termRefresh.nudge()
                        return PersonalContextFormatting.appleContextualStrings(
                            personalContext.load())
                    }
                )
            }
        )
        let router = TranscriptionModeRouter(
            local: localBatch,
            remote: batchCloud,
            onRemoteOutcome: classifiedCloudOutcomeSink(cloudHealth),
            mode: { settingsBox.transcriptionMode }
        )
        self.transcriptionRouter = router
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
        // The bridge between the live transcribers (actors) and the enrichment pass's synchronous
        // `liveTextOf` seam. The live pass fills it; `EnrichmentService` reads it.
        let livePreviews = LivePreviewCache()
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
        // `CloudHealth.message` is rendered verbatim on the Transcription & AI row, so the words
        // are chosen HERE and nowhere deeper.
        let cloudLive = CloudLiveTranscriber(
            tap: liveTap,
            provider: streamingCloud,
            enabled: { settingsBox.liveCloudEnabled },
            nowMs: nowMs,
            onOutcome: { outcome in
                switch outcome {
                case .ok(let detail): liveCloudOutcome(.ok(detail: detail))
                case .failed(let kind): liveCloudOutcome(.failed(message: kind.reason))
                }
            },
            logFailure: { label, error in
                AppRuntimeLog.shared.record("\(label): \(error)")
            },
            logNote: { note in
                AppRuntimeLog.shared.record(note)
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
            // Fills the mirror the enrichment pass reads; see `LivePreviewCache`.
            previewCache: livePreviews,
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
            mode: { settingsBox.aiMode },
            // AI failures had no home. The device's `diagnostics/companion.log` carried link,
            // session, heartbeat and cloud *transcription* lines and not one AI or note-job
            // line, so "my Extended summary keeps failing" could not be taken any further than
            // the sentence on the dock — which was itself naming the wrong provider. Same sink
            // as the pipeline: classified kinds and provider ids, never transcript text.
            log: { AppRuntimeLog.shared.record($0) }
        )
        self.aiRouter = aiRouter

        // The producer for `derivedTerms`. Without it `openAiSttPrompt` is nil for anyone who
        // pastes a bio and never imports contacts — the About You screen's whole promise of
        // getting names and jargon right, silently unbuilt.
        let personalContextTerms = PersonalContextTermRefresher(
            load: { personalContext.load() },
            save: { _ = try personalContext.save($0) },
            extractor: PersonalContextTermExtractor(router: aiRouter),
            nowMs: nowMs,
            // The write-back goes through the store's lock, not a load/save pair: the About You
            // editor and the Contacts/Calendar imports write the same document, and a refresh
            // finishing mid-import used to put the pre-import version back.
            mutate: { _ = try personalContext.mutate($0) },
            log: { AppRuntimeLog.shared.record($0) }
        )
        self.personalContextTerms = personalContextTerms
        termRefresh.install(personalContextTerms)
        // Catch up at launch so a bio pasted during onboarding is already biasing the first
        // recording, rather than only from the second one onwards.
        Task { await personalContextTerms.refreshIfNeeded() }

        let enrichment = EnrichmentService(
            worker: EnrichmentWorker(
                annotations: annotations, router: aiRouter, nowMs: nowMs,
                // One `stat` per member per pass instead of a decoded transcript: the workers
                // memoise what they learned from a transcript against this.
                transcriptVersionOf: { transcripts.version($0) }
            ),
            // Follow-ups are two passes over one store of candidates: extraction proposes from
            // a single conversation, curation decides across all of them. Both are handed the
            // conversation's own title and summary so the model reads a recording the way the
            // Library shows it rather than as an anonymous wall of speech.
            followUps: FollowUpWorker(
                candidates: followUpCandidates,
                state: try FollowUpExtractionStore(db: database),
                router: aiRouter,
                nowMs: nowMs,
                timeZone: { .current },
                contextOf: { conversationId in
                    guard let annotation = try? await annotations.load(conversationId)
                    else { return nil }
                    return FollowUpConversationContext(
                        title: annotation.title, summary: annotation.summary)
                },
                transcriptVersionOf: { transcripts.version($0) }
            ),
            curator: FollowUpCurator(
                candidates: followUpCandidates,
                followUps: followUps,
                router: aiRouter,
                nowMs: nowMs,
                timeZone: { .current },
                titleOf: { conversationId in
                    (try? await annotations.load(conversationId))?.title
                }
            ),
            annotations: annotations,
            store: store,
            database: database,
            pauseJournal: pauseJournal,
            transcriptOf: { transcripts.load($0) },
            // The open member's rolling text. Without it a live conversation had a combined length
            // of zero, so it stayed untitled — no provisional title, no summary — for the whole
            // recording, which for a long conversation is many minutes of a blank "Recording now"
            // row. The previews live behind actors and this seam is synchronous, so the live pass
            // mirrors them into `LivePreviewCache` and this reads the mirror.
            liveTextOf: { livePreviews.text(for: $0) },
            donator: donator,
            // The optional semantic half of conversation splitting. It only ever adjudicates
            // joins the structural layer already flagged (8–25 minutes of settled quiet), one
            // batched call, verdicts cached — and with the AI layer off it does nothing and the
            // grouping is purely structural.
            boundaryReviewer: BoundaryReviewer(
                reviews: BoundaryReviewStore(db: database), router: aiRouter, nowMs: nowMs
            ),
            // Turn timings only. The boundary layer sweeps EVERY segment on a regroup, and
            // `transcripts.load` would decode each one's per-word timing array — megabytes on a
            // full library — just to discard it.
            speechTimingsOf: { transcripts.loadSpeechTimings($0) },
            clock: clock,
            log: AppRuntimeLog.runtimeLog
        )

        let recap = RecapService(
            engine: DailyRecapEngine(
                // The store's cached index, not `files.listSegments()`, which parses every
                // sidecar off disk each call — measured at 2.4 CPU-s per 90 s on a charger.
                listSegments: { await store.listSegments() },
                // Collapsed, like every other model input (see `TranscriptCleanup.swift`): a
                // day containing one looped recording would otherwise hand the recap 12 000
                // words of the same sentence and get a day summarised around it.
                transcriptTextOf: { transcripts.load($0)?.withLoopedArtefactsCollapsed().text },
                store: recapStore,
                run: { request in try await aiRouter.run(request) },
                prompt: AiPromptTemplates.dailySummary,
                onRecapSaved: makeRecapDonationHook(
                    donator: donator, clock: clock, log: AppRuntimeLog.runtimeLog
                ),
                log: { AppRuntimeLog.shared.record($0) }
            ),
            store: recapStore
        )

        // --- receiver ------------------------------------------------------------------------

        let lossEvaluator = LossEventEvaluator(
            notifier: NativeSurfaceCoordinator.lossNotifier,
            captureIsActive: { settingsBox.captureIntent == .active },
            // The other half of the safeguard, ported and never connected: a pause journal row
            // can outlive an intent flip during teardown, and with the default `{ false }` a
            // "we missed some audio" alert could fire for a window the user deliberately paused.
            isPaused: { (try? await pauseJournal.openInterval()) != nil }
        )
        let wake = WakeChannel()
        let foreground = RuntimeForegroundState()
        self.foregroundState = foreground
        let diagnostics = DiagnosticsService(
            store: store,
            retention: retention,
            tasks: { (try? queue.all()) ?? [] },
            isForeground: { foreground.value },
            clock: clock,
            enrichment: {
                (await enrichment.awaitingEnrichmentCount(), await enrichment.isEnriching)
            }
        )

        // The receiver fires coverage triggers (segment opened, segment closed, pause applied)
        // from the moment it is built, but `CoverageSnapshotService` cannot exist yet — it reads
        // the receiver's own state for the status it writes. The relay closes that loop below.
        let coverageTriggers = CoverageTriggerRelay()

        // Built and prepared HERE, synchronously during launch: iOS hands `willRestoreState` only
        // to a central manager that already exists when the process comes up. The link used to
        // create its manager lazily on the first user-driven connect, so a Core Bluetooth
        // relaunch found no manager, got no restored peripheral, and the whole restoration path
        // never ran once in production.
        let gattLink = CoreBluetoothAudioGattLink()
        self.gattLink = gattLink
        // Every Core Bluetooth transition now also lands in Detailed Logs. Without this the one
        // screen a person can read on the phone said "Nothing logged yet" during the exact
        // failure it exists for, because the adapter only ever wrote to NSLog.
        gattLink.logSink = AppRuntimeLog.receiverLog
        // Wired before the central exists: `willRestoreState` is the first delegate callback and
        // can land within a millisecond of `prepareForRestoration()`.
        gattLink.onStateRestored = { AppComposition.noteStateRestored() }
        gattLink.prepareForRestoration()

        // The `audio` background mode's other half. Without it the app is suspended between Core
        // Bluetooth wakes, its keepalive stops firing, and the watch's 15 s liveness watchdog
        // stops the microphone — which is the whole of "it barely records anything unless I'm in
        // the app". The receiver takes and releases it with the user's capture intent.
        let residency = BackgroundResidency(log: AppRuntimeLog.runtimeLog)
        self.residency = residency

        // Second line of defence, for the windows residency cannot cover — a phone call has taken
        // the audio session, or the audio stack refused to start. Taken synchronously inside the
        // Core Bluetooth callback, because everything downstream of it is asynchronous and the
        // risk is being suspended between the delegate returning and the frame reaching disk.
        let activity = BackgroundActivityAssertion(log: AppRuntimeLog.runtimeLog)
        self.backgroundActivity = activity
        let telemetry = self.telemetry
        gattLink.onInboundNotification = { [weak residency] in
            telemetry.noteInboundNotification()
            // Only when residency is NOT holding us up. While it is, the process cannot be
            // suspended and the assertion buys nothing — and a background task renewed by every
            // notification is never released, which is precisely the shape iOS kills with
            // 0x8badf00d. Residency is what buys runtime; this only covers the windows where
            // residency is absent (an interruption, or an audio stack that refused).
            guard residency?.state.value != .held else { return }
            activity.renew()
        }

        let receiver = ReceiverService(
            link: gattLink,
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
            residency: residency,
            onStoreEvent: { wake.signal() },
            onCoverageTrigger: { await coverageTriggers.fire($0) },
            log: AppRuntimeLog.runtimeLog,
            sessionLog: AppRuntimeLog.receiverLog,
            // Foreground entry starts the receiver before `runtime.start()` has recovered the
            // store; the gate inside the service keeps the session from opening a segment that
            // recovery would then close as interrupted.
            sessionWaitsForStoreRecovery: true
        )
        self.receiver = receiver

        let cascade = DeleteCascade(
            store: store,
            transcription: transcription,
            annotations: annotations,
            aiOutputs: aiOutputs,
            followUps: followUps,
            candidates: followUpCandidates,
            recaps: recap,
            enrichment: enrichment,
            index: index,
            donator: donator,
            lossEvaluator: lossEvaluator,
            // A manual split/join is keyed by the segment after the join, so deleting that segment
            // must take the decision with it.
            boundaryOverrides: BoundaryOverrideStore(db: database),
            // Eight `log.failure` sites — a delete that leaves the transcript, the AI outputs or
            // the Spotlight entry behind reported success and recorded nothing anywhere.
            log: AppRuntimeLog.runtimeLog
        )
        let deferredDeletes = DeferredDeleteBuffer(cascade: cascade, clock: clock)
        let conversations = ConversationQueries(db: database)

        let snapshots = CoverageSnapshotService(
            store: store,
            // The writer's own doc says a silent snapshot failure is indistinguishable from a
            // widget nobody wired up, and that "has already cost a debugging session" — and then
            // it was constructed with the silent default anyway.
            writer: CoverageSnapshotWriter(log: AppRuntimeLog.runtimeLog),
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
                    watchServiceStateRaw: receiver.watchServiceState.value,
                    deviceName: receiver.deviceName.value,
                    linkFault: WatchLinkFault.classify(
                        state: receiver.state.value,
                        protocolError: receiver.lastProtocolError.value,
                        info: receiver.watchInfo.value,
                        watchServiceStateRaw: receiver.watchServiceState.value
                    ),
                    // The widget's honesty problem is not staleness of the FILE — the pipeline
                    // heartbeat keeps rewriting that for as long as the app lives, so the 30-minute
                    // bound never trips while a starved link is claiming to record. It is staleness
                    // of the DATA, and this is where that is settled: one status engine, weighed
                    // the same way for the card and for every native surface downstream of it.
                    streamVerdict: receiver.streamEvidence.value.verdict(nowMs: clock.nowMs)
                )
            },
            pauseJournal: pauseJournal,
            // Snapshot v2: what the widget shows besides coverage — the conversation being
            // recorded, its newest line, and the open follow-ups. This is the ONLY part of the
            // snapshot that reads the database, and the conversation half is skipped whenever
            // capture is not actually running.
            liveContextOf: { isRunning in
                var context = CoverageLiveContext()
                let open = (try? await followUps.list(scope: .open, nowMs: clock.nowMs)) ?? []
                context.openFollowUpCount = open.count
                context.followUps = open.prefix(3).map {
                    CoverageSnapshot.FollowUpRef(
                        id: $0.id, text: $0.text, conversationId: $0.sourceConversationId
                    )
                }
                guard isRunning else { return context }

                let rows = ((try? await conversations.library()) ?? []).flatMap(\.rows)
                guard let live = rows.first(where: \.isLive) else { return context }
                context.conversationTitle = live.title

                // Newest words first: the open segment's live preview if one exists, else the
                // durable transcript of the newest member that has one. Never a fabricated
                // placeholder — an empty line reads honestly as "nothing recognized yet".
                let openSegmentId = await store.openSegmentId
                if let openSegmentId {
                    let preview = LiveTranscriptPreview.merged(
                        cloud: await cloudLive.previews[openSegmentId],
                        local: await localLive.previewFor(openSegmentId)
                    )
                    context.latestLine = Self.lastLine(of: preview?.segments.map(\.text))
                }
                if context.latestLine == nil {
                    let detail = try? await conversations.detail(id: live.id)
                    for member in (detail?.members ?? []).reversed() {
                        let text = transcripts.load(member.segmentId)?.text
                        if let line = Self.lastLine(of: text.map { [$0] }) {
                            context.latestLine = line
                            break
                        }
                    }
                }
                return context
            }
        )
        // …and the loop closes here. Without this line the receive path — the ONLY thing running
        // while the app is backgrounded and actually recording — never rewrites the widget's
        // file, so a live conversation ages past the 30-minute staleness cut and every widget
        // quietly falls back to "as of <hours ago>".
        coverageTriggers.connect { [snapshots] trigger in await snapshots.refresh(trigger) }

        let importer = LegacyImporter(
            containerRoot: containerRoot,
            database: database,
            log: { AppRuntimeLog.shared.record($0) }
        )
        let importRunner = LegacyImportRunner(
            importer: importer, log: AppRuntimeLog.runtimeLog
        )
        // The sequencer has always announced each step through `onStep`; nothing supplied the
        // closure, so its default `{ _ in }` swallowed every one of them. On a migrated first
        // launch that recovery takes tens of seconds — during which Today truthfully has no
        // rows and therefore showed the first-run "Ready when you are." empty state to someone
        // with hundreds of recordings. This is the closure that was missing.
        let startupActivity = StartupActivity()
        self.startup = startupActivity
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
                sweepQuarantine: {
                    let swept = await store.sweepQuarantine()
                    guard swept.removed > 0 || swept.retainedWithAudio > 0 else { return }
                    AppRuntimeLog.shared.record(
                        "quarantine sweep: removed \(swept.removed) empty, "
                            + "kept \(swept.retainedWithAudio) with audio"
                    )
                },
                recoverQueue: { try await transcription.recoverOnStart() },
                enforceRetention: { try await retention.enforce() },
                cascadeDeleted: { _ = await cascade.deleteSegment($0) },
                enqueueClosedSegments: { try await transcription.enqueueClosedSegments() },
                refreshDiagnostics: { await diagnostics.refresh() }
            ),
            onStep: { startupActivity.record($0) },
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

    /// The last thing actually said, for the widget's one line of live transcript. Takes the
    /// newest non-blank sentence out of the newest non-blank block and trims it, so the widget
    /// never shows a leading fragment of a paragraph it has no room for.
    nonisolated static func lastLine(of texts: [String]?, limit: Int = 160) -> String? {
        guard let texts else { return nil }
        for text in texts.reversed() {
            let sentences =
                text
                .replacingOccurrences(of: "\n", with: " ")
                .components(separatedBy: CharacterSet(charactersIn: ".!?"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard var line = sentences.last else { continue }
            if line.count > limit { line = String(line.suffix(limit)) }
            return line
        }
        return nil
    }

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
        // Spotlight donation reuses this database connection rather than opening a second pool,
        // and reads each conversation's transcript so the index keeps the words that were
        // actually said — the pass replaces the document, so donating without them erases them.
        let queries = ConversationQueries(db: database)
        let transcripts = self.transcripts
        nativeSurfaces.attachDatabase(database) { conversationId in
            guard let detail = try? await queries.detail(id: conversationId) else { return nil }
            // Collapsed before it is indexed: 1 649 copies of one sentence in a single
            // recording would otherwise dominate bm25 for every word in it, so searching
            // "clothes" would return that one silent afternoon ahead of anything real.
            let text = detail.members
                .compactMap { transcripts.load($0.segmentId)?.withLoopedArtefactsCollapsed().text }
                .joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        // Held so Diagnostics → Rebuild Search Index can clear the donation watermark it owns.
        self.nativeSurfaces = nativeSurfaces
        // Every launch, scene or not. A restoration relaunch, a BGProcessingTask, or a Siri
        // invocation never reaches `RootView`'s `.task`, so without this a capture request left
        // in the App Group by Control Center or a widget sat unread in a process that was awake.
        nativeSurfaces.startCrossProcessListeners()

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
            SettingsDataSources.current = LiveSettingsDataSources.make(
                composition: self, capture: today
            )
            OnboardingDataSources.current = OnboardingDataSources(
                pairing: LiveWatchPairingSource(composition: self)
            )
        } else {
            // The mock snapshot says "Recording · connected" while `AppSettings` is a fresh
            // install saying off — so the review build drew a green "Recording" card with the
            // switch beside it turned OFF. Nothing was broken in the app, but a screen that
            // contradicts itself is worthless for reviewing exactly the surface it exists to
            // review, and it looks precisely like the bug the shared capture control was
            // written to prevent. The demo world states what its own data already claims.
            settings.captureIntent = .active
            settings.onboardingComplete = true
        }

        registerBackgroundTask()

        // TRAP (scene manifest): app-delegate lifecycle callbacks never fire in this app, so the
        // coordinator is driven by NOTIFICATION observers plus the explicit events below.
        lifecycleObserver.start()
        let lifecycle = self.lifecycle
        Task { await lifecycle.handle(.didFinishLaunching) }
        today.start()
        startHeartbeat()

        // The device conditions the catch-up policy judges on. Pushed into the shared foreground
        // state (which the pass closures already read synchronously) and the pipeline woken on
        // every change, so plugging in starts the backlog clearing within seconds rather than
        // whenever the next background pass happens to come round.
        let power = self.devicePower
        power.onChange = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.foregroundState.devicePower = power.snapshot
                self.runtime.notifyConfigChanged()
                self.scheduleChargingCatchUp()
            }
        }
        power.start()
        foregroundState.devicePower = power.snapshot

        // Nothing can suspend us in the foreground, so the assertion is pure liability there —
        // a leaked background task is a 0x8badf00d kill. Dropped on activation, and left to the
        // inbound-notification path to take again once we are backgrounded.
        let activity = self.backgroundActivity
        let link = self.gattLink
        foregroundReleaseToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in
            activity.release()
            // The link arms its give-up watchdog only when someone is watching — see
            // `CoreBluetoothAudioGattLink.setForeground`.
            link.setForeground(true)
        }
        backgroundMarkToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in link.setForeground(false) }
        // The launch itself: `.background` here means iOS started us headless, and the link must
        // already know that before its first connect attempt. Unreliable on its own — every
        // process start in the 2026-09-08 recorder read `.active`, headless wakes included — so it
        // is only a seed; `handleRestorationRelaunch()` and `noteSceneActive()` are what correct it.
        gattLink.setForeground(UIApplication.shared.applicationState != .background)

        // A retried bootstrap (the graph failed on the first attempt and was rebuilt from
        // `didBecomeActive`) is born into a process whose window is ALREADY on screen, and
        // `scenePhase` will not change again to say so. Carry the fact across.
        if Self.sceneHasBeenActive { applySceneActive() }
        // Likewise a restoration that reported before `shared` existed — see `noteStateRestored`.
        if Self.stateWasRestored { handleRestorationRelaunch(reason: "Core Bluetooth state restoration") }
    }

    /// A line a minute, for as long as the process is alive.
    ///
    /// Its VALUE IS ITS ABSENCE. Every timer in this app is a Swift or Dispatch timer, and a
    /// suspended process runs none of them — so a gap between two heartbeats is a direct reading
    /// of a window in which iOS had us suspended or dead. That window is the entire subject of the
    /// reliability work, and until now nothing in the log measured it: a log that simply stops and
    /// resumes an hour later is indistinguishable from a quiet hour.
    ///
    /// It carries the four facts that, together, name every failure this app has: what the link
    /// thinks, what the session thinks, whether we are resident, and how long since audio last
    /// arrived. "link ready, session authorized, residency held, audio 4h ago" is a completely
    /// different bug from "link disconnected, residency failed".
    private func startHeartbeat() {
        let receiver = self.receiver
        let residency = self.residency
        let clock = self.clock
        let telemetry = self.telemetry
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard self != nil, !Task.isCancelled else { return }
                let audioAge = receiver.streamEvidence.value.lastAudioAtMs
                    .map { "\((clock.nowMs - $0) / 1000)s ago" } ?? "never"
                // The watch's OWN state, not just ours. Reading an overnight log without it, the
                // answer to "why was there no audio for two and a half hours" was unavailable:
                // "authorized, no audio" is equally a paused watch, a power-saving watch, a flat
                // battery and a watch that quietly stopped. They need different fixes.
                let watch = receiver.watchServiceState.value.map(Self.watchStateName) ?? "unknown"
                // The battery half. Every line carries what this process cost since the last one
                // (CPU seconds; Bluetooth notifications received; control messages written to
                // the watch) beside the two batteries themselves, so a day of lines is a
                // percent-per-hour reading for both devices against whatever each was doing.
                // Without these the log could say WHAT the app was doing, never what it cost.
                let backgrounded = await MainActor.run {
                    UIApplication.shared.applicationState == .background
                }
                let cost = telemetry.sample(
                    controlWrites: receiver.outboundControlCount.value, backgrounded: backgrounded)
                let phone = await MainActor.run { HeartbeatTelemetry.phoneBattery() }
                let watchBattery = receiver.watchBatteryPercent.value
                    .map { "\($0)%" } ?? "?"
                AppRuntimeLog.shared.flightRecorder?.recordHeartbeat(
                    "link=\(receiver.state.value) intent=\(receiver.captureIntent) "
                        + "watch=\(watch) residency=\(residency.state.value.rawValue) "
                        + "audio=\(audioAge) app=\(backgrounded ? "bg" : "fg") \(cost) "
                        + "phone=\(phone) watchbatt=\(watchBattery)"
                )
            }
        }
    }

    /// `handleEventsForBackgroundURLSession` — routed from the app delegate.
    ///
    /// The system completion handler is stored on the transport and invoked when the session
    /// reports its events drained, NOT here: iOS kills an app that returns from this callback
    /// without ever calling it, and calling it immediately lets the system re-suspend us before
    /// the finished uploads have been delivered.
    func handleBackgroundUrlSessionEvents(
        identifier: String, completionHandler: @escaping @Sendable () -> Void
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

    /// Core Bluetooth restored this process's central: iOS relaunched us for the watch.
    ///
    /// Reported by the link from `willRestoreState`, on its own queue, at a moment `shared` may
    /// not exist yet — the central is created inside `init`, before `bootstrap` publishes the
    /// graph — so it is latched and `install()` checks the latch, exactly as `sceneHasBeenActive`
    /// is handled. The hop to the main actor is what makes the two orderings equivalent: either
    /// this lands first (latch set, `shared` nil, `install()` acts on the latch) or `install()`
    /// runs first (latch clear, then this lands and acts on `shared`). One call either way.
    nonisolated static func noteStateRestored() {
        Task { @MainActor in
            stateWasRestored = true
            shared?.handleRestorationRelaunch(reason: "Core Bluetooth state restoration")
        }
    }

    private static var stateWasRestored = false
    private var restorationHandled = false

    /// iOS started us without a user: receive-only, before anything starts.
    ///
    /// The flag is set SYNCHRONOUSLY here — see `ReceiverService.markLaunchedInBackground()`. The
    /// lifecycle event still runs, for the rest of the transition and for the handled-events
    /// ledger the tests assert on. Idempotent: the restoration callback and the application-state
    /// check in `PebbleAudioApp` can both fire for one launch, and the second is not news.
    func handleRestorationRelaunch(reason: String) {
        guard !restorationHandled else { return }
        restorationHandled = true
        // NOT the same claim as "iOS started us headless" — see `noteSceneActive()` and the
        // `launchedHeadless` comment in `PebbleAudioApp`. A scene that has already come up wins.
        guard !Self.sceneHasBeenActive else {
            AppRuntimeLog.shared.record("launch cause: \(reason) (visible)")
            receiver.clearLaunchedInBackground()
            return
        }
        AppRuntimeLog.shared.record("launch cause: \(reason)")
        receiver.markLaunchedInBackground()
        // The link's give-up watchdog must not be armed for a wake nobody is watching (see
        // `CoreBluetoothAudioGattLink.setForeground`). `install()` seeds it from
        // `UIApplication.shared.applicationState`, and the flight recorder shows that reading is
        // `.active` even on a plainly headless 05:35 relaunch — so this is the only place in the
        // launch that knows better. A real foreground launch corrects it a moment later, from
        // `didBecomeActive` and from `noteSceneActive()`.
        gattLink.setForeground(false)
        Task { [lifecycle] in await lifecycle.handle(.restorationRelaunch) }
    }

    /// A scene is ACTIVE. The one unambiguous statement in the whole launch that a person is
    /// looking at this app — and therefore the thing that decides foreground, rather than a launch
    /// option or `UIApplication.shared.applicationState`, both of which lie here (21 of the 22
    /// process starts in the 2026-09-08 flight recorder were labelled `(foreground)` and ALSO
    /// carried the Core Bluetooth restoration key, including plainly headless 30-minute wakes).
    /// "A window exists" is NOT that statement — see `SceneForegroundRule` for the launch behind
    /// the lock screen that taught the difference.
    ///
    /// Reached through `noteScenePhase(_:)` from `PebbleAudioApp`, on the root view's first
    /// appearance and on every phase change, whenever the phase is `.active`. Costs one actor hop
    /// when nothing is wrong — `setForeground` is a
    /// transition guard and returns immediately when the runtime is already foreground — so it
    /// adds no timer, no poll and no per-frame work. When something IS wrong it is the whole
    /// repair: without it, a launch mis-labelled headless leaves the pipeline taking its
    /// background early-return, which skips the regroup step every screen's live conversation
    /// comes from, and only backgrounding the app and returning could ever undo it.
    /// STATIC on purpose: `bootstrap` can fail and retry into a NEW composition (a background
    /// relaunch before first unlock), and that one has to be born knowing a window already exists
    /// rather than starting the same guess over — see `install()`.
    static func noteSceneActive() {
        // The launch banner could not say why this process exists (see `launchCause()`); this is
        // the moment it becomes knowable, so the answer is written once, next to the banner it
        // completes. Once per process — `noteSceneActive` also fires on every return to the
        // foreground, and "the app is visible" is not news the second time.
        if !sceneHasBeenActive {
            AppRuntimeLog.shared.record("launch cause: a window came on screen (foreground)")
        }
        sceneHasBeenActive = true
        shared?.applySceneActive()
    }

    /// The scene phase, from the app's root: `.active` promotes, `.background` demotes,
    /// `.inactive` says nothing. Called on the root view's first appearance and on every change.
    /// `SceneForegroundRule` holds the reasoning; the short version is that a window can exist
    /// with nobody looking at it (a launch on a locked phone), and only the scene phase says
    /// which it is — in both directions.
    static func noteScenePhase(_ phase: ScenePhase) {
        switch SceneForegroundRule.foreground(for: phase) {
        case true?: noteSceneActive()
        case false?: noteSceneBackground()
        case nil: break
        }
    }

    /// The scene went to (or was born in) the background. Idempotent with the
    /// `didEnterBackground` path in `AppLifecycleCoordinator` — `setForeground` is a transition
    /// guard on both objects — but that path only fires after the app has been ACTIVE, and a
    /// process launched behind the lock screen never is. Without this nothing could ever demote
    /// a runtime that `.task` had promoted on the strength of the window alone.
    static func noteSceneBackground() {
        if !sceneHasBeenActive, !sceneBackgroundNoted {
            sceneBackgroundNoted = true
            AppRuntimeLog.shared.record(
                "launch cause: a window exists but its scene is in the background (launched behind"
                    + " the lock screen?) — staying headless")
        }
        shared?.applySceneBackground()
    }

    private static var sceneBackgroundNoted = false

    private func applySceneActive() {
        receiver.clearLaunchedInBackground()
        gattLink.setForeground(true)
        Task { [runtime] in await runtime.setForeground(true) }
    }

    private func applySceneBackground() {
        gattLink.setForeground(false)
        Task { [runtime] in await runtime.setForeground(false) }
    }

    // MARK: - Background processing

    private func registerBackgroundTask() {
        guard !didRegisterBackgroundTask else { return }
        didRegisterBackgroundTask = true
        // `using: .main`, and NOT nil. With nil, BGTaskScheduler invokes the launch handler on
        // its own private serial queue ("com.apple.BGTaskScheduler (<identifier>)"), and the
        // `MainActor.assumeIsolated` below is a hard assertion: `dispatch_assert_queue` fails,
        // SIGTRAP, and the process dies before `run(backgroundTask:)` runs a single line. That
        // was EVERY BGTask launch since the SwiftUI composition root (58c86ef): the crash reports
        // named the queue, and the flight recorder saw only the relaunch. A crash there is not a
        // missed maintenance window — it kills the receiver mid-stream (15:49 on 2026-09-09: ten
        // minutes of audio) and it is what "relaunched every ~30 minutes overnight" actually was.
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskPolicy.processingTaskIdentifier,
            using: .main
        ) { task in
            MainActor.assumeIsolated { AppComposition.shared?.run(backgroundTask: task) }
        }
        if !registered {
            AppRuntimeLog.shared.record("BGTaskScheduler registration refused")
        }
        // The charger-gated twin. Registered separately because it asks iOS for a different KIND
        // of window: `requiresExternalPower` means "run this when the device is idle and plugged
        // in", which in practice is overnight and grants minutes rather than seconds.
        let chargingRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskPolicy.chargingTaskIdentifier,
            using: .main  // same trap as above
        ) { task in
            MainActor.assumeIsolated { AppComposition.shared?.run(chargingTask: task) }
        }
        if !chargingRegistered {
            AppRuntimeLog.shared.record("BGTaskScheduler charging registration refused")
        }
        scheduleBackgroundProcessing()
        scheduleChargingCatchUp()
    }

    private func run(backgroundTask task: BGTask) {
        // Logged on BOTH edges. A BGProcessing window is the only scheduled wake this app gets,
        // and iOS grants it on opaque heuristics that punish apps the user rarely opens — so "did
        // it ever run, and how often" is a question a support log has to answer, and until now
        // only the FAILURE to submit was recorded.
        AppRuntimeLog.shared.record("BGProcessing window opened")
        // Re-arm first: a window that ends without a follow-up request is the last one iOS ever
        // gives us.
        scheduleBackgroundProcessing()
        // The link is not the processing task's business — but a link that went down while we
        // were suspended has no timer left to bring it back, because a suspended process runs no
        // timers at all. This window is awake, so it is the one scheduled chance to notice.
        // `connect()` is idempotent and returns immediately when a link is up or in progress.
        if receiver.captureIntent != .off {
            receiver.dialLink()
        }
        let lifecycle = self.lifecycle
        let work = Task {
            await lifecycle.handle(.backgroundProcessingStarted)
            AppRuntimeLog.shared.record("BGProcessing window finished")
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            Task {
                AppRuntimeLog.shared.record("BGProcessing window expired")
                // Expiration cancels OPTIONAL work only — never the receiver, never the intent.
                await lifecycle.handle(.backgroundProcessingExpired)
                work.cancel()
            }
        }
    }

    private func run(chargingTask task: BGTask) {
        AppRuntimeLog.shared.record("charging catch-up window opened")
        // Re-arm first: a window that ends without a follow-up request is the last one iOS gives.
        scheduleChargingCatchUp()
        let lifecycle = self.lifecycle
        let work = Task {
            await lifecycle.handle(.chargingCatchUpStarted)
            AppRuntimeLog.shared.record("charging catch-up window finished")
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            Task {
                AppRuntimeLog.shared.record("charging catch-up window expired")
                await lifecycle.handle(.backgroundProcessingExpired)
                work.cancel()
            }
        }
    }

    /// Asks iOS for a charger window.
    ///
    /// `requiresExternalPower` is the whole point: it is how you tell the system "this is the
    /// expensive, deferrable work", and the system answers by running it when the device is idle
    /// and on power. Also re-submitted whenever the power state changes, because a request made
    /// while on battery is worth renewing the moment a cable appears.
    func scheduleChargingCatchUp() {
        let request = BGProcessingTaskRequest(
            identifier: BackgroundTaskPolicy.chargingTaskIdentifier
        )
        request.requiresExternalPower = true
        // Local transcription needs no network; a cloud mode's uploads are the background
        // URLSession's problem, not this window's. Demanding connectivity would only make iOS
        // schedule it less often.
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: BackgroundTaskPolicy.earliestBeginInterval
        )
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Already-submitted is the common case (we re-submit on every power change), and it is
            // not worth a line every time.
            let nsError = error as NSError
            if nsError.code != BGTaskScheduler.Error.Code.tooManyPendingTaskRequests.rawValue {
                AppRuntimeLog.shared.record("charging catch-up submit failed: \(error)")
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

    /// The watch's service state in words, for the heartbeat. Raw numbers in a log are a lookup
    /// the reader should not have to do at 3am.
    private static func watchStateName(_ raw: Int) -> String {
        guard raw >= 0, raw <= Int(UInt8.max), let state = ServiceState(rawValue: UInt8(raw)) else {
            return "raw(\(raw))"
        }
        return String(describing: state)
    }

    /// Why this process exists — which, at composition time, is not yet knowable.
    ///
    /// This used to read `UIApplication.shared.applicationState` and print "foreground" or
    /// "background". MEASURED and wrong: composition runs from `PebbleAudioApp.init`, before
    /// `didFinishLaunchingWithOptions` and long before any scene, and in the 2026-09-08 flight
    /// recorder ALL 22 process starts read `.active` — including the 05:35 / 06:07 / 06:37 /
    /// 07:07 half-hourly wakes that were plainly headless. So every line in the file said
    /// "(foreground)", and the one distinction the launch banner exists to draw — "the app kept
    /// running" versus "iOS killed it and brought it back four times" — was not drawn at all.
    ///
    /// A label that is right one time in five is worse than no label, because it is read as
    /// evidence. The banner therefore states what is true at that instant, and the two signals
    /// that ARE trustworthy write the answer underneath it a moment later, each exactly once:
    /// `handleRestorationRelaunch()` ("Core Bluetooth state restoration") and `noteSceneActive()`
    /// ("a window came on screen"). Reading a log means pairing the banner with the next
    /// `launch cause:` line; a start with neither is a wake nothing ever explained, which is
    /// itself the finding.
    private static func launchCause() -> String {
        "cause pending"
    }

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

// MARK: - Cloud health wording

/// `cloudOutcomeSink`, with the failure re-worded before it can reach a screen.
///
/// `CloudHealth.message` is rendered verbatim on the Transcription & AI row, but the router
/// fills it with `transcriptionErrorMessage(error)` — developer prose with up to 240 bytes of
/// the provider's own response body spliced in, which for a 4xx is the request URL. That is the
/// text B20 exists to keep off screens. `TranscriptionFailureKind` already knows how to read
/// exactly this prose, and the app already owns a sentence per kind, so the classification
/// happens here, at the boundary where the kit's log line becomes the user's row.
func classifiedCloudOutcomeSink(
    _ monitor: CloudHealthMonitor?
) -> @Sendable (CloudConnectivityResult) -> Void {
    let sink = cloudOutcomeSink(monitor)
    return { result in
        switch result {
        case .failed(let message):
            sink(.failed(message: TranscriptionFailureKind.classify(message).reason))
        case .ok, .notConfigured:
            sink(result)
        }
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

/// Whether startup recovery is still running, readable from any thread.
///
/// `StartupSequencer` reports each step through its `onStep` closure, and until now nothing
/// supplied one. The distinction it carries is the difference between two identical-looking
/// screens: a library that is empty because nothing was ever recorded, and a library that is
/// empty because the store is still being recovered (or, on the first launch after the upgrade,
/// still being imported from the old app — tens of seconds of it).
///
/// It starts in the recovering state on purpose: the graph is built before `recoverIfNeeded()`
/// runs, and the honest answer in that window is "not read yet", not "nothing here".
final class StartupActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isRecovering: Bool { lock.withLock { !finished } }

    /// `.refreshDiagnostics` is the sequencer's last step, and the only one it emits on the
    /// already-recovered path — so it is the one that means "the durable work is done".
    func record(_ step: StartupStep) {
        guard step == .refreshDiagnostics else { return }
        lock.withLock { finished = true }
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
    /// The same ring, for the receiver stack (which cannot see `RuntimeLog` — it sits below
    /// CompanionRuntime in the module graph).
    static let receiverLog = ReceiverLog { shared.record($0) }

    private static let capacity = 400
    private let lock = NSLock()
    private var lines: [String] = []
    private var subscribers: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var generation = 0

    /// The durable half. The in-memory ring above stays because the Detailed Logs screen wants a
    /// cheap live tail, but it dies with the process — and every failure worth diagnosing here
    /// ends with the process gone. `recorder` is what a person can actually send us afterwards.
    ///
    /// Attached by the composition root once it knows the container path, so a log line emitted
    /// before that still lands in the ring rather than being dropped.
    private var recorder: FlightRecorder?

    func attach(recorder: FlightRecorder) {
        lock.withLock { self.recorder = recorder }
    }

    var flightRecorder: FlightRecorder? { lock.withLock { recorder } }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func record(_ message: String) {
        let line = "\(Self.stamp.string(from: Date()))  \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
        generation += 1
        let now = generation
        let continuations = Array(subscribers.values)
        let recorder = self.recorder
        lock.unlock()
        recorder?.record(message)
        for continuation in continuations { continuation.yield(now) }
        #if DEBUG
            print("[companion] \(line)")
        #endif
    }

    /// Newest first, for the log sheet.
    ///
    /// Prefers the durable file so the screen shows the history that spans launches — the ring
    /// only ever held this process, which is the wrong window for "it stopped overnight".
    var recent: [String] {
        if let recorder = flightRecorder {
            let durable = recorder.recentLines()
            if !durable.isEmpty { return durable }
        }
        return lock.withLock { lines.reversed() }
    }

    /// One element per write, conflated to the newest.
    ///
    /// Detailed Logs used to read `recent` from a computed property on an `@Observable` class —
    /// which registers no dependency on anything, so the screen froze on whatever the ring held
    /// at push time. During a live reproduction, which is the only time this screen matters, it
    /// silently showed history while the rows above it updated around it.
    func generations() -> AsyncStream<Int> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock()
            subscribers[id] = continuation
            let snapshot = generation
            lock.unlock()
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }
}

/// The per-heartbeat cost counters. Cheap on the hot path (one lock, one increment per
/// notification) and read once a minute.
final class HeartbeatTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var notifications = 0
    private var lastNotifications = 0
    private var lastCpuSeconds: Double = HeartbeatTelemetry.cpuSeconds()
    private var lastControlWrites = 0

    /// Called on the Core Bluetooth delegate queue for every inbound notification.
    func noteInboundNotification() {
        lock.withLock { notifications += 1 }
    }

    /// The CPU watchdog's line in the sand: CPU-seconds per minute this process may spend while
    /// it is in the background before the heartbeat calls it out.
    ///
    /// Six seconds a minute is a tenth of one core. A backgrounded app that only receives audio
    /// over Bluetooth and writes it to disk measures well under one; the loop this watchdog was
    /// written after measured sixty-three. The number is deliberately loose -- it must never fire
    /// on a busy but honest minute (a segment closing, a snapshot being written) -- because a
    /// watchdog that cries wolf is a watchdog nobody reads.
    static let backgroundCpuBudgetSecondsPerMinute = 6.0

    /// Set while the last backgrounded heartbeat exceeded the budget, for the Diagnostics screen.
    private(set) var budgetExceededAt: Date?
    private(set) var lastBackgroundCpuSeconds: Double = 0

    /// One heartbeat's worth of deltas, formatted for the log line, and the baseline advanced.
    ///
    /// While backgrounded the CPU delta is judged against `backgroundCpuBudgetSecondsPerMinute`
    /// and the line says so in capitals, because "cpu=+63.5s" in a log nobody grepped for it is
    /// how a full core went unnoticed for weeks. The same verdict is kept for the Diagnostics
    /// screen, so the phone can report the problem without a Mac attached.
    func sample(controlWrites: Int, backgrounded: Bool) -> String {
        let cpu = Self.cpuSeconds()
        return lock.withLock {
            let notificationDelta = notifications - lastNotifications
            lastNotifications = notifications
            let cpuDelta = max(0, cpu - lastCpuSeconds)
            lastCpuSeconds = cpu
            let controlDelta = max(0, controlWrites - lastControlWrites)
            lastControlWrites = controlWrites
            var line = String(
                format: "cpu=+%.2fs notif=+%d ctl=+%d", cpuDelta, notificationDelta, controlDelta)
            if backgrounded {
                lastBackgroundCpuSeconds = cpuDelta
                if cpuDelta > Self.backgroundCpuBudgetSecondsPerMinute {
                    budgetExceededAt = Date()
                    line += String(
                        format: " CPU BUDGET EXCEEDED (background, %.0fs/min > %.0fs/min)",
                        cpuDelta, Self.backgroundCpuBudgetSecondsPerMinute)
                } else {
                    budgetExceededAt = nil
                }
            }
            return line
        }
    }

    /// The Diagnostics row, or nil when the last backgrounded minute was within budget.
    var alertText: String? {
        lock.withLock {
            guard budgetExceededAt != nil else { return nil }
            return String(
                format: "Using %.0f s of CPU a minute in the background (budget %.0f s). "
                    + "Something is looping; share the log.",
                lastBackgroundCpuSeconds, Self.backgroundCpuBudgetSecondsPerMinute)
        }
    }

    /// User + system CPU time this process has consumed, in seconds.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// "87%/unplugged", "62%/charging", or "?" when monitoring is off. `DevicePowerMonitor`
    /// enables battery monitoring at launch, so the level is normally available.
    @MainActor
    static func phoneBattery() -> String {
        let device = UIDevice.current
        let level = device.batteryLevel
        guard level >= 0 else { return "?" }
        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        default: state = "unknown"
        }
        return "\(Int((level * 100).rounded()))%/\(state)"
    }
}
