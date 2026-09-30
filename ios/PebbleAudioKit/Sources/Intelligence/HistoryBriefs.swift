import AppDB
import Foundation

// The words History's week and month pages are made of (plan 7.4): a day's headline and line,
// and a week's or a month's brief. Prompts, the input each is written from, and — the part that
// matters most — what an answer has to look like before it is allowed on screen.
//
// WHY THIS EXISTS (Roger, 2026-09-30, with phone screenshots): "These daily summaries in the week
// view don't have good titles. The titles are clearly part of a much longer summary, but they
// should just be a phrase or something short. And the month view doesn't seem to have any good
// summaries/titles at all." The week rows were headed by each recap's first sentence cut at
// sixty characters ("The day began with a long planning…"), the grey line under it was the rest
// of the recap starting mid-thought ("Later, you worked with friends…"), and the month rows had
// no headline at all. Nothing short had ever been WRITTEN about a day; the screen was cutting
// something long.
//
// So a second pass writes the short things on purpose, and this file refuses the answers that
// would put the same failures back on screen: a headline that is really a sentence ("The day
// focused heavily on development…"), a line that leans on a previous one ("Later, …"), the
// recap's third person ("The speaker also walked around Denver"). A refused field is left
// empty, never shortened into shape — the page's fallbacks are honest; a cut sentence is not.
//
// Every input here is the app's own finished prose, never a transcript, so none of the
// transcript rules the shared catalog opens with apply (see `RecapCondenser.prompt`).

public enum HistoryBriefText {

    // MARK: - Limits

    /// A headline's hard cap in characters. The row is one line of 16 pt semibold beside a
    /// 34 pt date column; on a 390 pt phone about 32–36 characters fit before the tail is
    /// clipped, so the prompt asks for 36 and anything past this is not a phrase.
    public static let headlineMaxCharacters = 42
    /// "2 to 6 words" is what the prompt asks for. One more is let through — a seven-word noun
    /// phrase under the character cap is still a phrase, and refusing it leaves the day with no
    /// headline until its recap is regenerated.
    public static let headlineMaxWords = 7
    public static let headlineMinWords = 2
    /// A line's hard cap. The row clamps it to two lines of 13 pt (about 90 characters a line);
    /// the prompt asks for 130.
    public static let lineSummaryMaxCharacters = 150
    /// The in-brief card's paragraph: 3–4 sentences, asked for at 480.
    public static let briefTextMaxCharacters = 700

    // MARK: - Voice rules

    /// Openings no headline may have: each is the start of a sentence about the day, or the
    /// recap's view of the wearer from outside, never a name for what the day was.
    static let bannedHeadlineOpenings = [
        "the day", "this day", "a day", "day of", "today", "you", "the speaker", "the user",
        "the wearer", "the person", "i", "in the", "on this day", "we", "they", "he", "she",
        // A period's headline, likewise.
        "the week", "this week", "a week", "week of", "the month", "this month", "a month",
        "month of",
    ]

    /// Openings no line or brief may have: they only make sense after something else was said
    /// ("Later, you worked with friends…" under a headline that was the recap's first sentence).
    static let bannedLineOpenings = [
        "later", "also", "then", "additionally", "meanwhile", "afterwards", "afterward",
        "furthermore", "moreover", "in addition", "the speaker", "the user", "the wearer",
        "the day", "today",
    ]

    /// Anywhere in anything: the recaps' outside view of the person the app belongs to.
    static let bannedPhrases = ["the speaker", "the user", "the wearer"]

    /// Words a Title Case answer capitalises that sentence case never does mid-phrase. Proper
    /// names are left alone — "Unit 4", "Fernwood", "Denver" — so only these are lowered.
    static let minorWords: Set<String> = [
        "a", "an", "and", "as", "at", "by", "for", "from", "in", "into", "of", "on", "or", "over",
        "the", "to", "with",
    ]

    // MARK: - Validation

    /// The headline to store, or nil when the answer is not a short phrase naming a subject.
    public static func headline(_ raw: String?) -> String? {
        guard var text = cleaned(raw) else { return nil }
        // Never a sentence: a full stop inside it means there were two.
        if text.contains(". ") { return nil }
        while let last = text.last, ".,;:!…".contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= headlineMaxCharacters else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard (headlineMinWords...headlineMaxWords).contains(words.count) else { return nil }
        guard !opens(text, withAnyOf: bannedHeadlineOpenings), !containsBannedPhrase(text) else {
            return nil
        }
        // Sentence case for the words a Title Case answer gets wrong; the rest as written.
        let lowered = words.enumerated().map { index, word -> String in
            let string = String(word)
            guard index > 0, minorWords.contains(string.lowercased()), string != string.uppercased()
            else { return string }
            return string.lowercased()
        }
        return capitalizedFirst(lowered.joined(separator: " "))
    }

