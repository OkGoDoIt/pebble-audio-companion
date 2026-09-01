import Foundation
import WireProtocol
import SegmentStore

// Port of `core/transport/.../AudioReceiverSession.kt` (740 lines — the contract), with the one
// documented modification from the implementation plan Part 6.1: user capture intent is the
// tri-state `CaptureIntent` (active | paused | off) instead of a boolean `desiredEnabled`, which
// changes exactly two lines — `reconcileWatchState`'s `wantPaused` and the STATE_CHANGED
// auto-resume safety net. Everything else ports line-for-line; the ORDER of operations in the
// STREAM_DATA path is load-bearing.

/// The user's capture intent (plan Part 6.1). "Background audio" (Settings) toggles
/// active <-> off; Pause/Resume toggles active <-> paused.
public enum CaptureIntent: Sendable, Equatable {
    case active
    case paused
    case off
}

/// Receiver/session state exposed to the UI layer.
public enum ReceiverSessionState: Sendable, Equatable {
    case disconnected
    case connecting

    /// A connection attempt failed. `kind` is classified from platform error codes so the UI can
    /// speak plainly; `detail` is the raw platform message for logs/support only, never the
    /// primary status text.
    case connectionFailed(kind: ConnectFailureKind, detail: String?)

    /// Link ready; reading Info and sending AUTH_REQUEST.
    case authorizing

    /// Watch returned pending-user-consent; waiting for the user to accept on the watch.
    case pendingConsent

    /// Watch has Background Audio off; waiting for the user to allow enabling it on-watch.
    case pendingEnable

    case denied(statusRaw: Int)

    /// Authorized on this connection, no stream currently open.
    case authorized

    case streaming(streamId: UInt32)

    case revoked(reasonRaw: Int)

    /// The decoded denial status, when this is `.denied` with a known raw value.
    public var deniedStatus: AuthStatus? {
        if case .denied(let raw) = self, raw >= 0, raw <= Int(UInt8.max) {
            return AuthStatus(rawValue: UInt8(raw))
        }
        return nil
    }
}

/// Static configuration for a receiver install.
public struct ReceiverConfig: Sendable {
    /// 32 random bytes generated once per app install (spec Section 6).
    public let receiverId: [UInt8]
    public let receiverName: String
    public let protoVersion: Int
    /// Send a checkpoint once this much appended audio has accumulated.
    public let checkpointAudioMs: Int64
    /// ... or once this much wall time has passed since the last send (and new data exists).
    public let checkpointMinIntervalMs: Int64
    /// While authorized but not actively receiving, ping the watch this often (RECEIVER_HEALTH)
    /// to keep its liveness watchdog armed and to revive a watch that already presumed us gone.
    /// Also doubles as a stale-link probe: repeated unanswered pings force a full reconnect.
    public let keepaliveIntervalMs: Int64
    /// Force a link resync after this many consecutive unanswered keepalive pings.
    public let keepaliveMaxFailures: Int
    /// How often to re-ask the watch what it is doing while a stream we believe is open has sent
    /// no audio. See `AudioReceiverSession.runStreamVerify`.
    public let streamVerifyIntervalMs: Int64

    public init(
        receiverId: [UInt8],
        receiverName: String,
        protoVersion: Int = ProtocolConstants.protocolVersion,
        checkpointAudioMs: Int64 = 2_000,
        checkpointMinIntervalMs: Int64 = 500,
        keepaliveIntervalMs: Int64 = 5_000,
        keepaliveMaxFailures: Int = 2,
        streamVerifyIntervalMs: Int64 = 20_000
    ) {
        precondition(
            receiverId.count == ProtocolConstants.receiverIdBytes,
            "receiverId must be \(ProtocolConstants.receiverIdBytes) bytes, got \(receiverId.count)"
        )
        self.receiverId = receiverId
        self.receiverName = receiverName
        self.protoVersion = protoVersion
        self.checkpointAudioMs = checkpointAudioMs
        self.checkpointMinIntervalMs = checkpointMinIntervalMs
        self.keepaliveIntervalMs = keepaliveIntervalMs
        self.keepaliveMaxFailures = keepaliveMaxFailures
        self.streamVerifyIntervalMs = streamVerifyIntervalMs
    }
}

