import Foundation
import SegmentStore
import WireProtocol

// Port of `app/.../SegmentWaveform.kt`.

/// One bucket of a stored segment's waveform, in media time (stored frames only).
public struct SegmentWaveformBar: Sendable, Equatable {
    /// 0..1 display amplitude (sqrt-compressed RMS).
    public let amplitude: Float
    public let state: WaveformBarState

    public init(amplitude: Float, state: WaveformBarState) {
        self.amplitude = amplitude
        self.state = state
    }
}

/// A marker at the media-time position where genuine audio loss occurred.
public struct SegmentGapMarker: Sendable, Equatable {
    /// 0..1 position within the stored audio where the missing audio would have been.
    public let fraction: Float
    public let approxDurationMs: Int64

    public init(fraction: Float, approxDurationMs: Int64) {
        self.fraction = fraction
        self.approxDurationMs = approxDurationMs
    }
}

public struct SegmentWaveform: Sendable, Equatable {
    public let bars: [SegmentWaveformBar]
    public let gapMarkers: [SegmentGapMarker]
    /// Duration of the stored audio (gaps excluded) — matches playback positions.
    public let mediaDurationMs: Int64

    public init(bars: [SegmentWaveformBar], gapMarkers: [SegmentGapMarker], mediaDurationMs: Int64) {
        self.bars = bars
        self.gapMarkers = gapMarkers
        self.mediaDurationMs = mediaDurationMs
    }
}

/// Builds the color-codable waveform of one stored segment from its durable frame log.
///
/// The bar axis is media time (stored frames only), so the playback cursor and tap-to-seek map
/// linearly onto it; missing audio is shown as gap markers at the position where it occurred
/// (the ux plan's "scrubber with gap markers"), not as fake silent time.
///
/// Not thread-safe (same as the Kotlin class): one owner drives it.
public final class SegmentWaveformBuilder {
    private let decoder: LiveFrameDecoder?
    private let frameDurationMs: Int64
    private let maxBars: Int
    private let decodeBatchFrames: Int
    /// While a segment is still recording its meta refreshes every few seconds; only re-read and
    /// re-decode once this much new audio exists (500 frames = 10 s), not on every refresh.
    private let minRebuildDeltaFrames: Int64

    private var cachedSegmentId: String?
    private var cachedFrameCount: Int64 = -1
    private var cachedValue: SegmentWaveform?

    public init(
        decoder: LiveFrameDecoder?,
        frameDurationMs: Int64 = 20,
        maxBars: Int = 240,
        decodeBatchFrames: Int = 200,
        minRebuildDeltaFrames: Int64 = 500
    ) {
        self.decoder = decoder
        self.frameDurationMs = frameDurationMs
        self.maxBars = maxBars
        self.decodeBatchFrames = decodeBatchFrames
        self.minRebuildDeltaFrames = minRebuildDeltaFrames
    }

    public func build(
        meta: SegmentMeta,
        framesProvider: () -> [FrameRecord]
    ) async -> SegmentWaveform {
        if let cached = cachedValue, cachedSegmentId == meta.segmentId {
            let delta = meta.frameCount - cachedFrameCount
            let fresh = delta == 0 || (meta.isOpen && delta >= 0 && delta < minRebuildDeltaFrames)
            if fresh { return cached }
        }
        let frames = framesProvider()

        let mediaDurationMs = Int64(frames.count) * frameDurationMs
        let framesPerBar = max((frames.count + maxBars - 1) / maxBars, 1)
        let barCount = frames.isEmpty ? 0 : (frames.count + framesPerBar - 1) / framesPerBar

        var sumSquares = [Double](repeating: 0, count: barCount)
        var sampleCounts = [Int](repeating: 0, count: barCount)

        var index = 0
        while index < frames.count {
            let end = min(index + decodeBatchFrames, frames.count)
            let batch = Array(frames[index..<end])
            let pcm = await decoder?.decode(batch.map(\.payload)) ?? []
            if pcm.isEmpty {
                // No decoder (tests): count frame presence so bars still render.
                for i in index..<end {
                    sampleCounts[i / framesPerBar] += 1
                }
            } else {
                let samplesPerFrame = pcm.count / batch.count
                for i in batch.indices {
                    let bar = (index + i) / framesPerBar
                    let from = i * samplesPerFrame
                    let to = min(from + samplesPerFrame, pcm.count)
                    for s in from..<to {
                        let sample = Double(pcm[s])
                        sumSquares[bar] += sample * sample
                    }
                    sampleCounts[bar] += to - from
                }
            }
            index = end
        }

        let bars = (0..<barCount).map { bar -> SegmentWaveformBar in
            let rms = sampleCounts[bar] > 0 ? (sumSquares[bar] / Double(sampleCounts[bar])).squareRoot() : 0.0
            return SegmentWaveformBar(
                amplitude: LiveAudioMonitor.displayAmplitude(rms),
                state: rms < LiveAudioMonitor.silenceRMS ? .silence : .recorded
            )
        }

        let markers = meta.gaps.compactMap { gap in gapMarker(gap, meta: meta, frames: frames) }
        let result = SegmentWaveform(bars: bars, gapMarkers: markers, mediaDurationMs: mediaDurationMs)
        cachedSegmentId = meta.segmentId
        cachedFrameCount = max(meta.frameCount, Int64(frames.count))
        cachedValue = result
        return result
    }

    /// Media-time position of a gap: the share of stored frames before its first missing seq.
    private func gapMarker(_ gap: GapMeta, meta: SegmentMeta, frames: [FrameRecord]) -> SegmentGapMarker? {
        if frames.isEmpty { return nil }
        // Silence-suppressed spans are known-quiet audio the watch skipped, not loss: the stored
        // audio simply continues across them, so they get no marker. Also hide a duplicate
        // receiver-synthesized skip if it covers the same range as a watch-reported silence span.
        if isKnownQuietGap(gap, allGaps: meta.gaps) { return nil }
        var low = 0
        var high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].sequence < gap.firstMissingSequence { low = mid + 1 } else { high = mid }
        }
        return SegmentGapMarker(
            fraction: Float(low) / Float(frames.count),
            approxDurationMs: Int64(gap.missingFrameCount) * Int64(meta.frameDurationMs)
        )
    }

    private func isKnownQuietGap(_ gap: GapMeta, allGaps: [GapMeta]) -> Bool {
        if gapReason(gap)?.isSilence == true { return true }
        if gap.origin != GapMeta.originSequenceSkip { return false }
        let gapStart = UInt64(gap.firstMissingSequence)
        let gapEnd = gapStart + UInt64(gap.missingFrameCount)
        return allGaps.contains { candidate in
            gapReason(candidate)?.isSilence == true
                && UInt64(candidate.firstMissingSequence) <= gapStart
                && UInt64(candidate.firstMissingSequence) + UInt64(candidate.missingFrameCount) >= gapEnd
        }
    }

    private func gapReason(_ gap: GapMeta) -> GapReason? {
        gap.reasonRaw.flatMap { UInt8(exactly: $0) }.flatMap(GapReason.init(rawValue:))
    }
}