    /// The line to store under a headline, or nil when it does not stand on its own.
    public static func lineSummary(_ raw: String?) -> String? {
        guard let text = cleaned(raw), text.count <= lineSummaryMaxCharacters else { return nil }
        guard !opens(text, withAnyOf: bannedLineOpenings), !containsBannedPhrase(text) else {
            return nil
        }
        return terminated(capitalizedFirst(text))
    }

    /// A week's or month's paragraph for the in-brief card, or nil.
    public static func briefText(_ raw: String?) -> String? {
        guard let text = cleaned(raw), text.count <= briefTextMaxCharacters else { return nil }
        guard !opens(text, withAnyOf: bannedLineOpenings), !containsBannedPhrase(text) else {
            return nil
        }
        return terminated(capitalizedFirst(text))
    }

    /// Whitespace collapsed, wrapping quotes and emphasis marks removed. Nil when nothing is
    /// left.
    static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "«", "»", "`", "*", "_"]
        while let first = text.first, wrappers.contains(first) { text.removeFirst() }
        while let last = text.last, wrappers.contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    static func opens(_ text: String, withAnyOf openings: [String]) -> Bool {
        let lower = text.lowercased()
        return openings.contains { opening in
            guard lower.hasPrefix(opening) else { return false }
            // A whole word or phrase: "Youth football" does not open with "you", "Daydreams"
            // not with "day".
            let after = lower.dropFirst(opening.count).first
            return after == nil || !(after!.isLetter || after!.isNumber)
        }
    }

    static func containsBannedPhrase(_ text: String) -> Bool {
        let lower = text.lowercased()
        return bannedPhrases.contains { lower.contains($0) }
    }

    /// The first letter capitalised — unless the word is written that way on purpose ("iPhone",
    /// "eBay": a capital right after it).
    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        if let second = text.dropFirst().first, second.isUppercase { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// A line ends as a sentence does.
    static func terminated(_ text: String) -> String {
        guard let last = text.last, !".!?…".contains(last) else { return text }
        return text + "."
    }

    // MARK: - Parsing

    /// The fields of a reply, leniently: the first JSON object in the text (a model that wraps
    /// it in a code fence or a sentence still counts), unknown keys ignored. Nil when there is no
    /// object at all.
    static func fields(_ reply: String) -> [String: String]? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"),
            open < close,
            let object = try? JSONSerialization.jsonObject(with: Data(reply[open...close].utf8))
                as? [String: Any]
        else { return nil }
        return object.compactMapValues { $0 as? String }
    }
}

// MARK: - A day

/// A day's headline and line, written from its recap.
public enum DayBrief {
    public static let templateId = "day-brief"

    /// What the answer came to. Either field may be nil on its own; both nil is a completed
    /// attempt that produced nothing usable.
    public struct Answer: Equatable, Sendable {
        public var headline: String?
        public var lineSummary: String?

        public init(headline: String?, lineSummary: String?) {
            self.headline = headline
            self.lineSummary = lineSummary
        }

        public var isEmpty: Bool { headline == nil && lineSummary == nil }
    }

    public static let prompt = AiPromptTemplate(
        id: templateId,
        title: "Day headline",
        systemPrompt: """
            You label one day in a person's history, from a recap of that day their own device \
            already wrote. The recap is finished prose and every fact in it is established: \
            never add, infer or re-interpret anything. The label sits on a list of days, and the \
            person must recognise the day from it at a glance.

            Write two things.
            headline: a short noun phrase naming what the day was mostly about. 2 to 6 words and \
            at most 36 characters. Sentence case: capitalise the first word and proper names \
            only. It is not a sentence: no full stop, and it never starts with "The day", "The \
            speaker", "The user", "Today", "You" or "A day". Name the one or two things that \
            most set this day apart; join two with "and"; never list three. Good headlines: \
            "Office in Unit 4 and Fernwood", "Ad audits and a Denver walk", "Deploying \
            the website changes", "Road trip to Denver".
            lineSummary: one or two short sentences, at most 130 characters in all, that stand \
            on their own and add to the headline rather than repeat it. Leave the subject out \
            where you can ("Signed a new office lease in Unit 4; weighed short terms.") and \
            say "you" where one is needed. The recap may call the person "the speaker", "the \
            user" or by a name: never do any of those. Never start with "Later", "Also" or \
            "Then".

            No Markdown. Reply with JSON only: {"headline":"...","lineSummary":"..."}
            """,
        userPrompt: "Label this day.")

