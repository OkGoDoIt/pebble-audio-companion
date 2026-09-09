import Foundation
import Testing

@testable import AudioCodec

// Stream EN. The levels asserted here are not invented: they are the real numbers measured over
// this user's 88-day library (758 spooled segments, 116 hours) with the app's own libspeex, so a
// change that moves the verdict on one of these fixtures is a change that would have moved the
// verdict on the corpus.

@Suite struct SegmentEnergyTests {
    private static let rate = 16_000

    /// s16le mono PCM: `ms` of a repeating deterministic waveform whose RMS is `rms`.
    ///
    /// A square wave, so RMS == amplitude exactly and the fixtures say what they mean; the meter
    /// only ever sees sums of squares, so waveform shape is irrelevant to what is under test.
    private static func pcm(rms: Int, ms: Int, sampleRateHz: Int = rate) -> Data {
        let samples = sampleRateHz * ms / 1000
        var out = Data(capacity: samples * 2)
        for i in 0..<samples {
            let value = Int16(i % 2 == 0 ? rms : -rms)
            out.append(UInt8(truncatingIfNeeded: value))
            out.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return out
    }

    private static func profile(_ chunks: [Data], sampleRateHz: Int = rate) -> SegmentEnergyProfile
    {
        SegmentEnergy.profile(pcmChunks: chunks, sampleRateHz: sampleRateHz)
    }

    // MARK: - The meter

    @Test func measuresLevelAndDuration() {
        let p = Self.profile([Self.pcm(rms: 500, ms: 2_000)])
        #expect(p.bucketCount == 20)
        #expect(p.durationMs == 2_000)
        #expect(abs(p.peakBucketRms - 500) < 1)
        #expect(abs(p.loudestWindowRms - 500) < 1)
        #expect(p.bucketsAboveFloor == 20)
    }

    @Test func chunkBoundariesDoNotChangeTheProfile() {
        // The two integration points feed the meter differently: the foreground path streams
        // decoder output in ~1 s pieces, the upload path hands over one assembled WAV. They must
        // agree, so the gate cannot depend on which path asked.
        let whole = Self.pcm(rms: 240, ms: 3_300)
        var odd: [Data] = []
        var offset = 0
        // Deliberately odd sizes, so most chunks split a 16-bit sample in half.
        for size in [777, 1_003, 51, 20_001, 33] where offset < whole.count {
            let end = min(whole.count, offset + size)
            odd.append(whole[offset..<end])
            offset = end
        }
        if offset < whole.count { odd.append(whole[offset...]) }

        let one = Self.profile([whole])
        let many = Self.profile(odd)
        #expect(one == many)
    }

    @Test func loudestWindowIsASlidingSecondNotTheWholeAverage() {
        // Two seconds of loud speech then a minute of room tone: the segment average is near the
        // floor, but the recording plainly contains sound and must not be gated.
        let p = Self.profile([Self.pcm(rms: 900, ms: 2_000), Self.pcm(rms: 10, ms: 60_000)])
        #expect(p.loudestWindowRms > 800)
        #expect(!p.isProvablySilent())
    }

    @Test func oneAudibleTransientIsEnoughToKeepASegmentOutOfTheGate() {
        // Ten minutes of near-nothing with a single 100 ms event in the middle. The window
        // averages the event over its second — RMS x alone reads as x/√10 — so the threshold a
        // lone transient has to clear is ≈ 3.2× the floor, about RMS 101. Above that, the segment
        // is never gated however quiet the other ten minutes are. That asymmetry is deliberate:
        // one spoken word should be enough to disqualify the claim "there is no voice here".
        let bare = Self.profile([Self.pcm(rms: 8, ms: 600_000)])
        #expect(bare.isProvablySilent())

        let withEvent = Self.profile([
            Self.pcm(rms: 8, ms: 300_000), Self.pcm(rms: 600, ms: 100),
            Self.pcm(rms: 8, ms: 300_000),
        ])
        #expect(withEvent.peakBucketRms > 500)
        #expect(!withEvent.isProvablySilent())

        // And the boundary itself: the loudest 100 ms anywhere in the 17 segments the real corpus
        // gates is RMS 43, comfortably under it.
        let corpusLoudestGatedPeak = Self.profile([
            Self.pcm(rms: 8, ms: 5_000), Self.pcm(rms: 43, ms: 100), Self.pcm(rms: 8, ms: 5_000),
        ])
        #expect(corpusLoudestGatedPeak.isProvablySilent())
    }

    // MARK: - The verdict, at the levels the real corpus produced

    @Test func digitalSilenceIsProvablySilent() {
        #expect(Self.profile([Data(count: Self.rate * 2)]).isProvablySilent())
    }

    @Test func theMicrophonesOwnNoiseFloorIsProvablySilent() {
        // Measured: the per-segment 5th-percentile 100 ms bucket has median RMS 12 across 608
        // segments of a minute or more. Room tone alone must gate.
        #expect(Self.profile([Self.pcm(rms: 12, ms: 30_000)]).isProvablySilent())
    }

    @Test func theLoudestFabricatedOnlyRecordingWouldHaveBeenGated() {
        // `seg-1786953646307-8b637542-20` and friends: 0.3–3.4 s recordings whose loudest 100 ms
        // never reached RMS 43, each of which the provider answered with one invented word.
        let p = Self.profile([Self.pcm(rms: 28, ms: 3_400)])
        #expect(p.isProvablySilent())
    }

    @Test func theQuietestRealSpeechInTheLibraryIsNotGated() {
        // THE test that decides whether this ships. `seg-1783802161950-a9fa2d8b-16` is 13 minutes
        // of heavily muffled but unmistakably real dictation; its loudest second is RMS 85 and
        // almost all of the rest of it sits under the floor. The gate must keep its hands off.
        let p = Self.profile([
            Self.pcm(rms: 11, ms: 600_000), Self.pcm(rms: 85, ms: 1_000),
            Self.pcm(rms: 11, ms: 200_000),
        ])
        #expect(!p.isProvablySilent())
        #expect(p.loudestWindowRms > SegmentEnergy.provableSilenceFloorRms * 2)
    }

    @Test func floorSitsWellBelowAnythingThatCouldBeSpeech() {
        // Guards the constant itself. 8.5 dB below the quietest verified real speech in 116
        // hours (RMS 85), and comfortably above the microphone's own noise (median RMS 12).
        #expect(SegmentEnergy.provableSilenceFloorRms < 85 / 2.5)
        #expect(SegmentEnergy.provableSilenceFloorRms > 12 * 2)
    }

    // MARK: - When the gate must not fire

    @Test func emptyAudioIsNeverASilenceVerdict() {
        // An empty spool file is a bookkeeping problem, not a quiet room. Claiming "nothing was
        // said" would settle a segment whose audio never arrived.
        let p = Self.profile([])
        #expect(p.isEmpty)
        #expect(!p.isProvablySilent())
    }

    @Test func audioTooShortToJudgeIsNeverASilenceVerdict() {
        // 120 ms of digital silence. Below `minimumMeasurableMs` there is not enough recording to
        // support the claim, whatever the level says.
        #expect(!Self.profile([Data(count: Self.rate * 2 * 120 / 1_000)]).isProvablySilent())
        // …and one bucket over the minimum, the same audio does gate.
        #expect(Self.profile([Data(count: Self.rate * 2 * 300 / 1_000)]).isProvablySilent())
    }

    @Test func aTinyProviderSeamStubIsNotMeasurable() {
        // The provider seam is exercised with sub-frame PCM stubs (4 bytes). A gate that fired on
        // those would be measuring nothing at all.
        #expect(!Self.profile([Data([1, 2, 3, 4])]).isProvablySilent())
        #expect(!Self.profile([Data(count: 4)]).isProvablySilent())
    }

    @Test func aQuietTailDoesNotDragDownALoudRecording() {
        // 20 ms of trailing silence is one codec frame, not a measurement; it must not close out
        // the recording as its own bucket.
        let p = Self.profile([Self.pcm(rms: 700, ms: 1_000), Data(count: Self.rate * 2 * 20 / 1_000)])
        #expect(p.bucketCount == 10)
        #expect(abs(p.peakBucketRms - 700) < 1)
    }

    // MARK: - WAV form (the background upload path measures the assembled body)

    @Test func wavProfileSkipsTheHeader() {
        let body = Self.pcm(rms: 400, ms: 1_000)
        let wav = PcmWav.encodeMono16(pcm: body, sampleRateHz: Self.rate)
        let fromWav = SegmentEnergy.profile(wav: wav, sampleRateHz: Self.rate)
        let fromPcm = SegmentEnergy.profile(pcmChunks: [body], sampleRateHz: Self.rate)
        #expect(fromWav == fromPcm)
    }

    @Test func headerlessBodyIsMeasuredAsRawPcm() {
        // Test seams hand the coordinator arbitrary bytes; a body with no RIFF magic is measured
        // whole rather than losing its first 44 bytes.
        let raw = Self.pcm(rms: 400, ms: 1_000)
        #expect(SegmentEnergy.profile(wav: raw, sampleRateHz: Self.rate).bucketCount == 10)
    }

    @Test func silentWavGatesAndLoudWavDoesNot() {
        let quiet = PcmWav.encodeMono16(
            pcm: Self.pcm(rms: 14, ms: 5_000), sampleRateHz: Self.rate)
        let loud = PcmWav.encodeMono16(
            pcm: Self.pcm(rms: 300, ms: 5_000), sampleRateHz: Self.rate)
        #expect(SegmentEnergy.profile(wav: quiet, sampleRateHz: Self.rate).isProvablySilent())
        #expect(!SegmentEnergy.profile(wav: loud, sampleRateHz: Self.rate).isProvablySilent())
    }

    @Test func bucketsTrackTheSampleRate() {
        // 8 kHz audio still buckets at 100 ms, so the verdict does not shift with rate.
        let p = SegmentEnergy.profile(
            pcmChunks: [Self.pcm(rms: 200, ms: 1_000, sampleRateHz: 8_000)], sampleRateHz: 8_000)
        #expect(p.bucketCount == 10)
        #expect(abs(p.loudestWindowRms - 200) < 1)
    }
}
