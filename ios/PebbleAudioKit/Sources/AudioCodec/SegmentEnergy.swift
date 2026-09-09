import Foundation

// Energy measurement for decoded segment audio, and the one question it is allowed to answer:
// "is there demonstrably no voice in this recording at all?"
//
// WHY THIS EXISTS. Cloud and on-device ASR both confabulate on near-silence: handed a stretch of
// room tone they return fluent, plausible, entirely invented sentences. Stream HC measured 5.0% of
// this user's transcribed corpus (25,669 words) as hallucination and shipped a text-side detector
// for the *looping* class. The rest is non-repeating confabulation, which HC proved is not
// separable from text alone. Audio is the other side of that: if the provider never sees the
// silence, it cannot invent anything from it — and the user does not pay to transcribe it.
//
// WHY IT IS DELIBERATELY BLUNT. This is a FLOOR, not a classifier. HC established, and the
// measurements below confirm, that loudness does NOT separate quiet-but-real speech from
// confabulated room tone anywhere in the interesting range. So this file does not try. It answers
// only the far weaker question — is this recording, end to end, within a few dB of the
// microphone's own electrical noise? — and stays silent about everything else.

/// Per-100 ms RMS summary of one segment's decoded PCM, and the silence verdict derived from it.
///
/// Deliberately O(1) in the segment's length: a three-hour segment summarises into the same
/// handful of numbers as a three-second one. Nothing here retains the per-bucket series, because
/// the only supported verdict is whole-segment (see `SegmentEnergy.provableSilenceFloorRms` for
/// why interior stretches are not).
public struct SegmentEnergyProfile: Equatable, Sendable {
    /// Number of complete 100 ms buckets measured.
    public let bucketCount: Int

    /// Loudest single 100 ms bucket, as RMS on the 16-bit sample scale.
    public let peakBucketRms: Double

    /// Loudest contiguous `SegmentEnergy.windowBuckets`-bucket window (1 second), as RMS. This is
    /// the statistic the silence verdict is made on — see the note on the floor constant.
    public let loudestWindowRms: Double

    /// Buckets whose own RMS clears the floor. Diagnostics only: a segment can have a handful of
    /// these and still be provably silent overall, which is exactly what a single door-slam in an
    /// empty room looks like.
    public let bucketsAboveFloor: Int

    public var durationMs: Int { bucketCount * SegmentEnergy.bucketMs }

    /// Nothing measurable was decoded. Never a silence verdict: an empty spool file is a
    /// bookkeeping problem, not a quiet room, and the providers already have their own terminal
    /// handling for it.
    public var isEmpty: Bool { bucketCount == 0 }

    public init(
        bucketCount: Int, peakBucketRms: Double, loudestWindowRms: Double, bucketsAboveFloor: Int
    ) {
        self.bucketCount = bucketCount
        self.peakBucketRms = peakBucketRms
        self.loudestWindowRms = loudestWindowRms
        self.bucketsAboveFloor = bucketsAboveFloor
    }

    /// True only when this recording demonstrably contains no voice: long enough to make the
    /// claim, and its loudest whole second still under the floor.
    ///
    /// The three conditions are all load-bearing.
    /// - `!isEmpty` — see above.
    /// - `durationMs >= minimumMeasurableMs` — a 12 ms buffer cannot support "there is no voice
    ///   here"; the sliding window has not even filled once.
    /// - `loudestWindowRms < floor` — the whole-segment form. Not a percentile: on the real
    ///   corpus p95 puts a confabulated segment at 59 and a real, distant conversation at 91,
    ///   which is not a decision anyone should make. The loudest second separates the same two
    ///   by 8 dB, because a recording that contains speech has at least ONE loud second in it.
    public func isProvablySilent(floorRms: Double = SegmentEnergy.provableSilenceFloorRms) -> Bool {
        guard !isEmpty, durationMs >= SegmentEnergy.minimumMeasurableMs else { return false }
        return loudestWindowRms < floorRms
    }
}

public enum SegmentEnergy {
    /// Analysis bucket. 100 ms is short enough to hold a single syllable and long enough that one
    /// codec artefact cannot move it.
    public static let bucketMs = 100

    /// Buckets per measurement window: 1 second.
    public static let windowBuckets = 10

