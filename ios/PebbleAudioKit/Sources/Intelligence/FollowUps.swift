import AppDB
import Foundation
import Transcription

// The follow-up pipeline's data shapes: what a conversation is asked for, how its answer is
// parsed, and how a quoted line is located back in the recording it came from.
//
// The design this replaces asked one cheap call per conversation for "action items" and wrote
// whatever came back straight onto the person's list. On an always-on wearable microphone that
// produced, from real recordings: a passing "I'll charge it tonight" said by a visitor about
// their own phone, six sentences of product feedback dictated to a coding assistant that had
// already done them, and an owner label reading "Roger" on every row because the schema made
// the field required. The shape below exists to make each of those impossible:
//
//   • every item must carry a VERBATIM quote, and the quote is matched back against the
//     transcript locally — an item whose words are not in the recording never lands;
//   • every item must say what goes wrong if it is forgotten, which is the one question the
//     junk cannot answer;
//   • there is no owner field, because an item that needs one belongs to somebody else;
//   • the segment and the millisecond offset are DERIVED from the quote, not asked for, so a
//     model cannot strand a row by inventing an id.

// MARK: - Extraction output

/// One proposal from a single conversation, exactly as the model returns it.
public struct ExtractedFollowUp: Equatable, Sendable, Codable {
    public var task: String
    public var quote: String
    public var ifForgotten: String
    /// `YYYY-MM-DD`, or empty when the transcript states no deadline.
    public var dueDate: String
    /// `high` | `medium` | `low`.
    public var confidence: String

    public init(
        task: String, quote: String = "", ifForgotten: String = "", dueDate: String = "",
        confidence: String = "medium"
    ) {
        self.task = task
        self.quote = quote
        self.ifForgotten = ifForgotten
        self.dueDate = dueDate
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        task = try c.decode(String.self, forKey: .task)
        quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
        ifForgotten = try c.decodeIfPresent(String.self, forKey: .ifForgotten) ?? ""
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate) ?? ""
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence) ?? "medium"
    }
}

public struct ExtractedFollowUps: Equatable, Sendable, Codable {
    public var items: [ExtractedFollowUp]
    public init(items: [ExtractedFollowUp]) { self.items = items }
}

/// Parses the extraction response.
///
/// There is deliberately no lenient prose fallback. The old parser had one, and it is where
/// `**Owner:**` fragments and the line "Here are the action items I found:" reached the
/// person's list. A response that is not the JSON we asked for is a failed call, and a failed
/// call costs a retry — which is strictly better than shipping a fragment of a model's
/// preamble as a thing somebody has to do.
public enum FollowUpExtractionParser {
    public static let schemaName = "follow_ups"

    /// Model output → proposals, dropping anything that fails a check we can make locally.
    public static func parse(raw: String) -> [ExtractedFollowUp]? {
        guard let data = jsonObject(in: raw) else { return nil }
        guard let parsed = try? JSONDecoder().decode(ExtractedFollowUps.self, from: data) else {
            return nil
        }
        return parsed.items.compactMap(clean(_:))
    }

    /// Trims, normalizes whitespace, and rejects an item that broke the contract.
    static func clean(_ item: ExtractedFollowUp) -> ExtractedFollowUp? {
        let task = tidy(item.task)
        guard !task.isEmpty else { return nil }
        // The three refusals, in the order they were earned by real output.
        // A task carrying markdown or a field label is the model writing a document rather
        // than an item; a task that is a bare topic has no verb to act on.
        if task.contains("**") || task.contains("`") { return nil }
        if task.range(of: #"(?i)\b(owner|due)\s*:"#, options: .regularExpression) != nil {
            return nil
        }
        let quote = tidy(item.quote)
        // No quote, no item. This is the single rule that removed most of the old noise.
        guard quote.count >= 8 else { return nil }
        let ifForgotten = tidy(item.ifForgotten)
        guard !ifForgotten.isEmpty else { return nil }
        return ExtractedFollowUp(
            task: task,
            quote: String(quote.prefix(240)),
            ifForgotten: String(ifForgotten.prefix(200)),
            dueDate: isoDate(item.dueDate) ?? "",
            confidence: ["high", "medium", "low"].contains(item.confidence.lowercased())
                ? item.confidence.lowercased() : "medium")
    }

