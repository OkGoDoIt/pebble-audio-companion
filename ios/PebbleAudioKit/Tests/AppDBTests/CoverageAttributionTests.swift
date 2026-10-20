import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// `CoverageComputer.computeAttributed` is `compute` plus the records each span came from, and
// the watch-quiet recut moved down from the app (`LiveTimeline`). Both moves must change NOTHING
// about what is drawn, so this suite keeps verbatim copies of the code as it was before the
// change and compares, over hand-picked days and a seeded fuzz of every gap reason, pause shape,
// close bound and "now".

@Suite struct CoverageAttributionTests {
    let zone = "UTC"
    let dateKey = "2026-03-10"
    var dayStart: Int64 { LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: zone)!.startMs }

    @Test func attributedCoverageIsComputeToTheMillisecond() {
        var rng = SplitMixGenerator(seed: 0x5EED_C0DE)
        var seen: Set<CoverageKind> = []
        for _ in 0..<400 {
            let day = randomCoverageDay(&rng, dayStart: dayStart)
            let legacy = legacyCompute(
                dateKey: dateKey, timeZoneID: zone, segments: day.segments, pauses: day.pauses,
                nowMs: day.nowMs)
            let attributed = CoverageComputer.computeAttributed(
                dateKey: dateKey, timeZoneID: zone, segments: day.segments, pauses: day.pauses,
                nowMs: day.nowMs)
            let plain = CoverageComputer.compute(
                dateKey: dateKey, timeZoneID: zone, segments: day.segments, pauses: day.pauses,
                nowMs: day.nowMs)
            #expect(attributed.coverage == legacy)
            #expect(plain == legacy)
            seen.formUnion(legacy.spans.map(\.kind))
        }
        // The fuzz reaches every kind, or the comparison above proves less than it claims.
        #expect(seen == [.recorded, .quiet, .missing, .paused, .off])
    }

    @Test func everyMissingAndPausedSpanIsExplainedByItsRecords() {
        var rng = SplitMixGenerator(seed: 42)
        for _ in 0..<300 {
            let day = randomCoverageDay(&rng, dayStart: dayStart)
            let attributed = CoverageComputer.computeAttributed(
                dateKey: dateKey, timeZoneID: zone, segments: day.segments, pauses: day.pauses,
                nowMs: day.nowMs)
            let loss = mergeRanges(attributed.lossRecords.map(\.range))
            let paused = mergeRanges(
                attributed.pauseRecords.map(\.range) + attributed.watchPauseRecords.map(\.range))
            for span in attributed.coverage.spans {
                let range = span.startMs..<span.endMs
                switch span.kind {
                case .missing:
                    #expect(subtractRanges([range], subtracting: loss).isEmpty)
                case .paused:
                    #expect(subtractRanges([range], subtracting: paused).isEmpty)
                default: break
                }
            }
            // And nothing the records list is outside the drawn day.
            if let domain = attributed.domain {
                for record in attributed.lossRecords + attributed.watchPauseRecords {
                    #expect(clip(record.range, to: domain) == record.range)
                }
                for record in attributed.lossRecords {
                    #expect(GapClassifier(day.segments.first { $0.meta.segmentId == record.segmentId }!.meta.gaps)
                        .classify(record.gap) == .loss)
                }
            }
        }
    }

    @Test func movedQuietRecutMatchesTheAppsCopy() {
        var rng = SplitMixGenerator(seed: 7)
        for _ in 0..<300 {
            let day = randomCoverageDay(&rng, dayStart: dayStart)
            let metas = day.segments.map(\.meta)
            #expect(CoverageComputer.silenceWindows(metas) == legacySilenceWindows(metas))
            let spans = CoverageComputer.compute(
                dateKey: dateKey, timeZoneID: zone, segments: day.segments, pauses: day.pauses,
                nowMs: day.nowMs
            ).spans
            let silence = legacySilenceWindows(metas)
            #expect(
                CoverageComputer.applyingQuiet(spans, silence: silence)
                    == legacyMerged(legacyApplyingQuiet(spans, silence: silence)))
        }
    }

    @Test func quietRecutOnlyTouchesRecordedTime() {
        // Minute 0-1 recorded, 1-2 a silence record, 2-3 a transport reset, 3-4 recorded.
        let start = dayStart + minutesMs(60)
        let meta = makeSegment(
            id: "s", stream: 1, startTimeMs: start, durationSamples: minutesSamples(4),
            gaps: [
                silenceGap(atSample: minutesSamples(1), minutes: 1),
                lossGap(atSample: minutesSamples(2), minutes: 1),
            ])
        let attributed = CoverageComputer.computeAttributed(
            dateKey: dateKey, timeZoneID: zone, segments: [SegmentCoverageInput(meta: meta)],
            pauses: [])
        #expect(attributed.silence == [start + minutesMs(1)..<start + minutesMs(2)])
        #expect(attributed.lossRecords.map(\.range) == [start + minutesMs(2)..<start + minutesMs(3)])
        let kinds = attributed.spansWithWatchQuiet.filter { $0.startMs >= start && $0.endMs <= start + minutesMs(4) }
        #expect(kinds.map(\.kind) == [.recorded, .quiet, .missing, .recorded])
    }
}