    /// Below this much audio the gate does not fire, whatever the level.
    ///
    /// Two buckets is the least that gives the window statistic any meaning. It also keeps the
    /// gate away from the sub-frame PCM stubs the provider seam is exercised with — a gate that
    /// fires on 4 bytes of test data would be measuring nothing at all.
    public static let minimumMeasurableMs = 200

    /// Loudest-second RMS below which a recording is treated as containing no voice.
    ///
    /// **32 of 32768 full scale = −60.2 dBFS.** Every number below was measured over this user's
    /// real library — 758 spooled segments, 116 hours, 88 days — decoded to per-100 ms RMS with
    /// the same vendored libspeex this app ships (stream HC's harness), so they describe this
    /// microphone through this codec and not audio in general.
    ///
    /// What the floor sits between:
    /// - **The microphone's own noise.** Per-segment 5th-percentile bucket: median RMS 12
    ///   (−68.7 dBFS), upper quartile 20. The floor is ~8.5 dB above that, so merely having a
    ///   noise floor never trips it.
    /// - **The quietest real speech in 116 hours.** A heavily muffled dictation
    ///   (`seg-1783802161950-a9fa2d8b-16`, 13 min, unmistakably real content) peaks at a loudest
    ///   second of RMS 85, −51.7 dBFS. The floor is **8.5 dB below** it. A median recording's
    ///   loudest second is RMS 1733 (−25.5 dBFS) — 35 dB of headroom.
    ///
    /// What it actually selects, on that corpus: **17 of 758 segments, 1.4 minutes of 116 hours.**
    /// Twelve had already ended as `NoSpeech` — meaning they had been uploaded and paid for to
    /// learn that. The other five had each produced a single fabricated word ("Okay.", "Okay.",
    /// "Oliver.", "Oliver.", "Oliver.") from 0.3–3.4 s recordings whose loudest 100 ms anywhere
    /// never reached RMS 43. **Zero of the seventeen contain real speech.** That set is small
    /// enough to have been inspected in full, which is the point of a floor this low.
    ///
    /// Two tempting alternatives were measured and rejected:
    /// - **A higher floor (40).** It would also catch an 88-second, 40-word confabulation whose
    ///   loudest second is 38 — but it leaves only 6.5 dB below the quietest verified real speech.
    ///   Forty invented words are not worth narrowing that margin: the audio survives either way,
    ///   but calling a real recording "quiet" is the one thing this product must never do.
    /// - **A relative floor** (crest above the segment's own noise floor). It is *anti*-correlated
    ///   here: a verified-real segment recorded over constant background music has a crest of
    ///   2.7×, while the confabulated 88-second one has 4.2×. Absolute level, or nothing.
    ///
    /// And why this is whole-segment only: applying the same floor to interior stretches of ≥30 s
    /// would cover 203 minutes of the corpus and 6,205 transcript words — mostly the looping
    /// confabulation HC catalogued, but the tail of that set is real, quiet conversation
    /// (`seg-1788030589092-f4c48ea5-27`, `seg-1788196204033-88801da6-1`,
    /// `seg-1788892202958-2f61501a-2` among others). Interior gating cannot be shipped without
    /// deleting real speech, so it is not.
    public static let provableSilenceFloorRms: Double = 32

    /// Streaming profile over PCM16 mono chunks, in the order a provider would receive them.
    public static func profile(
        pcmChunks: some Sequence<Data>,
        sampleRateHz: Int,
        floorRms: Double = provableSilenceFloorRms
    ) -> SegmentEnergyProfile {
        var meter = SegmentEnergyMeter(sampleRateHz: sampleRateHz, floorRms: floorRms)
        for chunk in pcmChunks { meter.consume(chunk) }
        return meter.finish()
    }

    /// Profile of a WAV body — the exact bytes the background upload path is about to send.
    ///
    /// Skips a 44-byte canonical `PcmWav` header when one is present. Anything shorter, or not
    /// starting with `RIFF`, is measured as raw PCM: this is a measurement, and guessing wrong
    /// about a header can only add two samples of noise to a bucket.
    public static func profile(
        wav: Data, sampleRateHz: Int, floorRms: Double = provableSilenceFloorRms
    ) -> SegmentEnergyProfile {
        var body = wav
        if wav.count > PcmWav.headerBytes, wav.prefix(4).elementsEqual("RIFF".utf8) {
            body = wav.dropFirst(PcmWav.headerBytes)
        }
        return profile(pcmChunks: [body], sampleRateHz: sampleRateHz, floorRms: floorRms)
    }
}