/// One receiver session per BLE connection (implementation plan Section 6.2).
///
/// On link Ready: read Info, send AUTH_REQUEST; on AUTH_RESULT(ok) consume data notifications,
/// appending frames durably via `SegmentSink` before any bookkeeping, synthesizing gap records
/// on sequence discontinuities, and checkpointing the highest *contiguous* persisted sequence.
/// On disconnect: close the open segment as interrupted and persist resume state.
///
/// Platform-free: no BLE imports; time is injected via `ReceiverClock` so tests run on virtual
/// time.
public actor AudioReceiverSession {
    private let link: AudioGattLink
    private let sink: SegmentSink
    private let policy: ReceiverPolicy
    private let resumeStore: ReceiverResumeStore
    private let config: ReceiverConfig
    private let clock: ReceiverClock

    /// The user's current capture intent. Drives the declarative reconcile after every
    /// (re)authorization, so restart is reliable regardless of what state the watch happened to
    /// be in (defaults to "wants audio" for bare tests).
    private let captureIntent: @Sendable () -> CaptureIntent

    /// One-shot permission for asking the watch to enable Background Audio. Lifecycle reconnects
    /// may still want recording, but they must not surprise the user with a watch prompt.
    private let consumeEnableRequestPermission: @Sendable () -> Bool

    // --- published state (StateFlow ports; thread-safe, sync-readable, streamable) -------------
    nonisolated public let state = StateSubject<ReceiverSessionState>(.disconnected)
    nonisolated public let watchInfo = StateSubject<InfoSnapshot?>(nil)
    nonisolated public let watchServiceState = StateSubject<Int?>(nil)
    nonisolated public let lastProtocolError = StateSubject<ErrorMessage?>(nil)
    nonisolated public let grantedProtoVersion = StateSubject<Int?>(nil)

    /// What actually backs the `.streaming` latch right now (see `StreamEvidence`). Published
    /// alongside `state` so the status layer can weigh the claim instead of repeating it.
    nonisolated public let streamEvidence = StateSubject<StreamEvidence>(.none)

    public init(
        link: AudioGattLink,
        sink: SegmentSink,
        policy: ReceiverPolicy,
        resumeStore: ReceiverResumeStore,
        config: ReceiverConfig,
        clock: ReceiverClock,
        captureIntent: @escaping @Sendable () -> CaptureIntent = { .active },
        consumeEnableRequestPermission: (@Sendable () -> Bool)? = nil
    ) {
        self.link = link
        self.sink = sink
        self.policy = policy
        self.resumeStore = resumeStore
        self.config = config
        self.clock = clock
        self.captureIntent = captureIntent
        self.consumeEnableRequestPermission =
            consumeEnableRequestPermission ?? { captureIntent() != .off }
    }

    // --- one-in-flight control request bookkeeping ---------------------------------------------
    private var tokenCounter = 0
    private var inFlightToken: Int?
    private var ackWaiter: OneShot<Bool>?

    /// When the current in-flight token was taken, so an unanswered request cannot hold the only
    /// slot forever.
    private var inFlightSinceMs: Int64 = 0

    /// LOAD-BEARING (this is the four-hour-blackout bug). CHECKPOINT is fire-and-forget: it takes
    /// the single in-flight slot and only the watch's ACK gives it back. `sendControlAwaitAck`
    /// releases its own slot on timeout, but nothing released the checkpoint's — so one dropped
    /// ACK notification wedged `takeToken()` at nil for the rest of the connection and the app
    /// never sent the watch another control message.
    ///
    /// That is fatal rather than merely lossy, because the watch's 15 s liveness watchdog
    /// (`prv_check_receiver_liveness_locked`) is re-armed ONLY by inbound control traffic, and
    /// during active streaming CHECKPOINT is the only control message we send. A wedged slot
    /// therefore stops capture on the watch 15 s later, and the watch then goes silent — which
    /// removes the Core Bluetooth events that are the only thing able to wake a suspended app.
    ///
    /// Generous on purpose: longer than `requestAckWaitMs` (2 s), so it never races a watch that
    /// is merely slow. Checkpoints carry a monotonically advancing watermark, so a duplicate or
    /// late one is harmless.
    private static let inFlightTokenReclaimMs: Int64 = 3_000

    private func takeToken() -> Int? {
        if inFlightToken != nil {
            // Only ever reclaim POST-authorization traffic. Before that the slot legitimately
            // sits in flight for a long time: `pendingUserConsent` holds it while a human answers
            // the watch's prompt, and stealing it there would orphan the AUTH_RESULT.
            guard authorized, clock.nowMs - inFlightSinceMs >= Self.inFlightTokenReclaimMs else {
                return nil
            }
            inFlightToken = nil
            ackWaiter?.complete(false)
            ackWaiter = nil
        }
        tokenCounter = (tokenCounter + 1) & 0xFF
        inFlightToken = tokenCounter
        inFlightSinceMs = clock.nowMs
        return tokenCounter
    }

    /// Wall time of the last control message we successfully handed to the link.
    ///
    /// The watch re-arms its liveness watchdog from OUR traffic, so this — not `lastInboundMs` —
    /// is what the keepalive has to watch. See `runKeepalive`.
    private var lastOutboundControlMs: Int64 = 0

    private func noteOutboundControl() {
        lastOutboundControlMs = clock.nowMs
    }

    /// Asks the watch to pause capture (maps to the watch's PausedPolicy state, visible in its
    /// Settings). Returns true when the watch acknowledged — callers use this result to journal
    /// pause intervals (the KMP source has no ack callbacks; the async result is the seam).
    /// Safe to call from any scope; waits briefly for an in-flight checkpoint to clear.
    public func requestPause(reasonRaw: UInt8 = PauseReason.user.rawValue) async -> Bool {
        await sendControlAwaitAck { token in
            PauseRequest(requestToken: token, reasonRaw: reasonRaw).encode()
        }
    }

    /// Asks the watch to resume capture after `requestPause`. True when acknowledged.
    public func requestResume() async -> Bool {
        await sendControlAwaitAck { token in
            ResumeRequest(requestToken: token).encode()
        }
    }

    private func sendControlAwaitAck(
        requireAuthorized: Bool = true,
        ackWaitMs: Int64 = AudioReceiverSession.requestAckWaitMs,
        build: @escaping @Sendable (Int) -> [UInt8]
    ) async -> Bool {
        if requireAuthorized && !authorized { return false }
        // Token wait: poll every 50 ms up to the deadline (withTimeoutOrNull { poll } in KMP).
        // Inline (not raced in a task group) so a token can never be taken-and-lost on the
        // timeout boundary.
        let deadline = clock.nowMs + Self.requestTokenWaitMs
        var taken = takeToken()
        while taken == nil {
            if clock.nowMs >= deadline { return false }
            do {
                try await clock.sleep(ms: 50)
            } catch {
                return false
            }
            taken = takeToken()
        }
        guard let token = taken else { return false }

        let waiter = OneShot<Bool>()
        ackWaiter = waiter
        var acked = false
        do {
            try await link.writeControl(build(token))
            noteOutboundControl()
            acked = await withReceiverTimeout(clock: clock, ms: ackWaitMs) {
                await waiter.value()
            } ?? false
        } catch {
            acked = false
        }
        if ackWaiter === waiter { ackWaiter = nil }
        // Free the slot on timeout/failure so checkpoints are not blocked forever.
        if !waiter.isCompleted && inFlightToken == token { inFlightToken = nil }
        return acked
    }

    // --- per-connection state ------------------------------------------------------------------
    private var authorized = false
    private var stream: StreamContext?

    /// Wall time of the last inbound control/data notification; drives the keepalive idle check.
    private var lastInboundMs: Int64 = 0

    private func noteInbound() {
        lastInboundMs = clock.nowMs
    }

    // --- evidence for the `.streaming` latch ----------------------------------------------------

    /// Records that audio for the open stream just arrived. The ONLY refresher of the audio half
    /// of the evidence: control traffic (an ACK, an ERROR) proves the watch is talking to us, not
    /// that it is capturing, and conflating the two is what made a starved link read as Recording.
    private func noteAudioArrived() {
        var evidence = streamEvidence.value
        evidence.lastAudioAtMs = clock.nowMs
        streamEvidence.value = evidence
    }

    /// Records the watch's own account of its service state, and stamps it. Both halves go
    /// through here — the Info read and the STATE_CHANGED push — so `watchServiceState` and its
    /// timestamp can never drift apart.
    private func noteWatchReport(_ serviceStateRaw: Int) {
        watchServiceState.value = serviceStateRaw
        var evidence = streamEvidence.value
        evidence.lastWatchReportAtMs = clock.nowMs
        evidence.lastWatchReportRaw = serviceStateRaw
        streamEvidence.value = evidence
    }

    /// Asks the watch what it thinks it is doing, right now.
    ///
    /// This is the whole mechanism: an Info read is the one thing that separates suppressed
    /// silence (the watch answers `streaming`) from a stream that died (it answers `authorizedIdle`,
    /// or does not answer at all). Bounded by a timeout, because a stale link the platform still
    /// reports as connected can leave a GATT read outstanding forever, and a verify that never
    /// returns is a verify that never happened.
    ///
    /// Returns true when the watch answered.
    @discardableResult
    public func verifyWatchState() async -> Bool {
        let bytes = await withReceiverTimeout(clock: clock, ms: Self.verifyReadTimeoutMs) {
            try? await self.link.readInfo()
        }
        guard let bytes, case .decoded(let message) = AudioCompanionProtocol.decodeInfo(bytes),
            let snapshot = message as? InfoSnapshot
        else { return false }
        watchInfo.value = snapshot
        noteWatchReport(Int(snapshot.serviceStateRaw))
        return true
    }

    /// Per-connection re-verify. While we believe a stream is open but no audio has arrived for
    /// `verifyAfterSilenceMs`, ask the watch directly, and keep asking on a cadence for as long as
    /// the silence lasts.
    ///
    /// It cannot misfire on ordinary quiet: every answer of `streaming` re-stamps the evidence, so
    /// a room that stays silent for an hour keeps the card on "Recording" the whole time — with
    /// evidence refreshed every cycle rather than with a latch nobody checked. It fires only when
    /// the watch says otherwise, or stops answering.
    ///
    /// AND WHEN IT STOPS ANSWERING, THIS ACTS. A watch that answers nothing on a link the
    /// platform still calls connected is a stale link, and the only cure is a fresh one. The
    /// keepalive's `resync` cannot cover this case: its idle test is on OUTBOUND control, and
    /// while we believe a stream is open we keep checkpointing (the spool stall-breaker sends
    /// one every 2 s of silence), so `lastOutboundControlMs` never goes stale and the ping that
    /// would have noticed is never sent. That is the shape of a long blackout — the phone
    /// talking steadily to a watch that has not said a word for eleven minutes, with the status
    /// card the only thing that knew, and nothing anywhere trying to fix it.
    private func runStreamVerify() async {
        var unanswered = 0
        while true {
            do {
                try await clock.sleep(ms: config.streamVerifyIntervalMs)
            } catch {
                return // cancelled with the connection
            }
            if Task.isCancelled { return }
            guard authorized, stream != nil else {
                unanswered = 0
                continue
            }
            let lastAudio = streamEvidence.value.lastAudioAtMs ?? 0
            guard clock.nowMs - lastAudio >= Self.verifyAfterSilenceMs else {
                // Audio is arriving; the link is manifestly fine.
                unanswered = 0
                continue
            }
            let lastReport = streamEvidence.value.lastWatchReportAtMs ?? 0
            guard clock.nowMs - lastReport >= config.streamVerifyIntervalMs else { continue }
            if await verifyWatchState() {
                unanswered = 0
                continue
            }
            unanswered += 1
            guard unanswered >= Self.verifyMaxFailures else { continue }
            // Same escalation the keepalive uses, for the same reason and with the same
            // consequences: drop this connection and build a fresh one, keeping the intent to
            // stay connected. The watch re-delivers from its spool, so nothing it captured
            // meanwhile is lost to the reconnect itself.
            link.resync()
            return
        }
    }

    // Per-connection child tasks (the Kotlin connection coroutineScope's children).
    private var controlTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var dataTask: Task<Void, Never>?
    private var verifyTask: Task<Void, Never>?
    private var auxTasks: [Task<Void, Never>] = []

    /// Sends a RECEIVER_HEALTH ping and waits for the watch's ACK. Used as an idle keepalive: the
    /// watch treats any control message as proof the receiver is alive, which re-arms its liveness
    /// watchdog and revives a session it had already presumed gone. Returns true on ACK.
    private func sendReceiverHealth() async -> Bool {
        await sendControlAwaitAck { token in
            ReceiverHealth(
                requestToken: token,
                batteryPct: 0,
                appStateRaw: 0,
                queueDepthFrames: 0
            ).encode()
        }
    }

    /// Per-connection keepalive. While authorized but not sending the watch anything, ping
    /// RECEIVER_HEALTH every interval. This:
    ///  - re-arms the watch's 15 s liveness watchdog so it does not stop capturing, and
    ///  - revives a watch that already presumed us gone — its control handler re-evaluates on the
    ///    next message and resumes streaming, re-announcing STREAM_START to us.
    /// If the watch stops answering entirely the link is stale even though the platform still
    /// reports it connected, so force a fresh GATT connection via `AudioGattLink.resync`.
    ///
    /// TRAP: the idle test is on OUTBOUND traffic, not inbound. The watch's watchdog is re-armed
    /// only by control messages IT receives, so "we are hearing audio" is no evidence at all that
    /// the watch still believes in us. Keying this off `lastInboundMs` meant a steady STREAM_DATA
    /// flow suppressed the ping for as long as it lasted — so when checkpointing wedged, the app
    /// went completely silent toward the watch while still being fed, the watch stopped capturing
    /// 15 s later, and the safety net that exists for exactly this never fired. Healthy streaming
    /// checkpoints every ≤2 s of audio, which keeps `lastOutboundControlMs` fresh, so this stays
    /// just as quiet as before in the normal case.
    private func runKeepalive() async {
        var failures = 0
        while true {
            do {
                try await clock.sleep(ms: config.keepaliveIntervalMs)
            } catch {
                return // cancelled with the connection
            }
            if Task.isCancelled { return }
            if !authorized {
                failures = 0
                continue
            }
            if clock.nowMs - lastOutboundControlMs < config.keepaliveIntervalMs {
                failures = 0 // we are still talking to the watch; no ping needed
                continue
            }
            if await sendReceiverHealth() {
                failures = 0
            } else {
                failures += 1
                if failures >= config.keepaliveMaxFailures {
                    link.resync()
                    return
                }
            }
        }
    }

    /// Per-connection checkpoint tick: flushes a due CHECKPOINT on a CLOCK, not only when data
    /// happens to arrive.
    ///
    /// `audio_companion_spool_trim_through(highest_contiguous_sequence_persisted)` is the only
    /// thing that frees the watch's spool, so the checkpoint is the watch's flow-control credit.
    /// Sending it only from `handleStreamData`/`handleStreamGap` made that credit self-starving:
    /// once the spool filled, the watch had nothing it was allowed to send, so no data arrived, so
    /// the phone never checkpointed, so the spool stayed full and dropped what the mic captured
    /// next. The real device shows exactly that cycle — a run of overflow gaps spaced 103 frames
    /// (2.06 s of audio) apart, each one a frame or two larger than the last, ratcheting up until
    /// the segment rotated.
    ///
    /// Deliberately a STALL-BREAKER rather than a second cadence: while data is flowing, the
    /// data-driven path already checkpoints at the configured rate and this sends nothing. It only
    /// steps in once a streaming watch has been quiet for `checkpointStallMs`, which is the state
    /// that used to be unrecoverable. `maybeSendCheckpoint` is idempotent
    /// (`checkpointedSinceLastChange`), so a stall with nothing new persisted stays silent too.
    private func runCheckpointTicker() async {
        while true {
            do {
                try await clock.sleep(ms: config.checkpointMinIntervalMs)
            } catch {
                return // cancelled with the connection
            }
            if Task.isCancelled { return }
            guard authorized, let ctx = stream else { continue }
            guard clock.nowMs - lastInboundMs >= Self.checkpointStallMs else { continue }
            await maybeSendCheckpoint(ctx)
        }
    }

    /// Sequence/contiguity tracker for the open stream.
    ///
    /// `contiguousNext` is the lowest sequence not yet accounted for; everything below it is
    /// either durably persisted or covered by a watch-reported gap (known-lost). Frames persisted
    /// beyond an unaccounted hole sit in `pendingRanges` and do not advance the checkpoint:
    /// CHECKPOINT carries the highest *contiguous* persisted sequence, not the highest seen.
    private final class StreamContext {
        let start: StreamStart
        var streamId: UInt32 { start.streamId }
        let frameSamples: UInt64
        let sampleRateHz: UInt64

        var contiguousNext: UInt32 = 0
        var contiguousSampleIndex: UInt64 = 0
        var pendingRanges: [PersistedRange] = []
        var pendingWatchGaps: [KnownGapRange] = []

        /// False until the first STREAM_DATA/STREAM_GAP fixes the contiguity base. A fresh stream
        /// is known to begin at sequence 0; a RESUME re-announcement (sent by the watch when it
        /// re-attaches a receiver mid-stream after a reconnect) continues at the watch's current
        /// sequence, so we adopt the first message's sequence as the base instead of assuming 0 —
        /// otherwise we would synthesize a bogus multi-thousand-frame leading gap and never
        /// checkpoint, stranding the resumed buffered audio.
        var baseInitialized: Bool

        /// First missing sequence of a watch-reported gap whose extent is still unknown.
        var openWatchGapFrom: UInt32?

        var samplesSinceCheckpoint: UInt64 = 0
        var lastCheckpointAtMs: Int64
        var checkpointedSinceLastChange = true

        init(start: StreamStart, nowMs: Int64) {
            self.start = start
            frameSamples = UInt64(start.frameSamples)
            sampleRateHz = UInt64(start.sampleRateHz)
            baseInitialized = (start.flags & ProtocolConstants.streamStartFlagResume) == 0
            lastCheckpointAtMs = nowMs
        }

        struct PersistedRange {
            let first: UInt32
            let endExclusive: UInt32
            let endSampleIndex: UInt64
        }

        struct KnownGapRange {
            let first: UInt32
            let endExclusive: UInt32
        }

        func ensureBase(firstSequence: UInt32, firstSampleIndex: UInt64) {
            if baseInitialized { return }
            contiguousNext = firstSequence
            contiguousSampleIndex = firstSampleIndex
            baseInitialized = true
        }

        func rememberKnownGap(first: UInt32, missingCount: UInt32) {
            if missingCount == 0 { return }
            let endExclusive = first &+ missingCount
            if endExclusive <= contiguousNext { return }
            pendingWatchGaps.append(KnownGapRange(first: first, endExclusive: endExclusive))
        }

        func advanceAccountedPrefix() -> UInt64 {
            var advancedGapSamples: UInt64 = 0
            while true {
                if let gapIndex = pendingWatchGaps.firstIndex(where: {
                    $0.first <= contiguousNext && $0.endExclusive > contiguousNext
                }) {
                    let nextGap = pendingWatchGaps[gapIndex]
                    let missingFrames = nextGap.endExclusive &- contiguousNext
                    advancedGapSamples &+= UInt64(missingFrames) &* frameSamples
                    contiguousSampleIndex &+= UInt64(missingFrames) &* frameSamples
                    contiguousNext = nextGap.endExclusive
                    pendingWatchGaps.remove(at: gapIndex)
                    continue
                }

                guard let rangeIndex = pendingRanges.firstIndex(where: { $0.first == contiguousNext })
                else {
                    return advancedGapSamples
                }
                let nextRange = pendingRanges[rangeIndex]
                contiguousNext = nextRange.endExclusive
                contiguousSampleIndex = nextRange.endSampleIndex
                pendingRanges.remove(at: rangeIndex)
            }
        }
    }

    /// Starts the session loop in a new task (KMP `start(scope)`); cancel the task to stop.
    @discardableResult
    nonisolated public func start() -> Task<Void, Never> {
        Task { await self.run() }
    }

    /// Consumes link state with collectLatest semantics: each change cancels (and awaits) the
    /// previous state's handler before running the new one. Teardown ALWAYS runs `onLinkDown`
    /// non-cancellably and forces Disconnected.
    public func run() async {
        let states = link.connectionState.stream()
        var handler: Task<Void, Never>?
        for await linkState in states {
            handler?.cancel()
            await handler?.value
            if Task.isCancelled { break }
            handler = Task { await self.handleLinkState(linkState) }
        }
        handler?.cancel()
        await handler?.value
        // Session torn down (runtime stop / revoke / task cancelled): the published state must
        // not keep claiming the last live state. onLinkDown runs regardless of cancellation.
        await onLinkDown()
        state.value = .disconnected
        watchServiceState.value = nil
    }

    private func handleLinkState(_ linkState: LinkState) async {
        switch linkState {
        case .disconnected:
            await onLinkDown()
            if let failure = link.lastFailure.value {
                state.value = .connectionFailed(kind: failure.kind, detail: failure.detail)
            } else {
                state.value = .disconnected
            }
            watchServiceState.value = nil
        case .connecting:
            await onLinkDown()
            state.value = .connecting
        case .ready:
            await runConnection()
        }
    }

    /// Set by a child of the connection when a fatal error must fail the whole connection (the
    /// Kotlin structured-concurrency equivalent: a failed child fails the connection scope).
    private var connectionAbort: OneShot<Bool>?

    private func runConnection() async {
        let abort = OneShot<Bool>()
        connectionAbort = abort
        do {
            try await connectionHandshake(abort: abort)
            // Mirror Kotlin's coroutineScope: the connection stays alive (children running)
            // until the link state changes (we get cancelled) or a child aborts it.
            _ = await abort.value()
        } catch {
            // Handshake failed (readInfo/AUTH write threw): tear the connection down below.
        }
        // Link dropped (cancel-on-change cancelled us) or the connection failed. Children first
        // (Kotlin's scope joins them), then per-link state — always, even when cancelled.
        await drainConnectionTasks()
        connectionAbort = nil
        await onLinkDown()
    }

    private func drainConnectionTasks() async {
        while true {
            var tasks: [Task<Void, Never>] = []
            if let task = controlTask { tasks.append(task); controlTask = nil }
            if let task = keepaliveTask { tasks.append(task); keepaliveTask = nil }
            if let task = checkpointTask { tasks.append(task); checkpointTask = nil }
            if let task = dataTask { tasks.append(task); dataTask = nil }
            if let task = verifyTask { tasks.append(task); verifyTask = nil }
            tasks.append(contentsOf: auxTasks)
            auxTasks = []
            if tasks.isEmpty { return }
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
        }
    }

    private func connectionHandshake(abort: OneShot<Bool>) async throws {
        state.value = .authorizing

        switch AudioCompanionProtocol.decodeInfo(try await link.readInfo()) {
        case .decoded(let message):
            if let snapshot = message as? InfoSnapshot {
                watchInfo.value = snapshot
                noteWatchReport(Int(snapshot.serviceStateRaw))
            }
        default:
            break // diagnostics only; auth decides whether we can proceed
        }

        lastInboundMs = clock.nowMs
        lastOutboundControlMs = clock.nowMs
        let controlStream = link.controlNotifications
        controlTask = Task { await self.consumeControl(controlStream, abort: abort) }
        keepaliveTask = Task { await self.runKeepalive() }
        checkpointTask = Task { await self.runCheckpointTicker() }
        verifyTask = Task { await self.runStreamVerify() }

        if captureIntent() != .off && watchInfo.value?.enabled == false {
            if !consumeEnableRequestPermission() {
                state.value = .denied(statusRaw: Int(AuthStatus.deniedDisabled.rawValue))
                return
            }
            state.value = .pendingEnable
            let enabled = await sendControlAwaitAck(
                requireAuthorized: false,
                ackWaitMs: Self.enableRequestAckWaitMs
            ) { token in
                EnableRequest(requestToken: token).encode()
            }
            if !enabled {
                state.value = .denied(statusRaw: Int(AuthStatus.deniedDisabled.rawValue))
                return
            }
            await refreshInfoSnapshot()
            state.value = .authorizing
        }

        guard let token = takeToken() else {
            assertionFailure("fresh connection must have no in-flight request")
            throw ReceiverSessionError.internalInvariant
        }
        try await link.writeControl(
            AuthRequest(
                protoVersion: config.protoVersion,
                requestToken: token,
                receiverId: config.receiverId,
                name: config.receiverName
            ).encode()
        )
        noteOutboundControl()
    }

    private func consumeControl(_ stream: AsyncStream<[UInt8]>, abort: OneShot<Bool>) async {
        for await bytes in stream {
            noteInbound()
            switch AudioCompanionProtocol.decodeControlOut(bytes) {
            case .decoded(let message):
                if let control = message as? ControlOutMessage {
                    do {
                        try await handleControl(control, abort: abort)
                    } catch {
                        abort.complete(true) // sink failure fails the connection (Kotlin scope)
                        return
                    }
                }
            default:
                break // unknown ids ignored per spec; malformed logged at most
            }
        }
    }

    private func handleControl(_ message: ControlOutMessage, abort: OneShot<Bool>) async throws {
        switch message {
        case let result as AuthResult:
            guard result.requestToken == inFlightToken else { return }
            switch result.status {
            case .some(.ok):
                inFlightToken = nil
                authorized = true
                grantedProtoVersion.value = result.grantedProtoVersion
                // The watch accepted us, so whatever it last complained about is settled. This
                // matters now that the error is read: a stale ERROR from an earlier connection
                // would otherwise keep explaining a link that is working.
                lastProtocolError.value = nil
                state.value = .authorized
                if dataTask == nil {
                    let dataStream = link.dataNotifications
                    dataTask = Task { await self.consumeData(dataStream, abort: abort) }
                }
                // Declarative reconcile: drive the watch to the user's intent now that we are
                // authorized. This does not depend on the (pre-auth) Info state, so restart
                // works whether the watch stayed paused on a shared link or fell back to Idle
                // after a real disconnect.
                auxTasks.append(Task { await self.reconcileWatchState() })
            case .some(.pendingUserConsent):
                // Token stays in flight: the watch pushes a second AUTH_RESULT with the same
                // token once the consent prompt resolves.
                state.value = .pendingConsent
            default:
                inFlightToken = nil
                authorized = false
                state.value = .denied(statusRaw: Int(result.statusRaw))
            }
        case let ack as Ack:
            if ack.requestToken == inFlightToken {
                inFlightToken = nil
                ackWaiter?.complete(ack.statusRaw == 0)
                ackWaiter = nil
            }
        case let revoked as Revoked:
            try await closeOpenSegment(.interrupted)
            authorized = false
            dataTask?.cancel()
            dataTask = nil
            state.value = .revoked(reasonRaw: Int(revoked.reasonRaw))
        case let changed as StateChanged:
            noteWatchReport(Int(changed.serviceStateRaw))
            // Safety net for a watch that pauses (policy) after we authorized: if the user
            // wants audio and we have no storage reason to hold the pause, resume. Fires only
            // for an ACTIVE intent (plan 6.1) and explicitly NOT for PausedPowerSave.
            if authorized,
               changed.serviceStateRaw == ServiceState.pausedPolicy.rawValue,
               captureIntent() == .active,
               policy.receiverFlags() == 0 {
                auxTasks.append(Task { _ = await self.requestResume() })
            }
        case let error as ErrorMessage:
            lastProtocolError.value = error
        default:
            break
        }
    }

    private func refreshInfoSnapshot() async {
        guard let bytes = try? await link.readInfo() else { return }
        switch AudioCompanionProtocol.decodeInfo(bytes) {
        case .decoded(let message):
            if let snapshot = message as? InfoSnapshot {
                watchInfo.value = snapshot
                noteWatchReport(Int(snapshot.serviceStateRaw))
            }
        default:
            break // Keep the previous diagnostic snapshot; auth will report real failure.
        }
    }

    /// Brings the watch's capture state in line with the local intent after (re)authorization.
    /// Gated on the watch's reported state so the common reconnect (watch already
    /// streaming/idle) sends nothing; we only act when the watch diverges from intent.
    /// RESUME/PAUSE are also idempotent on the watch, so a redundant send is harmless.
    /// Plan 6.1: `wantPaused = (intent != .active) || policyFlags != 0`.
    private func reconcileWatchState() async {
        if !authorized { return }
        let pausedOnWatch = watchServiceState.value == Int(ServiceState.pausedPolicy.rawValue)
        let intent = captureIntent()
        let wantPaused = intent != .active || policy.receiverFlags() != 0
        if wantPaused && !pausedOnWatch {
            // We want it paused but the watch is not holding a policy pause: assert one. A user
            // intent (paused or off) is a User pause; only policy flags produce a Policy pause.
            _ = await requestPause(
                reasonRaw: intent != .active ? PauseReason.user.rawValue : PauseReason.policy.rawValue
            )
        } else if !wantPaused && pausedOnWatch {
            // We want audio and the watch is holding a policy pause: release it.
            _ = await requestResume()
        }
    }

    private func consumeData(_ stream: AsyncStream<[UInt8]>, abort: OneShot<Bool>) async {
        for await bytes in stream {
            noteInbound()
            switch AudioCompanionProtocol.decodeData(bytes) {
            case .decoded(let message):
                if let data = message as? DataMessage {
                    do {
                        try await handleData(data)
                    } catch {
                        abort.complete(true) // sink failure fails the connection (Kotlin scope)
                        return
                    }
                }
            default:
                break // unknown ids ignored per spec
            }
        }
    }

    private func handleData(_ message: DataMessage) async throws {
        if !authorized { return }
        switch message {
        case let start as StreamStart:
            // A RESUME re-announcement of the stream we are already receiving (the watch
            // re-attaching after a transport blip the link layer never surfaced) must not
            // supersede the open segment: the sink continues it in place. Anything else —
            // a fresh stream, or a resume for a different id — supersedes as before.
            let resume = (start.flags & ProtocolConstants.streamStartFlagResume) != 0
            if resume && stream?.streamId == start.streamId {
                stream = nil // replaced below; the segment stays open for continuation
            } else {
                try await closeOpenSegment(.superseded)
            }
            try await sink.openSegment(
                start: start,
                receivedAtMs: clock.nowMs,
                provenance: watchInfo.value.map {
                    SegmentProvenance(
                        fwVersionPacked: $0.fwVersionPacked,
                        protocolVersion: start.protocolVersion
                    )
                }
            )
            stream = StreamContext(start: start, nowMs: clock.nowMs)
            noteAudioArrived()
            state.value = .streaming(streamId: start.streamId)
        case let data as StreamData:
            noteAudioArrived()
            try await handleStreamData(data)
        case let gap as StreamGap:
            noteAudioArrived()
            try await handleStreamGap(gap)
        case let stop as StreamStop:
            guard let ctx = stream else { return }
            if stop.streamId != ctx.streamId { return }
            try await closeOpenSegment(
                .stopped(
                    reasonRaw: Int(stop.reasonRaw),
                    finalSequence: stop.finalSequence,
                    finalSampleIndex: stop.finalSampleIndex
                )
            )
            // A clean stop retires the claim outright — there is no latch left to weigh, and
            // leaving stale audio timestamps behind would vouch for the next stream's first
            // seconds before any of its audio had arrived.
            streamEvidence.value = .none
            state.value = .authorized
        default:
            break
        }
    }

    private func handleStreamData(_ message: StreamData) async throws {
        guard let ctx = stream else { return } // STREAM_DATA before STREAM_START: nothing to attach it to
        if message.streamId != ctx.streamId { return }
        ctx.ensureBase(firstSequence: message.firstSequence, firstSampleIndex: message.firstSampleIndex)

        let first = message.firstSequence
        let count = UInt32(message.frameCount)
        let endExclusive = first &+ count

        let advancedKnownGapSamples = ctx.advanceAccountedPrefix()
        if advancedKnownGapSamples > 0 {
            ctx.samplesSinceCheckpoint &+= advancedKnownGapSamples
            ctx.checkpointedSinceLastChange = false
        }

        if endExclusive <= ctx.contiguousNext {
            await maybeSendCheckpoint(ctx)
            return // stale duplicate, already accounted
        }

        // Durability first: frames hit the frame log before any bookkeeping or checkpointing.
        var frames: [SegmentFrame] = []
        frames.reserveCapacity(message.frameCount)
        for (index, payload) in message.frames.enumerated() {
            frames.append(
                SegmentFrame(
                    sequence: message.sequenceOf(index),
                    sampleIndex: message.sampleIndexOf(index, frameSamples: ctx.start.frameSamples),
                    payload: payload
                )
            )
        }
        // The return value is what the sink ACTUALLY persisted (plan Part 4.2). It is legitimately
        // shorter than `frames` — a post-RESUME spool rewind re-sends frames the sink already
        // holds, and those are durable, so contiguity below still advances over them. What is NOT
        // legitimate is the sink having nowhere to put them at all: `SegmentSink.appendFrames`
        // throws for that, which fails the connection and forces a resync rather than letting the
        // bookkeeping below checkpoint audio nothing stored.
        _ = try await sink.appendFrames(streamId: ctx.streamId, frames: frames)

        if first > ctx.contiguousNext {
            let accountedByWatchGap = ctx.openWatchGapFrom.map { $0 <= ctx.contiguousNext } == true
            if accountedByWatchGap {
                // The watch already reported this hole (unknown extent); now we know where it
                // ends. The lost range is accounted: contiguity resumes at this batch.
                ctx.openWatchGapFrom = nil
                ctx.contiguousNext = first
                ctx.contiguousSampleIndex = message.firstSampleIndex
            } else {
                // Silent discontinuity: synthesize a gap record. Contiguity does NOT advance;
                // checkpoints keep reporting the last sequence before the hole.
                try await sink.recordGap(
                    streamId: ctx.streamId,
                    gap: GapRecord(
                        firstMissingSequence: ctx.contiguousNext,
                        missingFrameCount: first &- ctx.contiguousNext,
                        firstMissingSampleIndex: ctx.contiguousSampleIndex,
                        origin: .sequenceSkip
                    )
                )
            }
        }

        let endSampleIndex = message.firstSampleIndex &+ UInt64(count) &* ctx.frameSamples
        if first <= ctx.contiguousNext {
            ctx.contiguousNext = endExclusive
            ctx.contiguousSampleIndex = endSampleIndex
            let advancedSamples = ctx.advanceAccountedPrefix()
            if advancedSamples > 0 {
                ctx.samplesSinceCheckpoint &+= advancedSamples
                ctx.checkpointedSinceLastChange = false
            }
        } else {
            ctx.pendingRanges.append(
                StreamContext.PersistedRange(
                    first: first,
                    endExclusive: endExclusive,
                    endSampleIndex: endSampleIndex
                )
            )
        }

        ctx.samplesSinceCheckpoint &+= UInt64(count) &* ctx.frameSamples
        ctx.checkpointedSinceLastChange = false
        await maybeSendCheckpoint(ctx)
    }

    private func handleStreamGap(_ message: StreamGap) async throws {
        guard let ctx = stream else { return }
        if message.streamId != ctx.streamId { return }
        ctx.ensureBase(
            firstSequence: message.firstMissingSequence,
            firstSampleIndex: message.firstMissingSampleIndex
        )

        try await sink.recordGap(
            streamId: ctx.streamId,
            gap: GapRecord(
                firstMissingSequence: message.firstMissingSequence,
                missingFrameCount: message.missingFrameCount,
                firstMissingSampleIndex: message.firstMissingSampleIndex,
                origin: .watchReported(
                    reasonRaw: Int(message.reasonRaw),
                    watchDropCounter: message.watchDropCounter
                )
            )
        )

        var advancedSamples: UInt64 = 0
        if message.missingFrameCount == 0 {
            // Unknown extent: account for it when the next STREAM_DATA shows where it ends.
            ctx.openWatchGapFrom = message.firstMissingSequence
        } else {
            ctx.rememberKnownGap(
                first: message.firstMissingSequence,
                missingCount: message.missingFrameCount
            )
            if message.firstMissingSequence <= ctx.contiguousNext {
                // Known-lost range adjoining the contiguous prefix: those frames will never
                // arrive, so contiguity (and the checkpoint) advances past them.
                advancedSamples = ctx.advanceAccountedPrefix()
                if advancedSamples > 0 {
                    ctx.checkpointedSinceLastChange = false
                }
            }
        }
        if advancedSamples > 0 {
            ctx.samplesSinceCheckpoint &+= advancedSamples
            await maybeSendCheckpoint(ctx)
        }
    }

    private func maybeSendCheckpoint(_ ctx: StreamContext) async {
        if ctx.contiguousNext == 0 { return } // nothing contiguous persisted yet
        if ctx.checkpointedSinceLastChange { return }
        let audioMs = ctx.samplesSinceCheckpoint * 1000 / ctx.sampleRateHz
        let due = audioMs >= UInt64(config.checkpointAudioMs) ||
            (clock.nowMs - ctx.lastCheckpointAtMs) >= config.checkpointMinIntervalMs
        if !due { return }
        guard let token = takeToken() else { return } // a request is in flight; retry on the next append
        defer { ctx.lastCheckpointAtMs = clock.nowMs }
        do {
            try await link.writeControl(
                Checkpoint(
                    requestToken: token,
                    streamId: ctx.streamId,
                    highestContiguousSequencePersisted: ctx.contiguousNext &- 1,
                    persistedSampleIndex: ctx.contiguousSampleIndex,
                    receiverFlags: policy.receiverFlags(),
                    freeStorageHintKb: policy.freeStorageHintKb()
                ).encode()
            )
            noteOutboundControl()
            ctx.samplesSinceCheckpoint = 0
            ctx.checkpointedSinceLastChange = true
        } catch {
            // A checkpoint is recovery metadata, not the audio itself. If Core Bluetooth
            // temporarily refuses a write, keep the stream alive and retry on the next cadence.
            if inFlightToken == token { inFlightToken = nil }
        }
    }

    /// Ends the current segment from OUTSIDE the receive path — the destructive flows ("delete
    /// all data") that must not leave a recording behind.
    ///
    /// It exists so nothing has to reach past the session into the store. The segment and the
    /// session's stream context are one thing: closing only the store's half leaves the session
    /// appending into nothing, and `appendFrames` answers an absent segment with an empty array,
    /// so the session would advance contiguity and CHECKPOINT frames it never stored — telling
    /// the watch to free the only surviving copy, with no gap recorded anywhere. Whoever calls
    /// this owns getting the stream back (a resync); until then the session has no context and
    /// STREAM_DATA is ignored rather than half-processed, so the watch keeps its spool.
    public func endOpenSegment(_ reason: SegmentCloseReason = .interrupted) async {
        try? await closeOpenSegment(reason)
    }

    private func closeOpenSegment(_ reason: SegmentCloseReason) async throws {
        guard let ctx = stream else { return }
        stream = nil
        try await sink.closeSegment(reason: reason)
        await resumeStore.save(
            ReceiverResumeState(
                lastStreamId: ctx.streamId,
                lastContiguousSequence: ctx.contiguousNext > 0 ? ctx.contiguousNext &- 1 : nil,
                lastSampleIndex: ctx.contiguousSampleIndex
            )
        )
    }

    /// Connection teardown: close any open segment as interrupted and reset per-link state.
    private func onLinkDown() async {
        try? await closeOpenSegment(.interrupted)
        authorized = false
        dataTask = nil
        inFlightToken = nil
        inFlightSinceMs = 0
        lastOutboundControlMs = 0
        ackWaiter?.complete(false)
        ackWaiter = nil
        grantedProtoVersion.value = nil
        // Everything observed belonged to the connection that just ended. Carrying it across
        // would let a reconnect inherit the old link's proof of life.
        streamEvidence.value = .none
    }

    private enum ReceiverSessionError: Error {
        case internalInvariant
    }

    /// How long pause/resume waits for an in-flight checkpoint to release the token slot.
    private static let requestTokenWaitMs: Int64 = 2_000

    /// How long pause/resume waits for the watch's ACK.
    private static let requestAckWaitMs: Int64 = 2_000

    /// Enable waits on a human watch dialog; match the watch's consent-sized interaction.
    private static let enableRequestAckWaitMs: Int64 = 35_000

    /// How long a streaming watch may go quiet before `runCheckpointTicker` flushes credit
    /// anyway. Comfortably longer than an ordinary pause between batches, and far short of the
    /// watch's 15 s liveness timeout, so the spool is refreshed long before capture is at risk.
    private static let checkpointStallMs: Int64 = 2_000

    /// How long an open stream may send no audio before the session starts asking the watch what
    /// it is actually doing.
    ///
    /// Only a TRIGGER TO ASK, never a verdict: suppressed silence legitimately lasts far longer
    /// than this, and the answer that comes back ("streaming") is what keeps the status honest
    /// through it. Short enough that a stream which really did die is caught within the minute.
    static let verifyAfterSilenceMs: Int64 = 20_000

    /// A verify that never returns is a verify that never happened — a stale link the platform
    /// still calls connected can leave a GATT read outstanding indefinitely.
    static let verifyReadTimeoutMs: Int64 = 5_000

    /// Unanswered verifies before the link is presumed stale and rebuilt. Three, at the 20 s
    /// verify cadence: a minute of a watch saying nothing to a direct question, which no
    /// ordinary quiet, roaming or momentary radio trouble survives.
    static let verifyMaxFailures = 3
}
