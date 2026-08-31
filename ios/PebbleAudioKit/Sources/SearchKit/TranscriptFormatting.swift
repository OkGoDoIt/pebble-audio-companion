import Foundation
import SegmentStore
import StatusUI
import WireProtocol

// Port of the pure transcript-formatting derivations from `app/.../ui/LibraryScreen.kt`, pinned
// by `TranscriptFormattingTest`. These behaviors are the spec for the rebuilt transcript
// renderer.
//
// Structural adjustments vs KMP (mirrored in SearchKitTests):
// - `SegmentTranscript` (a Transcription-module type) is replaced by the local
//   `TranscriptContent` slice (text + segments + words) — SearchKit deliberately does not
//   depend on the Transcription module.
// - The KMP sealed interface `TranscriptTimelineItem` is a Swift enum with payload structs.
//
// NOT here (plan 4.7): the old hand-rolled fuzzy-search ENGINE. The product's search is the
// persistent FTS5 index in `TranscriptIndex.swift`, which indexes transcript text and ranks
// with bm25; the KMP scorer was ported alongside it, reached no screen, and was deleted rather
// than left looking like a second search engine someone might "fix" search by reaching for.
//
// Gap classification and its plain-language copy come from StatusUI — the one status
// vocabulary. This file used to carry a private copy of both, and the copy had already drifted:
// StatusUI's classifier was rewritten to O(log n) after the O(n²) original froze the main
// thread for ~12 s on a segment with thousands of gap records, and the copy here — the one that
// actually renders transcripts — never got that fix.

// MARK: - Input slices

/// Transcript display slice: durable text plus provider phrase/word timings.
public struct TranscriptContent: Equatable, Sendable {
    public var text: String
    public var segments: [TranscriptSegment]
    public var words: [TranscriptWord]

    public init(text: String, segments: [TranscriptSegment] = [], words: [TranscriptWord] = []) {
        self.text = text
        self.segments = segments
        self.words = words
    }
}

/// One provider phrase/window with timings (display slice).
public struct TranscriptSegment: Equatable, Sendable {
    public var text: String
    public var startMs: Int64
    public var endMs: Int64
    public var speaker: String?

    public init(text: String, startMs: Int64, endMs: Int64, speaker: String? = nil) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
    }
}

/// One provider word timing (display slice).
public struct TranscriptWord: Equatable, Sendable {
    public var text: String
    public var startMs: Int64
    public var endMs: Int64

    public init(text: String, startMs: Int64, endMs: Int64) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

// MARK: - Speaker presentation

/// Presents a raw provider speaker id ("1", "agent") as a friendly label ("Speaker 1", "Agent").
public func speakerLabel(_ speaker: String) -> String {
    let trimmed = speaker.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return trimmed }
    if trimmed.allSatisfy({ $0.isNumber }) {
        return "Speaker \(trimmed)"
    }
    if let first = trimmed.first, first.isLowercase {
        return first.uppercased() + trimmed.dropFirst()
    }
    return trimmed
}

/// Number of distinct speaker colors the UI cycles through.
public let speakerColorCount = 6

/// Stable palette index for a speaker label: numeric speakers stay stable and distinct; named
/// speakers hash (Kotlin 32-bit `acc * 31 + code` semantics preserved).
public func speakerColorIndex(_ speaker: String) -> Int {
    let normalized = speaker.trimmingCharacters(in: .whitespaces)
    let digits =
        normalized.hasPrefix("Speaker ")
        ? String(normalized.dropFirst("Speaker ".count)) : normalized
    if !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), let number = Int(digits), number > 0 {
        return (number - 1) % speakerColorCount
    }
    var hash: Int32 = 0
    for unit in normalized.lowercased().utf16 {
        hash = hash &* 31 &+ Int32(unit)
    }
    let count = Int32(speakerColorCount)
    return Int(((hash % count) + count) % count)
}

// MARK: - Timeline items

public enum TranscriptTimelineItem: Equatable, Sendable {
    public struct Speech: Equatable, Sendable {
        public var startMs: Int64
        public var endMs: Int64
        public var text: String
        public var speaker: String?