/// Incremental per-100 ms RMS meter for PCM16 mono, fed in arbitrary chunk sizes.
///
/// Chunk boundaries never move a bucket boundary: sample accounting carries across `consume`
/// calls, so streaming a segment in 4 KB pieces and measuring it in one buffer give the identical
/// profile. That matters because the two integration points feed it differently — the foreground
/// path streams decoder output, the upload path hands over one assembled WAV.
public struct SegmentEnergyMeter {
    private let samplesPerBucket: Int
    private let floorRms: Double

    private var bucketSumSquares: Double = 0
    private var bucketSamples: Int = 0

    private var bucketCount = 0
    private var peakBucketRms: Double = 0
    private var bucketsAboveFloor = 0

    /// Ring of the last `windowBuckets` bucket mean-squares, plus their running sum, so the
    /// sliding window costs one add and one subtract per bucket instead of a rescan.
    private var window: [Double]
    private var windowIndex = 0
    private var windowFill = 0
    private var windowSum: Double = 0
    private var bestWindowMeanSquare: Double = 0

    /// Odd trailing sample of a chunk that split a 16-bit frame in half.
    private var pendingLowByte: UInt8?

    public init(sampleRateHz: Int, floorRms: Double = SegmentEnergy.provableSilenceFloorRms) {
        // A zero or negative rate would make the bucket meaningless; clamp to at least one sample
        // so the meter degrades to "one bucket per sample" rather than dividing by zero.
        self.samplesPerBucket = max(1, sampleRateHz * SegmentEnergy.bucketMs / 1000)
        self.floorRms = floorRms
        self.window = [Double](repeating: 0, count: SegmentEnergy.windowBuckets)
    }

    public mutating func consume(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var index = 0
            if let low = pendingLowByte {
                pendingLowByte = nil
                accumulate(low: low, high: raw[0])
                index = 1
            }
            while index + 1 < raw.count {
                accumulate(low: raw[index], high: raw[index + 1])
                index += 2
            }
            if index < raw.count { pendingLowByte = raw[index] }
        }
    }

    /// Closes the last bucket and returns the profile.
    ///
    /// A partial trailing bucket is kept only when it holds at least half a bucket. A 20 ms
    /// remainder is a codec frame, not a measurement, and letting one quiet frame close out a
    /// loud segment would understate its peak.
    public mutating func finish() -> SegmentEnergyProfile {
        if bucketSamples * 2 >= samplesPerBucket { closeBucket() }
        // A recording shorter than the window has no full window to slide; its loudest "second"
        // is the whole of it. Longer ones use only complete windows, so a single loud bucket at
        // the very start cannot stand in for a second of sound.
        let best =
            bucketCount < SegmentEnergy.windowBuckets
            ? (windowFill > 0 ? windowSum / Double(windowFill) : 0)
            : bestWindowMeanSquare
        return SegmentEnergyProfile(
            bucketCount: bucketCount,
            peakBucketRms: peakBucketRms,
            loudestWindowRms: best.squareRoot(),
            bucketsAboveFloor: bucketsAboveFloor
        )
    }

    private mutating func accumulate(low: UInt8, high: UInt8) {
        let sample = Double(Int16(bitPattern: UInt16(low) | (UInt16(high) << 8)))
        bucketSumSquares += sample * sample
        bucketSamples += 1
        if bucketSamples == samplesPerBucket { closeBucket() }
    }

    private mutating func closeBucket() {
        guard bucketSamples > 0 else { return }
        let meanSquare = bucketSumSquares / Double(bucketSamples)
        let rms = meanSquare.squareRoot()
        bucketCount += 1
        if rms > peakBucketRms { peakBucketRms = rms }
        if rms >= floorRms { bucketsAboveFloor += 1 }

        windowSum -= window[windowIndex]
        window[windowIndex] = meanSquare
        windowSum += meanSquare
        windowIndex = (windowIndex + 1) % SegmentEnergy.windowBuckets
        windowFill = min(windowFill + 1, SegmentEnergy.windowBuckets)
        if windowFill == SegmentEnergy.windowBuckets {
            let mean = windowSum / Double(SegmentEnergy.windowBuckets)
            if mean > bestWindowMeanSquare { bestWindowMeanSquare = mean }
        }

        bucketSumSquares = 0
        bucketSamples = 0
    }
}
