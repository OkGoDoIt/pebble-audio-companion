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

    /// True only while the watch is actually sending us a stream.
    ///
    /// This is what background residency keys off, so it is deliberately narrow: the watch's
    /// receiver-liveness watchdog runs only in its Streaming state, so every other state is one
    /// where being suspended costs nothing.
    public var isStreaming: Bool {
        if case .streaming = self { return true }
        return false
    }

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
    ///
    /// A checkpoint is not cheap: it is an fsync of the frame log, a GATT write, and an ACK
    /// notification back -- three flash-and-radio events, on both ends. The defaults used to be
    /// 2 s of audio OR 500 ms of wall time, and because audio arrives in real time the wall rule
    /// won every time: two checkpoints a second, all day. Three seconds is what the watch can
    /// comfortably hold un-acknowledged even at its 8 KB spool floor (about 6.5 s of audio),
    /// with room for a slow drain on top, and it is a third of the watch's 15 s receiver-liveness
    /// window, which is what checkpoints re-arm while a stream is flowing. Six times fewer
    /// checkpoints; the audio itself is no less safe -- anything unacknowledged is re-sent.
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
        checkpointAudioMs: Int64 = 3_000,
        checkpointMinIntervalMs: Int64 = 3_000,
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
    private let log: ReceiverLog

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
        consumeEnableRequestPermission: (@Sendable () -> Bool)? = nil,
        log: ReceiverLog = .silent
    ) {
        self.link = link
        self.sink = sink
        self.policy = policy
        self.resumeStore = resumeStore
        self.config = config
        self.clock = clock
        self.log = log
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

    /// Control messages handed to the link since the session was built. Telemetry: the phone's
    /// heartbeat prints the delta, so a log reader can see how often the app is writing to the
    /// watch (checkpoints, almost entirely) without a Bluetooth sniffer.
    nonisolated public let outboundControlCount = StateSubject<Int>(0)

    private func noteOutboundControl() {
        lastOutboundControlMs = clock.nowMs
        outboundControlCount.value = outboundControlCount.value + 1
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

    /// Consecutive failed handshakes, for the retry backoff. Reset the moment one succeeds.
    private var handshakeFailures = 0

    /// One in-place re-authorization per connection after the watch enables Background Audio, so
    /// a stream of reports cannot stack AUTH_REQUESTs.
    private var reauthorizingAfterEnable = false

    /// Rate limit for the policy-pause resume, which now fires from every watch report rather
    /// than from one message; each attempt consumes the single in-flight request slot. Nil means
    /// "not yet this connection" — a zero would be indistinguishable from time zero.
    private var lastPolicyResumeAtMs: Int64?
    private var stream: StreamContext?

    /// Wall time of the last inbound control/data notification; drives the keepalive idle check.
    private var lastInboundMs: Int64 = 0

    /// STREAM_GAP notices that arrived for a stream we have not (yet) been told about, keyed by
    /// stream id. The watch drains its pending-gap table before the re-announced STREAM_START
    /// reaches us on every re-authorization (2026-09-09: six notices, 33 ms ahead of the start),
    /// and it takes each record OUT of that table to send it — so a notice dropped here is gone
    /// from both sides, and the loss it described is recorded later with no reason. Held briefly
    /// and replayed the moment the stream opens; bounded so a watch that never announces cannot
    /// grow it.
    private var orphanGaps: [UInt32: [StreamGap]] = [:]
    /// Was 16, and on 2026-09-20 23:48:37 a re-authorization delivered more than that before its
    /// STREAM_START: the notices past the sixteenth were dropped, and the quiet they described came
    /// back as 13 small sequence skips — silence recorded as LOSS. A held notice is a few dozen
    /// bytes and adjacent same-reason notices coalesce as they arrive (`holdOrphanGap`), so this
    /// bound only stops a watch that never announces from growing the hold without end.
    public static let orphanGapsPerStream = 1_024
    /// Frames the watch reported lost that this app had already stored (see `handleStreamGap`).
    private var phantomGapFrames: UInt32 = 0
    private var phantomGapNotices: UInt32 = 0

    /// Wall time of the last STREAM_DATA / STREAM_GAP that arrived with no stream to attach it to
    /// — either no open stream at all, or one whose id we do not recognise.
    ///
    /// This is PROOF POSITIVE of the worst state this link can be in: the watch is spending its
    /// battery encoding and sending audio, and this app is dropping every frame on the floor for
    /// want of a STREAM_START it never received. Nothing else in the session notices it. The
    /// frames are not checkpointed (there is no stream to checkpoint), so the watch's spool is
    /// never trimmed, and what it cannot hold is lost to overflow while both sides report health.
    private var lastOrphanDataAtMs: Int64 = 0

    /// Frames that arrived with no stream to attach them to, since this session started.
    ///
    /// FRAMES ONLY, and for the life of the session. It used to count held gap notices as if they
    /// were frames, and it was zeroed at every link teardown — so Diagnostics, which shows the row
    /// only while it is above zero, was nearly always reading a counter that had just been wiped.
    ///
    /// What the number means, and does not: none of these frames was stored when it arrived, and
    /// none was acknowledged, so the watch still held every one of them. It re-sends what it holds
    /// once it re-announces the stream, and anything its buffer could not keep in the meantime is
    /// recorded — as the watch's overflow notice, or as a gap this app's resume accounting finds
    /// (`seedResumedStream`). The count is evidence of the link being out of step, not a measure
    /// of audio lost.
    nonisolated public let orphanedFrameCount = StateSubject<Int>(0)

    /// One stretch of audio the watch sent while this app had no stream for it, reported once
    /// when the stream is announced (or the link goes down first) — see `reportOrphanEpisode`.
    private struct OrphanEpisode {
        var frames = 0
        var notices = 0
        var noticesDropped = 0
        var streamIds: Set<UInt32> = []
        var firstSequence: UInt32?
        var lastSequence: UInt32?

        var isEmpty: Bool { frames == 0 && notices == 0 }

        mutating func add(_ data: StreamData) {
            frames += data.frameCount
            streamIds.insert(data.streamId)
            let last = data.firstSequence &+ UInt32(max(data.frameCount, 1) - 1)
            firstSequence = min(firstSequence ?? data.firstSequence, data.firstSequence)
            lastSequence = max(lastSequence ?? last, last)
        }
    }
    private var orphanEpisode = OrphanEpisode()

    private func noteOrphanData(_ data: StreamData) {
        lastOrphanDataAtMs = clock.nowMs
        orphanedFrameCount.value = orphanedFrameCount.value + data.frameCount
        orphanEpisode.add(data)
    }

    /// Holds a notice for a stream not yet announced. A notice that continues the last held one
    /// for the same reason extends it instead of taking a slot — the watch sends its table oldest
    /// first, and two abutting records with one reason are one period (the store would merge them
    /// anyway).
    private func holdOrphanGap(_ gap: StreamGap) {
        lastOrphanDataAtMs = clock.nowMs
        orphanEpisode.notices += 1
        orphanEpisode.streamIds.insert(gap.streamId)
        var held = orphanGaps[gap.streamId] ?? []
        if let last = held.last, last.reasonRaw == gap.reasonRaw, last.missingFrameCount > 0,
            gap.missingFrameCount > 0,
            last.firstMissingSequence &+ last.missingFrameCount == gap.firstMissingSequence,
            UInt64(last.missingFrameCount) + UInt64(gap.missingFrameCount) <= UInt64(UInt32.max)
        {
            held[held.count - 1] = StreamGap(
                streamId: last.streamId, firstMissingSequence: last.firstMissingSequence,
                missingFrameCount: last.missingFrameCount + gap.missingFrameCount,
                firstMissingSampleIndex: last.firstMissingSampleIndex, reasonRaw: last.reasonRaw,
                watchDropCounter: max(last.watchDropCounter, gap.watchDropCounter))
        } else if held.count < Self.orphanGapsPerStream {
            held.append(gap)
        } else {
            orphanEpisode.noticesDropped += 1
            return
        }
        orphanGaps[gap.streamId] = held
    }

    /// Says what one orphan episode was, once, when it ends: either the stream it belonged to has
    /// just been announced, or the link is going down without it ever being announced.
    ///
    /// This used to be a single line at teardown — "the watch was sending audio this app could
    /// not store" — which overstated it. The frames were never checkpointed, so the watch kept
    /// them and re-sends them after it re-announces the stream; the line is the evidence of a
    /// link out of step, with the numbers to find the stretch in the recording.
    private func reportOrphanEpisode(announced streamId: UInt32?) {
        let episode = orphanEpisode
        orphanEpisode = OrphanEpisode()
        guard !episode.isEmpty else { return }
        var parts: [String] = []
        if episode.frames > 0 {
            var range = ""
            if let first = episode.firstSequence, let last = episode.lastSequence {
                range = " (sequences \(first)-\(last))"
            }
            parts.append("\(episode.frames) frame(s)\(range)")
        }
        if episode.notices > 0 {
            parts.append("\(episode.notices) gap notice(s)")
        }
        let streams = episode.streamIds.sorted().map(String.init).joined(separator: ", ")
        let what = parts.joined(separator: " and ") + " for stream \(streams)"
        if let streamId {
            log(
                "\(what) arrived before stream \(streamId) was announced; nothing was stored or "
                    + "acknowledged, so the watch kept the audio and re-sends it now")
        } else {
            log(
                "link down: \(what) arrived on a connection that never announced their stream; "
                    + "none of it was acknowledged, so the watch kept it for the next connection")
        }
        if episode.noticesDropped > 0 {
            log(
                "\(episode.noticesDropped) gap notice(s) did not fit the hold "
                    + "(\(Self.orphanGapsPerStream) per stream) and were dropped; "
                    + "their frames will be recorded as sequence skips")
        }
    }

    private func noteInbound() {
        lastInboundMs = clock.nowMs
    }

    // --- evidence for the `.streaming` latch ----------------------------------------------------

    /// Publishes a session state and narrates the transition. Every state assignment goes
    /// through here so Detailed Logs carries the sequence a person needs to explain what the app
    /// was doing while they were not looking at it.
    private func setState(_ newState: ReceiverSessionState) {
        guard state.value != newState else { return }
        log("session \(describe(state.value)) -> \(describe(newState))")
        state.value = newState
    }

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
        reactToWatchReport(serviceStateRaw)
    }

    /// The two states the watch can LEAVE without any further event reaching us, acted on here
    /// rather than in the STATE_CHANGED arm.
    ///
    /// This is the single funnel for everything the watch says about itself — the handshake Info
    /// read, a STATE_CHANGED push, and every re-verify read — so a push that was lost, or that
    /// arrived while iOS had the app suspended, is still caught by the next verify tick. Handling
    /// either of these on the message alone made recovery depend on an edge that may never come
    /// again.
    private func reactToWatchReport(_ serviceStateRaw: Int) {
        guard captureIntent() != .off else { return }

        // (1) The watch had Background Audio off, so we never even sent AUTH_REQUEST, and the
        // connection has been parked ever since with `authorized == false` — every child task
        // inert behind their own `authorized` guards. The user then turns Background Audio on at
        // the wrist, the watch pushes its new state, and until now the app read that and threw it
        // away. Re-drive the handshake IN PLACE: the watch still has our receiver id bound, so it
        // authorizes with no prompt on the wrist, and a full resync on a shared ACL would cost a
        // reconnect for nothing. `enableRequestArmed` is deliberately NOT re-armed — only an
        // explicit Start may ask the watch to enable anything.
        if !authorized,
           state.value == .denied(statusRaw: Int(AuthStatus.deniedDisabled.rawValue)),
           serviceStateRaw != Int(ServiceState.disabled.rawValue),
           !reauthorizingAfterEnable {
            reauthorizingAfterEnable = true
            log("watch enabled background audio; re-authorizing without a fresh connection")
            auxTasks.append(Task { await self.sendAuthRequest() })
            return
        }

        // (2) A policy pause the watch cannot leave on its own. The pause was asserted because we
        // reported low storage in a CHECKPOINT — and CHECKPOINT is the ONLY carrier of those
        // flags, while a paused watch sends no audio, so nothing ever produces the next one. The
        // watch's state does not change either, so there is no second STATE_CHANGED to react to.
        // Driving it from every report instead makes the clearing of the condition sufficient.
        if authorized,
           serviceStateRaw == Int(ServiceState.pausedPolicy.rawValue),
           captureIntent() == .active,
           policy.receiverFlags() == 0,
           lastPolicyResumeAtMs.map({ clock.nowMs - $0 >= config.keepaliveIntervalMs }) ?? true {
            lastPolicyResumeAtMs = clock.nowMs
            log("watch is holding a policy pause we no longer have a reason for; resuming")
            auxTasks.append(Task { _ = await self.requestResume() })
        }
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
            try? await self.readInfoFromLink()
        }
        guard let bytes, case .decoded(let message) = AudioCompanionProtocol.decodeInfo(bytes),
            let snapshot = message as? InfoSnapshot
        else { return false }
        watchInfo.value = snapshot
        noteWatchRestart(snapshot)
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
        var missingStream = 0
        while true {
            do {
                try await clock.sleep(ms: config.streamVerifyIntervalMs)
            } catch {
                return // cancelled with the connection
            }
            if Task.isCancelled { return }
            guard authorized else {
                unanswered = 0
                missingStream = 0
                continue
            }
            guard stream != nil else {
                unanswered = 0
                if await checkForAStreamWeShouldHave(strikes: &missingStream) { return }
                continue
            }
            missingStream = 0
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
            log("rebuilding the link: \(unanswered) verifies unanswered during a believed-open stream")
            link.resyncAutomatically()
            return
        }
    }

    /// Authorized, with NO open stream — and whether that is fine or is the worst state this app
    /// can be in depends entirely on what the watch is doing.
    ///
    /// Ordinarily it is fine: the watch is idle, paused, or has Background Audio off, so there is
    /// no stream to have and nothing to fix. It is a FAULT when the watch is capturing anyway,
    /// because then it is streaming audio at a receiver that cannot attach a single frame of it.
    ///
    /// NOTHING ELSE IN THE SESSION COVERS THIS. `runStreamVerify`'s other arm requires an open
    /// stream by definition. The keepalive is satisfied — a watch in this state answers every
    /// RECEIVER_HEALTH ping perfectly well, and answering is all the keepalive asks for. And the
    /// status card said "Authorized and ready. Waiting for the watch to start streaming.", which
    /// reads like a calm, transient handshake step rather than the indefinite deadlock it was.
    /// The user's report is the shape of it exactly: the watch says Streaming, the app says it is
    /// waiting for the watch, and it stays that way until a human intervenes.
    ///
    /// The cure is a fresh receiver session, because the watch re-announces STREAM_START on
    /// authorization. Returns true when it forced one.
    private func checkForAStreamWeShouldHave(strikes: inout Int) async -> Bool {
        let heardOrphanAudio = lastOrphanDataAtMs > 0
            && clock.nowMs - lastOrphanDataAtMs <= Self.orphanDataMaxAgeMs
        // Ask rather than trust. The last report may be minutes old, and the answer is the whole
        // discriminator between a watch that is idle and a watch that is recording into a void.
        _ = await verifyWatchState()
        let watchIsCapturing = streamEvidence.value.watchReportedStreaming
        guard heardOrphanAudio || watchIsCapturing else {
            strikes = 0
            return false
        }
        strikes += 1
        log(
            "watch is capturing but this app has no stream"
                + " (strike \(strikes)/\(Self.missingStreamMaxStrikes)"
                + (heardOrphanAudio ? ", audio arriving with nowhere to put it" : "") + ")"
        )
        guard strikes >= Self.missingStreamMaxStrikes else { return false }
        log("rebuilding the link: the watch is recording and we are not receiving it")
        link.resyncAutomatically()
        return true
    }

    // Per-connection child tasks (the Kotlin connection coroutineScope's children).
    /// The slow re-authorization after a retryable denial — see `scheduleDeniedRetry`.
    private var reauthTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var dataTask: Task<Void, Never>?
    private var verifyTask: Task<Void, Never>?
    private var authRequestTask: Task<Void, Never>?
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

    /// Answers the watch's liveness probe on the spot, instead of waiting for the keepalive tick.
    ///
    /// While the watch is suppressing silence it sends no audio at all, and pushes a STATE_CHANGED
    /// every RECEIVER_LIVENESS_TIMEOUT_MS purely to check we are still here — one control
    /// notification, chosen precisely because that is what wakes a suspended iOS app. If we do not
    /// answer within its window it stops the microphone.
    ///
    /// Relying on `runKeepalive` for that answer is a race we do not need to run. Its `Task.sleep`
    /// is frozen while the app is suspended, so the reply depends on how promptly the cooperative
    /// pool reschedules a long-overdue sleep after a wake — and the app is now deliberately
    /// suspendable during silence, because residency follows the stream rather than the intent.
    /// Answering straight off the notification that woke us removes the timing question entirely.
    ///
    /// Rate-limited by the same outbound-traffic test the keepalive uses, so a healthy streaming
    /// connection (which checkpoints constantly) sends nothing extra.
    private func answerWatchProbeIfDue() {
        guard authorized else { return }
        guard clock.nowMs - lastOutboundControlMs >= config.keepaliveIntervalMs else { return }
        auxTasks.append(Task { _ = await self.sendReceiverHealth() })
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
                    log("rebuilding the link: \(failures) keepalive pings unanswered")
                    link.resyncAutomatically()
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
                // Paced by the STALL it detects, not by the checkpoint interval. Those are
                // different numbers and conflating them meant waking twice a second, for the whole
                // life of every connection, to notice a two-second condition. The data-driven path
                // still checkpoints at `checkpointMinIntervalMs`; this only has to catch the case
                // where data stopped arriving, and a few seconds of extra latency there is
                // invisible against a watch spool measured in minutes.
                try await clock.sleep(ms: Self.checkpointStallMs)
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

        /// False until the contiguity base is known. A fresh stream is known to begin at sequence
        /// 0. A RESUME re-announcement (sent by the watch when it re-attaches a receiver
        /// mid-stream after a reconnect) continues at the watch's current sequence, so assuming
        /// 0 would synthesize a bogus multi-thousand-frame leading gap and never checkpoint.
        ///
        /// When the store already holds the stream, the base is SEEDED from what it holds (see
        /// `seed`) — that is the only way the hole a reconnect leaves can be compared against
        /// anything. Only a RESUME of a stream this app holds nothing of falls back to adopting
        /// the base from the first frame (`adoptBase`).
        var baseInitialized: Bool

        /// What to do with frames the watch re-sends BELOW a seeded base — its spool rewind
        /// after a reconnect always re-sends everything it holds that was never checkpointed.
        enum BelowBase {
            /// Drop them here: they are already accounted for (a fresh stream, or an unseeded
            /// RESUME — the behaviour before seeding existed).
            case drop
            /// The open segment is the one holding them: hand them to the sink, which drops the
            /// exact re-sends and keeps any that fall inside a recorded gap (a refill).
            case sinkDecides
            /// They belong to an EARLIER segment of this stream: never store them again.
            case trimAway
        }
        var belowBase: BelowBase = .drop

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
            let firstSampleIndex: UInt64
        }

        /// Starts the stream's contiguity from what is already stored: everything below `next` is
        /// persisted, and `recorded` is accounted for. From here on, any sequence between `next`
        /// and the first frame the watch delivers that no watch notice accounts for is a hole
        /// this app records as loss — which is the check the watch relies on for the frames its
        /// spool dropped after sending them into a dying link.
        func seed(
            next: UInt32, nextSampleIndex: UInt64, recorded: [KnownGapRange], belowBase: BelowBase
        ) {
            contiguousNext = next
            contiguousSampleIndex = nextSampleIndex
            baseInitialized = true
            self.belowBase = belowBase
            for range in recorded where range.endExclusive > next {
                pendingWatchGaps.append(range)
            }
            samplesSinceCheckpoint &+= advanceAccountedPrefix()
            // Re-announce our watermark on this connection: the watch rewound to its own trim
            // point, and a checkpoint lets it trim (and stop re-sending) what we already hold.
            checkpointedSinceLastChange = false
        }

        /// An unseeded RESUME fixes its base on the first FRAME, as the protocol specifies — not
        /// on the first notice. Notices held before it only lower the base, never raise it: a
        /// notice for frames ABOVE the watch's rewind point (quiet it skipped while we were
        /// away, say) used to set the base there, so the re-sent frames below it were discarded
        /// as stale duplicates and the next checkpoint told the watch to delete them.
        func adoptBase(firstDataSequence: UInt32, firstDataSampleIndex: UInt64) {
            if baseInitialized { return }
            contiguousNext = firstDataSequence
            contiguousSampleIndex = firstDataSampleIndex
            if let lowest = pendingWatchGaps.min(by: { $0.first < $1.first }),
                lowest.first < contiguousNext
            {
                contiguousNext = lowest.first
                contiguousSampleIndex = lowest.firstSampleIndex
            }
            if let open = openWatchGapFrom, open < contiguousNext {
                // An unknown-extent notice has no sample index of its own; the frame clock is
                // exact for every sequence the watch assigns, so derive it from the frame.
                contiguousSampleIndex &-= UInt64(contiguousNext &- open) &* frameSamples
                contiguousNext = open
            }
            baseInitialized = true
        }

        func rememberKnownGap(first: UInt32, missingCount: UInt32, firstSampleIndex: UInt64) {
            if missingCount == 0 { return }
            let endExclusive = first &+ missingCount
            if baseInitialized && endExclusive <= contiguousNext { return }
            pendingWatchGaps.append(
                KnownGapRange(first: first, endExclusive: endExclusive, firstSampleIndex: firstSampleIndex))
        }

        /// The parts of [contiguousNext, end) that no watch notice accounts for, each placed on
        /// the sample clock — the sequence skips to record when audio resumes at `end`.
        ///
        /// Recorded as ONE skip over the whole hole, as it used to be, the receiver claimed the
        /// watch's own overflow records as "the phone missed audio", and the store — before it
        /// learned to merge in sequence order — then swallowed the skip's lower part outright.
        func unaccountedRuns(upTo end: UInt32) -> [(first: UInt32, count: UInt32, sampleIndex: UInt64)] {
            var runs: [(first: UInt32, count: UInt32, sampleIndex: UInt64)] = []
            var cursor = contiguousNext
            var cursorSample = contiguousSampleIndex
            for gap in pendingWatchGaps.sorted(by: { $0.first < $1.first })
            where gap.endExclusive > cursor && gap.first < end {
                if gap.first > cursor {
                    runs.append((cursor, gap.first &- cursor, cursorSample))
                }
                cursor = gap.endExclusive
                cursorSample = gap.firstSampleIndex &+ UInt64(gap.endExclusive &- gap.first) &* frameSamples
                if cursor >= end { break }
            }
            if cursor < end {
                runs.append((cursor, end &- cursor, cursorSample))
            }
            return runs
        }

        /// Watch notices wholly below `sequence` are behind the contiguous prefix for good.
        func forgetKnownGaps(below sequence: UInt32) {
            pendingWatchGaps.removeAll { $0.endExclusive <= sequence }
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
        setState(.disconnected)
        watchServiceState.value = nil
    }

    private func handleLinkState(_ linkState: LinkState) async {
        switch linkState {
        case .disconnected:
            await onLinkDown()
            if let failure = link.lastFailure.value {
                setState(.connectionFailed(kind: failure.kind, detail: failure.detail))
            } else {
                setState(.disconnected)
            }
            watchServiceState.value = nil
        case .connecting:
            await onLinkDown()
            setState(.connecting)
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
        var handshakeError: Error?
        var aborted: Bool?
        do {
            try await connectionHandshake(abort: abort)
            // Mirror Kotlin's coroutineScope: the connection stays alive (children running)
            // until the link state changes (we get cancelled) or a child aborts it.
            aborted = await abort.value()
        } catch {
            handshakeError = error
        }
        // Link dropped (cancel-on-change cancelled us) or the connection failed. Children first
        // (Kotlin's scope joins them), then per-link state — always, even when cancelled.
        await drainConnectionTasks()
        connectionAbort = nil
        await onLinkDown()
        // BOTH exits recover, not just one.
        //
        // `runConnection` has two ways to end badly and only the handshake throw used to be
        // handled. When a CHILD aborted the connection instead — which is what every sink failure
        // does, and `SegmentStore` throws on any disk error as well as deliberately on
        // `noOpenSegment`/`streamMismatch` — `abort.value()` returned normally, `handshakeError`
        // was nil, and this function drained all six child tasks and returned having scheduled
        // nothing at all. Core Bluetooth still called the link `.ready`, and `StateSubject` does
        // not re-emit an equal value, so `run()`'s `for await` waited on an element that could
        // never arrive: zero tasks, zero timers, forever, with the UI still saying "Recording".
        // One failed write was enough.
        if let handshakeError {
            await recoverFromFailedHandshake(handshakeError)
        } else if aborted == true {
            await recoverFromFailedHandshake(
                SessionError.connectionAborted(abortReason ?? "a connection child failed")
            )
        }
        abortReason = nil
    }

    /// Why the current connection is being aborted. Read once by `runConnection` so the recovery
    /// and the log line can name the real cause instead of "a child failed".
    private var abortReason: String?

    private func noteConnectionAbort(_ label: String, _ error: Error) {
        let reason = "\(label): \(error)"
        log("aborting the connection — \(reason)")
        if abortReason == nil { abortReason = reason }
    }

    enum SessionError: Error, CustomStringConvertible {
        case connectionAborted(String)

        var description: String {
            switch self {
            case .connectionAborted(let reason): return reason
            }
        }
    }

    /// A handshake that threw used to be the quiet end of the session.
    ///
    /// THIS IS THE TERMINAL SINK FOR EVERY AUTOMATIC RECOVERY IN THIS FILE. The keepalive, the
    /// stream verify and the no-stream watchdog all recover the same way — ask the link for a
    /// fresh connection — which produces a new `.ready` and a new handshake. If that handshake
    /// throws, every child task has just been drained, so nothing is left running; and the link
    /// is still `.ready` as far as Core Bluetooth is concerned, so `run()`'s `for await` waits on
    /// a `StateSubject` that (by design) does not re-emit an equal value. Zero tasks, zero
    /// timers, zero escalations, forever — until a person taps something or relaunches the app.
    ///
    /// It is not exotic. `readInfo` throws on the link's own 10 s operation timeout (a half-dead
    /// connection the platform still calls connected), and on any ATT refusal of the encrypted
    /// Info characteristic — a bonded-reconnect encryption race, or the stale-GATT-cache case
    /// this project already knows well.
    ///
    /// So: say so plainly, back off, and ask for a fresh connection. Deliberately NO attempt
    /// limit — this is a background-audio product and giving up recreates exactly the park we are
    /// escaping. The stale-cache latch still applies (`resyncAutomatically`), so the one failure
    /// that genuinely cannot be retried does not spin the radio.
    private func recoverFromFailedHandshake(_ error: Error) async {
        handshakeFailures += 1
        setState(
            .connectionFailed(kind: .watchUnreachable, detail: "handshake failed: \(error)")
        )
        let delay = min(
            Self.handshakeRetryBaseMs << UInt64(min(handshakeFailures - 1, 4)),
            Self.handshakeRetryMaxMs
        )
        log("handshake failed (\(handshakeFailures)); rebuilding the link in \(delay) ms: \(error)")
        do {
            try await clock.sleep(ms: delay)
        } catch {
            return // a real link-state change pre-empted us; that path owns the recovery now
        }
        if Task.isCancelled { return }
        link.resyncAutomatically()
    }

    private func drainConnectionTasks() async {
        while true {
            var tasks: [Task<Void, Never>] = []
            if let task = reauthTask { tasks.append(task); reauthTask = nil }
            if let task = controlTask { tasks.append(task); controlTask = nil }
            if let task = keepaliveTask { tasks.append(task); keepaliveTask = nil }
            if let task = checkpointTask { tasks.append(task); checkpointTask = nil }
            if let task = dataTask { tasks.append(task); dataTask = nil }
            if let task = verifyTask { tasks.append(task); verifyTask = nil }
            if let task = authRequestTask { tasks.append(task); authRequestTask = nil }
            tasks.append(contentsOf: auxTasks)
            auxTasks = []
            if tasks.isEmpty { return }
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
        }
    }

    /// Info reads this session has asked the link for that have not come back yet.
    private var infoReadsInFlight = 0

    /// Every Info read this session makes goes through here, so the handshake can tell when it is
    /// about to collide with one of its own.
    private func readInfoFromLink() async throws -> [UInt8] {
        infoReadsInFlight += 1
        defer { infoReadsInFlight -= 1 }
        return try await link.readInfo()
    }

    private func connectionHandshake(abort: OneShot<Bool>) async throws {
        setState(.authorizing)

        // The link keeps ONE Info read in flight and refuses a second with `operationInFlight`,
        // and the handshake's read is the one that must not be refused: failing it fails the
        // whole handshake and rebuilds the link. On 2026-09-19 14:19:54 the app came to the
        // foreground while the link was still subscribing, foreground entry asked the watch what
        // it was doing (`verifyWatchState`, which the link accepts as soon as the Info
        // characteristic is discovered), the link reached Ready 400 ms later — and the handshake
        // read collided with the verify's, which answered 150 ms after that. One refused read
        // cost a cancel-and-reconnect of a link that was working. Wait for our own read to land
        // (bounded by the link's operation timeout), then ask.
        var waitedMs: Int64 = 0
        while infoReadsInFlight > 0 && waitedMs < Self.handshakeInfoReadWaitMs {
            try await clock.sleep(ms: Self.infoReadPollMs)
            waitedMs += Self.infoReadPollMs
        }

        switch AudioCompanionProtocol.decodeInfo(try await readInfoFromLink()) {
        case .decoded(let message):
            if let snapshot = message as? InfoSnapshot {
                watchInfo.value = snapshot
                noteWatchRestart(snapshot)
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
                setState(.denied(statusRaw: Int(AuthStatus.deniedDisabled.rawValue)))
                scheduleDeniedRetry(statusRaw: Int(AuthStatus.deniedDisabled.rawValue))
                return
            }
            setState(.pendingEnable)
            let enabled = await sendControlAwaitAck(
                requireAuthorized: false,
                ackWaitMs: Self.enableRequestAckWaitMs
            ) { token in
                EnableRequest(requestToken: token).encode()
            }
            if !enabled {
                setState(.denied(statusRaw: Int(AuthStatus.deniedDisabled.rawValue)))
                scheduleDeniedRetry(statusRaw: Int(AuthStatus.deniedDisabled.rawValue))
                return
            }
            await refreshInfoSnapshot()
            setState(.authorizing)
        }

        guard takeToken() != nil else {
            assertionFailure("fresh connection must have no in-flight request")
            throw ReceiverSessionError.internalInvariant
        }
        guard let token = inFlightToken else { throw ReceiverSessionError.internalInvariant }
        try await writeAuthRequest(token: token)
        authRequestTask = Task { await self.awaitAuthResult(firstToken: token) }
    }

    private func writeAuthRequest(token: Int) async throws {
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

    /// AUTH_REQUEST used to be fire-and-forget, with nothing anywhere waiting for the answer.
    ///
    /// The watch's reply is a GATT notification, and the firmware discards the send result — a
    /// refused notification (msys exhaustion on a host shared with the official app) is simply
    /// never retried, unlike STREAM_START which has its own pending flag. One dropped AUTH_RESULT
    /// therefore left the app at `.authorizing` with the token held, every child task idle behind
    /// its `authorized` guard, and no deadline anywhere. The watch, meanwhile, believes it
    /// authorized us.
    ///
    /// `.pendingConsent` is the one legitimate long wait — a human is answering a prompt on the
    /// wrist — so it is given the watch's own consent window plus slack rather than this deadline.
    /// It is still bounded: a consent whose result never arrives must not park us either.
    private func awaitAuthResult(firstToken: Int) async {
        var attempt = 0
        var token = firstToken
        while true {
            let waited = state.value == .pendingConsent
                ? Self.consentResultWaitMs : Self.authResultWaitMs
            do {
                try await clock.sleep(ms: waited)
            } catch {
                return // cancelled with the connection
            }
            if Task.isCancelled || authorized { return }
            switch state.value {
            case .authorizing, .pendingConsent:
                break // still waiting on an answer that has not come
            default:
                return // denied / revoked / torn down: not ours to retry
            }
            attempt += 1
            if attempt > Self.authResultMaxAttempts {
                log("no AUTH_RESULT after \(attempt) attempts; rebuilding the link")
                link.resyncAutomatically()
                return
            }
            // Release the stuck slot and ask again with a fresh token, so a late answer to the
            // old one cannot be mistaken for this one.
            inFlightToken = nil
            guard let next = takeToken() else { continue }
            token = next
            log("no AUTH_RESULT yet; re-sending AUTH_REQUEST (attempt \(attempt))")
            do {
                try await writeAuthRequest(token: token)
            } catch {
                log("re-sending AUTH_REQUEST failed: \(error)")
            }
        }
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
                        // Sink failure fails the connection (Kotlin scope). Recorded, not
                        // swallowed: this catch is where a disk error on the receive path ends
                        // up, and it used to leave no trace anywhere.
                        noteConnectionAbort("control handling failed", error)
                        abort.complete(true)
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
                reauthTask?.cancel()
                reauthTask = nil
                handshakeFailures = 0
                grantedProtoVersion.value = result.grantedProtoVersion
                // The watch accepted us, so whatever it last complained about is settled. This
                // matters now that the error is read: a stale ERROR from an earlier connection
                // would otherwise keep explaining a link that is working.
                lastProtocolError.value = nil
                setState(.authorized)
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
                setState(.pendingConsent)
            default:
                inFlightToken = nil
                authorized = false
                setState(.denied(statusRaw: Int(result.statusRaw)))
                scheduleDeniedRetry(statusRaw: Int(result.statusRaw))
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
            setState(.revoked(reasonRaw: Int(revoked.reasonRaw)))
        case let changed as StateChanged:
            // Recording it IS reacting to it: `noteWatchReport` is the single funnel, so the
            // safety nets fire here and on every re-verify read alike.
            noteWatchReport(Int(changed.serviceStateRaw))
            answerWatchProbeIfDue()
        case let error as ErrorMessage:
            lastProtocolError.value = error
        default:
            break
        }
    }

    /// A denial is a fact about right now, not a permanent one — so keep asking, slowly.
    ///
    /// `.denied` used to be a terminal park. Nothing throws on this path, so `runConnection` never
    /// reaches its recovery and sits on an abort that will never complete; and with
    /// `authorized == false` every remaining child is inert — the keepalive skips its ping, the
    /// stream verify skips its Info read, the checkpoint ticker skips its flush. A live link, zero
    /// timers, until the user does something.
    ///
    /// Only two denials may be retried automatically, and the distinction is important because
    /// getting it wrong means buzzing someone's wrist every minute. Reading the firmware's
    /// `prv_handle_auth_request_locked`: `DeniedDisabled` (Background Audio off on the watch) and
    /// `DeniedMismatch` (a different receiver is bound) are pure refusals that send an answer and
    /// nothing else. The `NoReceiver` case — which is what a `.revoked` session or a declined
    /// consent becomes — raises the on-watch consent prompt instead. That one stays a user gesture.
    private func scheduleDeniedRetry(statusRaw: Int) {
        let retryable =
            statusRaw == Int(AuthStatus.deniedDisabled.rawValue)
            || statusRaw == Int(AuthStatus.deniedMismatch.rawValue)
        guard retryable, reauthTask == nil else { return }
        reauthTask = Task { await self.retryDeniedAuthorization() }
    }

    private func retryDeniedAuthorization() async {
        var attempt = 0
        while !Task.isCancelled {
            let delay = min(
                Self.deniedRetryBaseMs << UInt64(min(attempt, 4)), Self.deniedRetryMaxMs
            )
            attempt += 1
            do { try await clock.sleep(ms: delay) } catch { return }
            if Task.isCancelled || authorized { return }
            log("re-authorizing after a denial (attempt \(attempt))")
            await sendAuthRequest()
        }
    }

    /// Re-runs authorization on the CURRENT connection — no reconnect, no watch prompt. Used by
    /// the Background-Audio-enabled recovery in `reactToWatchReport`.
    private func sendAuthRequest() async {
        inFlightToken = nil
        guard let token = takeToken() else { return }
        setState(.authorizing)
        do {
            try await writeAuthRequest(token: token)
        } catch {
            // Do not just return. This `return` skipped the line below that arms
            // `awaitAuthResult`, so there was no deadline, no re-send and no rebuild — and
            // `reauthorizingAfterEnable` stays latched for the connection, so no later watch report
            // could start a second attempt either. The session sat in `.authorizing` with
            // `authorized == false`, which makes the keepalive, the stream verify and the
            // checkpoint ticker all inert. A permanent park from one failed write.
            //
            // A link that cannot accept a control write is not a link worth keeping: this is the
            // same class of evidence as `readInfo` failing, which the handshake path already
            // treats as "rebuild".
            log("in-place re-authorization failed to write; rebuilding the link: \(error)")
            inFlightToken = nil
            reauthorizingAfterEnable = false
            link.resyncAutomatically()
            return
        }
        authRequestTask?.cancel()
        authRequestTask = Task { await self.awaitAuthResult(firstToken: token) }
    }

    /// The last restart summary written to the log, so a watch that keeps reporting the same
    /// restart on every Info read is logged once, and a NEW restart is logged the moment it is
    /// seen.
    private var loggedRestartSummary: String?

    private func noteWatchRestart(_ snapshot: InfoSnapshot) {
        guard let restart = snapshot.restart else { return }
        let fw = snapshot.fwVersionText.map { " (fw \($0))" } ?? ""
        let summary = restart.summary + fw
        guard summary != loggedRestartSummary else { return }
        loggedRestartSummary = summary
        log("watch \(summary)")
    }

    private func refreshInfoSnapshot() async {
        guard let bytes = try? await readInfoFromLink() else { return }
        switch AudioCompanionProtocol.decodeInfo(bytes) {
        case .decoded(let message):
            if let snapshot = message as? InfoSnapshot {
                watchInfo.value = snapshot
                noteWatchRestart(snapshot)
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
                        noteConnectionAbort("storing audio failed", error)
                        abort.complete(true)
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
            var continuingInPlace: StreamContext?
            if resume && stream?.streamId == start.streamId {
                continuingInPlace = stream
                stream = nil // replaced below; the segment stays open for continuation
            } else {
                try await closeOpenSegment(.superseded)
            }
            let continuation = try await sink.openSegment(
                start: start,
                receivedAtMs: clock.nowMs,
                provenance: watchInfo.value.map {
                    SegmentProvenance(
                        fwVersionPacked: $0.fwVersionPacked,
                        protocolVersion: start.protocolVersion
                    )
                }
            )
            let context = StreamContext(start: start, nowMs: clock.nowMs)
            if resume {
                await seedResumedStream(
                    context, continuation: continuation, inPlace: continuingInPlace)
            }
            stream = context
            noteAudioArrived()
            setState(.streaming(streamId: start.streamId))
            reportOrphanEpisode(announced: start.streamId)
            if let held = orphanGaps.removeValue(forKey: start.streamId), !held.isEmpty {
                log("applying \(held.count) gap notice(s) that arrived before STREAM_START")
                for gap in held {
                    try await handleStreamGap(gap)
                }
            }
            orphanGaps.removeAll()
        case let data as StreamData:
            guard let ctx = stream, ctx.streamId == data.streamId else {
                // Audio for a stream we cannot attach. Deliberately NOT counted as
                // `noteAudioArrived`: nothing was stored, so treating it as evidence of a healthy
                // recording is precisely the lie that let this state persist for hours.
                noteOrphanData(data)
                return
            }
            noteAudioArrived()
            try await handleStreamData(data)
        case let gap as StreamGap:
            guard let ctx = stream, ctx.streamId == gap.streamId else {
                // An orphaned GAP is worse than an orphaned frame, and it is the likeliest
                // explanation for the library's unattributed holes. The watch TAKES a gap record
                // out of its pending table to send it (`prv_send_one_pending_gap_locked`) and only
                // puts it back on BLE backpressure — so a notice we drop here is gone from both
                // sides. The hole itself survives, because the next STREAM_DATA still shows the
                // sequence jump and `handleStreamData` synthesizes a `sequence_skip`; what is lost
                // is the REASON. That matches the shape of the loss in Roger's export exactly:
                // every one of the 5,194 watch-reported gaps carries a reason and not one of the
                // 2,690 receiver-synthesized ones does, and the 38 largest unattributed holes hold
                // 62.6 h between them. Name it in the recorder so the next export can confirm it.
                //
                // So it is HELD, not dropped: on 2026-09-09 every re-authorization delivered the
                // watch's pending gaps 30-150 ms before the re-announced STREAM_START. The
                // notice is applied the moment that start opens the stream (`StreamStart`
                // above); if no start ever comes, the link teardown discards it.
                if orphanGaps[gap.streamId]?.isEmpty ?? true {
                    log(
                        "holding a watch gap notice for stream \(gap.streamId) "
                            + "(\(gap.missingFrameCount) frames, reason \(gap.reasonRaw)): "
                            + (stream == nil
                                ? "no open stream" : "our stream is \(stream?.streamId ?? 0)")
                            + " — applied when that stream is announced")
                }
                holdOrphanGap(gap)
                return
            }
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
            setState(.authorized)
        default:
            break
        }
    }

    /// Fixes a resumed stream's contiguity base on what this app already holds of it.
    ///
    /// THIS IS THE RECEIVER'S HALF OF A CONTRACT THE WATCH ALREADY KEEPS. When its spool cannot
    /// grow, the watch recycles its oldest 4 KB chunk (104 frames) and records a gap only for the
    /// frames in it that it had not yet SENT (`spool.c`, `prv_drop_oldest_chunk`); frames it had
    /// sent into a link that was already dying are dropped with no record, and the firmware
    /// relies on "the receiver's own sequence check" to catch them. A RESUME used to leave that
    /// check nothing to check against: the context started with no base, the first notice after
    /// the reconnect set one, and the stretch between the last frame stored and the watch's
    /// first overflow record was never compared with anything. In the 2026-09-29 backup that is
    /// 32 of the ~70 same-stream reconnects — an unrecorded run ending exactly where the first
    /// overflow record starts, typically 104-208 frames (one or two chunks) — 5,634 frames in
    /// all, and the four that were decoded are speech (09-19 21:38:52, 09-23 09:35:03,
    /// 09-23 14:30:37, 09-25 23:00:52). Today and Live painted those holes as recorded.
    ///
    /// Seeded, the hole is compared against the watch's own account: every sequence between what
    /// we hold and the first frame it delivers that no notice explains becomes a sequence skip —
    /// explicit loss. And the base can no longer be set by a notice for frames above the
    /// watch's rewind point, which discarded the re-sent frames below it as stale and then told
    /// the watch, by checkpoint, to delete them.
    ///
    /// Sources, most authoritative first: the store's answer; for an in-place re-announcement
    /// the stream context it replaces (a sink that cannot answer — the tests' fakes — still has
    /// that); and, when the stream carries on in a NEW segment, the resume state saved at the
    /// last close, which still knows how far we got if the segment holding it has since been
    /// deleted. With none of them, the base is adopted from the first frame, as the protocol
    /// specifies for a receiver that knows nothing.
    private func seedResumedStream(
        _ context: StreamContext, continuation: StreamContinuation?, inPlace: StreamContext?
    ) async {
        var next: UInt32?
        var nextSampleIndex: UInt64 = 0
        var recorded: [StreamContext.KnownGapRange] = []
        var belowBase = StreamContext.BelowBase.trimAway
        if let continuation {
            next = continuation.nextSequence
            nextSampleIndex = continuation.nextSampleIndex
            recorded = continuation.recordedRanges.map {
                StreamContext.KnownGapRange(
                    first: $0.firstSequence, endExclusive: $0.firstSequence &+ $0.frameCount,
                    firstSampleIndex: $0.firstSampleIndex)
            }
            belowBase = continuation.continuesSameSegment ? .sinkDecides : .trimAway
        } else if let inPlace, inPlace.baseInitialized {
            next = inPlace.contiguousNext
            nextSampleIndex = inPlace.contiguousSampleIndex
            recorded = inPlace.pendingWatchGaps
            belowBase = .sinkDecides
        }
        if belowBase == .trimAway, let saved = await resumeStore.load(),
            saved.lastStreamId == context.streamId, let last = saved.lastContiguousSequence,
            last < UInt32.max, next.map({ last + 1 > $0 }) ?? true
        {
            next = last + 1
            nextSampleIndex = saved.lastSampleIndex
        }
        if let inPlace { context.openWatchGapFrom = inPlace.openWatchGapFrom }
        guard let next else { return }
        context.seed(
            next: next, nextSampleIndex: nextSampleIndex, recorded: recorded, belowBase: belowBase)
        log(
            "stream \(context.streamId) resumed after sequence \(next &- 1) "
                + (belowBase == .sinkDecides ? "in the same recording" : "in a new recording")
                + "; any sequence the watch does not account for from here is recorded as missing")
    }

    private func handleStreamData(_ message: StreamData) async throws {
        guard let ctx = stream else { return } // STREAM_DATA before STREAM_START: nothing to attach it to
        if message.streamId != ctx.streamId { return }
        ctx.adoptBase(
            firstDataSequence: message.firstSequence, firstDataSampleIndex: message.firstSampleIndex)

        let first = message.firstSequence
        let count = UInt32(message.frameCount)
        let endExclusive = first &+ count

        let advancedKnownGapSamples = ctx.advanceAccountedPrefix()
        if advancedKnownGapSamples > 0 {
            ctx.samplesSinceCheckpoint &+= advancedKnownGapSamples
            ctx.checkpointedSinceLastChange = false
        }

        func frames() -> [SegmentFrame] {
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
            return frames
        }

        if endExclusive <= ctx.contiguousNext {
            // Stale: everything in it is already stored or accounted for. After a RESUME that
            // continued this very segment, it is the watch's rewind re-sending what it never saw
            // checkpointed — and the sink, not this bookkeeping, knows whether any of it falls
            // inside a gap it recorded and so is audio recovered rather than a duplicate.
            if ctx.belowBase == .sinkDecides {
                _ = try await sink.appendFrames(streamId: ctx.streamId, frames: frames())
            }
            await maybeSendCheckpoint(ctx)
            return
        }

        // Durability first: frames hit the frame log before any bookkeeping or checkpointing.
        var batch = frames()
        if first < ctx.contiguousNext && ctx.belowBase == .trimAway {
            // The stream carries on in a new segment and these are the tail of an earlier one.
            batch.removeAll { $0.sequence < ctx.contiguousNext }
        }
        // A hole under this batch is RECORDED BEFORE the batch is stored. The other way round, a
        // process killed between the two awaits left frames above an unrecorded hole — and on the
        // next RESUME the store answers "stored through the highest sequence", the session seeds
        // there, and its checkpoint tells the watch to delete the hole's frames, which it still
        // held and would have re-sent (review of the RESUME accounting, 2026-09-30). This way a
        // kill leaves a recorded gap and no frames above it: honest, and a re-send that arrives
        // still refills it. Nothing below is claimed until the checkpoint, so the order is free.
        let holeAccountedByWatch =
            first > ctx.contiguousNext
            && ctx.openWatchGapFrom.map { $0 <= ctx.contiguousNext } == true
        if first > ctx.contiguousNext && !holeAccountedByWatch {
            // Silent discontinuity: synthesize a gap record, then account for it (below).
            //
            // Contiguity used to stop here permanently, and the consequence was on the WATCH.
            // `highestContiguousSequencePersisted` is the watch's only instruction to free
            // spool (`audio_companion_spool_trim_through`), so a frozen watermark means the
            // spool never trims again. It saturates, starts evicting its head, and emits an
            // overflow gap for every newly captured frame — the ratcheting-overflow pattern
            // `runCheckpointTicker` documents, except with no way out for the rest of the
            // stream. One dropped notification cost every recording after it.
            //
            // The gap record is DURABLE and permanent: those frames are known-lost and will
            // never be re-sent, so `advanceAccountedPrefix()` can never step over them and
            // there is nothing to wait for. Accounting for them is what the watch-reported
            // branch below already does, for a hole that is no more recoverable than this one.
            //
            // Only the parts of the hole the watch has NOT already explained are the
            // receiver's to report: its own notices keep their reasons.
            for run in ctx.unaccountedRuns(upTo: first) {
                try await sink.recordGap(
                    streamId: ctx.streamId,
                    gap: GapRecord(
                        firstMissingSequence: run.first,
                        missingFrameCount: run.count,
                        firstMissingSampleIndex: run.sampleIndex,
                        origin: .sequenceSkip
                    )
                )
            }
        }

        // The return value is what the sink ACTUALLY persisted (plan Part 4.2). It is legitimately
        // shorter than `frames` — a post-RESUME spool rewind re-sends frames the sink already
        // holds, and those are durable, so contiguity below still advances over them. What is NOT
        // legitimate is the sink having nowhere to put them at all: `SegmentSink.appendFrames`
        // throws for that, which fails the connection and forces a resync rather than letting the
        // bookkeeping below checkpoint audio nothing stored.
        _ = try await sink.appendFrames(streamId: ctx.streamId, frames: batch)

        if first > ctx.contiguousNext {
            if holeAccountedByWatch {
                // The watch already reported this hole (unknown extent); now we know where it
                // ends. The lost range is accounted: contiguity resumes at this batch.
                ctx.openWatchGapFrom = nil
            }
            ctx.contiguousNext = first
            ctx.contiguousSampleIndex = message.firstSampleIndex
            ctx.forgetKnownGaps(below: first)
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
        // A notice never fixes the base (see `StreamContext.adoptBase`). Until a frame or the
        // store has fixed it, the notice is recorded and remembered, and nothing is advanced.

        // A watch gap is a claim about frames the receiver never got. Check it against what is
        // already stored before believing it. The watch's spool recycles its oldest chunk when
        // it cannot grow, and (until the matching firmware fix) recorded an overflow gap for
        // EVERY record in that chunk — including the ones it had already sent and this app had
        // already written, which merely had not been checkpoint-trimmed yet. Measured on
        // 2026-09-09: in segments where every sequence number in the range was on disk, the
        // sidecar still carried a ~30-frame "spool overflow" every 300 frames — 10% of all audio
        // drawn as missing on the waveform, in the transcript and in the day's "missing" total,
        // none of it lost. Everything below `contiguousNext` is stored or already accounted for
        // by an earlier notice, so a gap that ends there is phantom, and one that starts below
        // it is clipped to the part that is not.
        var first = message.firstMissingSequence
        var count = message.missingFrameCount
        var sampleIndex = message.firstMissingSampleIndex
        if count > 0 && ctx.baseInitialized {
            let endExclusive = first &+ count
            if endExclusive <= ctx.contiguousNext {
                phantomGapFrames &+= count
                phantomGapNotices &+= 1
                if phantomGapNotices == 1 {
                    log(
                        "ignored a watch gap notice for \(count) frame(s) from \(first) "
                            + "(reason \(message.reasonRaw)): every one of them is already stored")
                }
                await maybeSendCheckpoint(ctx)
                return
            }
            if first < ctx.contiguousNext {
                let trimmed = ctx.contiguousNext &- first
                phantomGapFrames &+= trimmed
                first = ctx.contiguousNext
                count &-= trimmed
                sampleIndex &+= UInt64(trimmed) &* ctx.frameSamples
            }
        }

        try await sink.recordGap(
            streamId: ctx.streamId,
            gap: GapRecord(
                firstMissingSequence: first,
                missingFrameCount: count,
                firstMissingSampleIndex: sampleIndex,
                origin: .watchReported(
                    reasonRaw: Int(message.reasonRaw),
                    watchDropCounter: message.watchDropCounter
                )
            )
        )

        var advancedSamples: UInt64 = 0
        if count == 0 {
            // Unknown extent: account for it when the next STREAM_DATA shows where it ends.
            ctx.openWatchGapFrom = first
        } else {
            ctx.rememberKnownGap(first: first, missingCount: count, firstSampleIndex: sampleIndex)
            if ctx.baseInitialized && first <= ctx.contiguousNext {
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
        // THE durability point. Appends are no longer fsynced one by one (that was ~7 flash writes
        // a second while streaming); the flush belongs here instead, because a CHECKPOINT is the
        // only thing that tells the watch it may free its spool. Flush first, then claim. If the
        // flush fails we must not claim anything: the watch keeps the audio and re-sends it.
        do {
            try await sink.flush()
        } catch {
            log("checkpoint skipped: flush failed (\(error))")
            if inFlightToken == token { inFlightToken = nil }
            return
        }
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
        reauthorizingAfterEnable = false
        lastPolicyResumeAtMs = nil
        inFlightToken = nil
        inFlightSinceMs = 0
        lastOutboundControlMs = 0
        ackWaiter?.complete(false)
        ackWaiter = nil
        grantedProtoVersion.value = nil
        // Everything observed belonged to the connection that just ended. Carrying it across
        // would let a reconnect inherit the old link's proof of life.
        streamEvidence.value = .none
        // Same reasoning, and it was missing: orphan activity is evidence too. `heardOrphanAudio`
        // treats anything within `orphanDataMaxAgeMs` (40 s) as current, so a dead connection's
        // orphans stayed "recent" well into the NEW one and could drive
        // `checkForAStreamWeShouldHave` into another resync — a reconnect loop feeding itself.
        //
        // Only the evidence latch is per connection. The episode is reported — once, with its
        // frames, notices and sequence range — when its stream is announced or here, whichever
        // comes first; and `orphanedFrameCount` is NOT zeroed any more: Roger's flight recorder
        // shows 27 process starts and 77 disconnects in a single day, so Diagnostics, which only
        // renders the row while the count is above zero, was reading a number that had just been
        // wiped and reported nothing for outages that cost hours.
        reportOrphanEpisode(announced: nil)
        if phantomGapNotices > 0 {
            log(
                "link down: ignored \(phantomGapNotices) watch gap notice(s) covering "
                    + "\(phantomGapFrames) frame(s) that were already stored")
        }
        phantomGapNotices = 0
        phantomGapFrames = 0
        orphanGaps.removeAll()
        lastOrphanDataAtMs = 0
    }

    private enum ReceiverSessionError: Error {
        case internalInvariant
    }

    /// First delay before re-asking a watch that refused us, then doubling. Slow on purpose: a
    /// refusal usually needs a human (turning Background Audio back on, forgetting the other
    /// receiver), so this is a safety net for when they do, not a way to hurry them.
    private static let deniedRetryBaseMs: Int64 = 60_000
    private static let deniedRetryMaxMs: Int64 = 15 * 60_000

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

    /// How long the handshake waits for an Info read of this session's own to finish before
    /// asking anyway: the link's per-operation timeout (10 s) plus slack, so a read the link has
    /// given up on is out of the way before the handshake's goes in.
    static let handshakeInfoReadWaitMs: Int64 = 12_000
    static let infoReadPollMs: Int64 = 50

    /// Unanswered verifies before the link is presumed stale and rebuilt. Three, at the 20 s
    /// verify cadence: a minute of a watch saying nothing to a direct question, which no
    /// ordinary quiet, roaming or momentary radio trouble survives.
    static let verifyMaxFailures = 3

    /// How recently audio must have arrived with nowhere to put it for that to still count as
    /// evidence. Two verify cycles, so one batch that raced a STREAM_STOP ages out on its own
    /// instead of being read as a fault.
    static let orphanDataMaxAgeMs: Int64 = 40_000

    /// Consecutive confirmations, at the verify cadence, that the watch is capturing while this
    /// app holds no stream, before the link is rebuilt. Two — about forty seconds — so the
    /// ordinary sub-second gap between one stream ending and the next beginning can never be
    /// mistaken for the deadlock, while the deadlock itself never outlives a minute.
    static let missingStreamMaxStrikes = 2

    /// First delay before rebuilding a link whose handshake threw; doubles per consecutive
    /// failure up to `handshakeRetryMaxMs`.
    public static let handshakeRetryBaseMs: Int64 = 2_000

    /// Backoff ceiling for handshake retries. Half a minute keeps a watch that comes back picked
    /// up quickly without a hot loop against one that is genuinely gone.
    public static let handshakeRetryMaxMs: Int64 = 30_000

    /// How long to wait for AUTH_RESULT before assuming the request or its answer was dropped.
    public static let authResultWaitMs: Int64 = 4_000

    /// The same wait while a human is answering the watch's consent prompt: the watch's own
    /// consent timeout plus slack, so the app never gives up before the watch does — but it does
    /// give up, because a consent whose answer is lost must not park the session either.
    public static let consentResultWaitMs: Int64 = 75_000

    /// Re-sends before the link is presumed unusable and rebuilt.
    public static let authResultMaxAttempts = 2
}

/// Short, stable words for a session state — for the log, never for the screen.
private func describe(_ state: ReceiverSessionState) -> String {
    switch state {
    case .disconnected: return "disconnected"
    case .connecting: return "connecting"
    case .connectionFailed(let kind, _): return "connectionFailed(\(kind))"
    case .authorizing: return "authorizing"
    case .pendingConsent: return "pendingConsent"
    case .pendingEnable: return "pendingEnable"
    case .denied(let raw): return "denied(\(raw))"
    case .authorized: return "authorized"
    case .streaming(let id): return "streaming(\(id))"
    case .revoked(let raw): return "revoked(\(raw))"
    }
}