// MARK: - Fuzzed days

struct FuzzCoverageDay {
    var segments: [SegmentCoverageInput]
    var pauses: [PauseInterval]
    var nowMs: Int64?
}

/// SplitMix64: deterministic, so a failure reproduces from its seed.
struct SplitMixGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Every gap reason (and an undecodable one, and a receiver skip), sometimes outside the
/// segment's own extent, sometimes past its close; frame ranges on some segments; user pauses,
/// open and closed; and "now" on some days.
func randomCoverageDay(_ rng: inout SplitMixGenerator, dayStart: Int64) -> FuzzCoverageDay {
    var segments: [SegmentCoverageInput] = []
    let count = Int.random(in: 0...6, using: &rng)
    for index in 0..<count {
        let startMs = dayStart + Int64.random(in: -120...1_500, using: &rng) * 60_000
        let first = UInt64.random(in: 0...20, using: &rng) * 16_000 * 30
        let length = UInt64.random(in: 1...90, using: &rng) * 960_000 / UInt64.random(in: 1...4, using: &rng)
        var gaps: [GapMeta] = []
        for _ in 0..<Int.random(in: 0...8, using: &rng) {
            // From 10 minutes before the first sample to a little past the last.
            let offset = Int64.random(in: -600...Int64(length / 16_000) + 120, using: &rng) * 16_000
            let at = UInt64(max(0, Int64(first) + offset))
            let frames = UInt32.random(in: 1...30_000, using: &rng)
            let pick = Int.random(in: 0...10, using: &rng)
            let reason: Int? =
                pick <= 7 ? pick + 1 : (pick == 8 ? 99 : (pick == 9 ? nil : Int(GapReason.silenceSuppressed.rawValue)))
            let isSkip = Int.random(in: 0...5, using: &rng) == 0
            gaps.append(
                GapMeta(
                    firstMissingSequence: UInt32(at / 320), missingFrameCount: frames,
                    firstMissingSampleIndex: at,
                    origin: isSkip ? GapMeta.originSequenceSkip : GapMeta.originWatch,
                    reasonRaw: isSkip ? nil : reason))
        }
        var meta = makeSegment(
            id: "seg-\(index)", stream: UInt32(index + 1), startTimeMs: startMs - Int64(first / 16),
            firstSample: first, durationSamples: length, gaps: gaps)
        switch Int.random(in: 0...3, using: &rng) {
        case 0: meta.closedAtMs = nil
        case 1: meta.closedAtMs = startMs + Int64(length / 16) / 2
        default: break
        }
        var frameRanges: [Range<UInt64>]?
        if Bool.random(using: &rng) {
            var ranges: [Range<UInt64>] = []
            var cursor = first
            while cursor < first + length {
                let run = UInt64.random(in: 1...200, using: &rng) * 320 * 50
                let hole = UInt64.random(in: 0...100, using: &rng) * 320 * 50
                ranges.append(cursor..<min(cursor + run, first + length))
                cursor += run + hole
            }
            frameRanges = ranges
        }
        segments.append(SegmentCoverageInput(meta: meta, frameSampleRanges: frameRanges))
    }
    var pauses: [PauseInterval] = []
    for _ in 0..<Int.random(in: 0...2, using: &rng) {
        let start = dayStart + Int64.random(in: -60...1_440, using: &rng) * 60_000
        let open = Int.random(in: 0...4, using: &rng) == 0
        pauses.append(
            PauseInterval(
                startMs: start,
                endMs: open ? nil : start + Int64.random(in: 0...240, using: &rng) * 60_000,
                source: ["statusCard", "schedule", "forgetWatch", "legacy"].randomElement(using: &rng)!))
    }
    let nowMs: Int64? =
        Bool.random(using: &rng) ? dayStart + Int64.random(in: -10...1_500, using: &rng) * 60_000 : nil
    return FuzzCoverageDay(segments: segments, pauses: pauses, nowMs: nowMs)
}