        public init(startMs: Int64, endMs: Int64, text: String, speaker: String? = nil) {
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
            self.speaker = speaker
        }
    }

    /// A short unlabeled visual break between paragraphs (5–30 s of nothing).
    public struct Break: Equatable, Sendable {
        public var startMs: Int64
        public var durationMs: Int64

        public init(startMs: Int64, durationMs: Int64) {
            self.startMs = startMs
            self.durationMs = durationMs
        }
    }

    /// A labeled pause row: genuine loss (`missing == true`, "audio interrupted…") or calm
    /// known-quiet time (`missing == false`, "quiet for…"). Never conflated.
    public struct Pause: Equatable, Sendable {
        public var startMs: Int64
        public var durationMs: Int64
        public var missing: Bool
        public var reasons: [String]

        public init(startMs: Int64, durationMs: Int64, missing: Bool, reasons: [String] = []) {
            self.startMs = startMs
            self.durationMs = durationMs
            self.missing = missing
            self.reasons = reasons
        }

        public var label: String {
            if missing {
                let base =
                    durationMs < 1_000
                    ? "audio briefly interrupted"
                    : "audio interrupted for \(Formatting.duration(durationMs))"
                if let summary = reasonSummary { return "\(base) (\(summary))" }
                return base
            }
            return "quiet for \(Formatting.duration(durationMs))"
        }

        private var reasonSummary: String? {
            switch reasons.count {
            case 0: return nil
            case 1: return reasons[0]
            default: return "several reasons"
            }
        }
    }

    case speech(Speech)
    case silenceBreak(Break)
    case pause(Pause)

    public var startMs: Int64 {
        switch self {
        case .speech(let item): return item.startMs
        case .silenceBreak(let item): return item.startMs
        case .pause(let item): return item.startMs
        }
    }

    public var asSpeech: Speech? {
        if case .speech(let item) = self { return item }
        return nil
    }

    public var asBreak: Break? {
        if case .silenceBreak(let item) = self { return item }
        return nil
    }

    public var asPause: Pause? {
        if case .pause(let item) = self { return item }
        return nil
    }
}

let silenceBreakThresholdMs: Int64 = 5_000
let quietPauseThresholdMs: Int64 = 30_000
let gapCollapseWindowMs: Int64 = 5_000

/// Derives the transcript timeline for one segment: readable speech blocks interleaved with
/// unlabeled breaks, calm quiet rows, and explicit loss rows (loss is never hidden and quiet is
/// never framed as loss).
public func transcriptTimelineItems(
    meta: SegmentMeta,
    segments: [TranscriptSegment],
    words: [TranscriptWord] = []
) -> [TranscriptTimelineItem] {
    let speech = coalescedSpeechBlocks(segments: segments, words: words)
        .flatMap { splitSpeechBlock($0) }
    if speech.isEmpty { return [] }

    let gaps = collapsedTranscriptGaps(meta)
    var items: [TranscriptTimelineItem] = []
    var gapIndex = 0
    var previousSpeechEnd: Int64?
    for block in speech {
        var insertedGapBeforeBlock = false
        while gapIndex < gaps.count, gaps[gapIndex].startMs <= block.startMs {
            items.append(.pause(gaps[gapIndex]))
            gapIndex += 1
            insertedGapBeforeBlock = true
        }
        if let previousEnd = previousSpeechEnd, !insertedGapBeforeBlock {
            let pauseMs = block.startMs - previousEnd
            if pauseMs >= quietPauseThresholdMs {
                items.append(
                    .pause(
                        TranscriptTimelineItem.Pause(
                            startMs: previousEnd, durationMs: pauseMs, missing: false
                        )
                    )
                )
            } else if pauseMs >= silenceBreakThresholdMs {
                items.append(
                    .silenceBreak(
                        TranscriptTimelineItem.Break(startMs: previousEnd, durationMs: pauseMs)
                    )
                )
            }
        }
        items.append(.speech(block))
        previousSpeechEnd = max(previousSpeechEnd ?? block.endMs, block.endMs)
    }
    while gapIndex < gaps.count {
        items.append(.pause(gaps[gapIndex]))
        gapIndex += 1
    }

    var seen = Set<String>()
    let deduped = items.filter { item in
        let key: String
        switch item {
        case .speech(let s): key = "speech:\(s.startMs):\(s.endMs):\(s.text)"
        case .silenceBreak(let b): key = "break:\(b.startMs):\(b.durationMs)"
        case .pause(let p):
            key = "pause:\(p.startMs):\(p.durationMs):\(p.missing):"
                + p.reasons.joined(separator: "|")
        }
        return seen.insert(key).inserted
    }
    return coalesceTimelineQuiet(deduped)
}

