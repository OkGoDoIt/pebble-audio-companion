import Foundation
import AppDB
import SegmentStore
import WireProtocol

// Port of `app/.../AskRetriever.kt` plus the Ask plumbing from `AudioCompanionRuntime.kt`
// (plan Part 4.5 "Ask", Part 6.6): hybrid retrieval, citation numbering keyed to
// source-segment order, the per-segment gap summary (B7-fixed: visible loss only, never
// silence), scope resolution as a pure function over segment metas, and Q18 history
// persistence through the existing AskHistoryStore.

/// One hit from the injected search index (SearchKit is a separate module; the retriever only
/// sees this shape).
public struct AskIndexHit: Equatable, Sendable {
    public let id: String
    public let score: Float

    public init(id: String, score: Float) {
        self.id = id
        self.score = score
    }
}

/// Retrieves transcript excerpts for Ask Q&A: hybrid keyword (index hits first) + direct
/// segment stuffing, capped at `maxChunks`.
public struct AskRetriever: Sendable {
    /// `(query, limit) -> hits`. Nil (or an unavailable index returning []) degrades to pure
    /// excerpt stuffing.
    public typealias Search = @Sendable (String, Int) async -> [AskIndexHit]

    private let search: Search?

    public init(search: Search? = nil) {
        self.search = search
    }

    public struct RetrievedChunk: Equatable, Sendable {
        public let segmentId: String
        public let text: String
        public let startTimeMs: Int64?
        public let endTimeMs: Int64?
        /// When this was recorded, in words ("Saturday, 29 August 2026, 9:35 PM – 9:51 PM
        /// (yesterday; Asia/Ho_Chi_Minh)"). Epoch ms mean nothing to a language model, and
        /// without a real date it reads every transcript as if it happened today.
        public let timeLabel: String?
        public let gapSummary: String?
        public let score: Float

        public init(
            segmentId: String, text: String, startTimeMs: Int64? = nil,
            endTimeMs: Int64? = nil, timeLabel: String? = nil, gapSummary: String? = nil,
            score: Float = 0
        ) {
            self.segmentId = segmentId
            self.text = text
            self.startTimeMs = startTimeMs
            self.endTimeMs = endTimeMs
            self.timeLabel = timeLabel
            self.gapSummary = gapSummary
            self.score = score
        }
    }

    public func retrieve(
        query: String,
        excerpts: [TranscriptExcerpt],
        gapSummaries: [String: String?] = [:],
        maxChunks: Int = 12
    ) async -> [RetrievedChunk] {
        let hits = await search?(query, maxChunks) ?? []
        let hitIds = Set(hits.map(\.id))
        let fromIndex = hits.compactMap { hit -> RetrievedChunk? in
            guard let excerpt = excerpts.first(where: { $0.segmentId == hit.id }) else {
                return nil
            }
            return RetrievedChunk(
                segmentId: excerpt.segmentId,
                text: excerpt.text,
                startTimeMs: excerpt.startTimeMs,
                endTimeMs: excerpt.endTimeMs,
                timeLabel: excerpt.timeLabel,
                gapSummary: gapSummaries[excerpt.segmentId] ?? nil,
                score: hit.score)
        }
        let remainder = excerpts
            .filter { !hitIds.contains($0.segmentId) }
            .prefix(max(0, maxChunks - fromIndex.count))
            .map { excerpt in
                RetrievedChunk(
                    segmentId: excerpt.segmentId,
                    text: excerpt.text,
                    startTimeMs: excerpt.startTimeMs,
                    endTimeMs: excerpt.endTimeMs,
                    timeLabel: excerpt.timeLabel,
                    gapSummary: gapSummaries[excerpt.segmentId] ?? nil)
            }
        return Array((fromIndex + remainder).prefix(maxChunks))
    }

    /// Render chunks for the prompt. When `citationNumberOf` is supplied, each chunk is
    /// prefixed with a stable `[n]` citation number (keyed off the source-segment order, not
    /// the relevance order) so the model can cite `[n]` and the app can map those numbers
    /// straight back to a real segment id. Without it, the legacy unnumbered format is
    /// preserved.
    public func formatForPrompt(
        _ chunks: [RetrievedChunk],
        citationNumberOf: ((String) -> Int?)? = nil
    ) -> String {
        chunks.map { chunk in
            let time: String
            if let label = chunk.timeLabel {
                // Words, not epoch ms: the model has to reason about WHEN each conversation
                // happened to place "tomorrow"/"next weekend" said inside it.
                time = ", recorded \(label)"
            } else if let start = chunk.startTimeMs, let end = chunk.endTimeMs {
                time = " @\(start)-\(end)ms"
            } else if let start = chunk.startTimeMs {
                time = " @\(start)ms"
            } else {
                time = ""
            }
            let cite = citationNumberOf?(chunk.segmentId).map { "[\($0)] " } ?? ""
            let gaps = chunk.gapSummary.map { "\nGAPS: \($0)" } ?? ""
            return "\(cite)[segment \(chunk.segmentId)\(time)]\(gaps)\n\(chunk.text)"
        }.joined(separator: "\n\n")
    }
}

