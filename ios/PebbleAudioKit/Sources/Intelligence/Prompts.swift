import Foundation

// Port of `core/ai/.../SegmentAnnotationPrompt.kt` and `core/ai/.../AiPromptTemplates.kt`.
// The prompt strings are VERBATIM from the KMP app (plan 4.5) — do not "improve" the wording.

// MARK: - SegmentAnnotationPrompt

/// Prompt + response contract for automatic titles/summaries. One short call per enrichment
/// pass; output is parsed leniently so a slightly off-format model response still yields
/// usable row text.
public enum SegmentAnnotationPrompt {
    public static let templateId = "segment-annotation"
    public static let liveTemplateId = "segment-annotation-live"

    private static let systemPrompt =
        "You label transcripts of background audio captured by the user's own always-on "
        + "wearable microphone. The audio is recorded from a low-quality microphone in noisy, "
        + "real-world conditions and then transcribed automatically, so the text very likely "
        + "contains misheard words, garbled names, run-on fragments, and annotated gaps where "
        + "audio was missing. Read past these errors and infer the most plausible intended "
        + "meaning, but never invent facts, names, or events that are not supported by the "
        + "text. Prefer general phrasing when a detail is clearly garbled rather than guessing "
        + "a specific wrong word. Produce a specific plain title, a concise summary, and "
        + "2-4 short topic tags. Tags should be lowercase when they are general topics "
        + "(work, budget, health), and title case only for people, organizations, or proper "
        + "nouns. Prefer reusable tags over one-off phrases. Do not include Markdown.\n"
        + "For text-only providers, respond with exactly three lines and nothing else:\n"
        + "TITLE: a specific, plain title of at most 8 words (no quotes, no trailing period)\n"
        + "SUMMARY: 1-3 plain sentences summarizing what was discussed\n"
        + "TAGS: 2-4 short topic tags, comma-separated (e.g. work, budget, Sarah)\n"
        + "If the transcript is too short or unclear to summarize, still produce your best "
        + "honest label, e.g. TITLE: Brief unclear conversation."

    /// Closed-conversation, authoritative pass over the complete durable transcript.
    public static let template = AiPromptTemplate(
        id: templateId,
        title: "Segment title and summary",
        systemPrompt: systemPrompt,
        userPrompt: "This is the complete transcript of a finished conversation. Create the "
            + "authoritative title and summary for it."
    )

    /// In-progress pass while the conversation is still being recorded and transcribed.
    public static let liveTemplate = AiPromptTemplate(
        id: liveTemplateId,
        title: "Segment title and summary (live)",
        systemPrompt: systemPrompt,
        userPrompt: "This conversation is still ongoing and only partially transcribed. "
            + "Summarize what has been discussed so far; a later pass will produce the final "
            + "version."
    )

    /// The prompt to use for a given pass: `liveTemplate` while recording, `template` when
    /// final.
    public static func forPass(live: Bool) -> AiPromptTemplate {
        live ? liveTemplate : template
    }

    public struct Parsed: Equatable, Sendable {
        public let title: String?
        public let summary: String?
        public let tags: [String]

        public init(title: String?, summary: String?, tags: [String] = []) {
            self.title = title
            self.summary = summary
            self.tags = tags
        }
    }

    /// Structured (JSON) response shape requested from schema-capable providers. Lenient like
    /// the Kotlin serializer: unknown keys ignored, missing keys default.
    private struct Structured: Decodable {
        var title: String = ""
        var summary: String = ""
        var tags: [String] = []