    /// Only a real `YYYY-MM-DD` survives. Prose in a date slot ("maybe Thursday", "when she is
    /// back") is the model telling us there is no date, and it must never become one.
    static func isoDate(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 10,
            trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        else { return nil }
        return trimmed
    }

    static func tidy(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{201C}\u{201D}\""))
    }

    /// Models occasionally wrap strict JSON in a fence or a sentence. Take the outermost
    /// object rather than failing the whole call over decoration.
    static func jsonObject(in raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") { return Data(trimmed.utf8) }
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"),
            start < end
        else { return nil }
        return Data(trimmed[start...end].utf8)
    }
}

// MARK: - Curation output

/// What the curation pass decided about one candidate it was shown.
public struct CurationDecision: Equatable, Sendable, Codable {
    /// 1-based index into the candidate list the pass was given.
    public var index: Int
    /// `keep` | `drop` | `duplicate`
    public var decision: String
    /// One clause. Shown nowhere by default; it is what makes a dropped candidate auditable
    /// in Diagnostics instead of a silent disappearance.
    public var reason: String
    /// Rewritten task text, or empty to keep what extraction wrote.
    public var task: String
    /// `high` | `normal` | `low`.
    public var priority: String
    /// `YYYY-MM-DD` or empty. May correct or clear what extraction produced.
    public var dueDate: String

    public init(
        index: Int, decision: String, reason: String = "", task: String = "",
        priority: String = "normal", dueDate: String = ""
    ) {
        self.index = index
        self.decision = decision
        self.reason = reason
        self.task = task
        self.priority = priority
        self.dueDate = dueDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        decision = try c.decodeIfPresent(String.self, forKey: .decision) ?? "drop"
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? "normal"
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate) ?? ""
    }
}

public struct CurationDecisions: Equatable, Sendable, Codable {
    public var decisions: [CurationDecision]
    public init(decisions: [CurationDecision]) { self.decisions = decisions }
}

public enum FollowUpCurationParser {
    public static let schemaName = "follow_up_curation"

    public static func parse(raw: String) -> [CurationDecision]? {
        guard let data = FollowUpExtractionParser.jsonObject(in: raw),
            let parsed = try? JSONDecoder().decode(CurationDecisions.self, from: data)
        else { return nil }
        return parsed.decisions
    }

    public static func priority(_ value: String) -> FollowUpPriority {
        switch value.lowercased() {
        case "high": return .high
        case "low": return .low
        default: return .normal
        }
    }
}

// MARK: - Rendering a conversation for the model

/// One member recording of a conversation, with whatever the transcriber knew about who was
/// speaking when.
public struct FollowUpSourcePart: Equatable, Sendable {
    public let segmentId: String
    /// Wall-clock start of the recording.
    public let startedAtMs: Int64
    public let text: String
    public let turns: [TranscriptSegment]

    public init(
        segmentId: String, startedAtMs: Int64, text: String, turns: [TranscriptSegment] = []
    ) {
        self.segmentId = segmentId
        self.startedAtMs = startedAtMs
        self.text = text
        self.turns = turns
    }
}

/// Where a quoted line was actually spoken.
public struct QuoteLocation: Equatable, Sendable {
    public let segmentId: String
    /// Offsets inside that segment.
    public let startMs: Int64?
    public let endMs: Int64?
}

public enum FollowUpTranscriptRenderer {
    /// Builds the body the model reads.
    ///
    /// Three things it does that the old flat rendering did not, each of which cost a real
    /// false positive:
    ///  • REAL LOCAL TIMES, so "tomorrow" spoken on a Sunday resolves to a Monday date instead
    ///    of the model being handed `epoch ms 1788193751778` and guessing.
    ///  • SPEAKER TURNS, so two adjacent sentences by two different people are not read as one
    ///    person's promise. Flat text turned "I might try the soup" and someone else's
    ///    "I can text you when it is ready" into a single commitment.
    ///  • THE WHOLE CONVERSATION at once, so a loop that opens in one part and closes in
    ///    another is visibly closed.
    public static func render(
        parts: [FollowUpSourcePart],
        title: String?,
        summary: String?,
        recordedAt: Date,
        timeZone: TimeZone,
        maxChars: Int,
        requests: [FollowUpRequest] = []
    ) -> String {
        var out = "Recorded: \(dayLabel(recordedAt, timeZone))\n"
        if let title, !title.isEmpty { out += "Conversation: \(title)\n" }
        if let summary, !summary.isEmpty { out += "Summary so far: \(summary)\n" }
        out += "\n"
        var transcript = ""
        for part in parts {
            let started = Date(timeIntervalSince1970: Double(part.startedAtMs) / 1000)
            transcript += "--- \(clockLabel(started, timeZone)) ---\n"
            transcript += speakerLines(part) + "\n\n"
        }
        if let asked = FollowUpRequestDetector.promptBlock(requests, in: transcript) {
            out += asked + "\n\n"
        }
        out += transcript
        let body = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count > maxChars else { return body }
        // Keep the END. A conversation's later parts are what close its open loops, and
        // dropping them is what makes a finished errand look like an outstanding one.
        return "[earlier part of this conversation omitted for length]\n"
            + String(body.suffix(maxChars))
    }

