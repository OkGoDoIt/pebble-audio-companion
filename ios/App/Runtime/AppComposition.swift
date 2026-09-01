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
    /// Produces `PersonalContext.derivedTerms` — the keyword list the OpenAI STT prompt is
    /// built from. Held so a surface that edits "About you" can ask for an immediate refresh
    /// instead of waiting for the next transcription to notice.
    let personalContextTerms: PersonalContextTermRefresher

    // --- pipeline ---------------------------------------------------------------------------

    /// The receive half, held so the status/diagnostics layer can read the watch's own refusal
    /// (`lastProtocolError`, `watchInfo`) synchronously — `runtime.environment` is actor-isolated
    /// and the status card is derived on the main actor without an await.
    let receiver: ReceiverService
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
            selected: { settingsBox.localTranscriptionModelId }
        )
        let router = TranscriptionModeRouter(
            local: localBatch,
            remote: batchCloud,
            onRemoteOutcome: classifiedCloudOutcomeSink(cloudHealth),
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
            mode: { settingsBox.aiMode }
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
            log: { AppRuntimeLog.shared.record($0) }
        )
        self.personalContextTerms = personalContextTerms
        termRefresh.install(personalContextTerms)
        // Catch up at launch so a bio pasted during onboarding is already biasing the first
        // recording, rather than only from the second one onwards.
        Task { await personalContextTerms.refreshIfNeeded() }

        let enrichment = EnrichmentService(
            worker: EnrichmentWorker(
                annotations: annotations, router: aiRouter, nowMs: nowMs
            ),
            // Follow-up extraction (plan Part 4.5). `FollowUps.swift` was ported whole and then
            // never called by anything, which is why every conversation truthfully reported
            // "All caught up." — nothing had ever written a follow-up.
            followUps: FollowUpWorker(
                items: ActionItemStore(db: database, nowMs: nowMs),
                state: try FollowUpExtractionStore(db: database),
                router: aiRouter,
                nowMs: nowMs
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
                onRecapSaved: makeRecapDonationHook(
                    donator: donator, clock: clock, log: AppRuntimeLog.runtimeLog
                )
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
        gattLink.prepareForRestoration()

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
            onStoreEvent: { wake.signal() },
            onCoverageTrigger: { await coverageTriggers.fire($0) },
            log: AppRuntimeLog.runtimeLog
        )
        self.receiver = receiver

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
            lossEvaluator: lossEvaluator,
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
                let open = (try? await followUps.list(done: false)) ?? []
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
        // Spotlight donation reuses this database connection rather than opening a second pool.
        nativeSurfaces.attachDatabase(database)
        // Held so Diagnostics → Rebuild Search Index can clear the donation watermark it owns.
        self.nativeSurfaces = nativeSurfaces

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
    ///
    /// The flag is set SYNCHRONOUSLY here — see `ReceiverService.markLaunchedInBackground()`. The
    /// lifecycle event still runs, for the rest of the transition and for the handled-events
    /// ledger the tests assert on.
    func handleRestorationRelaunch() {
        receiver.markLaunchedInBackground()
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
