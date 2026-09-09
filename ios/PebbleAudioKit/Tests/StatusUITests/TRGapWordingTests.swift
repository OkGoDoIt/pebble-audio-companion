import Foundation
import Testing
import SegmentStore

@testable import StatusUI

/// Stream TR. An unattributed sequence skip is the only gap the app cannot attribute — the watch's
/// sequence numbers jumped and it never said why. The wording has to stay truthful against the
/// duration rendered next to it, because in Roger's 88-day export 79 of the 2,690 skips display
/// longer than a minute and hold 27 h between them, the largest a single 10 h 30 m hole.
@Suite struct TRGapWordingTests {

    private func skip(frames: UInt32) -> GapMeta {
        GapMeta(
            firstMissingSequence: 100,
            missingFrameCount: frames,
            firstMissingSampleIndex: 32_000,
            origin: GapMeta.originSequenceSkip
        )
    }

    @Test func shortSkipStaysBrief() {
        // The overwhelming majority: median 0.9 s, p90 14.8 s across the real library.
        #expect(
            gapDescription(skip(frames: 45), displayedDurationMs: 900)
                == "phone briefly missed audio")
    }

    @Test func aTenHourHoleIsNotCalledBrief() {
        #expect(
            gapDescription(skip(frames: 1_890_102), displayedDurationMs: 37_802_000)
                == "phone missed audio")
    }

    @Test func theBoundaryIsOneMinute() {
        #expect(
            gapDescription(skip(frames: 3_000), displayedDurationMs: 59_999)
                == "phone briefly missed audio")
        #expect(
            gapDescription(skip(frames: 3_000), displayedDurationMs: 60_000)
                == "phone missed audio")
    }

    @Test func aLongRawCountThatDisplaysShortIsStillBrief() {
        // 16 gaps in the export run past a minute raw but display under one, because the record
        // reaches outside the segment's own audio extent and the renderer clips it. Deciding on
        // `missingFrameCount` would over-claim on exactly those, so the rule takes the length the
        // caller is about to show.
        #expect(
            gapDescription(skip(frames: 81_000), displayedDurationMs: 10_000)
                == "phone briefly missed audio")
    }

    @Test func unknownLengthKeepsTheOriginalWording() {
        #expect(
            gapDescription(skip(frames: 1_890_102), displayedDurationMs: nil)
                == "phone briefly missed audio")
        #expect(gapDescription(skip(frames: 1_890_102)) == "phone briefly missed audio")
    }

    @Test func watchReportedReasonsAreUnaffectedByLength() {
        // Only the unattributed skip has a brevity claim to lose; a watch-reported reason names a
        // cause and must read the same at any length.
        let watchGap = GapMeta(
            firstMissingSequence: 100,
            missingFrameCount: 1_890_102,
            firstMissingSampleIndex: 32_000,
            origin: GapMeta.originWatch,
            reasonRaw: 6  // transportReset
        )
        #expect(
            gapDescription(watchGap, displayedDurationMs: 37_802_000)
                == "connection was interrupted")
    }
}