    /// The text a day's brief is written from: the condensed recap when there is a current one,
    /// else the recap itself. Nil when there is nothing to read.
    public static func input(_ recap: DailyRecap) -> String? {
        let text = (RecapCondenser.condensation(of: recap) ?? recap.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// True when this recap still owes a brief pass for its CURRENT text.
    public static func needsPass(_ recap: DailyRecap) -> Bool {
        guard input(recap) != nil else { return false }
        return recap.briefOfHash != RecapCondenser.fingerprint(recap.text)
    }

    /// The headline and line to SHOW for this recap: nil fields when the pass has not run for
    /// its current text (a headline written about superseded text is never shown).
    public static func current(_ recap: DailyRecap) -> Answer {
        guard recap.briefOfHash == RecapCondenser.fingerprint(recap.text) else {
            return Answer(headline: nil, lineSummary: nil)
        }
        return Answer(headline: recap.headline, lineSummary: recap.lineSummary)
    }

    public static func parse(_ reply: String) -> Answer {
        let fields = HistoryBriefText.fields(reply) ?? [:]
        return Answer(
            headline: HistoryBriefText.headline(fields["headline"]),
            lineSummary: HistoryBriefText.lineSummary(fields["lineSummary"]))
    }
}

// MARK: - A week or a month

/// A week's or a month's brief: the in-brief card's paragraph, and a headline and line for the
/// month's week rows (a month's are not shown on a row today, but cost nothing to ask for and
/// keep the two shapes one).
public enum PeriodBriefWriter {
    public static let weekTemplateId = "week-brief"
    public static let monthTemplateId = "month-brief"

    /// Characters of input one brief is written from. Plan 7.4: "about 4,500 characters, which
    /// fits even the on-device model" — the iOS 26 window leaves roughly 8,000 characters for
    /// input once this prompt, a full About You block and the answer are paid for.
    public static let maxInputCharacters = 4_500

    public struct Answer: Equatable, Sendable {
        public var text: String?
        public var headline: String?
        public var lineSummary: String?

        public init(text: String?, headline: String?, lineSummary: String?) {
            self.text = text
            self.headline = headline
            self.lineSummary = lineSummary
        }

        public var isEmpty: Bool { text == nil && headline == nil && lineSummary == nil }
    }

    /// One day of a week, as the week brief reads it.
    public struct DayEntry: Equatable, Sendable {
        public var dateKey: String
        public var headline: String?
        public var lineSummary: String?
        /// The condensed recap, else the recap.
        public var recap: String

        public init(dateKey: String, headline: String?, lineSummary: String?, recap: String) {
            self.dateKey = dateKey
            self.headline = headline
            self.lineSummary = lineSummary
            self.recap = recap
        }
    }

    /// One week of a month, as the month brief reads it.
    public struct WeekEntry: Equatable, Sendable {
        public var firstDateKey: String
        public var lastDateKey: String
        public var headline: String?
        public var lineSummary: String?
        public var text: String?

        public init(
            firstDateKey: String, lastDateKey: String, headline: String?, lineSummary: String?,
            text: String?
        ) {
            self.firstDateKey = firstDateKey
            self.lastDateKey = lastDateKey
            self.headline = headline
            self.lineSummary = lineSummary
            self.text = text
        }
    }

    static let answerRules = """
        Write three things.
        text: 3 or 4 sentences, at most 480 characters, for the top of the page: what the \
        period was mostly about, what was decided or changed, and anything that ran through it, \
        in the order it happened where the order matters.
        headline: a short noun phrase naming the period's one or two main threads. 2 to 6 words \
        and at most 36 characters, sentence case (capitalise the first word and proper names \
        only), no full stop, never a sentence, never starting with "The", "This", "Today" or \
        "You". Join two threads with "and"; never list three.
        lineSummary: one or two short sentences, at most 130 characters in all, that stand on \
        their own and add to the headline rather than repeat it.

        Voice for all three: plain and direct. Leave the subject out where you can and say \
        "you" where one is needed. The input may call the person "the speaker", "the user" or \
        by a name: never do any of those. Never start with "Later", "Also" or "Then". No \
        Markdown. Reply with JSON only: {"text":"...","headline":"...","lineSummary":"..."}
        """

    public static let weekPrompt = AiPromptTemplate(
        id: weekTemplateId,
        title: "Week in brief",
        systemPrompt: """
            You summarise one week of a person's history from what their own device already \
            wrote about each day of it: a headline, a line and a recap per day, in order. It is \
            finished prose and every fact in it is established: never add, infer or \
            re-interpret anything, and never mention a day that is not listed. The person reads \
            this to recognise the week and remember what mattered in it.

            \(answerRules)
            """,
        userPrompt: "Summarise this week.")

    public static let monthPrompt = AiPromptTemplate(
        id: monthTemplateId,
        title: "Month in brief",
        systemPrompt: """
            You summarise one month of a person's history from what their own device already \
            wrote about each week of it: a headline, a line and a short summary per week, in \
            order. A week at either end may run into the next or previous month. It is finished \
            prose and every fact in it is established: never add, infer or re-interpret \
            anything. The person reads this to recognise the month and remember what mattered \
            in it.

            \(answerRules)
            """,
        userPrompt: "Summarise this month.")

    public static func parse(_ reply: String) -> Answer {
        let fields = HistoryBriefText.fields(reply) ?? [:]
        return Answer(
            text: HistoryBriefText.briefText(fields["text"]),
            headline: HistoryBriefText.headline(fields["headline"]),
            lineSummary: HistoryBriefText.lineSummary(fields["lineSummary"]))
    }

    // MARK: - Input

    /// A week's input: each day's date, headline, line and recap, oldest first, the recaps
    /// shortened (at a sentence where one ends in reach) so the whole fits
    /// `maxInputCharacters`. The headlines and lines are never cut: they are the substance.
    public static func weekInput(_ days: [DayEntry]) -> String {
        let blocks = days.map { day -> (fixed: String, body: String) in
            var fixed = dayLabel(day.dateKey)
            if let headline = day.headline { fixed += "\nHeadline: \(headline)" }
            if let line = day.lineSummary { fixed += "\nIn one line: \(line)" }
            return (fixed, day.recap)
        }
        return fitted(blocks, bodyLabel: "Recap")
    }

    /// A month's input: each week's dates, headline, line and summary, oldest first.
    public static func monthInput(_ weeks: [WeekEntry]) -> String {
        let blocks = weeks.map { week -> (fixed: String, body: String) in
            var fixed = "Week of \(dayLabel(week.firstDateKey)) to \(dayLabel(week.lastDateKey))"
            if let headline = week.headline { fixed += "\nHeadline: \(headline)" }
            if let line = week.lineSummary { fixed += "\nIn one line: \(line)" }
            return (fixed, week.text ?? "")
        }
        return fitted(blocks, bodyLabel: "Summary")
    }

    /// The blocks joined, each body cut to an equal share of what the fixed parts leave.
    static func fitted(_ blocks: [(fixed: String, body: String)], bodyLabel: String) -> String {
        let separator = "\n\n"
        let label = "\n\(bodyLabel): "
        let fixedTotal = blocks.reduce(0) { $0 + $1.fixed.count }
            + max(0, blocks.count - 1) * separator.count
        let withBody = blocks.filter { !$0.body.isEmpty }
        let room = max(0, maxInputCharacters - fixedTotal - withBody.count * label.count)
        // Short bodies give their unused share to the long ones.
        var share = withBody.isEmpty ? 0 : room / withBody.count
        let short = withBody.filter { $0.body.count <= share }
        let long = withBody.count - short.count
        if long > 0 {
            share = (room - short.reduce(0) { $0 + $1.body.count }) / long
        }
        return blocks.map { block in
            guard !block.body.isEmpty else { return block.fixed }
            return block.fixed + label + shortened(block.body, to: max(0, share))
        }.joined(separator: separator)
    }

    /// At most `limit` characters: the text whole, else up to its last sentence end within the
    /// limit (when that keeps at least half), else a word-boundary cut with an ellipsis.
    static func shortened(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        guard limit > 1 else { return "" }
        let prefix = String(trimmed.prefix(limit))
        if let end = prefix.lastIndex(where: { ".!?".contains($0) }),
            prefix.distance(from: prefix.startIndex, to: end) >= limit / 2
        {
            return String(prefix[...end])
        }
        let cut = prefix.dropLast().lastIndex(where: \.isWhitespace) ?? prefix.index(before: prefix.endIndex)
        return prefix[..<cut].trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "Sunday 27 September 2026" — the weekday helps the model place a day; the year keeps two
    /// Septembers apart. Fixed English and Gregorian: this is prompt text, not a label on screen.
    static func dayLabel(_ dateKey: String) -> String {
        let parts = dateKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return dateKey }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard
            let date = calendar.date(
                from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return dateKey }
        let weekday = weekdays[calendar.component(.weekday, from: date) - 1]
        return "\(weekday) \(parts[2]) \(months[parts[1] - 1]) \(parts[0])"
    }

    private static let weekdays = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]
    private static let months = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September",
        "October", "November", "December",
    ]
}