/// Collapses consecutive non-speech rows of the same kind so the transcript reads cleanly: a
/// run of quiet spans becomes one quiet period of their combined length, and a run of
/// interruptions becomes one. The merged quiet total is then labelled by length — 30 s+ gets a
/// "quiet for…" label, 5–30 s a bare break, shorter is dropped.
private func coalesceTimelineQuiet(
    _ items: [TranscriptTimelineItem]
) -> [TranscriptTimelineItem] {
    var out: [TranscriptTimelineItem] = []
    var i = 0
    while i < items.count {
        guard let kind = timelineQuietKind(items[i]) else {
            out.append(items[i])
            i += 1
            continue
        }
        let startMs = items[i].startMs
        var totalMs: Int64 = 0
        var j = i
        while j < items.count, timelineQuietKind(items[j]) == kind {
            totalMs += timelineItemDurationMs(items[j])
            j += 1
        }
        if kind == .loss {
            var reasons: [String] = []
            for item in items[i..<j] {
                guard case .pause(let pause) = item else { continue }
                for reason in pause.reasons where !reasons.contains(reason) {
                    reasons.append(reason)
                }
            }
            out.append(
                .pause(
                    TranscriptTimelineItem.Pause(
                        startMs: startMs, durationMs: totalMs, missing: true, reasons: reasons
                    )
                )
            )
        } else if totalMs >= quietPauseThresholdMs {
            out.append(
                .pause(
                    TranscriptTimelineItem.Pause(
                        startMs: startMs, durationMs: totalMs, missing: false
                    )
                )
            )
        } else if totalMs >= silenceBreakThresholdMs {
            out.append(
                .silenceBreak(TranscriptTimelineItem.Break(startMs: startMs, durationMs: totalMs))
            )
        }
        // Shorter than a break: nothing to show.
        i = j
    }
    return out
}

private enum TimelineQuietKind {
    case quiet
    case loss
}

/// Quiet (skipped silence / too-quiet pause / break) vs interruption; nil for speech.
private func timelineQuietKind(_ item: TranscriptTimelineItem) -> TimelineQuietKind? {
    switch item {
    case .speech: return nil
    case .silenceBreak: return .quiet
    case .pause(let pause): return pause.missing ? .loss : .quiet
    }
}

private func timelineItemDurationMs(_ item: TranscriptTimelineItem) -> Int64 {
    switch item {
    case .speech: return 0
    case .silenceBreak(let b): return b.durationMs
    case .pause(let p): return p.durationMs
    }
}

private func coalescedSpeechBlocks(
    segments: [TranscriptSegment],
    words: [TranscriptWord]
) -> [TranscriptTimelineItem.Speech] {
    // Prefer word-level timings for the finest timeline, EXCEPT when diarization labeled the
    // segments with speakers (words carry no speaker) — then segment-level keeps the labels.
    let hasSpeakers = segments.contains { !($0.speaker ?? "").isEmptyOrBlank }
    let raw: [TranscriptTimelineItem.Speech]
    if !words.isEmpty && !hasSpeakers {
        raw = words.map {
            TranscriptTimelineItem.Speech(
                startMs: max($0.startMs, 0),
                endMs: max($0.endMs, $0.startMs),
                text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                speaker: nil
            )
        }
    } else {
        raw = segments.map {
            TranscriptTimelineItem.Speech(
                startMs: max($0.startMs, 0),
                endMs: max($0.endMs, $0.startMs),
                text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                speaker: $0.speaker.map(speakerLabel)
            )
        }
    }
    let sorted = raw.filter { !$0.text.isEmptyOrBlank }.sorted { $0.startMs < $1.startMs }

    var blocks: [TranscriptTimelineItem.Speech] = []
    var current: TranscriptTimelineItem.Speech?
    for next in sorted {
        if let existing = current,
            next.startMs - existing.endMs < silenceBreakThresholdMs,
            next.speaker == existing.speaker
        {
            current = TranscriptTimelineItem.Speech(
                startMs: existing.startMs,
                endMs: max(existing.endMs, next.endMs),
                text: joinTranscriptText(existing.text, next.text),
                speaker: existing.speaker
            )
        } else {
            if let existing = current { blocks.append(existing) }
            current = next
        }
    }
    if let existing = current { blocks.append(existing) }
    return blocks
}

