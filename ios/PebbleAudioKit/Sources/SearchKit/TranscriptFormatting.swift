import Foundation
import WireProtocol
import SegmentStore

// Port of the pure transcript-formatting and search-match derivations from
// `app/.../ui/LibraryScreen.kt`, pinned by `TranscriptFormattingTest` (plan 4.7: the old
// hand-rolled fuzzy-search ENGINE is not the product's search — the persistent FTS index in
// `TranscriptIndex.swift` is — but these behaviors are the spec for the rebuilt transcript
// renderer and for in-conversation search snippets/highlights).
//
// Structural adjustments vs KMP (mirrored in SearchKitTests):
// - `SegmentTranscript` (a Transcription-module type) is replaced by the local
//   `TranscriptContent` slice (text + segments + words) — SearchKit deliberately does not
//   depend on the Transcription module.
// - `SegmentAnnotation` / `ActionItem` / `AiOutput` are lightweight local value slices carrying
//   exactly the fields this layer reads (same pattern as StatusUI's Timeline.swift; module
//   namespacing keeps them importable side by side with the full models).
// - The KMP sealed interface `TranscriptTimelineItem` is a Swift enum with payload structs.
// - Timestamps in "Transcript match · 9:12 AM" labels honor Q16: they format in the segment's
//   `recordedTimeZone` (falling back to the device zone for pre-rebuild files).
// - Gap classification (visible loss vs quiet) is an internal copy of the StatusUi classifier;
//   StatusUI is not importable from SearchKit and the functions stay internal to avoid
//   cross-module free-function ambiguity.

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

/// AI title/summary/tags (display slice).
public struct SegmentAnnotation: Equatable, Sendable {
    public var title: String?
    public var summary: String?
    public var tags: [String]

    public init(title: String? = nil, summary: String? = nil, tags: [String] = []) {
        self.title = title
        self.summary = summary
        self.tags = tags
    }
}

/// One follow-up item (display slice).
public struct ActionItem: Equatable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// One stored AI output (display slice).
public struct AiOutput: Equatable, Sendable {
    public var promptTitle: String
    public var text: String

    public init(promptTitle: String, text: String) {
        self.promptTitle = promptTitle
        self.text = text
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
                    : "audio interrupted for \(durationText(durationMs))"
                if let summary = reasonSummary { return "\(base) (\(summary))" }
                return base
            }
            return "quiet for \(durationText(durationMs))"
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
    let segmentDuration = max(segmentDurationMsLocal(meta), 0)

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
                    let description = gapDescriptionLocal(gap)
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
    let visibility = LocalGapVisibility(meta.gaps)
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

// MARK: - Library search match (in-conversation snippets/highlights)

public enum LibrarySearchMatchKind: Equatable, Sendable {
    case transcript
    case title
    case summary
    case tag
    case actionItem
    case aiOutput
}

public struct LibrarySearchMatch: Equatable, Sendable {
    public var kind: LibrarySearchMatchKind
    public var label: String
    public var snippet: String
    public var startMs: Int64?
    public var highlightTerm: String?
    public var score: Int

