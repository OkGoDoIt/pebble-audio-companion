import Foundation
import Receiver
import SegmentStore
import Testing
import WireProtocol

// A RESUME re-announcement is held to account against what this app already stores.
//
// The watch recycles its oldest spool chunk when it cannot grow and records a gap only for the
// frames in it that it had not yet sent; frames it had sent into a link that was already dying
// vanish without a record, and the firmware leaves them to "the receiver's own sequence check"
// (`spool.c`, `prv_drop_oldest_chunk`). The receiver used to start every RESUME with no sequence
// base and adopt whatever the first notice said, so that check compared the hole with nothing.
// In the 2026-09-29 backup: 32 of ~70 same-stream reconnects left an unrecorded run ending exactly
// where the watch's first overflow record starts — 5,634 frames, and the decoded ones are speech.

@Suite struct ResumeAccountingTests {
    private let streamId: UInt32 = 0x5EED_0003

    private typealias Fixture = FakeSinkSession

    private func start(resume: Bool) -> StreamStart {
        StreamStart(
            protocolVersion: 1, streamId: streamId, codecIdRaw: 1, channels: 1, frameSamples: 320,
            sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
            startTimeMs: 1_781_000_000_000, startMonotonicMs: 1,
            flags: resume ? ProtocolConstants.streamStartFlagResume : 0)
    }

    private func data(_ first: UInt32, _ count: Int) -> StreamData {
        StreamData(
            streamId: streamId, firstSequence: first, firstSampleIndex: UInt64(first) * 320, flags: 0,
            frames: (0..<count).map { _ in [UInt8](repeating: 0x21, count: 12) })
    }

    private func notice(_ first: UInt32, _ count: UInt32, _ reason: GapReason) -> StreamGap {
        StreamGap(
            streamId: streamId, firstMissingSequence: first, missingFrameCount: count,
            firstMissingSampleIndex: UInt64(first) * 320, reasonRaw: reason.rawValue,
            watchDropCounter: reason == .spoolOverflow ? count : 0)
    }

    private func describe(_ gaps: [GapRecord]) -> [String] {
        gaps.map { gap in
            let kind: String
            switch gap.origin {
            case .sequenceSkip: kind = "skip"
            case .watchReported(let reason, _): kind = "watch\(reason)"
            }
            return "\(kind)[\(gap.firstMissingSequence),\(gap.firstMissingSequence + gap.missingFrameCount))@\(gap.firstMissingSampleIndex / 320)"
        }
    }

    // --- the hole a reconnect leaves ---------------------------------------------------------

    @Test("a resume that continues this recording records every part of the hole the watch never explained")
    func theReconnectHoleIsRecordedAroundTheWatchsOwnNotices() async {
        let fx = Fixture()
        await fx.authorize()
        // The store holds this stream through sequence 99 and the reattach continues that segment.
        fx.sink.continuation = StreamContinuation(
            nextSequence: 100, nextSampleIndex: 100 * 320, continuesSameSegment: true)

        // The watch's held overflow notice arrives ahead of the re-announcement, then the
        // buffered audio after it.
        fx.link.pushData(notice(120, 20, .spoolOverflow))
        fx.link.pushData(start(resume: true))
        fx.link.pushData(data(160, 8))
        await fx.clock.settle()

        // 100..119 went into the dying link (the watch recycled the chunk without a record);
        // 140..159 the watch never mentioned either. Both are the receiver's to report, each on
        // its own sample clock, and the watch's own record keeps its reason.
        #expect(
            describe(fx.sink.gaps) == [
                "watch1[120,140)@120", "skip[100,120)@100", "skip[140,160)@140",
            ])
        #expect(fx.sink.appends.last?.first?.sequence == 160)
        #expect(fx.lines.lines.contains { $0.contains("resumed after sequence 99 in the same recording") })