        private enum CodingKeys: String, CodingKey { case title, summary, tags }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        }
    }

    public static func parse(_ text: String) -> Parsed {
        if let structured = parseStructured(text) { return structured }
        var title: String?
        var summaryParts: [String] = []
        var tags: [String] = []
        var activeField: String?
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = matchFieldLine(trimmed) {
                let field = match.field.uppercased()
                let value = AiPlainText.clean(match.value)
                activeField = field
                switch field {
                case "TITLE":
                    if title == nil { title = value }
                case "SUMMARY":
                    if let value, !value.isEmpty { summaryParts.append(value) }
                case "TAGS":
                    if tags.isEmpty {
                        tags = match.value
                            .components(separatedBy: CharacterSet(charactersIn: ",;"))
                            .compactMap { cleanTag($0) }
                            .filter { !$0.isEmpty }
                            .distinctByLowercase()
                            .prefix(maxTags)
                            .map { $0 }
                    }
                default:
                    break
                }
            } else if activeField == "SUMMARY" {
                if let cleaned = AiPlainText.cleanLine(trimmed) { summaryParts.append(cleaned) }
            }
        }
        var summary: String? = {
            let joined = summaryParts.joined(separator: " ")
            return joined.trimmingCharacters(in: .whitespaces).isEmpty ? nil : joined
        }()
        if title == nil && summary == nil {
            // Lenient fallback: first non-blank line is the title, the rest the summary.
            let lines = text.components(separatedBy: .newlines)
                .compactMap { AiPlainText.cleanLine($0) }
            title = lines.first
            let rest = lines.dropFirst().joined(separator: " ")
            summary = rest.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rest
        }
        return Parsed(
            title: shortenTitle(title),
            summary: AiPlainText.clean(summary, maxChars: maxSummaryChars),
            tags: tags
        )
    }

    private static func parseStructured(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let structured = try? JSONDecoder().decode(Structured.self, from: Data(trimmed.utf8))
        else { return nil }
        return Parsed(
            title: shortenTitle(structured.title),
            summary: AiPlainText.clean(structured.summary, maxChars: maxSummaryChars),
            tags: structured.tags
                .compactMap { cleanTag($0) }
                .distinctByLowercase()
                .prefix(maxTags)
                .map { $0 }
        )
    }

    /// Titles are capped at `maxTitleChars`, and the models overshoot the prompt's "at most
    /// 8 words" often enough that the cap is what the user actually reads. A hard `prefix`
    /// cut it mid-word — real rows read "…Soniox, and a request for", which looks like the
    /// app lost the rest. So: prefer ending on a clause boundary (a comma, dash or colon past
    /// the halfway mark) where the shortened title still reads as a whole phrase; otherwise
    /// cut on a word boundary and mark it with an ellipsis. Either way the title never ends
    /// on a dangling "and"/"for"/"the" or on stray punctuation.
    static func shortenTitle(_ text: String?) -> String? {
        guard let cleaned = AiPlainText.clean(text), !cleaned.isEmpty else { return nil }
        guard cleaned.count > maxTitleChars else { return cleaned }
        let window = String(cleaned.prefix(maxTitleChars))
        if let clause = window.lastIndex(where: { clauseBreaks.contains($0) }),
            window.distance(from: window.startIndex, to: clause) >= maxTitleChars / 2
        {
            let head = trimTitleEdge(String(window[window.startIndex..<clause]))
            if !head.isEmpty { return head }
        }
        // The ellipsis counts against the cap, so a shortened title is never LONGER than one
        // that fitted.
        if let space = window.lastIndex(of: " ") {
            let head = trimTitleEdge(String(window[window.startIndex..<space]))
            if !head.isEmpty { return head + "…" }
        }
        let head = trimTitleEdge(String(cleaned.prefix(maxTitleChars - 1)))
        return head.isEmpty ? nil : head + "…"
    }

    private static let clauseBreaks: Set<Character> = [",", ";", ":", "—", "–"]
    private static let danglingWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "with", "for", "to", "of", "in", "on", "at",
        "from", "about", "by", "into", "over", "than", "that",
    ]

    private static func trimTitleEdge(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespaces)
        func trimTrailingPunctuation() {
            while let last = result.last,
                last.isWhitespace || clauseBreaks.contains(last) || last == "-" || last == "."
            {
                result.removeLast()
            }
        }
        trimTrailingPunctuation()
        while let word = result.split(separator: " ").last,
            danglingWords.contains(word.lowercased())
        {
            result.removeLast(word.count)
            trimTrailingPunctuation()
        }
        return result
    }

    private static func cleanTag(_ value: String) -> String? {
        guard var tag = AiPlainText.clean(value, maxChars: maxTagChars) else { return nil }
        tag = tag.trimmingCharacters(in: .whitespaces)
        tag = tag.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        tag = tag.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return tag.isEmpty ? nil : tag
    }

    // Kotlin: ^\s*(?:#{1,6}\s*)?(?:[-*]\s*)?(?:\*\*)?\s*(TITLE|SUMMARY|TAGS)\s*:?\s*(?:\*\*)?\s*:?\s*(.*)$
    private static let fieldLine = try! NSRegularExpression(
        pattern: "^\\s*(?:#{1,6}\\s*)?(?:[-*]\\s*)?(?:\\*\\*)?\\s*(TITLE|SUMMARY|TAGS)"
            + "\\s*:?\\s*(?:\\*\\*)?\\s*:?\\s*(.*)$",
        options: [.caseInsensitive]
    )

    /// `Regex.matchEntire` equivalent for one (newline-free) line.
    private static func matchFieldLine(_ line: String) -> (field: String, value: String)? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard
            let match = fieldLine.firstMatch(in: line, options: [], range: full),
            match.range == full
        else { return nil }
        return (field: ns.substring(with: match.range(at: 1)),
                value: ns.substring(with: match.range(at: 2)))
    }

    static let maxTitleChars = 80
    static let maxSummaryChars = 600
    static let maxTagChars = 32
    static let maxTags = 4
}

