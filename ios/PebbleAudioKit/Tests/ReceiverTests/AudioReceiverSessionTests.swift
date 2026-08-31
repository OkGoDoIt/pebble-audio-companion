import Foundation
import Receiver
import SegmentStore
import Testing
import WireProtocol

// Port of `core/transport/src/commonTest/.../AudioReceiverSessionTest.kt` — all 29 cases, same
// names, on virtual time (TestClock). `settle()` is the `runCurrent()` equivalent;
// `clock.advance(by:)` is `advanceTimeBy`.

@Suite struct AudioReceiverSessionTests {

    private let receiverId: [UInt8] = (0..<32).map { UInt8($0) }
    private let streamId: UInt32 = 0x5EED_0001

    private final class Fixture {
        let link: FakeAudioGattLink
        let sink: FakeSegmentSink
        let policy: FakeReceiverPolicy
        let resumeStore: FakeResumeStore
        let session: AudioReceiverSession
        let clock: TestClock
        let sessionTask: Task<Void, Never>

        init(
            link: FakeAudioGattLink,
            sink: FakeSegmentSink,
            policy: FakeReceiverPolicy,
            resumeStore: FakeResumeStore,
            session: AudioReceiverSession,
            clock: TestClock,
            sessionTask: Task<Void, Never>
        ) {
            self.link = link
            self.sink = sink
            self.policy = policy
            self.resumeStore = resumeStore
            self.session = session
            self.clock = clock
            self.sessionTask = sessionTask
        }

        deinit {
            sessionTask.cancel()
        }

        /// Decoded control writes seen by the watch.
        func writes() -> [AudioCompanionMessage] {
            link.controlWrites.compactMap {
                if case .decoded(let message) = AudioCompanionProtocol.decodeControlIn($0) {
                    return message
                }
                return nil
            }
        }

        func checkpoints() -> [Checkpoint] { writes().compactMap { $0 as? Checkpoint } }

        func authRequests() -> [AuthRequest] { writes().compactMap { $0 as? AuthRequest } }

        func authRequest() -> AuthRequest {
            let requests = authRequests()
            precondition(requests.count == 1, "expected a single AUTH_REQUEST, got \(requests.count)")
            return requests[0]
        }

        func settle() async {
            await clock.settle()
        }

        /// Moves the BLE link and returns once the session has finished reacting to the move.
        ///
        /// `settle()` cannot see this on its own: a link-state change is delivered through the
        /// link's StateFlow and handled between suspension points the harness does not own (that
        /// flow and the connection's abort deferred), so there is no park for the ledger to wait
        /// on. Every transition does have one definite, causally-guaranteed outcome, and that is
        /// what this waits for.
        func setLink(_ linkState: LinkState) async {
            let writesBefore = link.controlWrites.count
            link.linkState.value = linkState
            switch linkState {
            case .ready:
                // The connection handshake either announces us to the watch (an ENABLE_REQUEST,
                // or the AUTH_REQUEST when the watch is already enabled) or refuses to, which it
                // reports as a denial.
                await waitFor("the session to announce itself to the watch") {
                    self.link.controlWrites.count > writesBefore
                        || self.session.state.value.deniedStatus != nil
                }
            case .connecting:
                await waitFor("the session to report Connecting") {
                    self.session.state.value == .connecting
                }
            case .disconnected:
                await waitFor("the session to report the link down") {
                    if case .connectionFailed = self.session.state.value { return true }
                    return self.session.state.value == .disconnected
                }
            }
        }

        /// Stops the session and waits for its task to finish unwinding — the exact signal that
        /// teardown (close the open segment, publish Disconnected) has completed.
        func stop() async {
            sessionTask.cancel()
            await sessionTask.value
            await settle()
        }

        private func waitFor(_ description: String, _ condition: @escaping () -> Bool) async {
            for _ in 0..<500 {
                await settle()
                if condition() { return }
            }
            Issue.record("timed out waiting for \(description)")
        }
    }

    private func startSession(
        infoBytes: [UInt8]? = nil,
        captureIntent: @escaping @Sendable () -> CaptureIntent = { .active },
        consumeEnableRequestPermission: (@Sendable () -> Bool)? = nil
    ) async -> Fixture {
        let scheduler = TestScheduler()
        let link = infoBytes.map { FakeAudioGattLink(scheduler: scheduler, infoBytes: $0) }
            ?? FakeAudioGattLink(scheduler: scheduler)
        let sink = FakeSegmentSink(scheduler: scheduler)
        let policy = FakeReceiverPolicy()
        let resumeStore = FakeResumeStore(scheduler: scheduler)
        let clock = TestClock(scheduler: scheduler)
        let session = AudioReceiverSession(
            link: link,
            sink: sink,
            policy: policy,
            resumeStore: resumeStore,
            config: ReceiverConfig(receiverId: receiverId, receiverName: "Audio Companion"),
            clock: clock,
            captureIntent: captureIntent,
            consumeEnableRequestPermission: consumeEnableRequestPermission
        )
        let task = session.start()
        await clock.settle()
        return Fixture(
            link: link, sink: sink, policy: policy, resumeStore: resumeStore,
            session: session, clock: clock, sessionTask: task
        )
    }

