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
                    if case .connectionFailed = self.session.state.value { return true }
                    return self.link.controlWrites.count > writesBefore
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

        /// Wait for any condition the caller can express. Used by the handshake-failure cases,
        /// whose definite outcome is a state rather than a control write.
        func waitUntil(_ description: String, _ condition: @escaping () -> Bool) async {
            await waitFor(description, condition)
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
        consumeEnableRequestPermission: (@Sendable () -> Bool)? = nil,
        phoneMediaProbe: (@Sendable () -> UInt8)? = nil
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
            // The cadence tests below drive the MECHANISM on a 2 s / 500 ms schedule, which is
            // the one the KMP contract was written against. The production defaults are slower
            // (see `ReceiverConfig.checkpointAudioMs`) and are pinned by their own test.
            config: ReceiverConfig(
                receiverId: receiverId, receiverName: "Audio Companion",
                checkpointAudioMs: 2_000, checkpointMinIntervalMs: 500
            ),
            clock: clock,
            captureIntent: captureIntent,
            consumeEnableRequestPermission: consumeEnableRequestPermission,
            phoneMediaProbe: phoneMediaProbe
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

    // A failed disk write used to park the receiver forever, with the UI still saying "Recording".
    //
    // Every durable write in SegmentStore throws — the file append, the fsync, the atomic sidecar
    // write — and `SegmentStore.appendFrames` also throws deliberately for `noOpenSegment` and
    // `streamMismatch`. That error propagated to `consumeData`'s catch, which completed the
    // connection abort. `runConnection` then returned with `handshakeError == nil`, so it drained
    // all six per-connection tasks and scheduled NOTHING: Core Bluetooth still called the link
    // `.ready`, and `StateSubject` does not re-emit an equal value, so the session's `for await`
    // waited on an element that could never arrive. Zero tasks, zero timers, forever, from one
    // bad write.
    @Test func aSinkFailureRebuildsTheLinkInsteadOfParkingTheSession() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()
        #expect(fx.session.state.value == .streaming(streamId: streamId))

        let resyncsBefore = fx.link.resyncCount
        fx.sink.failAppends = true
        fx.link.pushData(data(0, 8))
        await fx.settle()

        // The session must not still be claiming it is recording into a store that just refused.
        #expect(fx.session.state.value != .streaming(streamId: streamId))

        // And the recovery has to actually run: back off, then ask the link for a fresh session.
        await fx.clock.advance(by: 60_000)
        await fx.settle()
        #expect(
            fx.link.resyncCount > resyncsBefore,
            "a sink failure must rebuild the link, not leave it parked at .ready with no tasks"
        )
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

    // A silent discontinuity is DURABLY accounted, so the checkpoint moves past it.
    //
    // Contiguity used to freeze here for the rest of the stream, and the damage was on the watch:
    // `highestContiguousSequencePersisted` is its only instruction to free spool, so a frozen
    // watermark meant the spool never trimmed again. It saturated, began evicting its head, and
    // emitted an overflow gap for every newly captured frame. One dropped notification cost every
    // recording after it.
    //
    // The checkpoint is still CONTIGUOUS rather than highest-seen — frames past an UNaccounted
    // hole still wait (see `futureExplicitGapIsAccountedWhenEarlierFramesArriveLater`). The
    // difference is that a `.sequenceSkip` gap record is permanent: those frames are known-lost
    // and will never be re-sent, so there is nothing left to wait for.
    @Test func aSilentDiscontinuityIsAccountedSoTheWatchCanKeepTrimming() async {
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

        // Frames past the hole are persisted (durability first) AND the watermark advances over
        // the recorded gap, so the watch is told it may free everything up to here.
        #expect(fx.sink.appends.count == 2)
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(16, 1))
        await fx.settle()
        #expect(fx.checkpoints().count == 1)
        let cp = fx.checkpoints()[0]
        #expect(
            cp.highestContiguousSequencePersisted == 16,
            "a durable sequence-skip gap must not freeze the watch's spool trim point"
        )
        #expect(cp.persistedSampleIndex == 17 * 320)
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

    @Test func watchAskingWhetherThePhoneIsPlayingGetsTheAudioSessionsAnswer() async {
        // BookPlayer publishes "playing" while paused, so the watch asks the phone's audio system.
        let flags = PhoneMediaState.flagChecked | PhoneMediaState.flagOtherAudio
        let fx = await startSession(phoneMediaProbe: { flags })
        await authorize(fx)

        fx.link.pushControl(PhoneMediaQuery())
        await fx.settle()
        let answers = fx.writes().compactMap { $0 as? PhoneMediaState }
        #expect(answers.count == 1)
        #expect(answers.first?.flags == flags)
    }

    @Test func museSetupTrafficReachesItsHandlerAndRequestsReportTheWatchsAck() async {
        // Pairing Muse through the watch (Section 4.3) needs every relayed value in order, and
        // needs to tell a busy watch (send again) from a refusal.
        let fx = await startSession()
        await authorize(fx)
        let received = MuseInboundBox()
        await fx.session.setMuseSetupHandler { received.append($0) }

        let rx = MuseSetupRx(seq: 0, flags: 0, data: Array("{}".utf8))
        let opened = MuseSetupEvent(eventRaw: MuseSetupEventKind.opened.rawValue, detail: 0, mtu: 0, secondsLeft: 300)
        fx.link.pushControl(opened)
        fx.link.pushControl(rx)
        await fx.settle()
        #expect(received.values == [.event(opened), .rx(rx)])

        let session = fx.session
        let reply = Task { await session.sendMuseSetup { MuseSetupTx(requestToken: $0, data: [1, 2, 3]).encode() } }
        await fx.settle()
        guard let tx = fx.writes().compactMap({ $0 as? MuseSetupTx }).last else {
            Issue.record("no MUSE_SETUP_TX written")
            return
        }
        #expect(tx.data == [1, 2, 3])
        fx.link.pushControl(Ack(requestToken: tx.requestToken, statusRaw: AckStatus.busy.rawValue))
        await fx.settle()
        #expect(await reply.value == .busy)
    }

    @Test func aMarkedMomentIsPlacedOnTheRecordingsOwnClock() async {
        // The watch's clock drifts from its sample count over a long stream, and the transcript
        // is on the sample count: a mark naming the open stream is placed by its samples.
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()
        let received = MomentBox()
        await fx.session.setMomentHandler { received.append($0); return true }

        fx.link.pushControl(
            MomentMark(
                markId: 3, flags: MomentMark.flagRecording, streamId: streamId,
                sampleIndex: 16_000 * 90, wallMs: 1_781_000_095_000))
        // Marked with nothing recording: the watch's clock is all there is.
        fx.link.pushControl(
            MomentMark(markId: 4, flags: 0, streamId: 0, sampleIndex: 0, wallMs: 1_781_000_200_000))
        // A watch whose clock was never set: placed at its arrival.
        fx.link.pushControl(
            MomentMark(markId: 5, flags: 0, streamId: 0, sampleIndex: 0, wallMs: 1_262_304_000_000))
        await fx.settle()

        let moments = received.values
        #expect(moments.count == 3)
        #expect(moments.first?.wallMs == 1_781_000_090_000)
        #expect(moments.first?.onAudioClock == true)
        #expect(moments.first?.id == "watch-1781000095000-3")
        #expect(moments.dropFirst().first?.wallMs == 1_781_000_200_000)
        #expect(moments.dropFirst().first?.onAudioClock == false)
        #expect(moments.last?.wallMs == moments.last?.receivedAtMs)
        #expect(fx.writes().compactMap { $0 as? MomentSaved }.isEmpty) // legacy watch
    }

    @Test func onlyDurablySavedMomentsAreReceiptedAndDuplicateRetriesAreReceiptedAgain() async {
        let fx = await startSession(infoBytes: FakeAudioGattLink.defaultInfo(
            watchCapabilities: ProtocolConstants.capabilityDurableMoments).encode())
        await authorize(fx)
        let mark = MomentMark(markId: 3, flags: 0, streamId: 0, sampleIndex: 0, wallMs: 1_781_000_095_000)
        let received = MomentBox()
        await fx.session.setMomentHandler { received.append($0); return false }
        fx.link.pushControl(mark)
        await fx.waitUntil("failed persistence attempt") { received.values.count == 1 }
        await fx.settle()
        #expect(fx.writes().compactMap { $0 as? MomentSaved }.isEmpty)
        await fx.session.setMomentHandler { _ in true }
        for count in 1...2 {
            fx.link.pushControl(mark)
            await fx.waitUntil("durable receipt") { fx.writes().compactMap { $0 as? MomentSaved }.count == count }
            let receipt = fx.writes().compactMap { $0 as? MomentSaved }.last!
            #expect(receipt.markId == mark.markId)
            #expect(receipt.wallMs == mark.wallMs)
            fx.link.pushControl(Ack(requestToken: receipt.requestToken, statusRaw: 0))
            await fx.settle()
        }
    }

    @Test func withoutAProbeThePhoneMediaQueryGoesUnanswered() async {
        // The watch then falls back to the media service alone.
        let fx = await startSession()
        await authorize(fx)

        fx.link.pushControl(PhoneMediaQuery())
        await fx.settle()
        #expect(fx.writes().compactMap { $0 as? PhoneMediaState }.isEmpty)
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

    /// A handshake that throws used to be the quiet end of the session — and it is the terminal
    /// sink for every automatic recovery here, because each of them recovers by asking for a
    /// fresh `.ready` and landing back in the handshake. Nothing must be able to park it: the
    /// link stays `.ready` from Core Bluetooth's point of view, so no further link-state element
    /// is ever emitted for `run()` to react to.
    @Test func aHandshakeThatThrowsIsRetriedInsteadOfParkingTheSession() async {
        let fx = await startSession()
        fx.link.failInfoReads = true
        await fx.setLink(.ready)

        // It says so plainly rather than sitting on a stale state.
        await fx.waitUntil("the handshake failure to be published") {
            if case .connectionFailed = fx.session.state.value { return true }
            return false
        }
        #expect(fx.link.resyncCount == 0, "the retry is backed off, not immediate")

        await fx.clock.advance(by: AudioReceiverSession.handshakeRetryBaseMs)
        await fx.settle()
        #expect(fx.link.resyncCount == 1, "a failed handshake must rebuild the link")
    }

    /// ...and it is never given up on, however many times it fails. This is a background-audio
    /// product: latching off automatic recovery recreates exactly the park being escaped.
    @Test func repeatedHandshakeFailuresAreNeverGivenUpOn() async {
        let fx = await startSession()
        fx.link.failInfoReads = true
        for attempt in 1...4 {
            await fx.setLink(.disconnected)
            await fx.waitUntil("the link to settle at disconnected") {
                fx.session.state.value == .disconnected
            }
            await fx.setLink(.ready)
            await fx.waitUntil("handshake \(attempt) to fail") {
                if case .connectionFailed = fx.session.state.value { return true }
                return false
            }
            await fx.clock.advance(by: AudioReceiverSession.handshakeRetryMaxMs)
            await fx.settle()
            #expect(fx.link.resyncCount == attempt, "attempt \(attempt) must still retry")
        }
    }

    /// AUTH_REQUEST was fire-and-forget, and the watch's reply is an unacknowledged notification
    /// the firmware never retries. One dropped AUTH_RESULT left the session at `.authorizing`
    /// with the request token held and every child task idle behind its `authorized` guard.
    @Test func anAuthRequestWithNoAnswerIsResentThenTheLinkIsRebuilt() async {
        let fx = await startSession()
        await fx.setLink(.ready)
        #expect(fx.authRequests().count == 1)

        for _ in 0...AudioReceiverSession.authResultMaxAttempts {
            await fx.clock.advance(by: AudioReceiverSession.authResultWaitMs)
            await fx.settle()
        }

        let requests = fx.authRequests()
        #expect(requests.count == AudioReceiverSession.authResultMaxAttempts + 1)
        #expect(
            Set(requests.map(\.requestToken)).count == requests.count,
            "each re-send must carry a fresh token so a late answer cannot be mistaken for it"
        )
        #expect(fx.link.resyncCount >= 1, "a watch that never answers AUTH must be reconnected")
    }

    /// The watch had Background Audio off, so we never sent AUTH_REQUEST at all and the
    /// connection has been parked with `authorized == false` ever since. The user then turns it
    /// on at the wrist. The watch says so — and the app used to read that and discard it, leaving
    /// a live connection that would never authorize.
    @Test func enablingBackgroundAudioOnTheWatchReAuthorizesInPlace() async {
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
        #expect(fx.session.state.value.deniedStatus == .deniedDisabled)
        #expect(fx.authRequests().isEmpty)

        fx.link.pushControl(StateChanged(serviceStateRaw: ServiceState.idle.rawValue))
        await fx.settle()

        #expect(fx.authRequests().count == 1, "the watch enabling audio must re-drive AUTH")
        #expect(
            fx.writes().compactMap { $0 as? EnableRequest }.isEmpty,
            "recovery must never prompt the watch; only an explicit Start may do that"
        )
        #expect(fx.session.state.value == .authorizing)
        #expect(fx.link.resyncCount == 0, "the live connection is reused, not rebuilt")
    }

    /// A policy pause the watch cannot leave on its own. CHECKPOINT is the only carrier of the
    /// storage flags that asserted it, and a paused watch sends no audio, so no checkpoint is
    /// ever produced — and the watch's state does not change again, so there is no second
    /// STATE_CHANGED either. Clearing the condition has to be enough on its own.
    @Test func aPolicyPauseIsReleasedByTheVerifyReadWhenStorageRecovers() async {
        let fx = await startSession()
        await authorize(fx)
        fx.policy.flags = ProtocolConstants.receiverFlagLowStorage

        fx.link.pushControl(StateChanged(serviceStateRaw: ServiceState.pausedPolicy.rawValue))
        await fx.settle()
        func resumes() -> Int { fx.writes().compactMap { $0 as? ResumeRequest }.count }
        #expect(resumes() == 0, "we still have a storage reason to hold the pause")

        // Space is recovered. Nothing on the wire announces that — only the next time the watch
        // tells us what it is doing can the app notice, and the verify read is that moment.
        fx.policy.flags = 0
        fx.link.infoBytes = FakeAudioGattLink.defaultInfo(
            serviceStateRaw: ServiceState.pausedPolicy.rawValue
        ).encode()
        await fx.clock.advance(by: 20_000)
        await fx.settle()

        #expect(resumes() >= 1, "a pause we no longer have a reason for must be released")
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

    // The watch's spool recycles its oldest chunk when it cannot grow and, until the matching
    // firmware fix, reported an overflow gap for every record in it — including frames it had
    // already sent and this app had already stored. In segments where every sequence number was
    // on disk, the sidecars still carried a ~30-frame "overflow" every 300 frames (2026-09-09).
    // A gap that ends inside what is already stored is phantom and must not be persisted.
    @Test func watchGapOverAudioAlreadyStoredIsNotPersisted() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()
        fx.link.pushData(data(0, 32))
        fx.link.pushData(data(32, 8))
        await fx.settle()
        #expect(fx.sink.appends.count == 2)

        fx.link.pushData(
            StreamGap(
                streamId: streamId,
                firstMissingSequence: 8,
                missingFrameCount: 30,
                firstMissingSampleIndex: 8 * 320,
                reasonRaw: GapReason.spoolOverflow.rawValue,
                watchDropCounter: 30
            )
        )
        await fx.settle()
        #expect(fx.sink.gaps.isEmpty, "frames 8..37 are on disk; the notice describes no loss")

        // Contiguity is untouched: the next frames attach with no synthesized skip either.
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(40, 4))
        await fx.settle()
        #expect(fx.sink.gaps.isEmpty)
        #expect(fx.checkpoints().last?.highestContiguousSequencePersisted == 43)
    }

    // ...and a notice that straddles the stored prefix keeps only the part that is not stored.
    @Test func watchGapPartlyOverStoredAudioIsClippedToTheUnstoredTail() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()
        fx.link.pushData(data(0, 10))
        await fx.settle()

        fx.link.pushData(
            StreamGap(
                streamId: streamId,
                firstMissingSequence: 6,
                missingFrameCount: 8,  // 6..13, of which 6..9 are stored
                firstMissingSampleIndex: 6 * 320,
                reasonRaw: GapReason.spoolOverflow.rawValue,
                watchDropCounter: 8
            )
        )
        await fx.settle()
        #expect(fx.sink.gaps.count == 1)
        let gap = fx.sink.gaps[0]
        #expect(gap.firstMissingSequence == 10)
        #expect(gap.missingFrameCount == 4)
        #expect(gap.firstMissingSampleIndex == 10 * 320)
        #expect(gap.origin == .watchReported(reasonRaw: Int(GapReason.spoolOverflow.rawValue), watchDropCounter: 8))

        // The clipped loss is accounted: 14 attaches after it with no synthesized skip.
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(14, 2))
        await fx.settle()
        #expect(fx.sink.gaps.count == 1)
        #expect(fx.checkpoints().last?.highestContiguousSequencePersisted == 15)
    }

    // On every re-authorization the watch drained its pending gap notices 30-150 ms BEFORE the
    // re-announced STREAM_START reached us, and each one was dropped as "no open stream" — the
    // record is gone from the watch the moment it is sent, so the reason was lost for good. A
    // notice for a stream we have not heard of is held and applied when that stream opens.
    @Test func gapNoticeArrivingBeforeStreamStartIsAppliedWhenTheStreamOpens() async {
        let fx = await startSession()
        await authorize(fx)

        fx.link.pushData(
            StreamGap(
                streamId: streamId,
                firstMissingSequence: 5_000,
                missingFrameCount: 104,
                firstMissingSampleIndex: 5_000 * 320,
                reasonRaw: GapReason.spoolOverflow.rawValue,
                watchDropCounter: 104
            )
        )
        await fx.settle()
        #expect(fx.sink.gaps.isEmpty, "nothing to attach it to yet")
        #expect(fx.session.state.value == .authorized)

        fx.link.pushData(resumeStart())
        await fx.settle()
        #expect(fx.session.state.value == .streaming(streamId: streamId))
        #expect(fx.sink.gaps.count == 1, "the held notice lands on the stream it named")
        let gap = fx.sink.gaps[0]
        #expect(gap.firstMissingSequence == 5_000)
        #expect(gap.missingFrameCount == 104)
        #expect(gap.origin == .watchReported(reasonRaw: Int(GapReason.spoolOverflow.rawValue), watchDropCounter: 104))

        // The buffered audio after the loss attaches contiguously: one gap, and it has a reason.
        fx.link.pushData(data(5_104, 8))
        await fx.settle()
        #expect(fx.sink.gaps.count == 1)
        #expect(fx.sink.appends.first?.first?.sequence == 5_104)
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

    /// The blackout the keepalive cannot see. While we believe a stream is open the checkpoint
    /// ticker keeps sending — every 2 s of silence, by design, because that is the watch's only
    /// spool credit — so `lastOutboundControlMs` never goes stale and the keepalive's ping (and
    /// therefore its resync) never fires. A watch that has stopped answering entirely then sat
    /// behind a link the platform still called connected, with the status card the only thing
    /// that knew and nothing anywhere trying to fix it. Roger's was eleven minutes.
    @Test func aWatchThatStopsAnsweringVerifiesGetsTheLinkRebuilt() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        fx.link.pushData(data(0, 4))
        await fx.settle()

        // The watch goes silent — no audio, and now no answer to a direct question either. Our
        // own control traffic keeps flowing (the checkpoint ticker), which is exactly why the
        // keepalive stays quiet throughout.
        fx.link.failInfoReads = true
        for _ in 0..<3 {
            await fx.clock.advance(by: 20_000)
            await fx.settle()
        }

        #expect(
            fx.link.resyncCount >= 1,
            "a watch answering nothing for a minute is a stale link, not a quiet room"
        )
    }

    /// THE REPORTED DEADLOCK. The app is authorized, the watch says it is Recording, and no
    /// STREAM_START ever arrives — so the app holds no stream, drops every frame the watch sends,
    /// never checkpoints (so the watch's spool overflows and the audio is really lost), and says
    /// "Authorized and ready. Waiting for the watch to start streaming." indefinitely.
    ///
    /// Nothing used to notice. The other verify arm requires an open stream; the keepalive is
    /// satisfied because a watch in this state answers every ping. Only a person toggling
    /// Background Audio on the watch ended it.
    @Test func aWatchRecordingIntoAVoidGetsTheLinkRebuilt() async {
        let fx = await startSession()
        await authorize(fx)
        // The watch's own answer is the discriminator, and it says it is capturing.
        fx.link.infoBytes = FakeAudioGattLink.defaultInfo(
            serviceStateRaw: ServiceState.streaming.rawValue
        ).encode()
        await fx.settle()
        #expect(fx.session.state.value == .authorized)

        for _ in 0..<3 {
            await fx.clock.advance(by: 20_000)
            await fx.settle()
        }

        #expect(
            fx.link.resyncCount >= 1,
            "a watch that is recording while we hold no stream must force a fresh session"
        )
    }

    /// The mirror image, which must NOT resync: the watch is authorized and simply not capturing.
    /// That is the ordinary idle link — paused, Background Audio off, or between recordings — and
    /// rebuilding it every forty seconds would be a permanent reconnect loop.
    @Test func anIdleWatchWithNoStreamIsNotAFault() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.infoBytes = FakeAudioGattLink.defaultInfo(
            serviceStateRaw: ServiceState.authorizedIdle.rawValue
        ).encode()
        await fx.settle()

        // A healthy idle watch answers the keepalive, so only the no-stream arm is under test.
        var acked = 0
        for _ in 0..<130 {
            await fx.clock.advance(by: 1_000)
            await fx.settle()
            let pings = fx.writes().compactMap { $0 as? ReceiverHealth }
            for ping in pings.dropFirst(acked) {
                fx.link.pushControl(Ack(requestToken: ping.requestToken, statusRaw: 0))
            }
            acked = pings.count
            await fx.settle()
        }

        #expect(fx.link.resyncCount == 0, "an idle watch is not a fault")
        #expect(fx.session.state.value == .authorized)
    }

    /// Audio arriving for a stream we never learned about is the loudest possible proof of the
    /// deadlock: the watch is spending battery encoding and sending, and every frame goes on the
    /// floor. It must be counted as loss, must NOT refresh the recording evidence, and must force
    /// a fresh session even if the watch's Info read never resolves.
    @Test func audioWithNoStreamToAttachItIsCountedAndForcesARebuild() async {
        let fx = await startSession()
        await authorize(fx)
        // The watch says nothing at all when asked; the orphaned audio has to carry the case.
        fx.link.failInfoReads = true

        fx.link.pushData(data(0, 4))
        await fx.settle()
        #expect(fx.session.orphanedFrameCount.value == 4)
        #expect(
            fx.session.streamEvidence.value.lastAudioAtMs == nil,
            "audio we threw away is not evidence that recording is working"
        )
        #expect(fx.sink.events.isEmpty, "nothing may be stored without a stream")

        for _ in 0..<3 {
            await fx.clock.advance(by: 20_000)
            await fx.settle()
            fx.link.pushData(data(4, 2))
            await fx.settle()
        }

        #expect(fx.link.resyncCount >= 1, "audio with nowhere to go must rebuild the link")
    }

    /// ...and the mirror image, which must NOT resync: a quiet room. The watch answers every
    /// verify with `streaming`, so the silence is voice-activity suppression and the link is
    /// fine. Rebuilding it would interrupt a recording for nothing.
    @Test func aQuietRoomNeverRebuildsTheLink() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        fx.link.pushData(data(0, 4))
        fx.link.infoBytes = FakeAudioGattLink.defaultInfo(
            serviceStateRaw: ServiceState.streaming.rawValue
        ).encode()
        await fx.settle()

        // A healthy watch answers everything we send it, including the idle keepalive pings the
        // checkpoint ticker stops suppressing once there is nothing new to checkpoint. Stepped
        // a second at a time so those ACKs land inside the ping's own wait, the way a real
        // watch's would.
        var acked = 0
        for _ in 0..<130 {
            await fx.clock.advance(by: 1_000)
            await fx.settle()
            let pings = fx.writes().compactMap { $0 as? ReceiverHealth }
            for ping in pings.dropFirst(acked) {
                fx.link.pushControl(Ack(requestToken: ping.requestToken, statusRaw: 0))
            }
            acked = pings.count
            await fx.settle()
        }

        #expect(fx.link.resyncCount == 0, "suppressed silence is not a fault")
        #expect(fx.session.streamEvidence.value.watchReportedStreaming)
    }

    // MARK: - Evidence behind the `.streaming` latch

    /// Streaming, then silence — and the watch, asked, says it is still capturing. This is
    /// voice-activity silence: the watch has stopped its drain timer and will send nothing at all
    /// until audio resumes. The claim must survive it intact, refreshed by the answer rather than
    /// held up by the latch.
    @Test func suppressedSilenceKeepsTheClaimAliveByAskingTheWatch() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        // From here the watch is suppressing silence: its Info reports Streaming, and not one
        // byte of audio arrives for ten minutes.
        fx.link.infoBytes = FakeAudioGattLink.defaultInfo(
            serviceStateRaw: ServiceState.streaming.rawValue
        ).encode()
        let readsBefore = fx.link.infoReads
        await fx.clock.advance(by: 10 * 60 * 1_000)

        #expect(
            fx.link.infoReads > readsBefore,
            "data silence must make the session ask the watch, not guess")
        #expect(fx.session.state.value == .streaming(streamId: streamId))
        let verdict = fx.session.streamEvidence.value.verdict(nowMs: fx.clock.nowMs)
        #expect(
            verdict == .watchSaysStreaming,
            "ten minutes of suppressed silence is quiet, and must never be demoted")
        #expect(verdict.supportsRecording)
    }

    /// While audio is flowing there is nothing to ask about, and the watch is not disturbed.
    @Test func aHealthyStreamIsNeverInterrogated() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()
        let readsAfterHandshake = fx.link.infoReads

        // Two minutes of ordinary streaming, well past the silence trigger, one batch a second.
        for batch in 0..<120 {
            await fx.clock.advance(by: 1_000)
            fx.link.pushData(data(UInt32(batch), 1))
            await fx.settle()
        }

        #expect(fx.link.infoReads == readsAfterHandshake, "arriving audio is its own evidence")
        #expect(
            fx.session.streamEvidence.value.verdict(nowMs: fx.clock.nowMs) == .hearingAudio)
    }

    /// The watch's liveness watchdog tripped: it stopped capturing and dropped to AuthorizedIdle,
    /// and the STATE_CHANGED that would have said so never reached us. Nothing in the session
    /// state changes — the latch is exactly as it was — so only the re-verify can catch this.
    @Test func aWatchThatStoppedWithoutSayingSoIsCaughtByTheReVerify() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        fx.link.infoBytes = FakeAudioGattLink.defaultInfo(
            serviceStateRaw: ServiceState.authorizedIdle.rawValue
        ).encode()
        await fx.clock.advance(by: 2 * 60 * 1_000)

        // The latch is untouched: this is precisely why it cannot be trusted on its own.
        #expect(fx.session.state.value == .streaming(streamId: streamId))
        let verdict = fx.session.streamEvidence.value.verdict(nowMs: fx.clock.nowMs)
        #expect(verdict == .watchSaysNotStreaming)
        #expect(!verdict.supportsRecording)
    }

    /// The starved link. The watch answers control messages (so the keepalive's failure count
    /// never trips) but has stopped answering Info and stopped sending audio. Nothing can be
    /// confirmed, and the honest verdict is that nothing is confirmed.
    @Test func aLinkThatStoppedAnsweringLeavesTheClaimUnverified() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        fx.link.failInfoReads = true
        await fx.clock.advance(by: 5 * 60 * 1_000)

        #expect(fx.link.infoReads > 1, "the session must have tried to ask")
        let verdict = fx.session.streamEvidence.value.verdict(nowMs: fx.clock.nowMs)
        #expect(verdict == .unverified)
        #expect(!verdict.supportsRecording)
    }

    /// A clean STREAM_STOP retires the claim outright: no stale timestamps are left behind to
    /// vouch for whatever stream opens next.
    @Test func aCleanStopClearsTheEvidence() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        fx.link.pushData(data(0, 4))
        await fx.settle()
        #expect(fx.session.streamEvidence.value.lastAudioAtMs != nil)

        fx.link.pushData(
            StreamStop(
                streamId: streamId, reasonRaw: 1, finalSequence: 3, finalSampleIndex: 1_280,
                countersCrcOrZero: 0))
        await fx.settle()

        #expect(fx.session.state.value == .authorized)
        #expect(fx.session.streamEvidence.value.lastAudioAtMs == nil)
    }

    /// A link drop takes the evidence with it — a reconnect must not inherit the previous
    /// connection's proof of life.
    @Test func aLinkDropClearsTheEvidence() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        fx.link.pushData(data(0, 4))
        await fx.settle()
        #expect(fx.session.streamEvidence.value.lastAudioAtMs != nil)

        await fx.setLink(.disconnected)
        #expect(fx.session.streamEvidence.value == .none)
    }

    /// The watch pushing its own state change is evidence too, and lands without an Info read.
    @Test func aStateChangePushRefreshesTheEvidence() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        fx.link.pushControl(StateChanged(serviceStateRaw: ServiceState.streaming.rawValue))
        await fx.settle()

        let evidence = fx.session.streamEvidence.value
        #expect(evidence.lastWatchReportRaw == Int(ServiceState.streaming.rawValue))
        #expect(evidence.lastWatchReportAtMs == fx.clock.nowMs)
    }

    // Appends are no longer fsynced one at a time — that was ~7 flash writes a second while the
    // watch streams, and it bought a guarantee at a granularity nothing needed. The invariant is
    // "checkpoint only what is flushed", and a CHECKPOINT is the ONLY thing that tells the watch it
    // may free its spool, so the flush belongs immediately before it. These two pin that.

    @Test func aCheckpointIsPrecededByAFlush() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()
        fx.link.pushData(data(0, 8))
        await fx.settle()
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(8, 1))
        await fx.settle()

        #expect(!fx.checkpoints().isEmpty)
        #expect(fx.sink.flushes > 0, "the watch is told to free audio only once it is on disk")
    }

    @Test func aFailedFlushSendsNoCheckpoint() async {
        // The safety property. If the audio did not reach the disk we must not claim it — the
        // watch keeps it and re-sends it on the next RESUME, which is exactly the fallback the
        // whole spool exists to be.
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()
        fx.sink.failFlush = true

        fx.link.pushData(data(0, 8))
        await fx.settle()
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(8, 1))
        await fx.settle()

        #expect(fx.checkpoints().isEmpty, "never authorize the watch to drop audio we did not store")

        // ...and it recovers: the next cadence checkpoints once the disk is working again.
        fx.sink.failFlush = false
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(9, 1))
        await fx.settle()
        #expect(!fx.checkpoints().isEmpty)
    }

    /// The watch's silence probe is answered off the notification itself, not off a timer.
    ///
    /// While suppressing silence the watch sends no audio and pushes a STATE_CHANGED every
    /// RECEIVER_LIVENESS_TIMEOUT_MS purely to ask whether we are still here — one control
    /// notification, chosen because that is what wakes a suspended iOS app. Miss the answer and it
    /// stops the microphone.
    ///
    /// Waiting for `runKeepalive` to notice would make that a race against how quickly the
    /// cooperative pool reschedules a long-overdue `Task.sleep` after a wake, and the app is now
    /// deliberately suspendable during silence (residency follows the stream, not the intent).
    @Test func aWatchProbeDuringSilenceIsAnsweredImmediately() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()

        // Quiet: nothing outbound for longer than the keepalive interval.
        await fx.clock.advance(by: 10_000)
        let before = fx.writes().compactMap { $0 as? ReceiverHealth }.count

        fx.link.pushControl(StateChanged(serviceStateRaw: ServiceState.streaming.rawValue))
        await fx.settle()

        let after = fx.writes().compactMap { $0 as? ReceiverHealth }.count
        #expect(after > before, "the watch asked whether we are alive; it must get an answer")
    }

    /// ...and a healthy stream, which checkpoints constantly, sends nothing extra for it.
    @Test func aProbeOnABusyStreamAddsNoTraffic() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.pushData(streamStart())
        await fx.settle()
        let before = fx.writes().compactMap { $0 as? ReceiverHealth }.count

        fx.link.pushControl(StateChanged(serviceStateRaw: ServiceState.streaming.rawValue))
        await fx.settle()

        let after = fx.writes().compactMap { $0 as? ReceiverHealth }.count
        #expect(after == before, "recent outbound traffic already proves we are alive")
    }

    /// The foreground probe: the app woke after a long suspension and asks directly, without
    /// waiting for the session's own cadence to come round.
    @Test func verifyWatchStateAsksTheWatchOnDemand() async {
        let fx = await startSession()
        await authorize(fx)
        fx.link.infoBytes = FakeAudioGattLink.defaultInfo(
            serviceStateRaw: ServiceState.streaming.rawValue
        ).encode()
        let readsBefore = fx.link.infoReads

        let answered = await fx.session.verifyWatchState()

        #expect(answered)
        #expect(fx.link.infoReads == readsBefore + 1)
        #expect(
            fx.session.streamEvidence.value.lastWatchReportRaw
                == Int(ServiceState.streaming.rawValue))
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

private final class MomentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AudioReceiverSession.MarkedMoment] = []
    func append(_ value: AudioReceiverSession.MarkedMoment) { lock.withLock { stored.append(value) } }
    var values: [AudioReceiverSession.MarkedMoment] { lock.withLock { stored } }
}

private final class MuseInboundBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AudioReceiverSession.MuseSetupInbound] = []
    func append(_ value: AudioReceiverSession.MuseSetupInbound) { lock.withLock { stored.append(value) } }
    var values: [AudioReceiverSession.MuseSetupInbound] { lock.withLock { stored } }
}