    public init(
        kind: LibrarySearchMatchKind,
        label: String,
        snippet: String,
        startMs: Int64? = nil,
        highlightTerm: String? = nil,
        score: Int = 0
    ) {
        self.kind = kind
        self.label = label
        self.snippet = snippet
        self.startMs = startMs
        self.highlightTerm = highlightTerm
        self.score = score
    }
}

/// Best display match for one conversation/segment against a query: prefers timed transcript
/// context (so tapping a result can seek playback), supports out-of-order multi-term queries
/// and light fuzziness, and always returns a human snippet plus the term to highlight.
public func librarySearchMatch(
    query: String,
    meta: SegmentMeta,
    transcript: TranscriptContent?,
    annotation: SegmentAnnotation?,
    actionItems: [ActionItem] = [],
    aiOutputs: [AiOutput] = []
) -> LibrarySearchMatch? {
    guard let parts = libraryQueryParts(query) else { return nil }
    let candidates = librarySearchCandidates(
        meta: meta,
        transcript: transcript,
        annotation: annotation,
        actionItems: actionItems,
        aiOutputs: aiOutputs
    )
    let scored = candidates.enumerated()
        .compactMap { index, candidate -> ScoredLibrarySearchCandidate? in
            guard let score = scoreLibraryText(parts: parts, text: candidate.text, weight: candidate.weight)
            else { return nil }
            return ScoredLibrarySearchCandidate(index: index, candidate: candidate, textScore: score)
        }
        .sorted { lhs, rhs in
            if lhs.textScore.score != rhs.textScore.score {
                return lhs.textScore.score > rhs.textScore.score
            }
            return lhs.index < rhs.index
        }
    if let best = scored.first { return best.toMatch() }
    return aggregateLibrarySearchMatch(parts: parts, candidates: candidates)?.toMatch()
}

private func librarySearchCandidates(
    meta: SegmentMeta,
    transcript: TranscriptContent?,
    annotation: SegmentAnnotation?,
    actionItems: [ActionItem],
    aiOutputs: [AiOutput]
) -> [LibrarySearchCandidate] {
    var candidates: [LibrarySearchCandidate] = []
    if let transcript {
        for item in transcriptTimelineItems(
            meta: meta, segments: transcript.segments, words: transcript.words
        ) {
            guard case .speech(let speech) = item else { continue }
            candidates.append(
                LibrarySearchCandidate(
                    kind: .transcript,
                    label: "Transcript match · \(clockTimeFor(meta, offsetMs: speech.startMs))",
                    text: speech.text,
                    weight: 920,
                    startMs: speech.startMs
                )
            )
        }
        candidates.append(
            LibrarySearchCandidate(
                kind: .transcript, label: "Transcript match", text: transcript.text, weight: 880
            )
        )
    }
    candidates.append(
        LibrarySearchCandidate(kind: .title, label: "Title match", text: annotation?.title, weight: 850)
    )
    candidates.append(
        LibrarySearchCandidate(
            kind: .summary, label: "Summary match", text: annotation?.summary, weight: 580
        )
    )
    for tag in annotation?.tags ?? [] {
        candidates.append(
            LibrarySearchCandidate(kind: .tag, label: "Tag match", text: tag, weight: 760)
        )
    }
    for item in actionItems {
        candidates.append(
            LibrarySearchCandidate(
                kind: .actionItem, label: "Action item match", text: item.text, weight: 620
            )
        )
    }
    for output in aiOutputs {
        candidates.append(
            LibrarySearchCandidate(
                kind: .aiOutput, label: "AI output match", text: output.promptTitle, weight: 520
            )
        )
        candidates.append(
            LibrarySearchCandidate(
                kind: .aiOutput, label: "AI output match", text: output.text, weight: 480
            )
        )
    }
    return candidates
}

private struct LibrarySearchCandidate {
    var kind: LibrarySearchMatchKind
    var label: String
    var text: String?
    var weight: Int
    var startMs: Int64?

    init(
        kind: LibrarySearchMatchKind,
        label: String,
        text: String?,
        weight: Int,
        startMs: Int64? = nil
    ) {
        self.kind = kind
        self.label = label
        self.text = text
        self.weight = weight
        self.startMs = startMs
    }
}

private struct ScoredLibrarySearchCandidate {
    var index: Int
    var candidate: LibrarySearchCandidate
    var textScore: LibraryTextSearchScore