extension Array where Element == String {
    /// Kotlin `distinctBy { it.lowercase() }` — keeps the first occurrence, preserves order.
    func distinctByLowercase() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0.lowercased()).inserted }
    }
}

// MARK: - AiPromptTemplates

/// Built-in manual templates for the AI flow (ux-visual-design-plan Section 19). Users can
/// also run a custom prompt; custom templates persist via `CustomTemplateStore` (AppDB).
public enum AiPromptTemplates {
    /// The `[n]` convention, shared by every template whose output is read beside the
    /// recording. The numbers are the excerpt labels the prompt builder writes, and they are
    /// what map a chip in the UI back to a segment - so the model must never invent one.
    static let citationRules =
        "Each transcript segment is labelled with a citation number like [2]. When a point "
        + "comes from a segment, place that bracketed number right after it, e.g. \"They "
        + "decided to take the ferry [2].\" Cite more than one when several apply, e.g. "
        + "[2][5]. Use only the numbers you were given - never a segment id, a markdown link, "
        + "or a number for a segment that was not provided."

    static let commonSystemRules =
        "You are processing transcripts of background audio captured by the user's own "
        + "wearable microphone. Transcripts may contain transcription errors, fragments, and "
        + "annotated gaps where audio was missing. Never invent content for gaps; mention "
        + "missing audio only when it matters for the answer. Be concise and factual."

    public static let dailySummary = AiPromptTemplate(
        id: "daily-summary",
        title: "Daily summary",
        systemPrompt: "\(commonSystemRules) Produce a short plain-text recap of one day's "
            + "captured conversations and events, in chronological order. Segments are labelled "
            + "with their local start time; the day runs from early morning to early morning, so "
            + "treat transcripts from shortly after midnight as the tail of the same day. The "
            + "transcripts may cover only the day so far - recap what has happened without "
            + "remarking that the day is incomplete or ongoing. Use 2-4 concise sentences. Do "
            + "not use Markdown, headings, bullets, bold text, or numbered lists.",
        userPrompt: "Summarize what happened in these transcripts."
    )

    public static let meetingNotes = AiPromptTemplate(
        id: "meeting-notes",
        title: "Meeting notes",
        systemPrompt: "\(commonSystemRules) Produce structured meeting notes: topic, "
            + "discussion points, decisions, and open questions. \(citationRules)",
        userPrompt: "Write meeting notes for this conversation.",
        citesSources: true
    )

    public static let actionItems = AiPromptTemplate(
        id: "action-items",
        title: "Action items",
        systemPrompt: "\(commonSystemRules) Extract only real commitments or follow-up tasks "
            + "as a plain checklist. Do not include headings, introductory text, numbering, "
            + "Markdown emphasis, nested bullets, or transcript-summary bullets. Use one item "
            + "per line in this exact shape: - Task text. Owner: Name if known. Due: deadline "
            + "if known. If there are no action items, say: No action items found.",
        userPrompt: "Extract the action items from these transcripts."
    )

