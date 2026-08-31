import AppDB
import CompanionRuntime
import Foundation
import Intelligence
import LiveAudio
import Receiver
import SearchKit
import SegmentStore
import StatusUI
import Transcription
import WireProtocol

// Hermetic fixtures: no Bluetooth, no network, no wall-clock waits. Every clock is the virtual
// `TestClock` (same discipline as ReceiverTests), every store is a temp directory or an
// in-memory database, and every provider is a fake.

// MARK: - Fakes

/// A link that never connects: the receiver session idles and never reads or streams.
/// (Port of `AudioCompanionRuntimeBackgroundTest.IdleGattLink`.)
final class IdleGattLink: AudioGattLink, @unchecked Sendable {
    let connectionState = StateSubject<LinkState>(.disconnected)
    let lastFailure = StateSubject<ConnectFailure?>(nil)
    private(set) var resyncCount = 0
    private(set) var disconnectCount = 0

    func readInfo() async throws -> [UInt8] { [] }
    func writeControl(_ message: [UInt8]) async throws {}
    var controlNotifications: AsyncStream<[UInt8]> { AsyncStream { $0.finish() } }
    var dataNotifications: AsyncStream<[UInt8]> { AsyncStream { $0.finish() } }
    func disconnect() { disconnectCount += 1 }
    func resync() { resyncCount += 1 }
}

/// Records model release calls. (Port of `RecordingLifecycle`.)
final class RecordingLifecycle: LocalTranscriptionLifecycle, @unchecked Sendable {
    private let lock = NSLock()
    private var _releaseReasons: [String] = []
    private var _idleChecks = 0

    var releaseReasons: [String] { lock.withLock { _releaseReasons } }
    var idleChecks: Int { lock.withLock { _idleChecks } }

    func releaseModel(reason: String) async {
        lock.withLock { _releaseReasons.append(reason) }
    }

    func releaseModelIfIdle(nowMs: Int64, idleTimeoutMs: Int64) async {
        lock.withLock { _idleChecks += 1 }
    }
}

/// Captures Q9 notifications.
final class RecordingLossNotifier: LossNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [LossEvent] = []

    var events: [LossEvent] { lock.withLock { _events } }

    func notifyAudioMissed(_ event: LossEvent) async {
        lock.withLock { _events.append(event) }
    }
}

struct UnlimitedFreeSpace: FreeSpaceProvider {
    func freeBytes() -> Int64 { .max }
}

/// In-memory transcript index so donation is observable without SQLite/Spotlight.
final class RecordingIndex: TranscriptIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: IndexItem] = [:]
    private(set) var removedIds: [String] = []

    var isAvailable: Bool { true }

    func upsert(_ newItems: [IndexItem]) throws {
        lock.withLock { for item in newItems { items[key(item.id, item.kind)] = item } }
    }

    func search(_ query: String, limit: Int) throws -> [IndexHit] { [] }

    func remove(id: String, kind: IndexKind) throws {
        lock.withLock {
            items.removeValue(forKey: key(id, kind))
            removedIds.append(id)
        }
    }

    func remove(id: String) throws {
        lock.withLock {
            for kind in IndexKind.allCases { items.removeValue(forKey: key(id, kind)) }
            removedIds.append(id)
        }
    }

    func removeAll() throws { lock.withLock { items.removeAll() } }

    var ids: Set<String> { lock.withLock { Set(items.values.map(\.id)) } }

    private func key(_ id: String, _ kind: IndexKind) -> String { "\(kind.rawValue):\(id)" }
}

/// Spotlight sink that records donations instead of touching CoreSpotlight.
final class RecordingSpotlight: SpotlightIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var donated: [String] = []
    private(set) var removed: [String] = []

    func donate(_ donations: [SpotlightDonation]) async throws {
        lock.withLock { donated.append(contentsOf: donations.map(\.uniqueIdentifier)) }
    }

    func remove(uniqueIdentifiers: [String]) async throws {
        lock.withLock { removed.append(contentsOf: uniqueIdentifiers) }
    }

    func removeAll() async throws {}
}