    func toMatch() -> LibrarySearchMatch {
        LibrarySearchMatch(
            kind: candidate.kind,
            label: candidate.label,
            snippet: textScore.snippet,
            startMs: candidate.startMs,
            highlightTerm: textScore.highlightTerm,
            score: textScore.score
        )
    }
}

private struct LibraryQueryParts {
    var phrase: String
    var terms: [String]
}

private struct LibraryTextSearchScore {
    var score: Int
    var snippet: String
    var highlightTerm: String
}

private struct LibraryTermMatch {
    var start: Int
    var end: Int
    var text: String
    var exact: Bool
    var distance: Int
}

private struct LibrarySearchToken {
    var text: String
    var start: Int
    var end: Int
}

private func libraryQueryParts(_ query: String) -> LibraryQueryParts? {
    let phrase = normalizeSearchText(query)
    if phrase.isEmptyOrBlank { return nil }
    var seen = Set<String>()
    let terms = searchTokens(phrase)
        .map { $0.text.lowercased() }
        .filter { $0.count >= 2 }
        .filter { seen.insert($0).inserted }
    return LibraryQueryParts(phrase: phrase, terms: terms)
}

private func aggregateLibrarySearchMatch(
    parts: LibraryQueryParts,
    candidates: [LibrarySearchCandidate]
) -> ScoredLibrarySearchCandidate? {
    if parts.terms.count < 2 { return nil }
    var bestPerTerm: [ScoredLibrarySearchCandidate] = []
    for term in parts.terms {
        let best = candidates.enumerated()
            .compactMap { index, candidate -> ScoredLibrarySearchCandidate? in
                guard
                    let score = scoreLibraryTermText(
                        term: term, text: candidate.text, weight: candidate.weight
                    )
                else { return nil }
                return ScoredLibrarySearchCandidate(
                    index: index, candidate: candidate, textScore: score
                )
            }
            .sorted { lhs, rhs in
                if lhs.textScore.score != rhs.textScore.score {
                    return lhs.textScore.score > rhs.textScore.score
                }
                return lhs.index < rhs.index
            }
            .first
        guard let best else { return nil }
        bestPerTerm.append(best)
    }
    let display = bestPerTerm.sorted { lhs, rhs in
        if lhs.textScore.score != rhs.textScore.score {
            return lhs.textScore.score > rhs.textScore.score
        }
        return lhs.index < rhs.index
    }[0]
    let fieldSpreadPenalty = max(Set(bestPerTerm.map { $0.index }).count - 1, 0) * 80
    let coverageScore =
        4_500
        + bestPerTerm.reduce(0) { $0 + min($1.textScore.score / 20, 140) }
        - fieldSpreadPenalty
        + display.candidate.weight
    var adjusted = display
    adjusted.textScore.score = coverageScore
    return adjusted
}

private func scoreLibraryText(
    parts: LibraryQueryParts,
    text: String?,
    weight: Int
) -> LibraryTextSearchScore? {
    let normalized = normalizeSearchText(text)
    if normalized.isEmptyOrBlank { return nil }

    if let phraseMatch = indexOfIgnoreCase(normalized, parts.phrase) {
        return LibraryTextSearchScore(
            score: weight + 10_000 + min(parts.phrase.count, 160),
            snippet: snippetAround(
                normalized, index: phraseMatch.start, length: phraseMatch.end - phraseMatch.start
            ),
            highlightTerm: phraseMatch.text
        )
    }

    if parts.terms.isEmpty { return nil }
    let tokens = searchTokens(normalized)
    var matches: [LibraryTermMatch] = []
    for term in parts.terms {
        guard
            let match = exactTermMatch(normalized, term: term)
                ?? fuzzyTermMatch(tokens, term: term)
        else { return nil }
        matches.append(match)
    }
    let first = matches.min { $0.start < $1.start }!
    let spanStart = matches.map { $0.start }.min()!
    let spanEnd = matches.map { $0.end }.max()!
    let proximityBonus = min(max(240 - ((spanEnd - spanStart) / 8), 0), 240)
    let exactCount = matches.filter { $0.exact }.count
    let fuzzyCount = matches.count - exactCount
    let distancePenalty = matches.reduce(0) { $0 + $1.distance } * 45
    return LibraryTextSearchScore(
        score: weight + 6_000 + (exactCount * 220) + (fuzzyCount * 110)
            + proximityBonus - distancePenalty,
        snippet: snippetAround(
            normalized, index: first.start, length: max(first.end - first.start, 1)
        ),
        highlightTerm: first.text
    )
}

private func scoreLibraryTermText(
    term: String,
    text: String?,
    weight: Int
) -> LibraryTextSearchScore? {
    let normalized = normalizeSearchText(text)
    if normalized.isEmptyOrBlank { return nil }
    guard
        let match = exactTermMatch(normalized, term: term)
            ?? fuzzyTermMatch(searchTokens(normalized), term: term)
    else { return nil }
    let score = weight + (match.exact ? 1_000 : 740 - (match.distance * 80))
    return LibraryTextSearchScore(
        score: score,
        snippet: snippetAround(normalized, index: match.start, length: max(match.end - match.start, 1)),
        highlightTerm: match.text
    )
}

/// Case-insensitive find, returning character offsets and the matched text (original casing).
private func indexOfIgnoreCase(
    _ haystack: String, _ needle: String
) -> (start: Int, end: Int, text: String)? {
    guard !needle.isEmpty,
        let range = haystack.range(of: needle, options: [.caseInsensitive])
    else { return nil }
    let start = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
    let end = haystack.distance(from: haystack.startIndex, to: range.upperBound)
    return (start, end, String(haystack[range]))
}

private func exactTermMatch(_ text: String, term: String) -> LibraryTermMatch? {
    guard let match = indexOfIgnoreCase(text, term) else { return nil }
    return LibraryTermMatch(
        start: match.start, end: match.end, text: match.text, exact: true, distance: 0
    )
}

private let maxFuzzyTokensPerField = 2_500
private let maxFuzzyTokenChars = 36

private func fuzzyTermMatch(
    _ tokens: [LibrarySearchToken], term: String
) -> LibraryTermMatch? {
    if term.count < 3 { return nil }
    let threshold = fuzzyDistanceThreshold(term)
    let termChars = Array(term)
    var best: LibraryTermMatch?
    for token in tokens.prefix(maxFuzzyTokensPerField) {
        guard token.text.count <= maxFuzzyTokenChars,
            abs(token.text.count - term.count) <= threshold
        else { continue }
        let distance = levenshteinDistanceAtMost(
            termChars, Array(token.text.lowercased()), maxDistance: threshold
        )
        guard distance <= threshold else { continue }
        let candidate = LibraryTermMatch(
            start: token.start, end: token.end, text: token.text, exact: false, distance: distance
        )
        if let current = best {
            if candidate.distance < current.distance
                || (candidate.distance == current.distance && candidate.start < current.start)
            {
                best = candidate
            }
        } else {
            best = candidate
        }
    }
    return best
}

private func fuzzyDistanceThreshold(_ term: String) -> Int {
    switch term.count {
    case ...4: return 1
    case ...8: return 2
    default: return 3
    }
}

private func levenshteinDistanceAtMost(
    _ a: [Character], _ b: [Character], maxDistance: Int
) -> Int {
    if abs(a.count - b.count) > maxDistance { return maxDistance + 1 }
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        var rowMin = current[0]
        for j in 1...b.count {
            let substitutionCost = a[i - 1] == b[j - 1] ? 0 : 1
            current[j] = Swift.min(
                previous[j] + 1, current[j - 1] + 1, previous[j - 1] + substitutionCost
            )
            rowMin = Swift.min(rowMin, current[j])
        }
        if rowMin > maxDistance { return maxDistance + 1 }
        swap(&previous, &current)
    }
    return previous[b.count]
}