// MARK: - Time context

// Everything the model needs to place a transcript in time. Without this it sees only epoch
// milliseconds and answers as though every recording happened today — so "we fly out
// tomorrow", said in a conversation from last week, gets reported as tomorrow.

private func askDateFormatter(_ format: String, _ timeZoneID: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
    return formatter
}

private func askDate(_ ms: Int64) -> Date {
    Date(timeIntervalSince1970: Double(ms) / 1000)
}

/// Whole days between two `YYYY-MM-DD` keys (`to - from`). Keys are plain dates, so UTC math
/// is exact regardless of either wall zone's DST.
public func askDayDelta(from: String, to: String) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return cal.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
    guard let start = date(from), let end = date(to) else { return 0 }
    return cal.dateComponents([.day], from: start, to: end).day ?? 0
}

/// "today" / "yesterday" / "6 days ago" — how far back a logical day is from today's.
public func askRelativeDayPhrase(daysAgo: Int) -> String {
    switch daysAgo {
    case 0: return "today"
    case 1: return "yesterday"
    case ..<0: return daysAgo == -1 ? "tomorrow" : "in \(-daysAgo) days"
    default: return "\(daysAgo) days ago"
    }
}

/// When a segment was recorded, in words the model can reason with:
/// "Saturday, 29 August 2026, 9:35 PM – 9:51 PM (yesterday; Asia/Ho_Chi_Minh)".
/// Formatted in the zone the audio was RECORDED in (Q16), so a conversation keeps the times
/// it actually happened at after the user flies home.
public func askWhenLabel(
    startMs: Int64, endMs: Int64?, timeZoneID: String, nowMs: Int64,
    deviceTimeZoneID: String = TimeZone.current.identifier
) -> String {
    let day = askDateFormatter("EEEE, d MMMM yyyy", timeZoneID).string(from: askDate(startMs))
    let clock = askDateFormatter("h:mm a", timeZoneID)
    var label = "\(day), \(clock.string(from: askDate(startMs)))"
    if let endMs, endMs > startMs {
        label += " – \(clock.string(from: askDate(endMs)))"
    }
    // Relative to the user's own today, using the app's 5 AM logical day so "yesterday" here
    // means the same day the Library groups it under.
    let daysAgo = askDayDelta(
        from: LogicalDay.dateKey(forMs: startMs, timeZoneID: timeZoneID),
        to: LogicalDay.dateKey(forMs: nowMs, timeZoneID: deviceTimeZoneID))
    var suffix = askRelativeDayPhrase(daysAgo: daysAgo)
    // The zone is worth naming only when it is not the one the user is standing in.
    if timeZoneID != deviceTimeZoneID { suffix += "; \(timeZoneID)" }
    return "\(label) (\(suffix))"
}

/// The header that anchors "now" for the whole prompt. A model with no current date cannot
/// resolve "tomorrow", "last week", or "how long ago" in either the question or the audio.
public func askNowContext(
    nowMs: Int64, timeZoneID: String = TimeZone.current.identifier, scopeDescription: String
) -> String {
    let now = askDateFormatter("EEEE, d MMMM yyyy 'at' h:mm a", timeZoneID)
        .string(from: askDate(nowMs))
    return """
        RIGHT NOW: \(now) (\(timeZoneID)).
        TRANSCRIPT RANGE: \(scopeDescription). Each transcript below is labelled with the \
        date and time it was recorded — that is when the people in it were speaking.
        """
}