private func splitSpeechBlock(
    _ block: TranscriptTimelineItem.Speech,
    maxChars: Int = 260,
    maxWords: Int = 34
) -> [TranscriptTimelineItem.Speech] {
    let chunks = readableChunks(block.text, maxChars: maxChars, maxWords: maxWords)
    if chunks.count <= 1 { return [block] }
    let totalWords = Int64(max(wordCount(block.text), 1))
    let durationMs = max(block.endMs - block.startMs, 0)
    var consumedWords: Int64 = 0
    return chunks.map { chunk in
        let chunkWords = Int64(max(wordCount(chunk), 1))
        let startOffset = durationMs * consumedWords / totalWords
        consumedWords += chunkWords
        let endOffset = durationMs * consumedWords / totalWords
        return TranscriptTimelineItem.Speech(
            startMs: block.startMs + startOffset,
            endMs: max(block.startMs + endOffset, block.startMs + startOffset),
            text: chunk,
            speaker: block.speaker
        )
    }
}

private func collapsedTranscriptGaps(_ meta: SegmentMeta) -> [TranscriptTimelineItem.Pause] {
    if meta.gaps.isEmpty { return [] }
    let segmentDuration = max(segmentDurationMs(meta), 0)

    func rangeOf(_ gap: GapMeta) -> (Int64, Int64) {
        let rawStart = sampleOffsetMs(meta, sampleIndex: gap.firstMissingSampleIndex)
        let start =
            segmentDuration > 0
            ? min(max(rawStart, 0), segmentDuration) : max(rawStart, 0)
        let rawDuration = max(Int64(gap.missingFrameCount) * Int64(meta.frameDurationMs), 0)
        let end = segmentDuration > 0 ? min(start + rawDuration, segmentDuration) : start + rawDuration
        return (start, max(end, start))
    }

    struct GapCluster {
        var startMs: Int64
        var endMs: Int64
        var gaps: [GapMeta]
    }

    func collapse(_ gaps: [GapMeta]) -> [GapCluster] {
        let ranges = gaps.map { gap -> GapCluster in
            let (start, end) = rangeOf(gap)
            return GapCluster(startMs: start, endMs: end, gaps: [gap])
        }.sorted { $0.startMs < $1.startMs }
        var merged: [GapCluster] = []
        for range in ranges {
            if let last = merged.last, range.startMs <= last.endMs + gapCollapseWindowMs {
                merged[merged.count - 1].endMs = max(last.endMs, range.endMs)
                merged[merged.count - 1].gaps.append(contentsOf: range.gaps)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    func pauses(_ gaps: [GapMeta], missing: Bool) -> [TranscriptTimelineItem.Pause] {
        collapse(gaps).map { cluster in
            var reasons: [String] = []
            if missing {
                for gap in cluster.gaps {
                    let description = gapDescription(gap)
                    if !reasons.contains(description) { reasons.append(description) }
                }
            }
            return TranscriptTimelineItem.Pause(
                startMs: cluster.startMs,
                durationMs: max(cluster.endMs - cluster.startMs, 0),
                missing: missing,
                reasons: reasons
            )
        }
    }

    // Silence-suppressed spans are known-quiet audio (missing=false, "quiet"); genuine loss is
    // missing=true ("audio interrupted"). They collapse separately so a quiet stretch never
    // inherits an interruption's framing; length-based labelling happens later in
    // coalesceTimelineQuiet on the combined totals.
    let visibility = GapVisibility(meta.gaps)
    let lost = pauses(meta.gaps.filter { visibility.isVisibleLoss($0) }, missing: true)
    let quiet = pauses(meta.gaps.filter { !visibility.isVisibleLoss($0) }, missing: false)
    return (lost + quiet).sorted { $0.startMs < $1.startMs }
}

private func joinTranscriptText(_ a: String, _ b: String) -> String {
    if a.isEmptyOrBlank { return b }
    if b.isEmptyOrBlank { return a }
    if let first = b.first, ".,!?;:".contains(first) { return a + b }
    return "\(a) \(b)"
}

private func sampleOffsetMs(_ meta: SegmentMeta, sampleIndex: UInt64) -> Int64 {
    let base = meta.firstSampleIndex ?? sampleIndex
    let samples = sampleIndex >= base ? sampleIndex - base : 0
    return Int64(samples) * 1_000 / Int64(meta.sampleRateHz)
}

// MARK: - Paragraphs

/// Splits durable transcript text into readable paragraphs: explicit blank lines are kept,
/// sentences pack up to the char/word budgets, and punctuation-free live text splits by words.
public func transcriptParagraphs(
    _ text: String,
    maxChars: Int = 280,
    maxWords: Int = 34
) -> [String] {
    let normalized = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\r", with: "\n")
    if normalized.isEmptyOrBlank { return [] }
    var paragraphs: [String] = []
    var current = ""
    var currentWords = 0
    func flush() {
        if !current.isEmpty {
            paragraphs.append(current)
            current = ""
            currentWords = 0
        }
    }
    // Kotlin `split(Regex("\\n{2,}"))`.
    let blocks = normalized
        .replacingOccurrences(of: "\n{2,}", with: "\u{0}", options: .regularExpression)
        .components(separatedBy: "\u{0}")
    for (blockIndex, block) in blocks.enumerated() {
        if blockIndex > 0 { flush() }
        for sentence in sentencesIn(block)
            .flatMap({ readableChunks($0, maxChars: maxChars, maxWords: maxWords) })
        {
            let words = wordCount(sentence)
            if !current.isEmpty
                && (current.count + 1 + sentence.count > maxChars
                    || currentWords + words > maxWords)
            {
                flush()
            }
            if !current.isEmpty { current.append(" ") }
            current.append(sentence)
            currentWords += words
        }
    }
    flush()
    return paragraphs
}

private func readableChunks(_ text: String, maxChars: Int, maxWords: Int) -> [String] {
    let words = text
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
        .split(separator: " ")
        .map(String.init)
        .filter { !$0.isEmptyOrBlank }
    if words.isEmpty { return [] }
    if text.count <= maxChars && words.count <= maxWords {
        return [text.trimmingCharacters(in: .whitespaces)]
    }
    var chunks: [String] = []
    var current: [String] = []
    var currentChars = 0
    func flush() {
        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
            current = []
            currentChars = 0
        }
    }
    for word in words {
        let nextChars = currentChars + word.count + (current.isEmpty ? 0 : 1)
        if !current.isEmpty && (nextChars > maxChars || current.count >= maxWords) {
            flush()
        }
        current.append(word)
        currentChars += word.count + (current.count == 1 ? 0 : 1)
    }
    flush()
    return chunks
}

private func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).count
}

private func sentencesIn(_ block: String) -> [String] {
    let chars = Array(block)
    var sentences: [String] = []
    var current = ""
    for index in chars.indices {
        let char = chars[index]
        current.append(char == "\n" || char == "\t" ? " " : char)
        let next = index + 1 < chars.count ? chars[index + 1] : nil
        let nextAfterSpace = chars[(index + 1)...].first { !$0.isWhitespace }
        if (char == "." || char == "!" || char == "?"),
            next?.isWhitespace == true,
            nextAfterSpace == nil || nextAfterSpace!.isUppercase || nextAfterSpace!.isNumber
        {
            sentences.append(collapseSpaces(current))
            current = ""
        }
    }
    let tail = collapseSpaces(current)
    if !tail.isEmptyOrBlank { sentences.append(tail) }
    return sentences
}

private func collapseSpaces(_ text: String) -> String {
    text
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

extension String {
    fileprivate var isEmptyOrBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