        await fx.clock.advance(by: 600)
        fx.link.pushData(data(168, 1))
        await fx.clock.settle()
        #expect(fx.checkpoints().last?.highestContiguousSequencePersisted == 168)
    }

    @Test("an in-place re-announcement keeps the stream's own contiguity when the sink cannot say")
    func anInPlaceResumeKeepsContiguity() async {
        let fx = Fixture()
        await fx.authorize()
        fx.link.pushData(start(resume: false))
        fx.link.pushData(data(0, 10))
        await fx.clock.settle()

        // Re-announced on the same connection (a liveness revival on the watch). The fake sink
        // knows nothing, but the context being replaced does: the stream is stored through 9.
        fx.link.pushData(start(resume: true))
        fx.link.pushData(data(30, 5))
        await fx.clock.settle()

        #expect(describe(fx.sink.gaps) == ["skip[10,30)@10"], "the frames lost across the revival must be recorded")
        #expect(fx.sink.closes.isEmpty)
    }

    @Test("the resume state carries the base when the store holds nothing of the stream")
    func theResumeStateSeedsANewRecording() async {
        let fx = Fixture()
        // The segment that held the stream is gone (deleted), but the last close remembered how
        // far this app got.
        await fx.resumeStore.save(
            ReceiverResumeState(lastStreamId: streamId, lastContiguousSequence: 99, lastSampleIndex: 100 * 320))
        await fx.authorize()

        fx.link.pushData(start(resume: true))
        fx.link.pushData(data(95, 30))  // the rewind re-sends 95..99, then 100..124
        fx.link.pushData(data(140, 4))
        await fx.clock.settle()

        #expect(describe(fx.sink.gaps) == ["skip[125,140)@125"])
        // The tail of the earlier recording is never stored into the new one.
        #expect(fx.sink.appends.first?.first?.sequence == 100)
        #expect(fx.sink.appends.flatMap { $0 }.allSatisfy { $0.sequence >= 100 })
    }

    @Test("a stale resume state never claims audio the store holds as missing")
    func theStoresAnswerBeatsAStaleResumeState() async {
        let fx = Fixture()
        // Saved long ago; the store has since stored the stream much further (a crash skipped
        // the save that would have updated it).
        await fx.resumeStore.save(
            ReceiverResumeState(lastStreamId: streamId, lastContiguousSequence: 49, lastSampleIndex: 50 * 320))
        await fx.authorize()
        fx.sink.continuation = StreamContinuation(
            nextSequence: 100, nextSampleIndex: 100 * 320, continuesSameSegment: false)

        fx.link.pushData(start(resume: true))
        fx.link.pushData(data(100, 4))
        await fx.clock.settle()

        #expect(fx.sink.gaps.isEmpty, "50..99 are stored; nothing between them and 100 is missing")
    }

    // --- what the watch re-sends ---------------------------------------------------------------

    @Test("a notice above the watch's rewind point no longer throws away the audio re-sent below it")
    func aNoticeAboveTheRewindPointKeepsTheResentAudio() async {
        let fx = Fixture()
        await fx.authorize()
        fx.sink.continuation = StreamContinuation(
            nextSequence: 100, nextSampleIndex: 100 * 320, continuesSameSegment: true)

        // The watch skipped 150..169 as quiet while we were away, and reports it first; then it
        // rewinds to its trim point (90) and re-sends everything it never saw checkpointed.
        fx.link.pushData(notice(150, 20, .silenceSuppressed))
        fx.link.pushData(start(resume: true))
        fx.link.pushData(data(90, 30))
        fx.link.pushData(data(120, 30))
        fx.link.pushData(data(170, 8))
        await fx.clock.settle()

        let stored = Set(fx.sink.appends.flatMap { $0 }.map(\.sequence))
        #expect((100..<150).allSatisfy { stored.contains($0) }, "the audio re-sent below the notice must be stored")
        #expect(describe(fx.sink.gaps) == ["watch8[150,170)@150"], "nothing was lost")

        await fx.clock.advance(by: 600)
        fx.link.pushData(data(178, 1))
        await fx.clock.settle()
        #expect(fx.checkpoints().last?.highestContiguousSequencePersisted == 178)
    }

    @Test("with nothing stored, the base comes from the first frame, never from a notice above it")
    func anUnseededResumeAdoptsTheFirstFrameNotAHigherNotice() async {
        let fx = Fixture()
        await fx.authorize()

        fx.link.pushData(notice(150, 20, .silenceSuppressed))
        fx.link.pushData(start(resume: true))
        fx.link.pushData(data(90, 30))
        fx.link.pushData(data(120, 30))
        fx.link.pushData(data(170, 8))
        await fx.clock.settle()

        // This used to take 150 as the base from the notice, discard 90..149 as stale, and then
        // checkpoint past them — telling the watch to delete audio this app never stored.
        let stored = Set(fx.sink.appends.flatMap { $0 }.map(\.sequence))
        #expect((90..<150).allSatisfy { stored.contains($0) })
        #expect(describe(fx.sink.gaps) == ["watch8[150,170)@150"])
    }

    @Test("a resume into a new recording never stores the earlier recording's tail twice")
    func aNewRecordingTrimsTheEarlierTail() async {
        let fx = Fixture()
        await fx.authorize()
        fx.sink.continuation = StreamContinuation(
            nextSequence: 100, nextSampleIndex: 100 * 320, continuesSameSegment: false)

        fx.link.pushData(start(resume: true))
        fx.link.pushData(data(80, 10))  // wholly the earlier recording's
        fx.link.pushData(data(90, 20))  // straddles
        await fx.clock.settle()

        #expect(fx.sink.appends.count == 1)
        #expect(fx.sink.appends.first?.map(\.sequence) == Array(100..<110))
        #expect(fx.sink.gaps.isEmpty)
    }

    @Test("re-sent audio below the base reaches the sink when the recording it belongs to is open")
    func resentAudioReachesTheSinkForRefill() async {
        let fx = Fixture()
        await fx.authorize()
        fx.sink.continuation = StreamContinuation(
            nextSequence: 100, nextSampleIndex: 100 * 320, continuesSameSegment: true)

        fx.link.pushData(start(resume: true))
        fx.link.pushData(data(90, 5))
        await fx.clock.settle()

        // The sink decides: exact re-sends it drops, frames inside a gap it recorded it keeps
        // (a refill). Nothing about contiguity moves.
        #expect(fx.sink.appends.count == 1)
        #expect(fx.sink.appends.first?.first?.sequence == 90)
        #expect(fx.sink.gaps.isEmpty)
    }

    @Test("the watermark we already hold is re-announced after a reconnect")
    func theWatermarkIsReannounced() async {
        let fx = Fixture()
        await fx.authorize()
        fx.sink.continuation = StreamContinuation(
            nextSequence: 100, nextSampleIndex: 100 * 320,
            recordedRanges: [.init(firstSequence: 100, frameCount: 10, firstSampleIndex: 100 * 320)],
            continuesSameSegment: true)

        fx.link.pushData(start(resume: true))
        await fx.clock.settle()
        await fx.clock.advance(by: 600)
        fx.link.pushData(data(95, 5))  // nothing new arrives, only the rewind
        await fx.clock.settle()

        // Stored through 99 and a recorded gap through 109: the watch may trim all of it, and
        // stop re-sending it.
        #expect(fx.checkpoints().last?.highestContiguousSequencePersisted == 109)
    }

    // --- against the real store ----------------------------------------------------------------

    @Test("a reconnect's hole reaches the store as explicit loss, in sequence order")
    func theHoleLandsInTheStore() async throws {
        let harness = try StoreBackedSession()
        try await harness.connectAndAuthorize()
        harness.link.pushData(start(resume: false))
        try await harness.push(data(0, 32))
        try await harness.push(data(32, 32))
        try await harness.push(data(64, 32))
        try await harness.push(data(96, 4))  // stored through 99

        try await harness.disconnect()
        await harness.clock.advance(by: 5_000)
        try await harness.connectAndAuthorize()
        harness.link.pushData(notice(120, 10, .spoolOverflow))
        harness.link.pushData(notice(140, 10, .spoolOverflow))
        harness.link.pushData(start(resume: true))
        try await harness.push(data(90, 10))  // the rewind re-sends what was never checkpointed
        try await harness.push(data(160, 8))
        try await harness.disconnect()

        let segments = await harness.segments()
        #expect(segments.count == 1, "the reattach continues the interrupted recording")
        #expect(segments.first?.frameCount == 108, "nothing the watch re-sent is stored twice")
        #expect(await harness.store.readFrames(try #require(segments.first).segmentId).count == 108)
        let gaps = try #require(segments.first).gaps.map {
            "\($0.origin)[\($0.firstMissingSequence),\(UInt64($0.firstMissingSequence) + UInt64($0.missingFrameCount)))"
        }
        #expect(
            gaps == [
                "sequence_skip[100,120)", "watch[120,130)", "sequence_skip[130,140)", "watch[140,150)",
                "sequence_skip[150,160)",
            ])
    }
}
