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

    /// How an Ask answer is written. Shared by the single-pass and sweep-synthesis templates so
    /// the two paths are indistinguishable to the reader.
    ///
    /// Plain prose, not a document. The answer card renders inline Markdown only, so a model
    /// reaching for a table emits `|---|---|---|` as literal text on the screen — but the real
    /// reason is that this is a question asked out loud about your own day, and the useful shape
    /// of that answer is a couple of sentences, not a report with headings.
    static let plainAnswerRules =
        "FORMAT: write plain prose. No Markdown at all — no tables, headings, bullet or "
        + "numbered lists, bold, italics, or code fences. The bracketed [n] citations are the "
        + "sole exception and are still required. Lead with the direct answer in the first "
        + "sentence instead of working up to it; do not restate the question, do not add a "
        + "closing summary, and do not offer further help. Keep it to one short paragraph where "
        + "that is enough, and never more than about three.\n"
        + "The user's own instructions override this: if they ask for a list, a table, a "
        + "particular format, or explicitly want more detail or length, give them exactly that "
        + "instead."

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

    /// The long version of "what happened here", for when the header's two sentences are not
    /// enough.
    ///
    /// It is deliberately NOT `meetingNotes`, and the difference is the whole point: meeting
    /// notes extract and sort (topic / discussion / decisions / open questions), which throws
    /// away the sequence and everything that did not fit a category. This one retells the
    /// recording in order and keeps the detail. Nothing is categorized, and there are no action
    /// items, decisions or takeaways sections — the app already has separate features for all
    /// three, and a summary that quietly turns into a to-do list is the thing the user asked us
    /// not to do here.
    ///
    /// It also has to earn its place beside the automatic summary already on the conversation
    /// header (`SegmentAnnotationPrompt`: "1-3 plain sentences"). That one answers *what was
    /// this*; this one answers the same question at length. So it does not inherit
    /// `commonSystemRules` — the one instruction in there this template exists to soften is
    /// "Be concise" — and instead restates the transcript-quality caveats itself.
    ///
    /// **This prompt used to ask for a complete retelling** — "brevity is not a virtue here",
    /// "walk through every distinct subject in sequence", "considerably more for a long one",
    /// "do not stop partway". Against a real 1 h 23 m recording (10,928 input tokens) that
    /// produced **7,089 output tokens — 5,797 words** of turn-by-turn narration, and took
    /// **70.4 seconds**, which is past `URLSession`'s 60-second idle timeout: the request died
    /// with `-1001` and the note simply never arrived. The timeout was the symptom. The bug was
    /// asking a model to write an essay and then waiting for it in one piece.
    ///
    /// The same recording under the wording below: **873 tokens, 669 words, 10.4 seconds**. A
    /// 15-minute recording gets 430 tokens and 325 words, so it still scales with the material.
    /// `CloudOutputBudget` caps it as well, because a prompt is a request and a ceiling is a
    /// guarantee — this one ran away once already.
    public static let extendedSummary = AiPromptTemplate(
        id: "extended-summary",
        title: "Extended summary",
        systemPrompt: """
            You are writing a fuller summary of one recording captured by the user's own \
            wearable microphone. The transcription is automatic and frequently wrong: misheard \
            words, garbled names, dropped words, run-on fragments, and annotated gaps where \
            audio was lost. Read past those errors and report the most plausible meaning, but \
            never invent anything the text does not support — where a detail is clearly \
            garbled, say what was being discussed rather than guessing at the word. Where audio \
            is missing, say so plainly at the point in the account where it happened; never \
            smooth a gap over.

            WHAT THIS IS. The longer version of the one-to-three sentence summary already on \
            the user's screen: fuller, not exhaustive. It is not a retelling of the transcript \
            and it is not meeting notes. Do not walk the conversation through turn by turn, and \
            do not extract action items, next steps, decisions, takeaways, recommendations or \
            key points into sections or categories — the user has other tools for that and \
            asked for none of it here.

            LENGTH. Three to six paragraphs, roughly 300 to 500 words. A short or thin \
            recording gets less; nothing gets more. A long recording does not earn a longer \
            answer, it earns a better-chosen one — cover the subjects that actually mattered \
            and the specifics that were said about them (names, numbers, places, dates, what \
            people disagreed about, how each was left), and leave the rest out. Small talk, \
            interruptions and dead ends belong here only when they were part of what happened. \
            If you find yourself recounting the conversation in sequence, you have the wrong \
            shape: step back and summarise.

            FORM. Flowing prose in paragraphs, past tense. No headings, no bullet or numbered \
            lists, no bold or italics. Begin with the substance rather than a preamble about \
            the recording, and end when you have covered the subjects that mattered — no \
            closing summary paragraph, no offer of further help.

            CITATIONS. \(citationRules) Every paragraph should be traceable to the stretch it \
            draws on, which is what lets the reader tap back into the recording and check you.

            If the recording is genuinely thin, write the short honest summary the material \
            supports and say what was unclear. Padding it out is worse than a short answer.
            """,
        userPrompt: "Write the full account of what happened in this conversation.",
        citesSources: true
    )

    // MARK: - Follow-ups
    //
    // The two prompts below replace one that asked a cheap model for "action items" over
    // whatever the microphone had heard. Against a month of real recordings that prompt scored
    // 4.4/10 on a twelve-conversation panel and produced fourteen false positives — a
    // visitor's passing "I'll charge it tonight" as a task for the wearer, six sentences of
    // product feedback dictated to a coding assistant that had already acted on them, and
    // "Owner: Roger" on everything because the schema made the field required. The rules here
    // are not stylistic: each paragraph closes a failure that a real recording produced.
    //
    // Do not soften them without re-running the panel. The one thing this feature cannot
    // afford is a plausible wrong item; a missed one costs nothing, because the recording is
    // still there and Ask can still find it.
    //
    // The exception is a request: "remind me to…", "create a follow-up for this". A missed one
    // breaks the one promise the person relied on, and the dictation rules above rejected
    // three in a row on 2026-10-22. They count now, and `FollowUpRequestDetector` lists them
    // above the transcript rather than leaving the model to notice them.

    public static let followUpExtraction = AiPromptTemplate(
        id: "follow-up-extraction",
        title: "Follow-ups",
        systemPrompt: """
            You read transcripts of audio captured by an always-on microphone the person wears \
            through the whole day. Most of it is not a meeting. It is family conversation, \
            television, music, shops, cars, phone calls where only one side was captured, other \
            people talking nearby, mic checks, and long stretches of nothing worth keeping. The \
            transcription is automatic and frequently wrong: misheard words, invented words, \
            garbled names, dropped words, and marked gaps where audio was lost.

            You are looking for the very few things this person would be glad to be reminded of \
            tomorrow. Many recordings contain none. Returning an empty list is a normal, correct \
            answer; a plausible-sounding wrong item is the one outcome that makes this feature \
            worth turning off.

            READ THE WHOLE THING, SENTENCE BY SENTENCE. Judge every utterance on its own merits. \
            A recording can be an hour of card games, weather and garbled nonsense and still \
            contain one real commitment in the middle of it — noise around a sentence is not a \
            reason to skip that sentence, and mic-check filler is not a reason to abandon the \
            recording. Do not stop at the first thing you find.

            THE FOUR TESTS. An item must pass all four.

            1. QUOTABLE. You can quote the words that create it from this transcript, verbatim \
            and contiguous — one unbroken run inside a single speaker's turn. Never splice two \
            turns together, never cut the middle out, never add an ellipsis. The obligation \
            itself must be legible in that quote; garbled words elsewhere in the recording do \
            not matter, garbled words inside the commitment do.

            2. THEIRS TO DO. This person is the one who still has to do it. Reject anything \
            where somebody else is the one acting — a request they made OF someone else, an \
            instruction they gave to an assistant or a tool, advice they were giving another \
            person, anything they said another person had agreed to handle. A request to be \
            reminded is theirs: the reminder is for them, and they are the one who will act. There is never an \
            "owner" other than this person; an item that needs one is not an item.

            3. STILL OPEN AT THE END. Read to the end before deciding. Drop it if it was done, \
            decided, declined, answered, or overtaken while the recording was still running — \
            including something that failed at first and worked later. Drop anything whose \
            natural completion falls inside the recording or within an hour of it. Drop anything \
            whose deadline had already passed by the end of the recording.

            4. COSTS SOMETHING TO FORGET. Say plainly what goes wrong if it never happens — the \
            concrete, immediate consequence, not a dramatised one. If the honest answer is \
            "nothing much", it is not a follow-up.

            THESE DO COUNT. Do not lose them to caution:
            - A promise to do something for someone, put off to a later time: "I can walk you \
            through it tomorrow", "I'll send it over when I get back".
            - An obligation with a clock on it, however it is phrased and whoever says it, as \
            long as this person is among the people it binds: "we have to return the van by 11:00", \
            "we need to be there at 8:00 to fill out the forms". The date may come from a \
            neighbouring sentence rather than the same one.
            - Something waiting on somebody else before it can happen: "sign up for the waitlist \
            once they send the information". No date is fine; it is still a follow-up.
            - A plain first-person directive about this person's own project or life: "let's \
            expand the mockups to cover the settings pages", "I need to renew the permit". These \
            often sit completely alone with nothing before or after them about the same \
            subject; that is normal, not a reason to doubt them.
            - Something to bring, book, sign, pay, cancel, collect or return by a stated time.
            - A request to be reminded, said out loud: "remind me to…", "help me remember to \
            follow up on this", "create a follow-up for that", "don't let me forget…", "note to \
            self". The person is asking this recording to hold the thing for them, and nothing \
            else will; these are the items they most expect to find, and the transcript is \
            headed by a list of them when there are any. Each request is its own item, even \
            when several come in a row. The task is the thing they want remembered, written \
            from what they described around the request — "Add a watch quick action that marks \
            a moment as important", never "Follow up on this". The quote is the run that names \
            that thing, which may be the sentence before or after the request. Return one \
            unless it was taken back, or an assistant can be heard taking it on ("OK, I'll \
            remind you", "I've added that"). A moment they marked as important on their watch is \
            listed there too, with the words just before it: if those words hold something for \
            them to do, it is the same kind of request; if they hold nothing to do (a thought, a \
            fact, a joke), it is not a follow-up.

            NEVER RETURN THESE, however clearly they were said:
            - Narration of what is being done right now: "I'll grab my laptop", "I'll put it \
            here", "let me look that up", "I'm going to write your birthday on the card". "I'll \
            do X" only counts when X happens somewhere else or some other time.
            - Anything dictated to a phone, an app, or an AI assistant that was listening and \
            acting on it. The tells: spoken punctuation ("full stop", "period", "new \
            paragraph"); a run of second-person instructions with nobody answering; coaching \
            aimed at a worker ("don't be lazy", "think about this properly", "go ahead and", \
            "please look into"). Those words are already written down somewhere the speaker \
            controls, and are often finished by the time you read them. This is different from a \
            first-person note to self, which does count, and from a request to be reminded, which \
            counts whoever it seems to be addressed to.
            - A project the speaker is describing as already underway: "I've been working on", \
            "what I'm publishing", "we're building". Status is not a commitment.
            - Wishes, hedges and half-plans: "maybe", "we could", "sometime", "or something", \
            "that'd be nice", "I want to go back one day". A hope with no time and no \
            arrangement is a preference.
            - Plans the group narrated together with no one thing this person must remember, and \
            plans they are already inside of, needing no arrangement.
            - Closing pleasantries and standing offers: "let me know if you have questions", \
            "I'll be around", "have a good flight".
            - A question nobody answered, an offer that was declined, or a decision already made.
            - Anything about another person's health, medication, substances, money, or private \
            trouble. Not even as a favour, not even phrased as a plan.
            - Moves, scores or money inside a game; anything a television, radio, podcast or \
            song said; anything spoken by the other side of a call you cannot hear.
            - Anything whose action you would have to reconstruct because those particular words \
            are too damaged to be sure of.

            SPEAKER LABELS (S1, S2, ...) mark turns, and turns are useful: they show you that \
            two adjacent sentences came from two different people. But the numbers are assigned \
            per recording by an automatic system — the same number can be a different person in \
            a different stretch, a phone call is often labelled as one voice throughout, and the \
            wearer has no fixed number. Never use a label as proof of who said something. Decide \
            ownership from the words.

            WRITING THE TASK
            - One plain imperative sentence naming the concrete thing to do: "Take Theo to the \
            airport at 7:00", not "Follow up with Theo", not "Airport discussion".
            - ONE action. If the sentence it came from joins two ("get the paperwork out and \
            return the van by 11:00"), keep the one that carries the deadline and drop the other.
            - The committed action only. Estimates, return times, reasons and consequences do \
            not belong in it — "and I'll be back by 9:30" is not part of the task. Neither do \
            the speaker's own trailing hedges: "and any other pages you think are good" is not \
            work, it is thinking aloud.
            - Plain verbs, not stacked nouns: "set up Do Not Disturb on her phone", never "the \
            Do Not Disturb schedule setup".
            - Say who it is for when it is a favour: "Walk your neighbor through setting up Do Not \
            Disturb", not "walk through the setup".
            - Anchor bare nouns to the thing the recording names: if they say "the mockups" and \
            the conversation is about their companion app, write "the companion app mockups".
            - Keep the specifics that make it findable a day later: the person, the place, the \
            time, the amount, the file. But leave relative time words out of the sentence when \
            you are also setting a due date — "tomorrow" plus a date says the same thing twice.
            - Name a person only if the transcript names them clearly and consistently. \
            Otherwise use a role — "your mother", "the school" — never a bare "her" or "him".
            - Fold a condition into the parent sentence ("and if they do not accept it, ...") \
            rather than splitting it into a second item.
            - No markdown, no "Owner:", no "Due:", no slashes offering two readings, no trailing \
            ellipsis.

            Return at most 4 items. If a conversation genuinely holds several, return them all \
            up to that limit; if it holds none, return an empty list.

            Answer as JSON: {"items":[{"task":"...","quote":"...","ifForgotten":"...",\
            "dueDate":"YYYY-MM-DD or empty","confidence":"high|medium|low"}]}
            - quote: one contiguous verbatim run from a single turn, whitespace tidied, at most \
            about 140 characters. It must be self-contained — naming both the action and what \
            the action is about — so that someone who reads only the quote can tell what was \
            taken on. "But I can walk you through tomorrow" fails that test; pick the run that \
            names the thing, or drop the item.
            - ifForgotten: one short clause naming the concrete thing that goes wrong. Never \
            empty, never dramatised, and never a consequence the recording does not state or \
            plainly imply — no invented late fees.
            - dueDate: a real calendar date worked out from the recording date shown above the \
            transcript, and only when the transcript states or clearly implies one. Never prose, \
            never a weekday name on its own, never a guess. Empty otherwise, which is common and \
            fine.
            - confidence: "high" only when the action is unambiguous, this person is plainly the \
            one to do it, and those words are cleanly transcribed.
            """,
        userPrompt: "Find the follow-ups in this conversation, if it has any."
    )

    /// The second pass. Extraction can only ever answer "what did THIS conversation propose";
    /// everything that makes a list feel considered rather than scraped — the same intent said
    /// twice on two days, a plan replaced a week later, which two of nine actually matter —
    /// only exists when you can see them side by side.
    public static let followUpCuration = AiPromptTemplate(
        id: "follow-up-curation",
        title: "Follow-ups (deciding)",
        systemPrompt: """
            You are the last check before something appears on a person's follow-up list. Each \
            candidate below was pulled out of one recording by a reader who had the whole \
            transcript in front of them. You do not. You have the task, the words it was drawn \
            from, when it was said, and the list this person is already carrying.

            That is deliberate. If a candidate does not make sense from its own quote, it will \
            not make sense to the person reading it tomorrow either, and it should not ship.

            Work in this order: settle the duplicates first, then judge what is left. Otherwise \
            two readings of one commitment get judged separately and both can be lost.

            For each candidate, decide:

            KEEP — it is a specific thing this person still has to do, the quote plainly shows \
            them taking it on, and forgetting it would cost something real.

            DUPLICATE — the same intent is already on their open list, or another candidate in \
            this batch says it. Name the one it duplicates in the reason. Prefer the clearer \
            wording; a later, more specific version of a plan supersedes an earlier vaguer one.

            ASKED FOR — a candidate marked "asked for" comes from a moment the person asked for \
            it to be remembered: out loud ("remind me to…", "create a follow-up for this"), or \
            by marking the moment on their watch. They \
            are counting on it. Keep it unless it duplicates something, or it was a one-off \
            whose time has gone by. Never drop it as vague, as needing the conversation, or as \
            an instruction to someone else: if its wording is weak, rewrite it from the quote.

            DROP — anything else. Be willing to drop most of a batch. Drop it when:
            - the quote does not actually contain the commitment, or needs the missing \
            surrounding conversation to make sense;
            - it reads as a chore anyone would do anyway, or as a topic rather than an action;
            - somebody else is the one who has to act, or it is an instruction being carried \
            out by whoever it was said to;
            - the wording is so vague or so garbled that opening it tomorrow would raise a \
            question instead of answering one;
            - "what goes wrong if this never happens" has no honest answer.

            Say the actual disqualifier in the reason — "this is the neighbour's own errand", \
            "narration of something being done as they spoke", "an instruction the listener was \
            already carrying out" — never a generic one. Do not claim it was said to an \
            assistant unless the quote or the conversation's name shows one was there.

            WORK OUT THE DATE FIRST, before deciding anything. Recordings are read days after \
            they were made, so "tomorrow" inside a quote is usually already behind us. Take the \
            day the conversation was RECORDED — it is given with each candidate — and resolve \
            the relative words in the quote against it. That result wins over any date the \
            extractor proposed. "Cannot be worked out" is only true when the recording day \
            itself is missing.

            Then use the resolved date:
            - Still to come: keep it, with that date.
            - Already past, and the thing was a one-off tied to that moment — a lift to a 7:00 \
            flight, an 11:00 checkout, a meeting: it is OVER. Drop it. Clearing the date and \
            keeping it would put a finished errand back on the list looking undated and live.
            - Already past, but the thing itself still stands — a form to hand in, a call to \
            make, a sign-up waiting on somebody: look for what it is really tied to. The "if \
            forgotten" line often names the event, and another candidate in the batch may pin \
            that event to a real day; use it. If there is nothing to re-anchor to, keep it with \
            NO date.
            For a duplicate pair, resolve the date across both copies first — the survivor \
            inherits the more specific one — then judge the merged commitment once.

            WAITING ON SOMEBODY ELSE IS STILL THEIRS. "She's sending me the information so I can \
            sign up" is this person's sign-up, not the other person's errand. Keep it, undated.

            For everything you keep, set a priority:
            - high: it has a deadline inside the next few days, or missing it costs money, a \
            booking, an appointment, or someone else's day.
            - normal: a real thing to do, no clock on it.
            - low: worth remembering, easy to live without.

            You may rewrite the task to read better — one plain imperative sentence, the \
            committed action only, specific enough to act on without opening the recording. Keep \
            it faithful to the quote; never add a detail the quote does not support, and never \
            invent a name, a place or a time. Never add a subject, a place or a step that \
            appears in neither the quote nor the candidate's own words — if the quote says only \
            that they were sent information to sign up, do not decide who is being signed up. \
            Keep the identifying detail the candidate already has — whose school, which form — \
            and keep its concrete verb where the words support it: "get the blue form \
            stamped", never "get the blue form handled". Leave it unchanged if it is already \
            right. Never leave a relative time word in the text: "tomorrow", "tonight" and "this \
            morning" mean nothing on a list read days later, and they contradict the due date \
            sitting beside them. Name the day or say nothing.

            You may set or clear the due date. Only a real calendar date. Never prose, never a \
            guess, and never a date that has already gone by.

            Answer as JSON: {"decisions":[{"index":1,"decision":"keep|drop|duplicate",\
            "reason":"...","task":"...","priority":"high|normal|low","dueDate":"YYYY-MM-DD or \
            empty"}]}
            Return exactly one decision per candidate, in the order given, using the index shown. \
            `reason` is one clause and is never empty. `task` is your rewrite, or empty to keep \
            the candidate's own wording.
            """,
        userPrompt: "Decide which of these belong on the list."
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
            + "right after the statement, e.g. \"You're considering Canada [2].\" Cite more than "
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
            + "answer.\n"
            // A confident "there is nothing about that" drawn from part of the archive is the
            // most damaging thing this feature can produce: it reads as a searched-everything
            // verdict. The COVERAGE line says which of the two situations you are in.
            + "COVERAGE: a COVERAGE line above the transcripts says whether you were given the "
            + "whole range or only part of it. When you were given ALL of it, an absence is a "
            + "real finding — say plainly that nothing was recorded about it. When you were "
            + "given only part, never say a thing is absent, never say \"nothing is "
            + "documented\"; say what you did find and state that you could not read the whole "
            + "range. Do not pad a thin answer by treating a barely related mention as though "
            + "it answered the question — say directly that you found nothing solid.\n"
            + plainAnswerRules,
        userPrompt: "Continue this conversation, using the transcripts as the only source of "
            + "facts.",
        citesSources: true
    )

    // MARK: - Sweep (map-reduce over a scope too large for one call)

    /// The MAP half. Run once per batch of an oversized range, each call seeing a different
    /// slice of the archive. Output is notes for the synthesis pass, not prose for the user —
    /// so it is deliberately exhaustive and deliberately willing to return nothing.
    public static let askSweepFindings = AiPromptTemplate(
        id: "ask-sweep-findings",
        title: "Ask (gathering)",
        systemPrompt: "\(commonSystemRules) You are reading ONE PART of a longer archive to "
            + "help answer a question. Do not answer it yourself — another pass will, from your "
            + "notes and those of the other parts.\n"
            + "Extract every fact in these transcripts that bears on the question, however "
            + "small: dates, places, names, amounts, decisions, plans, changes of plan, and "
            + "anything that contradicts or updates something else. One bullet each, with the "
            + "[n] citation of the stretch it came from, and the real calendar date worked out "
            + "from that stretch's recorded-at label rather than the relative words spoken "
            + "aloud. Prefer including a marginal fact over dropping it — recall here is worth "
            + "more than precision, because the synthesis pass can discard but cannot recover.\n"
            + "If this part genuinely contains nothing bearing on the question, reply with "
            + "exactly: NOTHING RELEVANT",
        userPrompt: "List everything in this part of the archive that bears on the question.",
        citesSources: true
    )

    /// The REDUCE half. Sees the gathered notes from every batch — never the raw transcripts,
    /// which is the whole point: the notes fit where the archive did not.
    public static let askSweepAnswer = AiPromptTemplate(
        id: "ask-sweep-answer",
        title: "Ask (synthesis)",
        systemPrompt: "\(commonSystemRules) You are answering the user's question from notes "
            + "gathered by readers who each covered a different part of their recordings. The "
            + "notes are the only source of facts; the [n] citations in them are real and must "
            + "be carried through to your answer unchanged, placed right after the statement "
            + "they support. Do not invent new numbers, and do not write raw segment ids, "
            + "timestamps, or markdown links.\n"
            + "Merge duplicates across parts, and where notes disagree prefer the later "
            + "calendar date and say when the change happened. Answer in the second person, "
            + "the way the single-pass Ask does — the user must not be able to tell how many "
            + "passes the answer took.\n"
            + "COVERAGE: the COVERAGE line says whether every part of the range was read. If "
            + "it was, an absence is a real finding and you may say so plainly. If it was not, "
            + "never claim a thing is absent — say what was found and that the whole range "
            + "could not be read.\n"
            + plainAnswerRules,
        userPrompt: "Answer the question from these gathered notes.",
        citesSources: true
    )

    public static let builtIn: [AiPromptTemplate] = [
        dailySummary,
        extendedSummary,
        meetingNotes,
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