// MARK: - The code as it was (verbatim), for the equivalence tests

/// `CoverageComputer.compute` before `computeAttributed` (ac6f667).
private func legacyCompute(
    dateKey: String,
    timeZoneID: String,
    segments: [SegmentCoverageInput],
    pauses: [PauseInterval],
    nowMs: Int64? = nil
) -> DayCoverage {
    guard let bounds = LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: timeZoneID) else {
        return DayCoverage(
            dateKey: dateKey, timeZoneID: timeZoneID, spans: [],
            totalRecordedMs: 0, totalMissingMs: 0)
    }
    let domainStart = bounds.startMs
    let domainEnd = min(bounds.endMs, nowMs ?? bounds.endMs)
    guard domainEnd > domainStart else {
        return DayCoverage(
            dateKey: dateKey, timeZoneID: timeZoneID, spans: [],
            totalRecordedMs: 0, totalMissingMs: 0)
    }
    let domain = domainStart..<domainEnd

    var recorded: [Range<Int64>] = []
    var missing: [Range<Int64>] = []
    var quiet: [Range<Int64>] = []
    var watchPaused: [Range<Int64>] = []

    for input in segments {
        let meta = input.meta
        let frameSamples = UInt64(meta.frameSamples > 0 ? meta.frameSamples : 320)
        func toWall(_ ranges: [Range<UInt64>]) -> [Range<Int64>] {
            ranges.compactMap { range in
                let start = ConversationGrouper.wallMs(ofSample: range.lowerBound, in: meta)
                let end = ConversationGrouper.wallMs(ofSample: range.upperBound, in: meta)
                return clip(start..<end, to: domain)
            }
        }
        let closeBound = meta.closedAtMs.map { $0 + CoverageComputer.recordAfterCloseSlackMs }
        let classifier = GapClassifier(meta.gaps)
        let lossSamples = mergeRanges(
            meta.gaps.filter { classifier.classify($0) == .loss && $0.missingFrameCount > 0 }.map { gap in
                let start = gap.firstMissingSampleIndex
                return start..<(start + UInt64(gap.missingFrameCount) * frameSamples)
            }
        )
        missing += toWall(lossSamples).compactMap { range in
            guard let closeBound else { return range }
            return clip(range, to: range.lowerBound..<max(range.lowerBound, closeBound))
        }
        let pausedSamples = mergeRanges(
            meta.gaps.filter { classifier.classify($0) == .watchPause && $0.missingFrameCount > 0 }.map { gap in
                let start = gap.firstMissingSampleIndex
                return start..<(start + UInt64(gap.missingFrameCount) * frameSamples)
            }
        )
        watchPaused += toWall(pausedSamples).compactMap { range in
            guard let closeBound else { return range }
            return clip(range, to: range.lowerBound..<max(range.lowerBound, closeBound))
        }
        guard let first = meta.firstSampleIndex, let last = meta.lastSampleIndexExclusive,
            last > first
        else { continue }
        let extent = first..<last
        let lossInExtent = mergeRanges(lossSamples + pausedSamples).compactMap { clip($0, to: extent) }
        let recordedSamples: [Range<UInt64>]
        let quietSamples: [Range<UInt64>]
        if let frameRanges = input.frameSampleRanges {
            let frames = mergeRanges(frameRanges.compactMap { clip($0, to: extent) })
            recordedSamples = frames
            quietSamples = subtractRanges(
                [extent], subtracting: mergeRanges(frames + lossInExtent))
        } else {
            recordedSamples = subtractRanges([extent], subtracting: lossInExtent)
            quietSamples = []
        }
        recorded += toWall(recordedSamples)
        quiet += toWall(quietSamples)
    }

    let paused = pauses.compactMap { pause -> Range<Int64>? in
        let end = pause.endMs ?? domainEnd
        guard end > pause.startMs else { return nil }
        return clip(pause.startMs..<end, to: domain)
    } + watchPaused

    let layers: [(kind: CoverageKind, ranges: [Range<Int64>])] = [
        (.recorded, mergeRanges(recorded)),
        (.paused, mergeRanges(paused)),
        (.missing, mergeRanges(missing)),
        (.quiet, mergeRanges(quiet)),
    ]
    var boundaries: Set<Int64> = [domainStart, domainEnd]
    for layer in layers {
        for range in layer.ranges {
            boundaries.insert(range.lowerBound)
            boundaries.insert(range.upperBound)
        }
    }
    let sorted = boundaries.sorted()
    var spans: [CoverageSpan] = []
    for (a, b) in zip(sorted, sorted.dropFirst()) where b > a {
        let kind =
            layers
            .filter { layer in layer.ranges.contains { $0.lowerBound <= a && $0.upperBound >= b } }
            .min { CoverageComputer.priority($0.kind) < CoverageComputer.priority($1.kind) }?.kind ?? .off
        if let lastSpan = spans.last, lastSpan.kind == kind, lastSpan.endMs == a {
            spans[spans.count - 1].endMs = b
        } else {
            spans.append(CoverageSpan(kind: kind, startMs: a, endMs: b))
        }
    }
    let totalRecorded = spans.filter { $0.kind == .recorded }.map(\.durationMs).reduce(0, +)
    let totalMissing = spans.filter { $0.kind == .missing }.map(\.durationMs).reduce(0, +)
    return DayCoverage(
        dateKey: dateKey, timeZoneID: timeZoneID, spans: spans,
        totalRecordedMs: totalRecorded, totalMissingMs: totalMissing)
}