// MARK: - Segment helpers

enum Fixture {
    static func temporaryDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-runtime-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let receiverId: [UInt8] = (0..<32).map { UInt8($0) }

    static func receiverConfig() -> ReceiverConfig {
        ReceiverConfig(receiverId: receiverId, receiverName: "test")
    }

    static func streamStart(
        streamId: UInt32 = 0x5EED_0001, startTimeMs: UInt64 = 1_756_512_000_000
    ) -> StreamStart {
        StreamStart(
            protocolVersion: ProtocolConstants.protocolVersion,
            streamId: streamId,
            codecIdRaw: CodecId.speexWideband.rawValue,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 8_000,
            frameDurationMs: 20,
            startTimeMs: startTimeMs,
            startMonotonicMs: 0,
            flags: 0
        )
    }

    /// A closed segment with `frames` 20 ms frames, so retention/queue tests have real input.
    @discardableResult
    static func writeSegment(
        into store: SegmentStore,
        streamId: UInt32 = 0x5EED_0001,
        startTimeMs: UInt64 = 1_756_512_000_000,
        frames: Int = 10,
        receivedAtMs: Int64 = 1_756_512_000_000,
        close: Bool = true,
        /// Default is `shutdown`, NOT `userDisabled`: a user stop always ends the conversation
        /// (plan Part 3 precedence), which would silently defeat any chaining fixture.
        stopReason: StopReason = .shutdown
    ) async throws -> String {
        try await store.openSegment(
            start: streamStart(streamId: streamId, startTimeMs: startTimeMs),
            receivedAtMs: receivedAtMs,
            provenance: nil
        )
        let payload: [UInt8] = Array(repeating: 0x11, count: 20)
        let batch = (0..<frames).map {
            SegmentFrame(
                sequence: UInt32($0), sampleIndex: UInt64($0) * 320, payload: payload
            )
        }
        _ = try await store.appendFrames(streamId: streamId, frames: batch)
        let id = await store.openSegmentId ?? ""
        if close {
            try await store.closeSegment(
                reason: .stopped(
                    reasonRaw: Int(stopReason.rawValue),
                    finalSequence: UInt32(max(0, frames - 1)),
                    finalSampleIndex: UInt64(frames) * 320
                )
            )
        }
        return id
    }

    /// Segment metadata carrying `gaps`, for the Q9 evaluator (no store needed).
    static func meta(
        segmentId: String = "seg-1",
        frameDurationMs: Int = 20,
        gaps: [GapMeta] = [],
        isOpen: Bool = false
    ) -> SegmentMeta {
        SegmentMeta(
            segmentId: segmentId,
            streamId: 1,
            protocolVersion: 1,
            codecIdRaw: CodecId.speexWideband.rawValue,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 8_000,
            frameDurationMs: frameDurationMs,
            startTimeMs: 1_756_512_000_000,
            startMonotonicMs: 0,
            receivedAtMs: 1_756_512_000_000,
            frameCount: 100,
            logBytes: 2_000,
            gaps: gaps,
            closeReason: isOpen ? nil : CloseReasonMeta(kind: "interrupted"),
            transcriptionState: .pending
        )
    }

    static func watchGap(
        reason: GapReason, missingFrames: UInt32, firstSequence: UInt32 = 100
    ) -> GapMeta {
        GapMeta(
            firstMissingSequence: firstSequence,
            missingFrameCount: missingFrames,
            firstMissingSampleIndex: UInt64(firstSequence) * 320,
            origin: GapMeta.originWatch,
            reasonRaw: Int(reason.rawValue),
            watchDropCounter: 1
        )
    }

    static func sequenceSkipGap(missingFrames: UInt32, firstSequence: UInt32 = 100) -> GapMeta {
        GapMeta(
            firstMissingSequence: firstSequence,
            missingFrameCount: missingFrames,
            firstMissingSampleIndex: UInt64(firstSequence) * 320,
            origin: GapMeta.originSequenceSkip
        )
    }
}