    public static let decisions = AiPromptTemplate(
        id: "decisions",
        title: "Decisions",
        systemPrompt: "\(commonSystemRules) List the decisions that were made, each with the "
            + "context that led to it. If no decisions were made, say so plainly. "
            + "\(citationRules)",
        userPrompt: "List the decisions made in these transcripts.",
        citesSources: true
    )

    public static let followUpEmail = AiPromptTemplate(
        id: "follow-up-email",
        title: "Follow-up email",
        systemPrompt: "\(commonSystemRules) Draft a short, professional follow-up email "
            + "covering what was discussed, decided, and agreed as next steps. Leave the "
            + "recipient placeholder as [Name].",
        userPrompt: "Draft a follow-up email based on these transcripts."
    )

    public static let studyNotes = AiPromptTemplate(
        id: "study-notes",
        title: "Study notes",
        systemPrompt: "\(commonSystemRules) Produce clear study notes: key concepts, "
            + "definitions, and takeaways organized for review. \(citationRules)",
        userPrompt: "Create study notes from these transcripts.",
        citesSources: true
    )

    public static let interviewHighlights = AiPromptTemplate(
        id: "interview-highlights",
        title: "Interview highlights",
        systemPrompt: "\(commonSystemRules) Summarize interview highlights: candidate "
            + "strengths, concerns, and notable quotes. Be factual. \(citationRules)",
        userPrompt: "Summarize interview highlights from these transcripts.",
        citesSources: true
    )

    public static let ask = AiPromptTemplate(
        id: "ask",
        title: "Ask",
        systemPrompt: "\(commonSystemRules) Answer the user's question using only the "
            + "provided transcripts. Each transcript is labelled with a citation number like [2]. "
            + "When a statement draws on a transcript, cite it by placing that bracketed number "
            + "right after the statement, e.g. \"You're considering Brazil [2].\" Cite more than "
            + "one when several apply, e.g. [2][5]. Do not write out raw segment ids, timestamps, "
            + "or markdown links — only the [n] numbers. If audio gaps matter, say so honestly. "
            + "Never fabricate.\n"
            // The transcripts are recordings of the user's own past days, so every answer is a
            // statement about time. Anchor it: RIGHT NOW is given, and each transcript carries
            // the date it was recorded.
            + "TIME: The recordings were made on different days, and RIGHT NOW is given above "
            + "them. Relative words spoken inside a transcript — \"tomorrow\", \"this weekend\", "
            + "\"next week\", \"in three days\" — are relative to THAT transcript's recording "
            + "date, not to today. Work out the real date before answering, and say it plainly "
            + "(\"Friday the 5th\", \"this coming weekend\") when it matters. Do not present a "
            + "plan made days ago as if it were made today, and do not describe a date that has "
            + "already passed as upcoming. When transcripts from different days disagree, the "
            + "most recent one wins — say when the change happened.\n"
            // Ask is a running conversation; earlier turns are handed back on every follow-up.
            + "CONVERSATION: If a CONVERSATION SO FAR section is present, you are mid-discussion "
            + "with the user. Resolve pronouns and shorthand (\"that\", \"the plan\", \"what "
            + "about Friday?\") against those earlier turns, keep your earlier statements "
            + "consistent, and answer only the new question — do not repeat a whole previous "
            + "answer.",
        userPrompt: "Continue this conversation, using the transcripts as the only source of "
            + "facts.",
        citesSources: true
    )

    public static let builtIn: [AiPromptTemplate] = [
        dailySummary,
        meetingNotes,
        actionItems,
        decisions,
        followUpEmail,
        studyNotes,
        interviewHighlights,
    ]

    public static func custom(_ prompt: String) -> AiPromptTemplate {
        AiPromptTemplate(
            id: "custom",
            title: "Custom prompt",
            systemPrompt: commonSystemRules,
            userPrompt: prompt
        )
    }
}