/// The turns of this Ask conversation so far, so a follow-up is answered in context instead
/// of as a fresh, contextless question. Bounded: the newest `maxTurns`, each answer clipped,
/// because the transcripts still need most of the model's input budget.
public func askThreadContext(
    _ turns: [AskEntry], maxTurns: Int = 6, maxAnswerChars: Int = 1_200
) -> String? {
    let recent = turns.suffix(maxTurns)
    guard !recent.isEmpty else { return nil }
    // The `-> String` is load-bearing: GRDB (via AppDB) makes its own SQL type expressible by
    // string interpolation, and without it the compiler infers THAT here and the prompt gets a
    // serialized SQL AST instead of the conversation.
    let body = recent.map { turn -> String in
        var answer = turn.answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.count > maxAnswerChars {
            answer = String(answer.prefix(maxAnswerChars)) + "…"
        }
        return "User: \(turn.question)\nYou: \(answer)"
    }.joined(separator: "\n\n")
    return "CONVERSATION SO FAR:\n\(body)"
}

/// Retrieval query for a follow-up. "So what's the plan?" retrieves nothing on its own — the
/// subject lives in the earlier turns, so they seed the search alongside the new question.
public func askRetrievalQuery(
    question: String, priorTurns: [AskEntry], priorQuestions: Int = 2
) -> String {
    (priorTurns.suffix(priorQuestions).map(\.question) + [question])
        .joined(separator: " ")
}

// MARK: - Citation numbering (source-segment order)

/// Distinct source-segment order of the excerpts handed to the model — the order the answer's
/// `segmentIds` are stored in, so `[n]` maps to `segmentIds[n-1]`.
public func askSourceOrder(_ excerpts: [TranscriptExcerpt]) -> [String] {
    var seen = Set<String>()
    return excerpts.compactMap { seen.insert($0.segmentId).inserted ? $0.segmentId : nil }
}

/// `citationNumberOf(id) = firstIndex + 1` over the source order; nil for unknown ids.
public func askCitationNumber(of segmentId: String, sourceOrder: [String]) -> Int? {
    sourceOrder.firstIndex(of: segmentId).map { $0 + 1 }
}

// MARK: - Gap summary (B7-fixed)

/// One calm gap note for the prompt, counting ONLY visible loss. The KMP runtime summed every
/// gap including VAD-skipped silence (bug B7), telling the model audio was missing when the
/// watch had simply skipped known-quiet time; silence never reaches the prompt here. Nil when
/// the segment has no genuinely missing audio.
public func askGapSummary(_ meta: SegmentMeta) -> String? {
    let lost = askVisibleLossGaps(meta)
    if lost.isEmpty { return nil }
    let missingMs = lost.reduce(Int64(0)) {
        $0 + Int64($1.missingFrameCount) * Int64(meta.frameDurationMs)
    }
    let noun = lost.count == 1 ? "gap" : "gaps"
    return "\(lost.count) \(noun), about \(missingMs)ms missing; "
        + "answer may be incomplete for this segment."
}

/// Local replica of StatusUI's visible-loss classifier (StatusUI is not an Intelligence
/// dependency). Behavior-identical: silence-suppressed gaps are never loss, watch-reported
/// non-silence gaps always are, and a receiver-synthesized `sequence_skip` fully covered by a
/// single silence gap renders as quiet, not loss.
public func askVisibleLossGaps(_ meta: SegmentMeta) -> [GapMeta] {
    let visibility = AskGapVisibility(meta.gaps)
    return meta.gaps.filter { visibility.isVisibleLoss($0) }
}

private func askIsSilenceGap(_ gap: GapMeta) -> Bool {
    guard let raw = gap.reasonRaw, raw >= 0, raw <= Int(UInt8.max),
        let reason = GapReason(rawValue: UInt8(raw))
    else { return false }
    return reason.isSilence
}

/// Sorted silence intervals with a running max end: "is this sequence-skip fully covered by
/// some single silence gap?" in O(log n) (mirrors StatusUI's GapVisibility).
struct AskGapVisibility {
    private let silenceStarts: [UInt64]
    private let silenceMaxEnd: [UInt64]

    init(_ gaps: [GapMeta]) {
        let silence = gaps
            .filter { askIsSilenceGap($0) }
            .map {
                (
                    UInt64($0.firstMissingSequence),
                    UInt64($0.firstMissingSequence) + UInt64($0.missingFrameCount)
                )
            }
            .sorted { $0.0 < $1.0 }
        var starts = [UInt64]()
        var maxEnds = [UInt64]()
        starts.reserveCapacity(silence.count)
        maxEnds.reserveCapacity(silence.count)
        var runningMax: UInt64 = 0
        for (index, interval) in silence.enumerated() {
            runningMax = index == 0 ? interval.1 : max(runningMax, interval.1)
            starts.append(interval.0)
            maxEnds.append(runningMax)
        }
        silenceStarts = starts
        silenceMaxEnd = maxEnds
    }