    @discardableResult
    private func authorize(_ fx: Fixture) async -> Int {
        await fx.setLink(.ready)
        let token = fx.authRequest().requestToken
        fx.link.pushControl(AuthResult(requestToken: token, statusRaw: 0, grantedProtoVersion: 1))
        await fx.settle()
        #expect(fx.session.state.value == .authorized)
        return token
    }

    private func streamStart(streamId: UInt32? = nil, flags: UInt32 = 0) -> StreamStart {
        StreamStart(
            protocolVersion: 1,
            streamId: streamId ?? self.streamId,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16000,
            bitRateBps: 9800,
            frameDurationMs: 20,
            startTimeMs: 1_781_000_000_000,
            startMonotonicMs: 86_400_123,
            flags: flags
        )
    }

    private func resumeStart() -> StreamStart {
        streamStart(flags: ProtocolConstants.streamStartFlagResume)
    }

    private func data(_ firstSequence: UInt32, _ frameCount: Int, frameLen: Int = 25) -> StreamData {
        StreamData(
            streamId: streamId,
            firstSequence: firstSequence,
            firstSampleIndex: UInt64(firstSequence) * 320,
            flags: 0,
            frames: (0..<frameCount).map { _ in (0..<frameLen).map { UInt8(truncatingIfNeeded: $0) } }
        )
    }

    // -------------------------------------------------------------------------------------

    @Test func happyPath_authStartDataCheckpointStop() async {
        let fx = await startSession()
        await fx.setLink(.ready)

        // AUTH_REQUEST carries our identity.
        let auth = fx.authRequest()
        #expect(auth.protoVersion == 1)
        #expect(auth.receiverId == receiverId)
        #expect(auth.name == "Audio Companion")
        #expect(fx.session.state.value == .authorizing)

        fx.link.pushControl(AuthResult(requestToken: auth.requestToken, statusRaw: 0, grantedProtoVersion: 1))
        await fx.settle()
        #expect(fx.session.state.value == .authorized)
        #expect(fx.session.grantedProtoVersion.value == 1)

        // STREAM_START opens a segment.
        fx.link.pushData(streamStart())
        await fx.settle()
        #expect(fx.session.state.value == .streaming(streamId: streamId))
        #expect(fx.sink.opens.count == 1)
        #expect(fx.sink.opens.first?.streamId == streamId)

        // First batch: appended durably, but no checkpoint yet (160 ms audio, < 500 ms elapsed).
        fx.link.pushData(data(0, 8))
        await fx.settle()
        #expect(fx.sink.appends.count == 1)
        let append = fx.sink.appends[0]
        #expect(append.first?.sequence == 0)
        #expect(append.last?.sequence == 7)
        #expect(append.last?.sampleIndex == 7 * 320)
        #expect(fx.checkpoints().isEmpty)

        // 600 ms later another batch arrives -> time-based checkpoint cadence fires.
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(8, 1))
        await fx.settle()
        #expect(fx.checkpoints().count == 1)
        let cp1 = fx.checkpoints()[0]
        #expect(cp1.streamId == streamId)
        #expect(cp1.highestContiguousSequencePersisted == 8)
        #expect(cp1.persistedSampleIndex == 9 * 320)
        fx.link.pushControl(Ack(requestToken: cp1.requestToken, statusRaw: 0))
        await fx.settle()

        // >= 2 s of appended audio triggers the audio-based cadence without any wall time passing.
        var seq: UInt32 = 9
        for _ in 0..<4 { // 4 * 32 frames * 20 ms = 2560 ms of audio
            fx.link.pushData(data(seq, 32, frameLen: 4))
            seq += 32
            await fx.settle()
        }
        #expect(fx.checkpoints().count == 2)
        let cp2 = fx.checkpoints()[1]
        #expect(cp2.highestContiguousSequencePersisted == seq - 1)
        fx.link.pushControl(Ack(requestToken: cp2.requestToken, statusRaw: 0))
        await fx.settle()
        #expect(fx.checkpoints().count == 2)

