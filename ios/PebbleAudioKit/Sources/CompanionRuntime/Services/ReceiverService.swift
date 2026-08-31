import AppDB
import Foundation
import LiveAudio
import Receiver
import SegmentStore
import WireProtocol

// The receive half of the runtime (plan Part 4.6, "Keep"). Owns the GATT link, the session, the
// durable sink chain, and the capture-intent tri-state — and nothing about transcription or AI.
//
// Sink chain (outermost first):
//   LossObservingSink  → Q9 evaluation + coverage-snapshot triggers + pipeline wakeups
//     TeeSegmentSink   → live waveform / live-cloud fan-out (only ACCEPTED frames)
//       SegmentStore   → durable .spxlog + meta.json

/// Decorator that observes the durable sink so the runtime learns about gaps and segment
/// boundaries without the session or the store knowing anything about notifications.
///
/// Every hook runs AFTER the downstream call returns, so nothing is observed before it is
/// durable — the ordering the receiver's whole durability story rests on.
final class LossObservingSink: SegmentSink, @unchecked Sendable {
    private let downstream: any SegmentSink
    private let openSegmentId: @Sendable () async -> String?
    private let onGapPersisted: @Sendable (String, GapRecord) async -> Void
    private let onSegmentOpened: @Sendable (String) async -> Void
    private let onSegmentClosed: @Sendable (String) async -> Void

    init(
        downstream: any SegmentSink,
        openSegmentId: @escaping @Sendable () async -> String?,
        onGapPersisted: @escaping @Sendable (String, GapRecord) async -> Void = { _, _ in },
        onSegmentOpened: @escaping @Sendable (String) async -> Void = { _ in },
        onSegmentClosed: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.downstream = downstream
        self.openSegmentId = openSegmentId
        self.onGapPersisted = onGapPersisted
        self.onSegmentOpened = onSegmentOpened
        self.onSegmentClosed = onSegmentClosed
    }

    func openSegment(
        start: StreamStart, receivedAtMs: Int64, provenance: DurableSegmentProvenance?
    ) async throws {
        try await downstream.openSegment(
            start: start, receivedAtMs: receivedAtMs, provenance: provenance
        )
        if let id = await openSegmentId() { await onSegmentOpened(id) }
    }

    func appendFrames(streamId: UInt32, frames: [SegmentFrame]) async throws -> [SegmentFrame] {
        try await downstream.appendFrames(streamId: streamId, frames: frames)
    }

    func recordGap(streamId: UInt32, gap: GapRecord) async throws {
        // Durability first, always: the gap is evaluated only once it is on disk.
        try await downstream.recordGap(streamId: streamId, gap: gap)
        if let id = await openSegmentId() { await onGapPersisted(id, gap) }
    }

    func closeSegment(reason: SegmentCloseReason) async throws {
        // Capture the id BEFORE the close: afterwards there is no open segment to ask about.
        let closing = await openSegmentId()
        try await downstream.closeSegment(reason: reason)
        if let closing { await onSegmentClosed(closing) }
    }
}