    func isVisibleLoss(_ gap: GapMeta) -> Bool {
        if askIsSilenceGap(gap) { return false }
        if gap.origin != GapMeta.originSequenceSkip { return true }
        let start = UInt64(gap.firstMissingSequence)
        return !coveredBySingleSilenceGap(start: start, end: start + UInt64(gap.missingFrameCount))
    }

    private func coveredBySingleSilenceGap(start: UInt64, end: UInt64) -> Bool {
        var lo = 0
        var hi = silenceStarts.count - 1
        var idx = -1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            if silenceStarts[mid] <= start {
                idx = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return idx >= 0 && silenceMaxEnd[idx] >= end
    }
}

// MARK: - Scope resolution (plan Part 6.6)

/// The Ask sheet's always-visible scope (anti-B5: never switched behind the user's back).
public enum AskScope: Equatable, Sendable {
    case today
    case yesterday
    case lastSevenDays
    case everything
    /// Inclusive `YYYY-MM-DD` logical-day keys from the system date-range picker.
    case dateRange(startKey: String, endKey: String)

    /// Approved picker copy (Part 6.6) — also the `scopeDescription` stored in ask_history.
    public var displayName: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .lastSevenDays: return "Last 7 days"
        case .everything: return "Everything"
        case .dateRange(let start, let end):
            return start == end ? start : "\(start) – \(end)"
        }
    }
}

/// Pure scope filter over segment metas. Each segment belongs to the logical day (5 AM
/// boundary) of its own RECORDED zone (Q16); the relative scopes anchor "today" on the
/// device's current zone.
public func segmentsInAskScope(
    _ metas: [SegmentMeta],
    scope: AskScope,
    nowMs: Int64,
    fallbackTimeZoneID: String = TimeZone.current.identifier
) -> [SegmentMeta] {
    guard let range = askScopeDateKeyRange(
        scope, nowMs: nowMs, timeZoneID: fallbackTimeZoneID)
    else { return metas }  // .everything
    return metas.filter { meta in
        let key = LogicalDay.dateKey(
            forMs: Int64(meta.startTimeMs),
            timeZoneID: meta.recordedTimeZone ?? fallbackTimeZoneID)
        return range.contains(key)
    }
}

/// The inclusive `YYYY-MM-DD` key range a scope covers, or nil for `.everything`.
/// `YYYY-MM-DD` keys compare correctly as strings.
public func askScopeDateKeyRange(
    _ scope: AskScope, nowMs: Int64, timeZoneID: String
) -> ClosedRange<String>? {
    let todayKey = LogicalDay.dateKey(forMs: nowMs, timeZoneID: timeZoneID)
    switch scope {
    case .everything:
        return nil
    case .today:
        return todayKey...todayKey
    case .yesterday:
        let y = askDateKey(byAdding: -1, to: todayKey)
        return y...y
    case .lastSevenDays:
        return askDateKey(byAdding: -6, to: todayKey)...todayKey
    case .dateRange(let start, let end):
        return min(start, end)...max(start, end)
    }
}

/// Calendar-safe day arithmetic on a `YYYY-MM-DD` key (keys are plain dates, so UTC math is
/// exact regardless of the wall zone's DST).
func askDateKey(byAdding days: Int, to key: String) -> String {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    guard parts.count == 3,
        let date = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
        let shifted = cal.date(byAdding: .day, value: days, to: date)
    else { return key }
    let c = cal.dateComponents([.year, .month, .day], from: shifted)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

// MARK: - Ask history persistence (Q18)

/// Citations for ask_history: numbers are the first-appearance display numbers over the
/// answer's cited ids (as produced by `parseGroundedAnswer(...).citedSegmentIds`).
public func askCitations(citedSegmentIds: [String]) -> [AskCitation] {
    citedSegmentIds.enumerated().map { AskCitation(segmentId: $1, number: $0 + 1) }
}

/// Persists one answered question into the Ask sheet's Recent list (Q18) via the existing
/// AskHistoryStore (which keeps only the newest 5).
@discardableResult
public func saveAskAnswer(
    question: String,
    answerText: String,
    citedSegmentIds: [String],
    scope: AskScope,
    history: AskHistoryStore,
    threadId: String? = nil,
    nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
) async throws -> AskEntry {
    try await history.save(
        question: question,
        answerText: answerText,
        citations: askCitations(citedSegmentIds: citedSegmentIds),
        scopeDescription: scope.displayName,
        threadId: threadId,
        nowMs: nowMs)
}
