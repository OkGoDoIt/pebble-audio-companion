import Foundation
import SegmentStore
import WireProtocol

@testable import AppDB

// Shared builders for AppDB tests: hand-built SegmentMeta values at 16 kHz / 320-sample
// frames, so 1 minute = 960_000 samples = 3_000 frames.

let testEpochMs: Int64 = 1_772_400_000_000

func minutesMs(_ n: Int64) -> Int64 { n * 60_000 }
func minutesSamples(_ n: UInt64) -> UInt64 { n * 960_000 }

let userStopClose = CloseReasonMeta(
    kind: CloseReasonMeta.kindStopped,
    stopReasonRaw: Int(StopReason.userDisabled.rawValue)
)

func makeSegment(
    id: String,
    stream: UInt32,
    startTimeMs: Int64,
    firstSample: UInt64 = 0,
    durationSamples: UInt64,
    close: CloseReasonMeta? = .interrupted,
    tz: String? = nil,
    gaps: [GapMeta] = []
) -> SegmentMeta {
    SegmentMeta(
        segmentId: id,
        streamId: stream,
        protocolVersion: 1,
        codecIdRaw: 1,
        channels: 1,
        frameSamples: 320,
        sampleRateHz: 16_000,
        bitRateBps: 9_800,
        frameDurationMs: 20,
        startTimeMs: UInt64(startTimeMs),
        startMonotonicMs: 0,
        receivedAtMs: startTimeMs + Int64(firstSample / 16),
        firstSequence: UInt32(firstSample / 320),
        lastSequence: UInt32((firstSample + durationSamples) / 320),
        firstSampleIndex: firstSample,
        lastSampleIndexExclusive: firstSample + durationSamples,
        frameCount: Int64(durationSamples / 320),
        gaps: gaps,
        closeReason: close,
        closedAtMs: startTimeMs + Int64((firstSample + durationSamples) / 16),
        recordedTimeZone: tz
    )
}

func lossGap(atSample sample: UInt64, minutes: UInt32, reasonRaw: Int? = 6) -> GapMeta {
    GapMeta(
        firstMissingSequence: UInt32(sample / 320),
        missingFrameCount: minutes * 3_000,
        firstMissingSampleIndex: sample,
        origin: GapMeta.originWatch,
        reasonRaw: reasonRaw
    )
}

func silenceGap(atSample sample: UInt64, minutes: UInt32) -> GapMeta {
    GapMeta(
        firstMissingSequence: UInt32(sample / 320),
        missingFrameCount: minutes * 3_000,
        firstMissingSampleIndex: sample,
        origin: GapMeta.originWatch,
        reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
    )
}

func sequenceSkipGap(atSample sample: UInt64, minutes: UInt32) -> GapMeta {
    GapMeta(
        firstMissingSequence: UInt32(sample / 320),
        missingFrameCount: minutes * 3_000,
        firstMissingSampleIndex: sample,
        origin: GapMeta.originSequenceSkip
    )
}