    /// The conversation as consecutive pieces the model can each read WHOLE, in order.
    ///
    /// `render` keeps the END of a conversation longer than `maxChars` and drops the rest —
    /// the right call when there is one call, since the end is what closes open loops. But the
    /// worker then settled the conversation as read, so a four-hour conversation's first hours
    /// were never looked at for follow-ups at all, by anything, ever. This cuts the conversation
    /// into pieces instead, each carrying the same header and saying which part of the whole it
    /// is, so every word is read by some call and the conversation settles only when all of
    /// them have been. A conversation that fits is one piece, identical to `render`.
    public static func renderChunks(
        parts: [FollowUpSourcePart],
        title: String?,
        summary: String?,
        recordedAt: Date,
        timeZone: TimeZone,
        maxChars: Int,
        requests: [FollowUpRequest] = []
    ) -> [String] {
        let whole = render(
            parts: parts, title: title, summary: summary, recordedAt: recordedAt,
            timeZone: timeZone, maxChars: Int.max, requests: requests)
        guard whole.count > maxChars else { return [whole] }

        var header = "Recorded: \(dayLabel(recordedAt, timeZone))\n"
        if let title, !title.isEmpty { header += "Conversation: \(title)\n" }
        if let summary, !summary.isEmpty { header += "Summary so far: \(summary)\n" }
        // Room for the part marker line added below.
        let room = max(1_000, maxChars - header.count - 160)

        // Each recording as "--- <clock> ---" plus its speaker lines, cut at line boundaries
        // (and, for a single enormous line, at whitespace) wherever one recording alone is more
        // than a piece can hold.
        var blocks: [String] = []
        for part in parts {
            let started = Date(timeIntervalSince1970: Double(part.startedAtMs) / 1000)
            let clock = "--- \(clockLabel(started, timeZone)) ---\n"
            var current = ""
            for line in speakerLines(part).split(separator: "\n", omittingEmptySubsequences: true)
            {
                for piece in pieces(String(line), limit: room - clock.count) {
                    if !current.isEmpty, clock.count + current.count + piece.count + 1 > room {
                        blocks.append(clock + current)
                        current = ""
                    }
                    current += piece + "\n"
                }
            }
            if !current.isEmpty { blocks.append(clock + current) }
        }

        var chunks: [String] = []
        var current = ""
        for block in blocks {
            if !current.isEmpty, current.count + block.count + 1 > room {
                chunks.append(current)
                current = ""
            }
            current += block + "\n"
        }
        if !current.isEmpty { chunks.append(current) }

        return chunks.enumerated().map { index, body in
            let asked = FollowUpRequestDetector.promptBlock(requests, in: body).map { $0 + "\n\n" }
            return header
                + "Part \(index + 1) of \(chunks.count) of this conversation, in order. The other "
                + "parts are read separately; report only what is in this part.\n\n"
                + (asked ?? "")
                + body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// `text` as pieces of at most `limit` characters, cut at whitespace where possible.
    static func pieces(_ text: String, limit: Int) -> [String] {
        let limit = max(200, limit)
        guard text.count > limit else { return [text] }
        var out: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            var cut = rest.index(rest.startIndex, offsetBy: limit, limitedBy: rest.endIndex)
                ?? rest.endIndex
            if cut < rest.endIndex,
                let space = rest[rest.startIndex..<cut].lastIndex(where: { $0.isWhitespace }),
                rest.distance(from: rest.startIndex, to: space) > limit / 2
            {
                cut = space
            }
            out.append(String(rest[rest.startIndex..<cut]))
            rest = rest[cut...].drop(while: { $0.isWhitespace })
        }
        return out
    }

    /// Speaker-turn text, collapsing consecutive turns by the same label. Falls back to the
    /// flat transcript when the provider gave us no diarization.
    static func speakerLines(_ part: FollowUpSourcePart) -> String {
        guard !part.turns.isEmpty else { return part.text }
        var lines: [String] = []
        var current: String?
        var buffer: [String] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            let body = buffer.joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { lines.append("S\(current ?? "?"): \(body)") }
            buffer = []
        }
        for turn in part.turns {
            let speaker = turn.speaker ?? "?"
            if speaker != current {
                flush()
                current = speaker
            }
            buffer.append(turn.text.trimmingCharacters(in: .whitespaces))
        }
        flush()
        return lines.isEmpty ? part.text : lines.joined(separator: "\n")
    }