/// `App/Screens/Live/LiveTimeline.silenceWindows` (verbatim but for the wall-clock helper, which
/// is the same formula as `ConversationGrouper.wallMs`).
private func legacySilenceWindows(_ metas: [SegmentMeta]) -> [Range<Int64>] {
    func wallMs(_ sampleIndex: UInt64, in meta: SegmentMeta) -> Int64 {
        let rate = meta.sampleRateHz > 0 ? UInt64(meta.sampleRateHz) : 16_000
        return Int64(meta.startTimeMs) + Int64(sampleIndex * 1000 / rate)
    }
    var windows: [Range<Int64>] = []
    for meta in metas {
        guard let first = meta.firstSampleIndex, let last = meta.lastSampleIndexExclusive,
            last > first
        else { continue }
        let frameSamples = UInt64(meta.frameSamples > 0 ? meta.frameSamples : 320)
        for gap in meta.gaps {
            guard gap.origin != GapMeta.originSequenceSkip,
                let raw = gap.reasonRaw,
                let reason = UInt8(exactly: raw).flatMap(GapReason.init(rawValue:)),
                reason.isSilence
            else { continue }
            let lower = max(gap.firstMissingSampleIndex, first)
            let upper = min(
                gap.firstMissingSampleIndex + UInt64(gap.missingFrameCount) * frameSamples,
                last)
            guard upper > lower else { continue }
            windows.append(wallMs(lower, in: meta)..<wallMs(upper, in: meta))
        }
    }
    return mergeRanges(windows)
}

/// `LiveTimeline.applyingQuiet` (verbatim).
private func legacyApplyingQuiet(
    _ spans: [CoverageSpan], silence: [Range<Int64>]
) -> [CoverageSpan] {
    guard !silence.isEmpty else { return spans }
    return spans.flatMap { span -> [CoverageSpan] in
        guard span.kind == .recorded else { return [span] }
        var pieces: [CoverageSpan] = []
        var cursor = span.startMs
        for window in silence
        where window.upperBound > span.startMs && window.lowerBound < span.endMs {
            let lower = max(window.lowerBound, cursor)
            let upper = min(window.upperBound, span.endMs)
            guard upper > lower else { continue }
            if lower > cursor {
                pieces.append(CoverageSpan(kind: .recorded, startMs: cursor, endMs: lower))
            }
            pieces.append(CoverageSpan(kind: .quiet, startMs: lower, endMs: upper))
            cursor = upper
        }
        if cursor < span.endMs {
            pieces.append(CoverageSpan(kind: .recorded, startMs: cursor, endMs: span.endMs))
        }
        return pieces.isEmpty ? [span] : pieces
    }
}

/// `LiveTimeline.merged(_: [CoverageSpan])` (verbatim).
private func legacyMerged(_ spans: [CoverageSpan]) -> [CoverageSpan] {
    var result: [CoverageSpan] = []
    for span in spans {
        if var last = result.last, last.kind == span.kind, last.endMs == span.startMs {
            last.endMs = span.endMs
            result[result.count - 1] = last
        } else {
            result.append(span)
        }
    }
    return result
}
