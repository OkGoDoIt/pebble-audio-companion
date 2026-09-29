import Foundation
import Receiver
import SegmentStore
import Testing
import WireProtocol

// Traffic that arrives for a stream this app has not been told about yet.
//
// The watch drains its pending gap table ahead of the re-announced STREAM_START on every
// re-authorization, and it TAKES each record out of that table to send it: a notice dropped here
// is gone from both sides. They are held and replayed when the stream opens. The hold was capped
// at 16, and on 2026-09-20 23:48:37 more than that arrived; the quiet the rest described came back
// as 13 small sequence skips — silence recorded as loss.
//
// Frames that arrive with no stream are counted for Diagnostics and reported in the flight
// recorder. That count used to include held notices, was zeroed at every link teardown, and its
// one log line said the watch "was sending audio this app could not store" — but none of those
// frames was acknowledged, so the watch kept them and re-sends them once the stream is announced.
@Suite struct OrphanHoldTests {
    private let streamId: UInt32 = 0x5EED_0005

    private func resumeStart() -> StreamStart {
        StreamStart(
            protocolVersion: 1, streamId: streamId, codecIdRaw: 1, channels: 1, frameSamples: 320,
            sampleRateHz: 16000, bitRateBps: 9800, frameDurationMs: 20,
            startTimeMs: 1_781_000_000_000, startMonotonicMs: 1,
            flags: ProtocolConstants.streamStartFlagResume)
    }

    private func data(_ first: UInt32, _ count: Int) -> StreamData {
        StreamData(
            streamId: streamId, firstSequence: first, firstSampleIndex: UInt64(first) * 320, flags: 0,
            frames: (0..<count).map { _ in [UInt8](repeating: 0x33, count: 10) })
    }

    private func notice(_ first: UInt32, _ count: UInt32, _ reason: GapReason) -> StreamGap {
        StreamGap(
            streamId: streamId, firstMissingSequence: first, missingFrameCount: count,
            firstMissingSampleIndex: UInt64(first) * 320, reasonRaw: reason.rawValue, watchDropCounter: 0)
    }

    // --- the hold ------------------------------------------------------------------------------

    @Test("far more held notices than the old cap of 16 all reach the recording")
    func manyHeldNoticesAreAllApplied() async {
        let fx = FakeSinkSession()
        await fx.authorize()
        // Forty notices tiling 100..299, alternating reasons so none can coalesce.
        for i in 0..<40 {
            fx.link.pushData(
                notice(100 + UInt32(i) * 5, 5, i.isMultiple(of: 2) ? .silenceSuppressed : .spoolOverflow))
        }
        fx.link.pushData(resumeStart())
        fx.link.pushData(data(300, 4))
        await fx.clock.settle()

        #expect(fx.sink.gaps.count == 40)
        #expect(
            !fx.sink.gaps.contains { $0.origin == .sequenceSkip },
            "every frame of 100..299 is accounted for by the watch; none may become a skip")
    }

    @Test("adjacent held notices with the same reason become one")
    func adjacentSameReasonNoticesCoalesce() async {
        let fx = FakeSinkSession()
        await fx.authorize()
        fx.link.pushData(notice(100, 10, .silenceSuppressed))
        fx.link.pushData(notice(110, 10, .silenceSuppressed))
        fx.link.pushData(notice(120, 10, .silenceSuppressed))
        fx.link.pushData(notice(130, 10, .spoolOverflow))
        fx.link.pushData(resumeStart())
        await fx.clock.settle()

        #expect(
            fx.sink.gaps
                == [
                    GapRecord(
                        firstMissingSequence: 100, missingFrameCount: 30, firstMissingSampleIndex: 100 * 320,
                        origin: .watchReported(reasonRaw: Int(GapReason.silenceSuppressed.rawValue), watchDropCounter: 0)),
                    GapRecord(
                        firstMissingSequence: 130, missingFrameCount: 10, firstMissingSampleIndex: 130 * 320,
                        origin: .watchReported(reasonRaw: Int(GapReason.spoolOverflow.rawValue), watchDropCounter: 0)),
                ])
    }

    @Test("notices past the bound are counted and said out loud, never silently lost")
    func overflowingTheHoldIsReported() async {
        let fx = FakeSinkSession()
        await fx.authorize()
        let bound = AudioReceiverSession.orphanGapsPerStream
        // Non-adjacent notices, so each needs its own slot.
        for i in 0..<(bound + 3) {
            fx.link.pushData(notice(UInt32(i) * 4, 2, .silenceSuppressed))
        }
        fx.link.pushData(resumeStart())
        await fx.clock.settle()

        #expect(fx.sink.gaps.count == bound)
        #expect(fx.lines.lines.contains { $0.contains("3 gap notice(s) did not fit the hold") })
    }

    // --- the orphan report ---------------------------------------------------------------------

    @Test("frames with no stream are reported with their range when the stream is announced")
    func anEpisodeIsReportedWhenTheStreamIsAnnounced() async {
        let fx = FakeSinkSession()
        await fx.authorize()
        fx.link.pushData(data(500, 32))
        fx.link.pushData(data(532, 8))
        fx.link.pushData(notice(540, 4, .spoolOverflow))
        await fx.clock.settle()

        // Frames only: a held notice is not audio.
        #expect(fx.session.orphanedFrameCount.value == 40)

        fx.link.pushData(resumeStart())
        await fx.clock.settle()
        let report = fx.lines.lines.first { $0.contains("arrived before stream") }
        #expect(report?.contains("40 frame(s) (sequences 500-539) and 1 gap notice(s)") == true, "\(fx.lines.lines)")
        #expect(report?.contains("the watch kept the audio and re-sends it now") == true)
        #expect(!fx.lines.lines.contains { $0.contains("could not store") })
    }

    @Test("the count survives the link going down, and the episode is reported there if never announced")
    func theCountOutlivesTheConnection() async {
        let fx = FakeSinkSession()
        await fx.authorize()
        fx.link.pushData(data(700, 10))
        await fx.clock.settle()

        await fx.disconnect()
        #expect(fx.session.orphanedFrameCount.value == 10, "Diagnostics must still be able to see it")
        #expect(
            fx.lines.lines.contains {
                $0.contains("link down: 10 frame(s) (sequences 700-709)")
                    && $0.contains("never announced their stream")
            })

        await fx.authorize()
        fx.link.pushData(data(900, 5))
        await fx.clock.settle()
        #expect(fx.session.orphanedFrameCount.value == 15)
    }
}