    static func dayLabel(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, yyyy-MM-dd 'at' h:mm a"
        return formatter.string(from: date)
    }

    static func clockLabel(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Grounding a quote back in the recording

public enum FollowUpQuoteLocator {
    /// Finds the recording a quoted line came from, and where inside it.
    ///
    /// This is why the extraction schema has no `segmentId` field. Asking a model which
    /// segment its answer came from invites it to invent one, and an invented id strands the
    /// row — the delete cascade removes follow-ups by segment, so a follow-up naming a segment
    /// that does not exist outlives the recording it was drawn from. Matching the quote
    /// locally cannot invent anything: either the words are in a transcript or the item is
    /// not grounded and does not ship.
    public static func locate(quote: String, in parts: [FollowUpSourcePart]) -> QuoteLocation? {
        let needle = normalize(quote)
        guard needle.count >= 8 else { return nil }
        for part in parts {
            guard normalize(part.text).contains(needle) else { continue }
            let offset = turnOffset(needle, in: part)
            return QuoteLocation(
                segmentId: part.segmentId, startMs: offset?.start, endMs: offset?.end)
        }
        // A quote can straddle a turn boundary and pick up a word the flat text renders
        // differently. Fall back to the longest run of it that does match, so a good item is
        // not lost to one character of punctuation.
        let shortened = String(needle.prefix(max(24, needle.count / 2)))
        guard shortened.count >= 12 else { return nil }
        for part in parts where normalize(part.text).contains(shortened) {
            let offset = turnOffset(shortened, in: part)
            return QuoteLocation(
                segmentId: part.segmentId, startMs: offset?.start, endMs: offset?.end)
        }
        return nil
    }

    /// Offsets of the diarized turn that best overlaps the quote — good enough to open the
    /// player a few seconds early, which is what someone reading the item actually wants.
    ///
    /// "Best", not "first": the earlier version accepted any turn whose text was a substring of
    /// the quote's opening, so a one-word backchannel — "And", "So", "No" — anywhere in the
    /// recording claimed the quote and sent the player to the wrong speaker a minute early
    /// ("and" is inside "h-and"). A turn now has to carry a real span of the quote to win, and
    /// the longest overlap takes it.
    static func turnOffset(_ needle: String, in part: FollowUpSourcePart) -> (
        start: Int64, end: Int64
    )? {
        guard !part.turns.isEmpty else { return nil }
        var best: (start: Int64, end: Int64, score: Int)?
        for turn in part.turns {
            let text = normalize(turn.text)
            guard text.count >= minimumTurnMatchChars else { continue }
            let score: Int
            if needle.contains(text) {
                score = text.count
            } else if text.contains(String(needle.prefix(minimumTurnMatchChars))) {
                score = minimumTurnMatchChars
            } else {
                continue
            }
            if score > (best?.score ?? 0) { best = (turn.startMs, turn.endMs, score) }
        }
        return best.map { ($0.start, $0.end) }
    }

    /// Short enough that a real sentence fragment matches, long enough that "and" or "okay"
    /// cannot.
    static let minimumTurnMatchChars = 12

    /// Lowercased, punctuation-free, single-spaced: enough that "I'll take Theo at 7:00." and
    /// "I'll take Theo at 7:00" are the same words, without pretending a paraphrase is a quote.
    static func normalize(_ text: String) -> String {
        let stripped = text.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return " "
        }
        return String(stripped)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
