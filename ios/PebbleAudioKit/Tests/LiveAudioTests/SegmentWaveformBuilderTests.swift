import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import LiveAudio

// Port of `app/src/commonTest/.../SegmentWaveformBuilderTest.kt` — all 8 cases, same names.
@Suite struct SegmentWaveformBuilderTests {

    private func meta(frameCount: Int64, gaps: [GapMeta] = [], open: Bool = false) -> SegmentMeta {
        SegmentMeta(
            segmentId: "seg-1",
            streamId: 7,
            protocolVersion: 1,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 9_800,
            frameDurationMs: 20,
            startTimeMs: 0,
            startMonotonicMs: 0,
            receivedAtMs: 0,
            frameCount: frameCount,
            gaps: gaps,
            closeReason: open ? nil : .rotated
        )
    }

    private func frames(_ count: Int, firstSequence: UInt32 = 0) -> [FrameRecord] {
        (0..<count).map { i in
            FrameRecord(
                sequence: firstSequence + UInt32(i),
                sampleIndex: UInt64(firstSequence + UInt32(i)) * 320,
                payload: [UInt8](repeating: 0, count: 25)
            )
        }
    }

    /// Deterministic decoder: loud for even frames, silent for odd ones.
    private struct EvenLoudDecoder: LiveFrameDecoder {
        func decode(_ frames: [[UInt8]]) async -> [Int16] {
            var out = [Int16](repeating: 0, count: frames.count * 320)
            for index in frames.indices where index % 2 == 0 {
                for s in 0..<320 { out[index * 320 + s] = 8_000 }
            }
            return out
        }
    }

    private struct ConstantDecoder: LiveFrameDecoder {
        let value: Int16
        func decode(_ frames: [[UInt8]]) async -> [Int16] {
            [Int16](repeating: value, count: frames.count * 320)
        }
    }

    private let decoder = EvenLoudDecoder()

    @Test func buildsBoundedBarsWithAmplitudeAndDuration() async {
        let builder = SegmentWaveformBuilder(decoder: decoder, maxBars: 10)
        let wave = await builder.build(meta: meta(frameCount: 100)) { frames(100) }
        #expect(wave.bars.count == 10)
        #expect(wave.mediaDurationMs == 100 * 20)
        // Every bucket mixes loud and silent frames, so all are Recorded with amplitude > 0.
        #expect(wave.bars.allSatisfy { $0.state == .recorded && $0.amplitude > 0 })
    }

    @Test func silentAudioMarksSilenceBars() async {
        let builder = SegmentWaveformBuilder(decoder: ConstantDecoder(value: 0), maxBars: 4)
        let wave = await builder.build(meta: meta(frameCount: 40)) { frames(40) }
        #expect(wave.bars.allSatisfy { $0.state == .silence })
    }

    @Test func lowLevelSpeechMarksRecordedAndVisible() async {
        let builder = SegmentWaveformBuilder(decoder: ConstantDecoder(value: 120), maxBars: 4)
        let wave = await builder.build(meta: meta(frameCount: 40)) { frames(40) }

        #expect(wave.bars.allSatisfy { $0.state == .recorded })
        #expect(wave.bars.allSatisfy { (0.08...0.2).contains($0.amplitude) })
    }

    @Test func gapMarkersLandAtTheMediaPositionOfTheLoss() async {
        // 50 stored frames, then 100 missing (seq 50..149), then 50 more stored (150..199).
        let stored = frames(50) + frames(50, firstSequence: 150)
        let gap = GapMeta(
            firstMissingSequence: 50,
            missingFrameCount: 100,
            firstMissingSampleIndex: 50 * 320,
            origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.micConflict.rawValue)
        )
        let builder = SegmentWaveformBuilder(decoder: decoder, maxBars: 10)
        let wave = await builder.build(meta: meta(frameCount: 100, gaps: [gap])) { stored }
        #expect(wave.gapMarkers.count == 1)
        let marker = wave.gapMarkers[0]
        #expect(marker.fraction == 0.5)
        #expect(marker.approxDurationMs == 2_000)
    }

    @Test func silenceSuppressionProducesNoGapMarker() async {
        // Voice-activity silence the watch skipped is not loss: the stored audio just continues
        // across it, so it must not draw a marker (which would read as something gone wrong).
        let stored = frames(50) + frames(50, firstSequence: 150)
        let gap = GapMeta(
            firstMissingSequence: 50,
            missingFrameCount: 100,
            firstMissingSampleIndex: 50 * 320,
            origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
        )
        let builder = SegmentWaveformBuilder(decoder: decoder, maxBars: 10)
        let wave = await builder.build(meta: meta(frameCount: 100, gaps: [gap])) { stored }
        #expect(wave.gapMarkers.isEmpty)
    }

    @Test func duplicateSequenceSkipCoveredBySilenceProducesNoGapMarker() async {
        let stored = frames(50) + frames(50, firstSequence: 150)
        let quiet = GapMeta(
            firstMissingSequence: 50,
            missingFrameCount: 100,
            firstMissingSampleIndex: 50 * 320,
            origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
        )
        let duplicateSkip = GapMeta(
            firstMissingSequence: 50,
            missingFrameCount: 100,
            firstMissingSampleIndex: 50 * 320,
            origin: GapMeta.originSequenceSkip
        )
        let builder = SegmentWaveformBuilder(decoder: decoder, maxBars: 10)
        let wave = await builder.build(meta: meta(frameCount: 100, gaps: [quiet, duplicateSkip])) { stored }
        #expect(wave.gapMarkers.isEmpty)
    }

    @Test func openSegmentRebuildsOnlyAfterEnoughNewAudio() async {
        let builder = SegmentWaveformBuilder(decoder: decoder, minRebuildDeltaFrames: 500)
        let reads = Box(0)
        let first = await builder.build(meta: meta(frameCount: 1_000, open: true)) {
            reads.value += 1
            return frames(1_000)
        }

        // A small refresh of the still-recording segment serves the cache without re-reading.
        let cached = await builder.build(meta: meta(frameCount: 1_200, open: true)) {
            reads.value += 1
            return frames(1_200)
        }
        #expect(reads.value == 1)
        // (The KMP test asserted `first === cached`; SegmentWaveform is a value type here, so
        // the single read plus equality pins the same caching behavior.)
        #expect(first == cached)

        // Enough new audio forces a rebuild.
        let rebuilt = await builder.build(meta: meta(frameCount: 1_600, open: true)) {
            reads.value += 1
            return frames(1_600)
        }
        #expect(reads.value == 2)
        #expect(rebuilt.mediaDurationMs == 1_600 * 20)

        // Closed segments rebuild on any frame-count change (the final exact waveform).
        _ = await builder.build(meta: meta(frameCount: 1_700)) {
            reads.value += 1
            return frames(1_700)
        }
        #expect(reads.value == 3)
    }

    @Test func emptySegmentYieldsNoBars() async {
        let builder = SegmentWaveformBuilder(decoder: decoder)
        let wave = await builder.build(meta: meta(frameCount: 0)) { [] }
        #expect(wave.bars.isEmpty)
        #expect(wave.gapMarkers.isEmpty)
        #expect(wave.mediaDurationMs == 0)
    }
}
