package dev.audiocompanion.transport

import dev.audiocompanion.protocol.Ack
import dev.audiocompanion.protocol.AudioCompanionProtocol
import dev.audiocompanion.protocol.AuthRequest
import dev.audiocompanion.protocol.AuthResult
import dev.audiocompanion.protocol.Checkpoint
import dev.audiocompanion.protocol.DecodeResult
import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.protocol.StreamData
import dev.audiocompanion.protocol.StreamGap
import dev.audiocompanion.protocol.StreamStart
import dev.audiocompanion.protocol.StreamStop
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class AudioReceiverSessionTest {

    private val receiverId = ByteArray(32) { it.toByte() }
    private val streamId = 0x5EED0001u

    private class Fixture(
        val link: FakeAudioGattLink,
        val sink: FakeSegmentSink,
        val policy: FakeReceiverPolicy,
        val resumeStore: FakeResumeStore,
        val session: AudioReceiverSession,
    ) {
        /** Decoded control writes seen by the watch. */
        fun writes(): List<Any> = link.controlWrites.map {
            (AudioCompanionProtocol.decodeControlIn(it) as DecodeResult.Decoded).message
        }

        fun checkpoints(): List<Checkpoint> = writes().filterIsInstance<Checkpoint>()

        fun authRequest(): AuthRequest = writes().filterIsInstance<AuthRequest>().single()
    }

    private fun TestScope.startSession(): Fixture {
        val link = FakeAudioGattLink()
        val sink = FakeSegmentSink()
        val policy = FakeReceiverPolicy()
        val resumeStore = FakeResumeStore()
        val session = AudioReceiverSession(
            link = link,
            sink = sink,
            policy = policy,
            resumeStore = resumeStore,
            config = ReceiverConfig(receiverId = receiverId, receiverName = "Audio Companion"),
            nowMs = { testScheduler.currentTime },
        )
        session.start(backgroundScope)
        runCurrent()
        return Fixture(link, sink, policy, resumeStore, session)
    }

    private fun TestScope.authorize(fx: Fixture): Int {
        fx.link.linkState.value = LinkState.Ready
        runCurrent()
        val token = fx.authRequest().requestToken
        fx.link.pushControl(AuthResult(requestToken = token, statusRaw = 0, grantedProtoVersion = 1))
        runCurrent()
        assertEquals(ReceiverSessionState.Authorized, fx.session.state.value)
        return token
    }

    private fun streamStart() = StreamStart(
        protocolVersion = 1,
        streamId = streamId,
        codecIdRaw = 1,
        channels = 1,
        frameSamples = 320,
        sampleRateHz = 16000u,
        bitRateBps = 9800u,
        frameDurationMs = 20,
        startTimeMs = 1_781_000_000_000u,
        startMonotonicMs = 86_400_123u,
        flags = 0u,
    )

    private fun data(firstSequence: UInt, frameCount: Int, frameLen: Int = 25): StreamData =
        StreamData(
            streamId = streamId,
            firstSequence = firstSequence,
            firstSampleIndex = firstSequence.toULong() * 320u,
            flags = 0,
            frames = List(frameCount) { ByteArray(frameLen) { b -> b.toByte() } },
        )

    // -------------------------------------------------------------------------------------

    @Test
    fun happyPath_authStartDataCheckpointStop() = runTest {
        val fx = startSession()
        fx.link.linkState.value = LinkState.Ready
        runCurrent()

        // AUTH_REQUEST carries our identity.
        val auth = fx.authRequest()
        assertEquals(1, auth.protoVersion)
        assertTrue(auth.receiverId.contentEquals(receiverId))
        assertEquals("Audio Companion", auth.name)
        assertEquals(ReceiverSessionState.Authorizing, fx.session.state.value)

        fx.link.pushControl(AuthResult(auth.requestToken, statusRaw = 0, grantedProtoVersion = 1))
        runCurrent()
        assertEquals(ReceiverSessionState.Authorized, fx.session.state.value)
        assertEquals(1, fx.session.grantedProtoVersion.value)

        // STREAM_START opens a segment.
        fx.link.pushData(streamStart())
        runCurrent()
        assertEquals(ReceiverSessionState.Streaming(streamId), fx.session.state.value)
        assertEquals(streamId, fx.sink.eventsOf<SinkEvent.Open>().single().start.streamId)

        // First batch: appended durably, but no checkpoint yet (160 ms audio, < 500 ms elapsed).
        fx.link.pushData(data(0u, 8))
        runCurrent()
        val append = fx.sink.eventsOf<SinkEvent.Append>().single()
        assertEquals(0u, append.frames.first().sequence)
        assertEquals(7u, append.frames.last().sequence)
        assertEquals(7uL * 320u, append.frames.last().sampleIndex)
        assertTrue(fx.checkpoints().isEmpty())

        // 600 ms later another batch arrives -> time-based checkpoint cadence fires.
        advanceTimeBy(600)
        fx.link.pushData(data(8u, 1))
        runCurrent()
        val cp1 = fx.checkpoints().single()
        assertEquals(streamId, cp1.streamId)
        assertEquals(8u, cp1.highestContiguousSequencePersisted)
        assertEquals(9uL * 320u, cp1.persistedSampleIndex)
        fx.link.pushControl(Ack(cp1.requestToken, statusRaw = 0))
        runCurrent()

        // >= 2 s of appended audio triggers the audio-based cadence without any wall time passing.
        var seq = 9u
        repeat(4) { // 4 * 32 frames * 20 ms = 2560 ms of audio
            fx.link.pushData(data(seq, 32, frameLen = 4))
            seq += 32u
            runCurrent()
        }
        val cp2 = fx.checkpoints()[1]
        assertEquals(seq - 1u, cp2.highestContiguousSequencePersisted)
        fx.link.pushControl(Ack(cp2.requestToken, statusRaw = 0))
        runCurrent()
        assertEquals(2, fx.checkpoints().size)

        // STREAM_STOP closes the segment and persists resume state.
        fx.link.pushData(
            StreamStop(streamId, reasonRaw = 1, finalSequence = seq - 1u,
                finalSampleIndex = seq.toULong() * 320u, countersCrcOrZero = 0u)
        )
        runCurrent()
        val close = fx.sink.eventsOf<SinkEvent.Close>().single()
        val stopped = assertIs<SegmentCloseReason.Stopped>(close.reason)
        assertEquals(1, stopped.reasonRaw)
        assertEquals(ReceiverSessionState.Authorized, fx.session.state.value)
        val resume = assertNotNull(fx.resumeStore.saved)
        assertEquals(streamId, resume.lastStreamId)
        assertEquals(seq - 1u, resume.lastContiguousSequence)
    }

    @Test
    fun pendingConsentThenOk() = runTest {
        val fx = startSession()
        fx.link.linkState.value = LinkState.Ready
        runCurrent()
        val token = fx.authRequest().requestToken

        fx.link.pushControl(AuthResult(token, statusRaw = 1, grantedProtoVersion = 0))
        runCurrent()
        assertEquals(ReceiverSessionState.PendingConsent, fx.session.state.value)

        // The watch pushes the final result with the same token after user consent.
        fx.link.pushControl(AuthResult(token, statusRaw = 0, grantedProtoVersion = 1))
        runCurrent()
        assertEquals(ReceiverSessionState.Authorized, fx.session.state.value)
    }

    @Test
    fun deniedMismatchFailsClosed() = runTest {
        val fx = startSession()
        fx.link.linkState.value = LinkState.Ready
        runCurrent()
        val token = fx.authRequest().requestToken

        fx.link.pushControl(AuthResult(token, statusRaw = 2, grantedProtoVersion = 0))
        runCurrent()
        val denied = assertIs<ReceiverSessionState.Denied>(fx.session.state.value)
        assertEquals(2, denied.statusRaw)

        // No data is consumed after a denial: a (protocol-violating) stream start is ignored.
        fx.link.pushData(streamStart())
        runCurrent()
        assertTrue(fx.sink.events.isEmpty())
    }

    @Test
    fun skippedSequencesSynthesizeGap_andCheckpointStaysContiguous() = runTest {
        val fx = startSession()
        authorize(fx)
        fx.link.pushData(streamStart())
        runCurrent()

        fx.link.pushData(data(0u, 8)) // contiguous 0..7
        runCurrent()
        fx.link.pushData(data(12u, 4)) // skip 8..11
        runCurrent()

        val gap = fx.sink.eventsOf<SinkEvent.Gap>().single().gap
        assertEquals(8u, gap.firstMissingSequence)
        assertEquals(4u, gap.missingFrameCount)
        assertEquals(8uL * 320u, gap.firstMissingSampleIndex)
        assertEquals(GapOrigin.SequenceSkip, gap.origin)

        // Frames past the hole are persisted (durability first) but do not advance the checkpoint.
        assertEquals(2, fx.sink.eventsOf<SinkEvent.Append>().size)
        advanceTimeBy(600)
        fx.link.pushData(data(16u, 1))
        runCurrent()
        val cp = fx.checkpoints().single()
        assertEquals(7u, cp.highestContiguousSequencePersisted, "checkpoint must be contiguous, not highest-seen")
        assertEquals(8uL * 320u, cp.persistedSampleIndex)
    }

    @Test
    fun explicitGapPassThrough_advancesContiguity() = runTest {
        val fx = startSession()
        authorize(fx)
        fx.link.pushData(streamStart())
        runCurrent()

        fx.link.pushData(data(0u, 8))
        runCurrent()
        fx.link.pushData(
            StreamGap(
                streamId = streamId,
                firstMissingSequence = 8u,
                missingFrameCount = 4u,
                firstMissingSampleIndex = 8uL * 320u,
                reasonRaw = 1,
                watchDropCounter = 4u,
            )
        )
        runCurrent()

        val gap = fx.sink.eventsOf<SinkEvent.Gap>().single().gap
        val origin = assertIs<GapOrigin.WatchReported>(gap.origin)
        assertEquals(1, origin.reasonRaw)
        assertEquals(4u, origin.watchDropCounter)
        assertEquals(8u, gap.firstMissingSequence)

        // The known-lost range is accounted: contiguity resumes after it, no synthetic gap.
        advanceTimeBy(600)
        fx.link.pushData(data(12u, 4))
        runCurrent()
        assertEquals(1, fx.sink.eventsOf<SinkEvent.Gap>().size)
        val cp = fx.checkpoints().single()
        assertEquals(15u, cp.highestContiguousSequencePersisted)
        assertEquals(16uL * 320u, cp.persistedSampleIndex)
    }

    @Test
    fun disconnectMidStream_closesInterruptedAndPersistsResume() = runTest {
        val fx = startSession()
        authorize(fx)
        fx.link.pushData(streamStart())
        runCurrent()
        fx.link.pushData(data(0u, 8))
        runCurrent()

        fx.link.linkState.value = LinkState.Disconnected
        runCurrent()

        assertEquals(SegmentCloseReason.Interrupted, fx.sink.eventsOf<SinkEvent.Close>().single().reason)
        assertEquals(ReceiverSessionState.Disconnected, fx.session.state.value)
        val resume = assertNotNull(fx.resumeStore.saved)
        assertEquals(streamId, resume.lastStreamId)
        assertEquals(7u, resume.lastContiguousSequence)
        assertEquals(8uL * 320u, resume.lastSampleIndex)
    }

    @Test
    fun onlyOneRequestInFlight_checkpointWaitsForAck() = runTest {
        val fx = startSession()
        authorize(fx)
        fx.link.pushData(streamStart())
        runCurrent()

        // 2.5 s of audio -> checkpoint #1 sent (token outstanding, never acked yet).
        var seq = 0u
        repeat(4) {
            fx.link.pushData(data(seq, 32, frameLen = 4))
            seq += 32u
            runCurrent()
        }
        assertEquals(1, fx.checkpoints().size)

        // Another 2.5 s of audio while the ack is outstanding -> still only one checkpoint.
        repeat(4) {
            fx.link.pushData(data(seq, 32, frameLen = 4))
            seq += 32u
            runCurrent()
        }
        assertEquals(1, fx.checkpoints().size)

        // Ack arrives -> the next append flushes the overdue checkpoint with fresh values.
        fx.link.pushControl(Ack(fx.checkpoints()[0].requestToken, statusRaw = 0))
        runCurrent()
        fx.link.pushData(data(seq, 1, frameLen = 4))
        seq += 1u
        runCurrent()
        assertEquals(2, fx.checkpoints().size)
        assertEquals(seq - 1u, fx.checkpoints()[1].highestContiguousSequencePersisted)
        assertTrue(fx.checkpoints()[1].requestToken != fx.checkpoints()[0].requestToken)
    }

    @Test
    fun checkpointCarriesPolicyFlagsAndStorageHint() = runTest {
        val fx = startSession()
        authorize(fx)
        fx.policy.flags = ProtocolConstants.RECEIVER_FLAG_LOW_STORAGE
        fx.policy.freeKb = 123_456u
        fx.link.pushData(streamStart())
        runCurrent()
        advanceTimeBy(600)
        fx.link.pushData(data(0u, 8))
        runCurrent()
        val cp = fx.checkpoints().single()
        assertEquals(ProtocolConstants.RECEIVER_FLAG_LOW_STORAGE, cp.receiverFlags)
        assertEquals(123_456u, cp.freeStorageHintKb)
    }

    @Test
    fun unknownMessagesAreIgnored() = runTest {
        val fx = startSession()
        authorize(fx)
        fx.link.pushData(streamStart())
        runCurrent()

        // Unknown data id (0x9F) and unknown control id (0x3F..0x7F range) must be skipped.
        fx.link.pushDataBytes(byteArrayOf(0x9F.toByte()) + ByteArray(8))
        fx.link.pushControlBytes(byteArrayOf(0x7F.toByte(), 0x00))
        // Malformed data must not kill the session either.
        fx.link.pushDataBytes(byteArrayOf())
        runCurrent()

        fx.link.pushData(data(0u, 8))
        runCurrent()
        assertEquals(1, fx.sink.eventsOf<SinkEvent.Append>().size)
        assertEquals(ReceiverSessionState.Streaming(streamId), fx.session.state.value)
    }

    @Test
    fun revokedClosesSegmentAndStopsConsumingData() = runTest {
        val fx = startSession()
        authorize(fx)
        fx.link.pushData(streamStart())
        runCurrent()
        fx.link.pushData(data(0u, 8))
        runCurrent()

        fx.link.pushControl(dev.audiocompanion.protocol.Revoked(reasonRaw = 1))
        runCurrent()
        val state = assertIs<ReceiverSessionState.Revoked>(fx.session.state.value)
        assertEquals(1, state.reasonRaw)
        assertEquals(SegmentCloseReason.Interrupted, fx.sink.eventsOf<SinkEvent.Close>().single().reason)

        fx.link.pushData(data(8u, 8))
        runCurrent()
        assertEquals(1, fx.sink.eventsOf<SinkEvent.Append>().size)
    }
}
