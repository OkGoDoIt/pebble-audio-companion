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

    /// LOAD-BEARING forward. Without it this decorator would silently inherit the protocol's
    /// no-op default, the store would never be flushed before a CHECKPOINT, and we would be
    /// telling the watch to free audio that is only in the page cache.
    func flush() async throws {
        try await downstream.flush()
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
    /// Keeps the process out of iOS's suspended state while capture is on — see
    /// `BackgroundResidency`. Optional so the host tests and command-line tools build without an
    /// audio stack.
    private let residency: BackgroundResidency?

    private var sessionTask: Task<Void, Never>?
    /// Watches the session state so residency tracks the watch's stream.
    private var residencyFollower: Task<Void, Never>?
    /// Invalidates a pending residency release when the stream comes back first.
    private var residencyGeneration: UInt64 = 0

    /// How long residency is kept after the stream stops. Tearing the audio session down and
    /// rebuilding it is not free, and a stream that pauses for two seconds — a reconnect, a
    /// segment rotation — would otherwise thrash it. Short enough that an idle night spends
    /// nothing.
    private static let residencyGraceMs: Int64 = 20_000

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
        residency: BackgroundResidency? = nil,
        onStoreEvent: @escaping @Sendable () -> Void = {},
        onCoverageTrigger: @escaping @Sendable (CoverageSnapshotTrigger) async -> Void = { _ in },
        log: RuntimeLog = .silent,
        sessionLog: ReceiverLog = .silent
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
        self.residency = residency

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
            consumeEnableRequestPermission: { armed.consume() },
            log: sessionLog
        )
    }

    // --- published state ---------------------------------------------------------------------

    public nonisolated var state: StateSubject<ReceiverSessionState> { session.state }
    public nonisolated var watchServiceState: StateSubject<Int?> { session.watchServiceState }
    /// What still backs the `.streaming` latch. Read by the status layer so "Recording" is a
    /// weighed claim rather than a flag nobody rechecks — see `Receiver.StreamEvidence`.
    public nonisolated var streamEvidence: StateSubject<StreamEvidence> { session.streamEvidence }
    public nonisolated var watchInfo: StateSubject<InfoSnapshot?> { session.watchInfo }
    /// Frames the watch sent that this app had no stream to put them in. Non-zero means the two
    /// sides disagreed about whether a stream existed, and that audio was lost on this side.
    public nonisolated var orphanedFrameCount: StateSubject<Int> { session.orphanedFrameCount }
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
    ///
    /// Dials the link too. The session only OBSERVES `link.connectionState`; it never dials. So
    /// before this, the ONLY things that ever brought the radio up were explicit user gestures
    /// (Start, Reconnect, onboarding) — meaning an app relaunched by iOS with capture intent
    /// already `.active` sat there observing a link nobody had asked to connect, indefinitely,
    /// while the status card said recording. `connect()` is idempotent, returns immediately when a
    /// link is up or in progress, and cannot prompt the watch: only `armWatchEnableRequest()` can
    /// do that (plan 4.2).
    public func start() {
        // BEFORE dialling. Residency is what stops iOS suspending us between Core Bluetooth
        // wakes, and a suspended app cannot answer the watch's 15 s liveness watchdog — the watch
        // then stops its microphone. Taking it first means the very first reconnect of a launch is
        // already protected.
        syncResidency()
        startResidencyFollower()
        link.connect()
        guard sessionTask == nil else { return }
        intentBox.running = true
        sessionTask = session.start()
    }

    /// Brings the radio up without starting the session.
    ///
    /// Split out of `start()` for launch ordering: the GATT dance (connect, discover services and
    /// characteristics, subscribe, authorize) is seconds of round trips that depend on nothing on
    /// disk, while the session cannot start until `SegmentStore.recover()` has run. Dialling first
    /// overlaps the two. `connect()` is idempotent and never prompts the watch, so the later
    /// `start()` finds the link already up or in progress and leaves it alone.
    public nonisolated func dialLink() {
        // Deliberately does NOT take residency: dialling is radio work, and nothing is streaming
        // yet. `syncResidency` takes it when the watch actually starts sending.
        link.connect()
    }

    /// Residency follows THE WATCH'S STREAM, not the user's intent.
    ///
    /// The first version keyed this off `intent == .active`, and a night of real logs showed what
    /// that costs: 152 consecutive minutes holding an audio session, keeping the process awake and
    /// the audio hardware powered, while `audio=never` — the watch was paused (its own power-save
    /// mute, a low battery, a policy pause) and had nothing to send. The phone stayed up all night
    /// for a watch that was asleep. That is most of the battery complaint.
    ///
    /// Streaming is the right trigger because it is exactly the condition the residency exists to
    /// serve. The watch's 15 s receiver-liveness watchdog runs ONLY in its Streaming state
    /// (`prv_check_receiver_liveness_locked` returns early otherwise), so when the watch is not
    /// streaming there is no deadline to meet and being suspended costs nothing. And getting back
    /// is free: every way the watch resumes — STREAM_START, a STATE_CHANGED push, a silence probe —
    /// is a BLE notification, and a notification is precisely what wakes a suspended
    /// `bluetooth-central` app. We take residency inside that wake, before the watch's watchdog
    /// window has meaningfully elapsed.
    private func syncResidency() {
        let wanted = intentBox.value == .active && session.state.value.isStreaming
        if wanted {
            residencyGeneration &+= 1
            residency?.setWanted(true)
        } else {
            scheduleResidencyRelease()
        }
    }

    /// Lets go a little after the stream stops, not the instant it does.
    ///
    /// Tearing the audio session down and rebuilding it is not free, and a stream that stops for
    /// two seconds — a reconnect, a segment rotation, a brief drop — would otherwise thrash it.
    /// The grace window is short enough that an idle night still spends nothing.
    private func scheduleResidencyRelease() {
        guard residency != nil else { return }
        residencyGeneration &+= 1
        let generation = residencyGeneration
        // On the INJECTED clock, like every other delay in the receiver: tests drive it on
        // virtual time instead of waiting twenty real seconds.
        let clock = self.clock
        Task { [weak self] in
            try? await clock.sleep(ms: Self.residencyGraceMs)
            guard let self else { return }
            await self.releaseResidencyIfStillIdle(generation)
        }
    }

    private func releaseResidencyIfStillIdle(_ generation: UInt64) {
        guard generation == residencyGeneration else { return }
        guard !(intentBox.value == .active && session.state.value.isStreaming) else { return }
        residency?.setWanted(false)
    }

    /// Follows the session's own state so residency tracks the stream without every caller having
    /// to remember to ask.
    private func startResidencyFollower() {
        guard residencyFollower == nil, residency != nil else { return }
        let states = session.state.stream()
        residencyFollower = Task { [weak self] in
            for await _ in states {
                guard let self else { return }
                await self.syncResidencyFromFollower()
            }
        }
    }

    private func syncResidencyFromFollower() {
        syncResidency()
    }

    /// What residency the process actually holds, for Diagnostics. `.failed` here is the difference
    /// between "recording in the background" and "recording only while you are looking at it".
    public nonisolated var residencyState: StateSubject<BackgroundResidency.State>? {
        residency?.state
    }

    /// Re-asserts the audio session after segment playback reconfigured it. Called on foreground
    /// entry, where any playback has ended.
    public nonisolated func reassertResidencyAfterPlayback() {
        residency?.reassertAfterForeignSessionUse()
    }

    /// Tears the session down without touching the user's intent or the watch's pause state.
    public func stop() {
        residencyFollower?.cancel()
        residencyFollower = nil
        residency?.setWanted(false)
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

    /// Asks the watch what it is doing, now, and refreshes the stream evidence with the answer.
    ///
    /// The session re-verifies on its own cadence during data silence; this is the prompt for the
    /// one moment that cadence cannot cover — the app returning from a long suspension, where the
    /// screen is about to be looked at and everything the phone knows is hours old.
    @discardableResult
    public func verifyWatchState() async -> Bool {
        await session.verifyWatchState()
    }

    /// "Someone is about to look at this": if the watch says it is recording while this app holds
    /// no stream, rebuild the link NOW instead of waiting for the session's own watchdog.
    ///
    /// The session already catches this on its own within about a minute, and that is the part
    /// that has to work while nobody is watching. This is the other half: the user's instinctive
    /// gesture for the failure is to leave the app and come back, and until now that only helped
    /// by coincidence — foreground entry re-read the watch's state and then did nothing with the
    /// answer. Now the gesture is the fix.
    ///
    /// Costs nothing in the healthy cases: an open stream is `.streaming`, and a watch that is
    /// idle, paused or off does not report `streaming`.
    @discardableResult
    public nonisolated func recoverIfWatchIsRecordingWithoutUs() -> Bool {
        guard case .authorized = state.value, streamEvidence.value.watchReportedStreaming else {
            return false
        }
        log.write("watch reports recording while we hold no stream; forcing a fresh session")
        link.resync()
        return true
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
        // Unconditional, and before the early return: the one way this can be wrong is silently —
        // the app looks fine in the foreground and stops recording the moment it is backgrounded.
        syncResidency()
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

    /// The same flag, settable synchronously from `didFinishLaunchingWithOptions`.
    ///
    /// "BEFORE the receiver starts" is an ordering claim, and hopping onto this actor cannot make
    /// it. `.didFinishLaunching` is enqueued from the composition root (the SwiftUI `App.init`,
    /// which runs first) and `.restorationRelaunch` from the app delegate, so the async events
    /// arrive in exactly the wrong order — the receiver would start in foreground mode, loading a
    /// transcription model for a UI nobody is looking at, on the tightest memory budget iOS ever
    /// gives us. The flag is a plain lock-protected box, so setting it synchronously in the
    /// delegate lands before `CompanionRuntime.start()` reads it, whatever the task ordering.
    public nonisolated func markLaunchedInBackground() {
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