        // STREAM_STOP closes the segment and persists resume state.
        fx.link.pushData(
            StreamStop(
                streamId: streamId, reasonRaw: 1, finalSequence: seq - 1,
                finalSampleIndex: UInt64(seq) * 320, countersCrcOrZero: 0
            )
        )
        await fx.settle()
        #expect(fx.sink.closes.count == 1)
        guard case .stopped(let reasonRaw, _, _) = fx.sink.closes[0] else {
            Issue.record("expected a Stopped close, got \(fx.sink.closes[0])")
            return
        }
        #expect(reasonRaw == 1)
        #expect(fx.session.state.value == .authorized)
        let resume = fx.resumeStore.saved
        #expect(resume != nil)
        #expect(resume?.lastStreamId == streamId)
        #expect(resume?.lastContiguousSequence == seq - 1)
    }

    @Test func checkpointWriteFailureDoesNotTearDownStreamingSession() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        fx.link.pushData(data(0, 8))
        await fx.settle()
        fx.link.failControlWrites = true

        await fx.clock.advance(by: 600)
        fx.link.pushData(data(8, 1))
        await fx.settle()

        #expect(fx.session.state.value == .streaming(streamId: streamId))
        #expect(fx.sink.appends.count == 2)
        #expect(fx.checkpoints().isEmpty)

        fx.link.failControlWrites = false
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(9, 1))
        await fx.settle()

        #expect(fx.checkpoints().count == 1)
        let cp = fx.checkpoints()[0]
        #expect(cp.highestContiguousSequencePersisted == 9)
        #expect(cp.persistedSampleIndex == 10 * 320)
    }

    @Test func pendingConsentThenOk() async {
        let fx = await startSession()
        await fx.setLink(.ready)
        let token = fx.authRequest().requestToken

        fx.link.pushControl(AuthResult(requestToken: token, statusRaw: 1, grantedProtoVersion: 0))
        await fx.settle()
        #expect(fx.session.state.value == .pendingConsent)

        // The watch pushes the final result with the same token after user consent.
        fx.link.pushControl(AuthResult(requestToken: token, statusRaw: 0, grantedProtoVersion: 1))
        await fx.settle()
        #expect(fx.session.state.value == .authorized)
    }

    @Test func deniedMismatchFailsClosed() async {
        let fx = await startSession()
        await fx.setLink(.ready)
        let token = fx.authRequest().requestToken

        fx.link.pushControl(AuthResult(requestToken: token, statusRaw: 2, grantedProtoVersion: 0))
        await fx.settle()
        #expect(fx.session.state.value == .denied(statusRaw: 2))

        // No data is consumed after a denial: a (protocol-violating) stream start is ignored.
        fx.link.pushData(streamStart())
        await fx.settle()
        #expect(fx.sink.events.isEmpty)
    }

    @Test func skippedSequencesSynthesizeGap_andCheckpointStaysContiguous() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        fx.link.pushData(data(0, 8)) // contiguous 0..7
        await fx.settle()
        fx.link.pushData(data(12, 4)) // skip 8..11
        await fx.settle()

        #expect(fx.sink.gaps.count == 1)
        let gap = fx.sink.gaps[0]
        #expect(gap.firstMissingSequence == 8)
        #expect(gap.missingFrameCount == 4)
        #expect(gap.firstMissingSampleIndex == 8 * 320)
        #expect(gap.origin == .sequenceSkip)

        // Frames past the hole are persisted (durability first) but do not advance the checkpoint.
        #expect(fx.sink.appends.count == 2)
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(16, 1))
        await fx.settle()
        #expect(fx.checkpoints().count == 1)
        let cp = fx.checkpoints()[0]
        #expect(cp.highestContiguousSequencePersisted == 7, "checkpoint must be contiguous, not highest-seen")
        #expect(cp.persistedSampleIndex == 8 * 320)
    }

    @Test func explicitGapPassThrough_advancesContiguity() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        fx.link.pushData(data(0, 8))
        await fx.settle()
        fx.link.pushData(
            StreamGap(
                streamId: streamId,
                firstMissingSequence: 8,
                missingFrameCount: 4,
                firstMissingSampleIndex: 8 * 320,
                reasonRaw: 1,
                watchDropCounter: 4
            )
        )
        await fx.settle()

        #expect(fx.sink.gaps.count == 1)
        let gap = fx.sink.gaps[0]
        #expect(gap.origin == .watchReported(reasonRaw: 1, watchDropCounter: 4))
        #expect(gap.firstMissingSequence == 8)

        // The known-lost range is accounted: contiguity resumes after it, no synthetic gap.
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(12, 4))
        await fx.settle()
        #expect(fx.sink.gaps.count == 1)
        #expect(fx.checkpoints().count == 1)
        let cp = fx.checkpoints()[0]
        #expect(cp.highestContiguousSequencePersisted == 15)
        #expect(cp.persistedSampleIndex == 16 * 320)
    }

    @Test func futureExplicitGapIsAccountedWhenEarlierFramesArriveLater() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        fx.link.pushData(data(0, 8))
        await fx.settle()
        fx.link.pushData(
            StreamGap(
                streamId: streamId,
                firstMissingSequence: 12,
                missingFrameCount: 8,
                firstMissingSampleIndex: 12 * 320,
                reasonRaw: GapReason.transportReset.rawValue,
                watchDropCounter: 8
            )
        )
        await fx.settle()

        // These frames complete the prefix up to the already-reported watch gap. The receiver
        // must then advance across that known loss instead of later synthesizing a duplicate
        // 12..20 skip.
        fx.link.pushData(data(8, 4))
        await fx.settle()
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(20, 4))
        await fx.settle()

        #expect(fx.sink.gaps.count == 1)
        #expect(
            fx.sink.gaps[0].origin ==
                .watchReported(reasonRaw: Int(GapReason.transportReset.rawValue), watchDropCounter: 8)
        )
        #expect(fx.checkpoints().count == 1)
        let cp = fx.checkpoints()[0]
        #expect(cp.highestContiguousSequencePersisted == 23)
        #expect(cp.persistedSampleIndex == 24 * 320)
    }

    @Test func silenceSuppressionGapCanCheckpointWithoutRecurringQuietData() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        fx.link.pushData(data(0, 8))
        await fx.settle()
        #expect(fx.checkpoints().isEmpty)

        await fx.clock.advance(by: 600)
        fx.link.pushData(
            StreamGap(
                streamId: streamId,
                firstMissingSequence: 8,
                missingFrameCount: 100,
                firstMissingSampleIndex: 8 * 320,
                reasonRaw: GapReason.silenceSuppressed.rawValue,
                watchDropCounter: 0
            )
        )
        await fx.settle()

        #expect(fx.sink.gaps.count == 1)
        #expect(
            fx.sink.gaps[0].origin ==
                .watchReported(reasonRaw: Int(GapReason.silenceSuppressed.rawValue), watchDropCounter: 0)
        )
        #expect(fx.checkpoints().count == 1)
        let cp = fx.checkpoints()[0]
        #expect(cp.highestContiguousSequencePersisted == 107)
        #expect(cp.persistedSampleIndex == 108 * 320)
    }

    @Test func disconnectMidStream_closesInterruptedAndPersistsResume() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()
        fx.link.pushData(data(0, 8))
        await fx.settle()

        await fx.setLink(.disconnected)

        #expect(fx.sink.closes == [SegmentCloseReason.interrupted])
        #expect(fx.session.state.value == .disconnected)
        let resume = fx.resumeStore.saved
        #expect(resume != nil)
        #expect(resume?.lastStreamId == streamId)
        #expect(resume?.lastContiguousSequence == 7)
        #expect(resume?.lastSampleIndex == 8 * 320)
    }

    @Test func reconnectingClearsConnectionFailedState() async {
        let fx = await startSession()
        await fx.setLink(.connecting)

        fx.link.failureState.value = ConnectFailure(
            kind: .bluetoothUnavailable,
            detail: "Bluetooth is unavailable to this app right now."
        )
        await fx.setLink(.disconnected)

        #expect(
            fx.session.state.value == .connectionFailed(
                kind: .bluetoothUnavailable,
                detail: "Bluetooth is unavailable to this app right now."
            )
        )

        await fx.setLink(.connecting)

        #expect(fx.session.state.value == .connecting)
    }

    @Test func onlyOneRequestInFlight_checkpointWaitsForAck() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        // 2.5 s of audio -> checkpoint #1 sent (token outstanding, never acked yet).
        var seq: UInt32 = 0
        for _ in 0..<4 {
            fx.link.pushData(data(seq, 32, frameLen: 4))
            seq += 32
            await fx.settle()
        }
        #expect(fx.checkpoints().count == 1)

        // Another 2.5 s of audio while the ack is outstanding -> still only one checkpoint.
        for _ in 0..<4 {
            fx.link.pushData(data(seq, 32, frameLen: 4))
            seq += 32
            await fx.settle()
        }
        #expect(fx.checkpoints().count == 1)

        // Ack arrives -> the next append flushes the overdue checkpoint with fresh values.
        fx.link.pushControl(Ack(requestToken: fx.checkpoints()[0].requestToken, statusRaw: 0))
        await fx.settle()
        fx.link.pushData(data(seq, 1, frameLen: 4))
        seq += 1
        await fx.settle()
        #expect(fx.checkpoints().count == 2)
        #expect(fx.checkpoints()[1].highestContiguousSequencePersisted == seq - 1)
        #expect(fx.checkpoints()[1].requestToken != fx.checkpoints()[0].requestToken)
    }

    @Test func checkpointCarriesPolicyFlagsAndStorageHint() async {
        let fx = await startSession()
        await authorize(fx)
        fx.policy.flags = ProtocolConstants.receiverFlagLowStorage
        fx.policy.freeKb = 123_456
        fx.link.pushData(streamStart())
        await fx.settle()
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(0, 8))
        await fx.settle()
        #expect(fx.checkpoints().count == 1)
        let cp = fx.checkpoints()[0]
        #expect(cp.receiverFlags == ProtocolConstants.receiverFlagLowStorage)
        #expect(cp.freeStorageHintKb == 123_456)
    }

    @Test func unknownMessagesAreIgnored() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        // Unknown data id (0x9F) and unknown control id (0x3F..0x7F range) must be skipped.
        fx.link.pushDataBytes([0x9F] + [UInt8](repeating: 0, count: 8))
        fx.link.pushControlBytes([0x7F, 0x00])
        // Malformed data must not kill the session either.
        fx.link.pushDataBytes([])
        await fx.settle()

        fx.link.pushData(data(0, 8))
        await fx.settle()
        #expect(fx.sink.appends.count == 1)
        #expect(fx.session.state.value == .streaming(streamId: streamId))
    }

    @Test func revokedClosesSegmentAndStopsConsumingData() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()
        fx.link.pushData(data(0, 8))
        await fx.settle()

        fx.link.pushControl(Revoked(reasonRaw: 1))
        await fx.settle()
        #expect(fx.session.state.value == .revoked(reasonRaw: 1))
        #expect(fx.sink.closes == [SegmentCloseReason.interrupted])

        fx.link.pushData(data(8, 8))
        await fx.settle()
        #expect(fx.sink.appends.count == 1)
    }

    @Test func requestPauseWritesPauseRequestAndResolvesOnAck() async {
        let fx = await startSession()
        await authorize(fx)

        let session = fx.session
        let result = Task { await session.requestPause() }
        await fx.settle()
        let pauses = fx.writes().compactMap { $0 as? PauseRequest }
        #expect(pauses.count == 1)
        #expect(pauses.first?.reasonRaw == PauseReason.user.rawValue)

        fx.link.pushControl(Ack(requestToken: pauses.first?.requestToken ?? -1, statusRaw: 0))
        await fx.settle()
        #expect(await result.value)
    }

    @Test func requestPauseTimesOutWithoutAckAndFreesTokenSlot() async {
        let fx = await startSession()
        await authorize(fx)

        let session = fx.session
        let result = Task { await session.requestPause() }
        await fx.settle()
        await fx.clock.advance(by: 3_000)
        await fx.settle()
        #expect(await result.value == false)

        // The slot must be free again for later requests (e.g. checkpoints, resume).
        let resume = Task { await session.requestResume() }
        await fx.settle()
        let resumeWrites = fx.writes().compactMap { $0 as? ResumeRequest }
        #expect(resumeWrites.count == 1)
        fx.link.pushControl(Ack(requestToken: resumeWrites.first?.requestToken ?? -1, statusRaw: 0))
        await fx.settle()
        #expect(await resume.value)
    }

    @Test func authorizingWhileWatchPausedByPolicySendsResume() async {
        let fx = await startSession(
            infoBytes: FakeAudioGattLink.defaultInfo(serviceStateRaw: 5).encode()
        )
        await fx.setLink(.ready)
        let auth = fx.authRequest()
        fx.link.pushControl(AuthResult(requestToken: auth.requestToken, statusRaw: 0, grantedProtoVersion: 1))
        await fx.settle()

        let resumes = fx.writes().compactMap { $0 as? ResumeRequest }
        #expect(resumes.count == 1, "re-authorizing a policy-paused watch must auto-resume")
    }

    @Test func authorizingWhileUserStoppedPausesTheWatch() async {
        // Default Info state is AuthorizedIdle (2): the watch is not paused. With the user
        // intent off (e.g. a sticky service reconnected after Stop), authorization must pause
        // the watch rather than let it stream.
        let fx = await startSession(captureIntent: { .off })
        await fx.setLink(.ready)
        let auth = fx.authRequest()
        fx.link.pushControl(AuthResult(requestToken: auth.requestToken, statusRaw: 0, grantedProtoVersion: 1))
        await fx.settle()

        let pauses = fx.writes().compactMap { $0 as? PauseRequest }
        #expect(pauses.count == 1, "authorizing while the user has stopped must pause the watch")
        #expect(pauses.first?.reasonRaw == PauseReason.user.rawValue)
    }

    @Test func disabledWatchDoesNotPromptWithoutFreshStartIntent() async {
        let disabledInfo = FakeAudioGattLink.defaultInfo(
            serviceStateRaw: ServiceState.disabled.rawValue,
            flags: ProtocolConstants.infoFlagReceiverAuthorized
        )
        let fx = await startSession(
            infoBytes: disabledInfo.encode(),
            captureIntent: { .active },
            consumeEnableRequestPermission: { false }
        )
        await fx.setLink(.ready)

        let writes = fx.writes()
        #expect(writes.compactMap { $0 as? EnableRequest }.isEmpty)
        #expect(writes.compactMap { $0 as? AuthRequest }.isEmpty)
        #expect(fx.session.state.value == .denied(statusRaw: Int(AuthStatus.deniedDisabled.rawValue)))
        #expect(fx.session.state.value.deniedStatus == .deniedDisabled)
    }

    @Test func enableRequestWaitsForHumanApprovalBeforeAuth() async {
        let disabledInfo = FakeAudioGattLink.defaultInfo(
            serviceStateRaw: ServiceState.disabled.rawValue,
            flags: ProtocolConstants.infoFlagReceiverAuthorized
        )
        let armed = ArmedFlag()
        let fx = await startSession(
            infoBytes: disabledInfo.encode(),
            captureIntent: { .active },
            consumeEnableRequestPermission: { armed.consume() }
        )
        await fx.setLink(.ready)

        let enables = fx.writes().compactMap { $0 as? EnableRequest }
        #expect(enables.count == 1)
        #expect(fx.session.state.value == .pendingEnable)
        guard let enable = enables.first else { return }

        await fx.clock.advance(by: 2_500)
        await fx.settle()
        #expect(fx.authRequests().isEmpty, "human approval must not time out at 2s")

        fx.link.infoBytes = FakeAudioGattLink.defaultInfo().encode()
        fx.link.pushControl(Ack(requestToken: enable.requestToken, statusRaw: 0))
        await fx.settle()

        #expect(fx.authRequests().count == 1)
        #expect(fx.session.state.value == .authorizing)
    }

    @Test func watchPausingByPolicyAfterAuthorizationTriggersResume() async {
        // Default Info state AuthorizedIdle (2): the gated reconcile sends nothing at auth. If
        // the watch later reports a policy pause (STATE_CHANGED) while the user wants audio,
        // the safety net resumes it without depending on the pre-auth Info snapshot.
        let fx = await startSession()
        await fx.setLink(.ready)
        let auth = fx.authRequest()
        fx.link.pushControl(AuthResult(requestToken: auth.requestToken, statusRaw: 0, grantedProtoVersion: 1))
        await fx.settle()

        func resumeCount() -> Int { fx.writes().compactMap { $0 as? ResumeRequest }.count }
        #expect(resumeCount() == 0, "no reconcile write when the watch is not paused")

        fx.link.pushControl(StateChanged(serviceStateRaw: ServiceState.pausedPolicy.rawValue))
        await fx.settle()
        #expect(resumeCount() == 1, "a watch that pauses by policy after auth must be resumed")
    }

    @Test func watchPowerSavePauseDoesNotTriggerResume() async {
        let fx = await startSession()
        await fx.setLink(.ready)
        let auth = fx.authRequest()
        fx.link.pushControl(AuthResult(requestToken: auth.requestToken, statusRaw: 0, grantedProtoVersion: 1))
        await fx.settle()

        fx.link.pushControl(StateChanged(serviceStateRaw: ServiceState.pausedPowerSave.rawValue))
        await fx.settle()

        let resumeCount = fx.writes().compactMap { $0 as? ResumeRequest }.count
        #expect(resumeCount == 0, "watch-side power-save pauses must not be auto-resumed")
    }

    @Test func sessionTeardownResetsStateToDisconnected() async {
        let fx = await startSession()
        await fx.setLink(.ready)
        let auth = fx.authRequest()
        fx.link.pushControl(AuthResult(requestToken: auth.requestToken, statusRaw: 0, grantedProtoVersion: 1))
        fx.link.pushData(streamStart())
        await fx.settle()
        #expect(fx.session.state.value == .streaming(streamId: streamId))

        await fx.stop()
        #expect(
            fx.session.state.value == .disconnected,
            "a stopped session must not keep claiming it is streaming"
        )
    }

    // --- reconnect resume (Scenario 1) ----------------------------------------------------------

    @Test func resumeStreamAdoptsBaseFromFirstData_noBogusLeadingGap() async {
        let fx = await startSession()
        await authorize(fx)

        // The watch re-announces an ongoing stream after a reconnect: RESUME flag set, frames
        // continue at a high sequence rather than 0 (it never reset s_next_sequence).
        fx.link.pushData(resumeStart())
        await fx.settle()
        #expect(fx.session.state.value == .streaming(streamId: streamId))

        fx.link.pushData(data(5_000, 8))
        await fx.settle()

        // No bogus 0..5000 leading gap, and the resumed buffered frames are persisted.
        #expect(
            fx.sink.gaps.isEmpty,
            "a RESUME stream must adopt the first frame's sequence as the base, not synthesize a gap"
        )
        #expect(fx.sink.appends.count == 1)
        #expect(fx.sink.appends.first?.first?.sequence == 5_000)

        // The checkpoint advances from the adopted base (a sequence-0 assumption would stall at 0).
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(5_008, 1))
        await fx.settle()
        #expect(fx.checkpoints().count == 1)
        #expect(fx.checkpoints()[0].highestContiguousSequencePersisted == 5_008)
    }

    @Test func resumeReannounceForLiveStreamDoesNotSupersedeOpenSegment() async {
        let fx = await startSession()
        await authorize(fx)

        fx.link.pushData(streamStart())
        await fx.settle()
        fx.link.pushData(data(0, 4))
        await fx.settle()

        // Mid-connection re-announce of the same stream (e.g. a liveness-watchdog revival on
        // the watch): RESUME flag, same id, and the phone never saw the link drop. The open
        // segment must be continued, not closed as superseded — a superseded segment can never
        // reattach.
        fx.link.pushData(resumeStart())
        await fx.settle()
        fx.link.pushData(data(4, 2))
        await fx.settle()

        #expect(
            fx.sink.closes.isEmpty,
            "an in-connection RESUME of the live stream must not close the open segment: \(fx.sink.closes)"
        )
        #expect(fx.session.state.value == .streaming(streamId: streamId))
        #expect(fx.sink.opens.count == 2, "the sink still sees the re-announce")
    }

    @Test func freshStreamStartStillSupersedesOpenSegment() async {
        let fx = await startSession()
        await authorize(fx)

        fx.link.pushData(streamStart())
        await fx.settle()
        fx.link.pushData(data(0, 4))
        await fx.settle()

        // A genuinely new stream (different id, no RESUME) replaces the open one, as before.
        fx.link.pushData(streamStart(streamId: streamId + 1))
        await fx.settle()

        #expect(fx.sink.closes == [SegmentCloseReason.superseded])
        #expect(fx.session.state.value == .streaming(streamId: streamId + 1))
    }

    @Test func resumeStreamWithLeadingOverflowGap_recordsLossOnceAndAdoptsBase() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(resumeStart())
        await fx.settle()

        // The first thing resent is the overflow gap the watch recorded while the buffer filled.
        fx.link.pushData(
            StreamGap(
                streamId: streamId,
                firstMissingSequence: 5_000,
                missingFrameCount: 10,
                firstMissingSampleIndex: 5_000 * 320,
                reasonRaw: GapReason.spoolOverflow.rawValue,
                watchDropCounter: 10
            )
        )
        await fx.settle()
        fx.link.pushData(data(5_010, 8))
        await fx.settle()

        // Exactly one gap (the real loss), then the buffered audio attaches contiguously after
        // it.
        #expect(fx.sink.gaps.count == 1)
        let gap = fx.sink.gaps[0]
        #expect(gap.firstMissingSequence == 5_000)
        #expect(gap.missingFrameCount == 10)
        #expect(fx.sink.appends.count == 1)
        #expect(fx.sink.appends.first?.first?.sequence == 5_010)
    }

    // --- keepalive / stale-link recovery (Scenario 2) -------------------------------------------

    @Test func keepalivePingsIdleWatchAndAckKeepsLinkAlive() async {
        let fx = await startSession()
        await authorize(fx) // authorized, but the watch is not streaming to us

        // After one keepalive interval with no inbound traffic, a RECEIVER_HEALTH ping goes out
        // — this is what re-arms the watch's liveness watchdog and revives a presumed-gone
        // watch. (6 s lands after the 5 s ping but before its 2 s ACK-wait would expire.)
        await fx.clock.advance(by: 6_000)
        await fx.settle()
        let health = fx.writes().compactMap { $0 as? ReceiverHealth }
        #expect(health.count == 1, "an idle authorized session must ping the watch")

        // The watch ACKs: the link is healthy, so no forced reconnect.
        fx.link.pushControl(Ack(requestToken: health.first?.requestToken ?? -1, statusRaw: 0))
        await fx.settle()
        #expect(fx.link.resyncCount == 0)
    }

    @Test func unansweredKeepalivePingsForceResync() async {
        let fx = await startSession()
        await authorize(fx)

        // The link is half-dead: writes fail, so pings are never acknowledged. After the
        // failure budget the session forces a fresh GATT connection instead of sitting "ready"
        // forever.
        fx.link.failControlWrites = true
        await fx.clock.advance(by: 5_000 * 3)
        await fx.settle()
        #expect(fx.link.resyncCount >= 1, "a stale link must be force-reconnected")
    }

    // --- the four-hour blackout: a wedged control channel ---------------------------------------

    /// CHECKPOINT is fire-and-forget and holds the single in-flight request slot until the watch
    /// ACKs it. One dropped ACK used to wedge that slot for the rest of the connection, so the app
    /// never sent the watch another control message — and CHECKPOINT is the ONLY control message
    /// an actively-streaming session sends, so the watch's 15 s liveness watchdog then stopped
    /// capture. Four hours of silence, with the phone still believing it was connected.
    @Test func unackedCheckpointDoesNotWedgeTheControlChannelForever() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        // First checkpoint goes out on the time-based cadence...
        fx.link.pushData(data(0, 8))
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(8, 1))
        await fx.settle()
        #expect(fx.checkpoints().count == 1)

        // ...and the watch never ACKs it (a dropped control notification). Audio keeps arriving.
        for batch in 0..<6 {
            await fx.clock.advance(by: 1_000)
            fx.link.pushData(data(9 + UInt32(batch), 1))
            await fx.settle()
        }

        // The slot is reclaimed, so checkpointing resumes: the watch can free its spool, and —
        // far more important — the watch keeps hearing from us inside its 15 s window.
        #expect(
            fx.checkpoints().count > 1,
            "an unanswered checkpoint must not stop the app talking to the watch"
        )
        let latest = fx.checkpoints().last
        #expect(latest?.highestContiguousSequencePersisted == 14)
    }

    /// The watch frees spool only on CHECKPOINT, so checkpointing has to run on a clock. Sending
    /// it only in response to arriving data made the credit self-starving: a full spool means no
    /// data, no data meant no checkpoint, and no checkpoint meant the spool stayed full — the
    /// ratcheting overflow gaps the real device shows, 103 frames apart, each one bigger.
    @Test func checkpointIsFlushedOnAClockWhenTheWatchStopsSending() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        // Audio arrives, then the watch goes quiet (its spool is full and untrimmed). Too little
        // audio for the size-based cadence, and no further append to drive the data path.
        fx.link.pushData(data(0, 8))
        await fx.settle()
        #expect(fx.checkpoints().isEmpty)

        await fx.clock.advance(by: 3_000)
        await fx.settle()
        #expect(
            fx.checkpoints().count == 1,
            "the watch cannot free its spool until we checkpoint; that must not wait for data"
        )
        #expect(fx.checkpoints().first?.highestContiguousSequencePersisted == 7)

        // Idempotent: nothing new persisted, so the ticker stays silent rather than spamming.
        fx.link.pushControl(Ack(requestToken: fx.checkpoints()[0].requestToken, statusRaw: 0))
        await fx.clock.advance(by: 5_000)
        await fx.settle()
        #expect(fx.checkpoints().count == 1)
    }

    /// The keepalive's idle test has to be on OUTBOUND traffic. Inbound STREAM_DATA is no evidence
    /// the watch still believes in us, so a steady audio flow must not suppress the ping when we
    /// have gone silent toward the watch.
    @Test func streamingInboundDataDoesNotSuppressTheKeepalive() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        // Frames arrive continuously for well over a keepalive interval, but nothing we send can
        // reach the watch (its ACKs are gone and its ATT writes fail) — the half-dead link.
        fx.link.failControlWrites = true
        for batch in 0..<14 {
            await fx.clock.advance(by: 1_000)
            fx.link.pushData(data(UInt32(batch), 1))
            await fx.settle()
        }

        // The session noticed it was talking into a void and forced a fresh GATT session, rather
        // than sitting "streaming" behind a watch that had already stopped capturing.
        #expect(
            fx.link.resyncCount >= 1,
            "inbound audio must not mask a control channel that stopped reaching the watch"
        )
    }
}

/// One-shot arming flag for the enable-request permission (the Kotlin test's captured `var`).
private final class ArmedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true

    func consume() -> Bool {
        lock.withLock {
            let wasArmed = armed
            armed = false
            return wasArmed
        }
    }
}