// MARK: - A whole runtime, wired from real services

/// Everything a runtime test needs to reach into, kept alive together.
final class RuntimeFixture: @unchecked Sendable {
    let root: URL
    let snapshotRoot: URL
    let clock: TestClock
    let database: AppDatabase
    let store: SegmentStore
    let retention: RetentionManager
    let settings: RuntimeSettingsBox
    let link: IdleGattLink
    let lifecycle: RecordingLifecycle
    let lossNotifier: RecordingLossNotifier
    let pauseJournal: PauseJournal
    let queue: TranscriptionQueue
    let transcriptStore: FileTranscriptStore
    let annotations: AnnotationStore
    let aiOutputs: AiOutputStore
    let followUps: FollowUpStore
    let recapStore: DailyRecapStore
    let index: RecordingIndex
    let spotlight: RecordingSpotlight
    let snapshotWriter: CoverageSnapshotWriter

    let receiver: ReceiverService
    let transcription: TranscriptionService
    let enrichment: EnrichmentService
    let recap: RecapService
    let live: LiveAudioService
    let diagnostics: DiagnosticsService
    let cascade: DeleteCascade
    let deferredDeletes: DeferredDeleteBuffer
    let snapshots: CoverageSnapshotService
    let startup: StartupSequencer
    let runtime: CompanionRuntime
    let stages = StageRecorder()