private func normalizeSearchText(_ text: String?) -> String {
    guard let text else { return "" }
    return text
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

private func searchTokens(_ text: String) -> [LibrarySearchToken] {
    var tokens: [LibrarySearchToken] = []
    var start: Int?
    var buffer = ""
    var offset = 0
    for char in text {
        if char.isLetter || char.isNumber {
            if start == nil { start = offset }
            buffer.append(char)
        } else if let tokenStart = start {
            tokens.append(LibrarySearchToken(text: buffer, start: tokenStart, end: offset))
            start = nil
            buffer = ""
        }
        offset += 1
    }
    if let tokenStart = start {
        tokens.append(LibrarySearchToken(text: buffer, start: tokenStart, end: offset))
    }
    return tokens
}

private func snippetAround(
    _ normalized: String,
    index: Int,
    length: Int,
    maxChars: Int = 170
) -> String {
    let chars = Array(normalized)
    let radius = max((maxChars - length) / 2, 24)
    var start = max(index - radius, 0)
    var end = min(index + length + radius, chars.count)
    while start > 0 && !chars[start - 1].isWhitespace { start -= 1 }
    while end < chars.count && !chars[end].isWhitespace { end += 1 }
    let prefix = start > 0 ? "..." : ""
    let suffix = end < chars.count ? "..." : ""
    let body = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
    return prefix + body + suffix
}

/// Plain phrase snippet around an exact query match (used by list rows), or nil when absent.
public func searchSnippet(_ text: String?, query: String, maxChars: Int = 170) -> String? {
    let normalized = normalizeSearchText(text)
    if normalized.isEmptyOrBlank { return nil }
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    guard let match = indexOfIgnoreCase(normalized, trimmed) else { return nil }
    return snippetAround(
        normalized, index: match.start, length: match.end - match.start, maxChars: maxChars
    )
}

// MARK: - Local gap classification + formatting helpers
// Internal copies of the StatusUi classifier/copy (StatusUI is not importable from SearchKit;
// keeping these internal avoids cross-module free-function ambiguity).

func gapDescriptionLocal(_ gap: GapMeta) -> String {
    if gap.origin == GapMeta.originSequenceSkip { return "phone briefly missed audio" }
    switch localGapReason(gap) {
    case .spoolOverflow: return "watch buffer filled while disconnected"
    case .micConflict: return "watch dictation used the mic"
    case .userDisabled: return "recording was paused"
    case .lowBattery: return "paused for watch battery"
    case .codecError: return "watch audio hiccup"
    case .transportReset: return "connection was interrupted"
    case .powerSave: return "watch was saving power"
    case .silenceSuppressed: return "quiet audio was skipped"
    case nil: return "audio missing"
    }
}

private func localGapReason(_ gap: GapMeta) -> GapReason? {
    guard let raw = gap.reasonRaw, raw >= 0, raw <= Int(UInt8.max) else { return nil }
    return GapReason(rawValue: UInt8(raw))
}

private func isLocalSilenceGap(_ gap: GapMeta) -> Bool {
    localGapReason(gap)?.isSilence == true
}

/// Visible-loss classifier: silence-suppressed spans are quiet, receiver-synthesized sequence
/// skips fully covered by a single silence gap defer to the watch's silence reason.
struct LocalGapVisibility {
    private let silence: [(start: UInt64, end: UInt64)]

    init(_ gaps: [GapMeta]) {
        silence = gaps
            .filter { isLocalSilenceGap($0) }
            .map {
                (
                    UInt64($0.firstMissingSequence),
                    UInt64($0.firstMissingSequence) + UInt64($0.missingFrameCount)
                )
            }
    }

    func isVisibleLoss(_ gap: GapMeta) -> Bool {
        if isLocalSilenceGap(gap) { return false }
        if gap.origin != GapMeta.originSequenceSkip { return true }
        let start = UInt64(gap.firstMissingSequence)
        let end = start + UInt64(gap.missingFrameCount)
        return !silence.contains { $0.start <= start && $0.end >= end }
    }
}

func segmentDurationMsLocal(_ meta: SegmentMeta) -> Int64 {
    if let first = meta.firstSampleIndex,
        let lastExclusive = meta.lastSampleIndexExclusive,
        lastExclusive > first, meta.sampleRateHz > 0
    {
        return Int64((lastExclusive - first) * 1_000 / UInt64(meta.sampleRateHz))
    }
    return meta.frameCount * Int64(meta.frameDurationMs)
}

/// "38 sec", "5 min", "1 hr 12 min" (KMP Formatting.duration).
func durationText(_ durationMs: Int64) -> String {
    let totalSeconds = durationMs / 1_000
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    switch (hours, minutes) {
    case let (h, m) where h > 0 && m > 0: return "\(h) hr \(m) min"
    case let (h, _) where h > 0: return "\(h) hr"
    case let (_, m) where m > 0: return "\(m) min"
    default: return "\(seconds) sec"
    }
}

/// "9:12 AM" in the segment's recorded timezone (Q16), falling back to the device zone for
/// pre-rebuild files that lack one.
private func clockTimeFor(_ meta: SegmentMeta, offsetMs: Int64) -> String {
    let zone = meta.recordedTimeZone.flatMap { TimeZone(identifier: $0) } ?? TimeZone.current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let date = Date(timeIntervalSince1970: Double(meta.receivedAtMs + offsetMs) / 1_000.0)
    let components = calendar.dateComponents([.hour, .minute], from: date)
    let hour = components.hour ?? 0
    let minute = components.minute ?? 0
    let hour12 = hour % 12 == 0 ? 12 : hour % 12
    let minuteText = String(format: "%02d", minute)
    return "\(hour12):\(minuteText) \(hour < 12 ? "AM" : "PM")"
}

extension String {
    fileprivate var isEmptyOrBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