/// Owns the receiver session and the user's capture intent.
public actor ReceiverService {
    private let link: any AudioGattLink
    private let store: SegmentStore
    private let resumeStore: any ReceiverResumeStore
    private let pauseJournal: PauseJournal?
    private let clock: RuntimeClock
    private let log: RuntimeLog

    private let session: AudioReceiverSession
    private let intentBox: IntentBox
    private let enableRequestArmed: ArmedFlag
    private let onCoverageTrigger: @Sendable (CoverageSnapshotTrigger) async -> Void

    private var sessionTask: Task<Void, Never>?

    public init(
        link: any AudioGattLink,
        store: SegmentStore,
        retention: RetentionManager,
        resumeStore: any ReceiverResumeStore,
        config: ReceiverConfig,
        clock: RuntimeClock,
        initialIntent: CaptureIntent = .off,
        liveMonitor: LiveAudioMonitor? = nil,
        liveAudioTap: LiveAudioTap? = nil,
        pauseJournal: PauseJournal? = nil,
        lossEvaluator: LossEventEvaluator? = nil,
        onStoreEvent: @escaping @Sendable () -> Void = {},
        onCoverageTrigger: @escaping @Sendable (CoverageSnapshotTrigger) async -> Void = { _ in },
        log: RuntimeLog = .silent
    ) {
        let intent = IntentBox()
        intent.set(initialIntent)
        let armed = ArmedFlag()

        self.link = link
        self.store = store
        self.resumeStore = resumeStore
        self.pauseJournal = pauseJournal
        self.clock = clock
        self.log = log
        self.intentBox = intent
        self.enableRequestArmed = armed
        self.onCoverageTrigger = onCoverageTrigger

        // Sink chain, innermost first.
        let durable: any SegmentSink
        if let liveMonitor {
            durable = TeeSegmentSink(
                store: store,
                monitor: liveMonitor,
                nowMs: { clock.nowMs },
                tap: liveAudioTap,
                onSegmentClosed: onStoreEvent
            )
        } else {
            durable = store
        }

        let observed = LossObservingSink(
            downstream: durable,
            openSegmentId: { await store.openSegmentId },
            onGapPersisted: { segmentId, gap in
                guard let lossEvaluator, let meta = await store.readMeta(segmentId) else { return }
                _ = await lossEvaluator.gapPersisted(
                    meta: meta,
                    gap: GapMeta.from(gap),
                    isSegmentOpen: true,
                    nowMs: clock.nowMs
                )
            },
            onSegmentOpened: { _ in await onCoverageTrigger(.manual) },
            onSegmentClosed: { segmentId in
                // Release the B21-deferred loss candidate now that the segment is terminal.
                if let lossEvaluator {
                    _ = await lossEvaluator.segmentClosed(
                        segmentId: segmentId, nowMs: clock.nowMs
                    )
                }
                onStoreEvent()
                await onCoverageTrigger(.segmentClosed)
            }
        )

        self.session = AudioReceiverSession(
            link: link,
            sink: observed,
            policy: retention,
            resumeStore: resumeStore,
            config: config,
            clock: clock,
            captureIntent: { intent.value },
            consumeEnableRequestPermission: { armed.consume() }
        )
    }

    // --- published state ---------------------------------------------------------------------

    public nonisolated var state: StateSubject<ReceiverSessionState> { session.state }
    public nonisolated var watchServiceState: StateSubject<Int?> { session.watchServiceState }
    public nonisolated var watchInfo: StateSubject<InfoSnapshot?> { session.watchInfo }
    /// The last `ERROR` the watch sent. Read by the status/diagnostics layer through
    /// `WatchLinkFault`: without it a de-authorized receiver loops connect → authorize → resync
    /// forever behind the word "Connecting…", with nothing anywhere to say why.
    public nonisolated var lastProtocolError: StateSubject<ErrorMessage?> {
        session.lastProtocolError
    }
    /// The version the watch granted at authorization (nil until one is). Diagnostics only.
    public nonisolated var grantedProtoVersion: StateSubject<Int?> { session.grantedProtoVersion }
    /// The bound watch's advertised name, straight from the link. Nil until one has been seen.
    public nonisolated var deviceName: StateSubject<String?> { link.deviceName }
    public nonisolated var captureIntent: CaptureIntent { intentBox.value }
    public nonisolated var isRunning: Bool { intentBox.running }
    /// Restoration relaunch flag — see `applyLaunchedInBackground()`.
    public nonisolated var launchedInBackground: Bool { intentBox.launchedInBackground }

    // --- lifecycle ---------------------------------------------------------------------------

    /// Starts the session. Idempotent: repeated calls (foreground entry, restoration relaunch,
    /// a Start tap) never stack sessions.
    public func start() {
        guard sessionTask == nil else { return }
        intentBox.running = true
        sessionTask = session.start()
    }

    /// Tears the session down without touching the user's intent or the watch's pause state.
    public func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        intentBox.running = false
        enableRequestArmed.disarm()
    }

    /// Arms EXACTLY ONE phone-initiated watch enable prompt.
    ///
    /// Automatic lifecycle reconnects may resume an already-enabled watch, but only an explicit
    /// Start/Settings tap may ask the watch to turn Background Audio on. When the watch already
    /// refused because the feature is disabled there, a resync is required for a fresh
    /// authorization (and therefore the new enable request) to happen at all.
    public func armWatchEnableRequest() {
        enableRequestArmed.arm()
        if session.state.value.deniedStatus == .deniedDisabled {
            link.resync()
        }
    }

    /// True while a one-shot enable request is armed (diagnostics/tests).
    public nonisolated var isWatchEnableRequestArmed: Bool { enableRequestArmed.isArmed }

    /// User-facing "Reconnect": a fresh GATT session now, without changing the intent.
    public nonisolated func reconnect() {
        link.resync()
    }

    /// User-initiated Stop: pause the watch first (so its own Settings show Paused and it does
    /// not stream into a void), then tear down and drop the connection.
    ///
    /// Race: a fast Stop → Start flips the intent back to `.active` while the pause request is
    /// still in flight. Tearing down then would strand the restart (a dead session with the
    /// intent on), so instead we keep the live session and just undo the pause.
    public func stopReceiving() async {
        _ = await session.requestPause()
        if intentBox.value == .active {
            _ = await session.requestResume()
            return
        }
        stop()
        link.disconnect()
    }

    // --- capture intent (plan 6.1) -------------------------------------------------------------

    /// Applies the tri-state. `active`↔`paused` is Pause/Resume; anything↔`off` is the Background
    /// Audio master switch.
    ///
    /// Pause journal (plan 6.1: the watch cannot report pause intervals and coverage needs them):
    /// a row BEGINS when the watch acks the pause and ENDS when it acks the resume. An
    /// unacknowledged pause writes nothing — coverage must never claim a pause the watch never
    /// took.
    public func applyCaptureIntent(
        _ intent: CaptureIntent, source: PauseSource = .statusCard
    ) async {
        let previous = intentBox.value
        intentBox.set(intent)
        guard previous != intent else { return }

        switch intent {
        case .active:
            start()
            if previous == .paused, await session.requestResume() {
                await endPauseInterval()
            }
        case .paused:
            // Pause only means something against a live session; otherwise record intent only.
            if sessionTask != nil, await session.requestPause() {
                await beginPauseInterval(source: source)
            }
        case .off:
            // Leaving a pause behind: the interval ends here — "off" is its own coverage state.
            if previous == .paused { await endPauseInterval() }
            await stopReceiving()
        }
        await onCoverageTrigger(.pauseChanged)
    }

    /// Restoration relaunch (plan Part 4.6): the app woke in the background, so receive-only is
    /// applied BEFORE the receiver starts. Never changes the user's intent.
    public func applyLaunchedInBackground() {
        intentBox.launchedInBackground = true
    }

    public func clearLaunchedInBackground() {
        intentBox.launchedInBackground = false
    }

    // --- teardown helpers used by destructive flows --------------------------------------------

    /// Local revoke: forget the binding so the next connection re-consents on the watch.
    public func revokeReceiverLocally() async {
        stop()
        link.disconnect()
        await resumeStore.clear()
    }

    /// Closes the open segment (interrupted) — used by "delete all data", so the cascade has
    /// nothing left to refuse.
    ///
    /// Routed through the SESSION, never straight at the store. The store's open segment and the
    /// session's stream context are one object split across two owners: closing only the store's
    /// half left the session appending into nothing (`appendFrames` answers an absent segment
    /// with an empty array, which reads exactly like an ordinary dedupe) and CHECKPOINTING the
    /// result, which tells the watch to free the only remaining copy of audio this app threw
    /// away — no gap, no error, and the UI still saying "recording".
    ///
    /// Pair it with `resumeAfterBulkDelete()`: until the stream is re-established the session has
    /// no context and drops STREAM_DATA on the floor (uncheckpointed, so the watch keeps it).
    public func closeOpenSegment() async {
        await session.endOpenSegment()
        // Belt and braces. The session owns every open segment, so this is a no-op in practice;
        // if the two ever disagreed, "delete all" leaving a live recording behind is the failure
        // this whole path exists to prevent.
        try? await store.closeSegment(reason: .interrupted)
    }

    /// Re-establishes the stream after a destructive bulk delete tore the segment down under it.
    ///
    /// A fresh GATT session makes the watch re-announce STREAM_START, which opens a new segment
    /// and redelivers everything past our last checkpoint. Without it the receiver would sit
    /// contextless — still connected, still "recording" — until the watch's next rotation, up to
    /// 15 minutes away. Called AFTER the cascade, so the re-announced stream cannot reattach to a
    /// segment that is about to be deleted.
    public func resumeAfterBulkDelete() {
        guard sessionTask != nil else { return }
        link.resync()
    }

    private func beginPauseInterval(source: PauseSource) async {
        guard let pauseJournal else { return }
        do {
            _ = try await pauseJournal.begin(source: source, atMs: clock.nowMs)
        } catch {
            log.failure("pause journal begin", error)
        }
    }

    private func endPauseInterval() async {
        guard let pauseJournal else { return }
        do {
            try await pauseJournal.end(atMs: clock.nowMs)
        } catch {
            log.failure("pause journal end", error)
        }
    }
}

// --- tiny shared boxes ---------------------------------------------------------------------

/// Capture intent + run flags shared with the session's synchronous closures.
final class IntentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var intent: CaptureIntent = .off
    private var _running = false
    private var _launchedInBackground = false

    var value: CaptureIntent { lock.withLock { intent } }
    func set(_ newValue: CaptureIntent) { lock.withLock { intent = newValue } }

    var running: Bool {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }

    var launchedInBackground: Bool {
        get { lock.withLock { _launchedInBackground } }
        set { lock.withLock { _launchedInBackground = newValue } }
    }
}

/// One-shot permission flag for the watch enable prompt.
final class ArmedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    var isArmed: Bool { lock.withLock { armed } }
    func arm() { lock.withLock { armed = true } }
    func disarm() { lock.withLock { armed = false } }

    func consume() -> Bool {
        lock.withLock {
            let was = armed
            armed = false
            return was
        }
    }
}
