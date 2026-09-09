import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import StatusUI

// "How long was this recording?" — the phantom-duration bug, per segment.
//
// `segmentDurationMs` is the WALL SPAN: `(lastSampleIndex − firstSampleIndex) / rate`, straight
// off the watch's sample counter. The counter keeps running while the BLE link is down, so across
// the real library that span exceeds the audio actually held by 82 h 15 m — 41.4%. As a clamp and
// as a placement it is correct and must stay exactly what it is; as an answer to "how long was it"
// it is a lie, and the same lie `ConversationBoundaryDetector.displayExtent` removed for whole
// conversations.
//
// `displaySegmentDurationMs` is the honest answer: audio held + time we have a RECORD of missing,
// never more than the counter's span. `displayGapMs` is clamped to it so the pair shown together
// ("18 min · 4 min missing") cannot contradict itself.

/// 20 ms frames at 16 kHz — the shipping shape, so the arithmetic below is the real arithmetic.
private let frameSamples: UInt64 = 320
private let frameMs: Int64 = 20

private func meta(
    heldFrames: Int64,
    spanSeconds: UInt64,
    gaps: [GapMeta] = []
) -> SegmentMeta {
    SegmentMeta(
        segmentId: "seg",
        streamId: 7,
        protocolVersion: 1,
        codecIdRaw: 1,
        channels: 1,
        frameSamples: Int(frameSamples),
        sampleRateHz: 16_000,
        bitRateBps: 9_800,
        frameDurationMs: Int(frameMs),
        startTimeMs: 1_000,
        startMonotonicMs: 1_000,
        receivedAtMs: 1_000,
        firstSampleIndex: 0,
        lastSampleIndexExclusive: spanSeconds * 16_000,
        frameCount: heldFrames,
        gaps: gaps,
        closeReason: .rotated
    )
}

/// A gap starting `afterSeconds` in, `seconds` long. `reason` nil = a receiver-synthesized
/// sequence skip (visible loss); `.silenceSuppressed` = the watch's own known-quiet record.
private func gap(afterSeconds: UInt64, seconds: UInt64, reason: GapReason? = nil) -> GapMeta {
    let startFrame = afterSeconds * 50
    return GapMeta(
        firstMissingSequence: UInt32(startFrame),
        missingFrameCount: UInt32(seconds * 50),
        firstMissingSampleIndex: startFrame * frameSamples,
        origin: reason == nil ? GapMeta.originSequenceSkip : GapMeta.originWatch,
        reasonRaw: reason.map { Int($0.rawValue) }
    )
}

@Suite("display duration") struct FLDisplayDurationTests {

    /// A healthy recording is unchanged: everything the counter spans is either audio on disk or
    /// a gap record, so the honest number IS the wall span.
    @Test func aRecordingWhoseMetadataAddsUpReadsAsItsWholeSpan() {
        // 10 minutes spanned, 8 minutes held, 2 minutes recorded as lost.
        let subject = meta(
            heldFrames: 8 * 60 * 50,
            spanSeconds: 600,
            gaps: [gap(afterSeconds: 480, seconds: 120)]
        )

        #expect(segmentDurationMs(subject) == 600_000)
        #expect(displaySegmentDurationMs(subject) == 600_000)
        #expect(displayGapMs(subject) == 120_000)
    }

    /// The bug. The counter ran for an hour; twenty minutes of audio arrived and nothing accounts
    /// for the other forty. The span is not this recording's length.
    @Test func timeNoAudioAndNoGapRecordAccountsForIsNotReportedAsRecordingTime() {
        let subject = meta(heldFrames: 20 * 60 * 50, spanSeconds: 3_600)

        #expect(segmentDurationMs(subject) == 3_600_000)
        #expect(displaySegmentDurationMs(subject) == 20 * 60_000)
    }

    /// Known loss is never erased by the correction — it is part of what the recording can vouch
    /// for, and it is the number `displayGapMs` reports beside it.
    @Test func recordedLossSurvivesTheCorrectionAndStillFitsInsideIt() {
        // 30 min spanned, 5 min held, 5 min recorded as lost, 20 min unaccounted for.
        let subject = meta(
            heldFrames: 5 * 60 * 50,
            spanSeconds: 1_800,
            gaps: [gap(afterSeconds: 300, seconds: 300)]
        )

        let duration = displaySegmentDurationMs(subject)
        let missing = displayGapMs(subject)

        #expect(duration == 10 * 60_000)
        #expect(missing == 5 * 60_000)
        #expect(missing <= duration)
    }

    /// VAD-skipped quiet really elapsed and is recorded, so it counts towards the length — but it
    /// is not loss, and the "missing" half of the pair stays silent about it.
    @Test func quietCountsTowardsLengthWithoutBeingCalledMissing() {
        let subject = meta(
            heldFrames: 5 * 60 * 50,
            spanSeconds: 1_800,
            gaps: [gap(afterSeconds: 300, seconds: 300, reason: .silenceSuppressed)]
        )

        #expect(displaySegmentDurationMs(subject) == 10 * 60_000)
        #expect(displayGapMs(subject) == 0)
    }

    /// The invariant the pairing rests on, over every mix: a recording is never reported as
    /// missing more time than it is reported as being long.
    @Test func missingNeverExceedsTheLengthItIsShownBeside() {
        let heldFrames: [Int64] = [0, 50, 5 * 60 * 50, 30 * 60 * 50]
        let spans: [UInt64] = [60, 600, 3_600]
        let losses: [UInt64] = [0, 30, 600, 7_200]
        for held in heldFrames {
            for span in spans {
                for lostSeconds in losses {
                    let subject = meta(
                        heldFrames: held,
                        spanSeconds: span,
                        gaps: lostSeconds == 0 ? [] : [gap(afterSeconds: 0, seconds: lostSeconds)]
                    )
                    let duration = displaySegmentDurationMs(subject)
                    #expect(duration >= 0)
                    #expect(duration <= segmentDurationMs(subject))
                    #expect(displayGapMs(subject) <= duration)
                }
            }
        }
    }

    /// A segment with no frames yet falls back to the span, exactly as `segmentStoredAudioMs`
    /// does — there is nothing else to say about it, and reporting zero would be its own lie.
    @Test func aSegmentWithNoStoredFramesFallsBackToItsSpan() {
        #expect(displaySegmentDurationMs(meta(heldFrames: 0, spanSeconds: 60)) == 60_000)
    }
}