    init(
        settings: RuntimeSettingsSnapshot = RuntimeSettingsSnapshot(captureIntent: .active),
        withLossNotifier: Bool = true
    ) throws {
        root = Fixture.temporaryDirectory("root")
        snapshotRoot = Fixture.temporaryDirectory("group")
        let clock = TestClock()
        self.clock = clock
        database = try AppDatabase.inMemory()
        store = SegmentStore(root: root, nowMs: { clock.nowMs })
        let settingsBox = RuntimeSettingsBox(settings)
        self.settings = settingsBox
        retention = RetentionManager(
            store: store,
            freeSpace: UnlimitedFreeSpace(),
            nowMs: { clock.nowMs },
            config: retentionConfig(for: settingsBox)
        )
        link = IdleGattLink()
        lifecycle = RecordingLifecycle()
        lossNotifier = RecordingLossNotifier()
        pauseJournal = PauseJournal(db: database)
        queue = TranscriptionQueue(database: database, nowMs: { clock.nowMs })
        transcriptStore = FileTranscriptStore(root: root, nowMs: { clock.nowMs })
        annotations = try AnnotationStore(db: database, nowMs: { clock.nowMs })
        aiOutputs = AiOutputStore(db: database, nowMs: { clock.nowMs })
        followUps = FollowUpStore(db: database)
        recapStore = DailyRecapStore(db: database, nowMs: { clock.nowMs })
        index = RecordingIndex()
        spotlight = RecordingSpotlight()
        snapshotWriter = CoverageSnapshotWriter(directory: snapshotRoot)

        let router = TranscriptionModeRouter(
            local: nil, remote: nil, mode: { settingsBox.transcriptionMode }
        )
        let store = self.store
        let processor = TranscriptionProcessor(
            queue: queue,
            router: router,
            pcmSource: { _ in AsyncThrowingStream { $0.finish() } },
            transcriptStore: transcriptStore,
            isSegmentOpen: { id in await store.openSegmentId == id }
        )
        let evaluator = LossEventEvaluator(
            notifier: lossNotifier,
            captureIsActive: { settingsBox.captureIntent == .active }
        )
        receiver = ReceiverService(
            link: link,
            store: store,
            retention: retention,
            resumeStore: FileReceiverResumeStore(root: root),
            config: Fixture.receiverConfig(),
            clock: clock,
            initialIntent: settings.captureIntent,
            pauseJournal: pauseJournal,
            lossEvaluator: withLossNotifier ? evaluator : nil
        )
        transcription = TranscriptionService(
            queue: queue,
            processor: processor,
            transcriptStore: transcriptStore,
            store: store,
            settings: settingsBox,
            clock: clock,
            modelLifecycle: lifecycle
        )
        let transcriptStore = self.transcriptStore
        let donator = SpotlightDonator(index: index, spotlight: spotlight)
        enrichment = EnrichmentService(
            worker: EnrichmentWorker(
                annotations: annotations, router: nil, nowMs: { clock.nowMs }
            ),
            annotations: annotations,
            store: store,
            database: database,
            pauseJournal: pauseJournal,
            transcriptOf: { transcriptStore.load($0) },
            donator: donator,
            clock: clock
        )
        recap = RecapService(engine: nil, store: recapStore)
        live = LiveAudioService(
            store: store,
            hasDurableTranscript: { transcriptStore.load($0) != nil },
            automaticWavExportEnabled: { settingsBox.automaticWavExportEnabled }
        )
        let foreground = RuntimeForegroundState()
        self.foreground = foreground
        let queue = self.queue
        diagnostics = DiagnosticsService(
            store: store,
            retention: retention,
            tasks: { (try? queue.all()) ?? [] },
            isForeground: { foreground.value },
            clock: clock
        )
        cascade = DeleteCascade(
            store: store,
            transcription: transcription,
            annotations: annotations,
            aiOutputs: aiOutputs,
            followUps: followUps,
            recaps: recap,
            enrichment: enrichment,
            index: index,
            donator: donator,
            lossEvaluator: evaluator
        )
        deferredDeletes = DeferredDeleteBuffer(cascade: cascade, clock: clock)
        snapshots = CoverageSnapshotService(
            store: store,
            writer: snapshotWriter,
            clock: clock,
            statusOf: { StatusModel.transcriptsOff },
            pauseJournal: pauseJournal
        )
        let transcription = self.transcription
        let retention = self.retention
        let cascade = self.cascade
        let diagnostics = self.diagnostics
        startup = StartupSequencer(
            steps: StartupSteps(
                recoverStore: { try await store.recover() },
                recoverQueue: { try await transcription.recoverOnStart() },
                enforceRetention: { try await retention.enforce() },
                cascadeDeleted: { _ = await cascade.deleteSegment($0) },
                enqueueClosedSegments: { try await transcription.enqueueClosedSegments() },
                refreshDiagnostics: { await diagnostics.refresh() }
            )
        )
        let stages = self.stages
        runtime = CompanionRuntime(
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
                foreground: foreground
            ),
            onStage: { stages.record($0) }
        )
    }

    /// Shared with the runtime: the pass and diagnostics read the same object.
    let foreground: RuntimeForegroundState

    deinit {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: snapshotRoot)
    }
}

/// Records pipeline stages in execution order.
final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _stages: [PipelineStage] = []

    var stages: [PipelineStage] { lock.withLock { _stages } }
    func record(_ stage: PipelineStage) { lock.withLock { _stages.append(stage) } }
    func reset() { lock.withLock { _stages.removeAll() } }
}

/// Records startup steps in execution order.
final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [StartupStep] = []

    var steps: [StartupStep] { lock.withLock { _steps } }
    func record(_ step: StartupStep) { lock.withLock { _steps.append(step) } }
}

/// Generic ordered-call recorder for the closure-based seams.
final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []

    var calls: [String] { lock.withLock { _calls } }
    func record(_ name: String) { lock.withLock { _calls.append(name) } }
    func reset() { lock.withLock { _calls.removeAll() } }
}

/// Waits for `condition` to hold. Used only where GRDB's own serial queue does real (not
/// virtual) work — everything the runtime itself sleeps on goes through `TestClock`.
/// Bounded and short so a genuine regression fails fast instead of hanging CI.
func waitUntil(
    timeoutMs: Int = 2_000,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    var waited = 0
    while waited < timeoutMs {
        if await condition() { return true }
        await TestClock.settle(yields: 20)
        try? await Task.sleep(nanoseconds: 1_000_000)
        waited += 1
    }
    return await condition()
}
