import Foundation

// Weeks and months (plan 5.4, 5.5, 7.10 "Weeks and months"), assembled from per-day FACTS.
//
// The finished design reads its headlines, summaries and tags from the chapter and brief stages
// (`day_chapters`, `chapter_tags`, `period_briefs`). Neither stage exists yet, so every piece of
// text on a week or month row comes from an INTERIM source that uses only what is already true
// of the day: its conversations' titles and tags, and its recap. All of it is behind one
// protocol, `HistoryPeriodSources`; when the stages land, a second conformer replaces
// `InterimHistoryPeriodSources` in one place (the caller's `sources:` argument) and nothing else
// here changes. The facts themselves — which days were recorded, what is waiting, which
// follow-ups were said when — are not interim and are not behind the protocol.
//
// Pure: no database, file or clock. `HistoryReader` (CompanionRuntime) gathers the facts.

/// What one logical day contributes to a week or month.
public struct HistoryDayFacts: Equatable, Sendable {
    public var dateKey: String
    public var isToday: Bool
    /// Today, and a conversation is being recorded right now.
    public var isLive: Bool
    /// Recordings with audio inside the day.
    public var recordings: Int
    /// Of those, the ones with a finished transcript (words or settled no-speech).
    public var transcribedRecordings: Int
    /// Recorded time inside the day whose recording is still waiting for its transcript.
    public var waitingMs: Int64
    /// Conversations overlapping the day (never one hidden by a pending delete).
    public var conversations: [HistoryConversationFact]
    /// The day's recap, reduced to the text a row may show. Nil when there is none.
    public var recap: HistoryRecapFact?
    /// Every follow-up placed on this day (open, snoozed and done; never archived), any order.
    public var followUps: [HistoryPlacedFollowUp]

    public init(
        dateKey: String, isToday: Bool = false, isLive: Bool = false, recordings: Int = 0,
        transcribedRecordings: Int = 0, waitingMs: Int64 = 0,
        conversations: [HistoryConversationFact] = [], recap: HistoryRecapFact? = nil,
        followUps: [HistoryPlacedFollowUp] = []
    ) {
        self.dateKey = dateKey
        self.isToday = isToday
        self.isLive = isLive
        self.recordings = recordings
        self.transcribedRecordings = transcribedRecordings
        self.waitingMs = waitingMs
        self.conversations = conversations
        self.recap = recap
        self.followUps = followUps
    }

    /// The roll-up the week row draws (plan 5.4): today is always today; a day with no audio
    /// is "Nothing recorded"; a day whose audio has no transcript at all yet, with some of it
    /// still waiting, is "Not transcribed yet"; everything else is recorded. A day whose every
    /// recording FAILED is recorded, not waiting — nothing is on its way.
    public var state: HistoryDayState {
        if isToday { return .today(isLive: isLive) }
        if recordings == 0 { return .nothingRecorded }
        if transcribedRecordings == 0, waitingMs > 0 { return .notTranscribedYet(waitingMs: waitingMs) }
        return .recorded
    }
}

/// A conversation as far as one day is concerned.
public struct HistoryConversationFact: Equatable, Sendable {
    public var id: String
    public var title: String?
    /// Its tags (user-removed ones already left out), any order.
    public var tags: [String]
    /// The conversation's extent inside the day.
    public var overlapMs: Int64
    /// Recorded time inside the day of its members that have a finished transcript with words.
    public var transcribedMs: Int64
    /// The whole conversation's length, start to end, whatever day it runs into. A title that
    /// describes hours of the day describes a blob, not a conversation.
    public var durationMs: Int64

    public init(
        id: String, title: String?, tags: [String] = [], overlapMs: Int64, transcribedMs: Int64,
        durationMs: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.tags = tags
        self.overlapMs = overlapMs
        self.transcribedMs = transcribedMs
        self.durationMs = durationMs ?? overlapMs
    }
}

/// The part of a day recap a row shows.
public struct HistoryRecapFact: Equatable, Sendable {
    /// The condensed form when there is a current one, else the digest.
    public var summary: String
    public var updatedAtMs: Int64

    public init(summary: String, updatedAtMs: Int64) {
        self.summary = summary
        self.updatedAtMs = updatedAtMs
    }
}

/// A follow-up with the moment History places it at (`FollowUpPlacement`: the moment it was
/// said, else its recording's start, else the day its id or creation names).
public struct HistoryPlacedFollowUp: Equatable, Sendable {
    public var line: HistoryFollowUpLine
    public var atMs: Int64

    public init(line: HistoryFollowUpLine, atMs: Int64) {
        self.line = line
        self.atMs = atMs
    }

    /// Plan 5.6: open ones first (snoozed counts as open), then done ones, each in the order
    /// they came up; ties by id so the order is stable.
    public static func displayOrder(_ a: HistoryPlacedFollowUp, _ b: HistoryPlacedFollowUp) -> Bool {
        if a.line.done != b.line.done { return !a.line.done }
        if a.atMs != b.atMs { return a.atMs < b.atMs }
        return a.line.id < b.line.id
    }
}

// MARK: - The replaceable text

/// Where a week or month row's words come from. `InterimHistoryPeriodSources` is the only
/// conformer until the chapter and brief stages exist; see the file header.
public protocol HistoryPeriodSources: Sendable {
    /// A day on the week page.
    func dayHeadline(_ day: HistoryDayFacts) -> String?
    func daySummary(_ day: HistoryDayFacts) -> String?
    /// Every tag of the day, most prominent first. The row shows the first three; the month's
    /// tag counts use all of them.
    func dayTags(_ day: HistoryDayFacts) -> [String]
    /// A week on the month page.
    func weekHeadline(_ days: [HistoryDayFacts]) -> String?
    func weekSummary(_ days: [HistoryDayFacts]) -> String?
    func weekTags(_ days: [HistoryDayFacts]) -> [String]
    /// The in-brief card of a week page and of a month page.
    func weekBrief(_ days: [HistoryDayFacts]) -> HistoryBrief?
    func monthBrief(_ days: [HistoryDayFacts]) -> HistoryBrief?
}

/// INTERIM (until the chapter and brief stages exist): only facts the app already has.
///
/// - Day headline: the title of the conversation with the most transcribed time inside the day —
///   unless that conversation runs longer than `longTitleMs` (its title describes a blob of the
///   day, not a conversation) or has no title, and the day has a recap: then the recap's first
///   sentence, cut to about `headlineCharacters` at a word boundary. Without a recap, the title
///   whatever its length.
/// - Day summary: the day's recap (without that first sentence when it became the headline and
///   more follows).
/// - Tags: conversation tags, ranked by the overlapping duration of the conversations carrying them.
/// - Week headline: none. Week summary: the distinct headlines of the week's days, the days with
///   the most transcribed talk first, joined — a list of facts, not a generated sentence.
/// - Week and month briefs: none (no such summaries exist).
public struct InterimHistoryPeriodSources: HistoryPeriodSources {
    /// How many titles a week's summary lists.
    public static let weekSummaryTitles = 3
    public static let separator = " · "
    /// A conversation longer than this does not name the day when a recap can.
    public static let longTitleMs: Int64 = 2 * 3_600_000
    /// About how long a headline taken from a recap may be.
    public static let headlineCharacters = 60

    public init() {}

    // INTERIM: replaced by the day's first chapter headline / the day brief's headline.
    public func dayHeadline(_ day: HistoryDayFacts) -> String? {
        headline(day).text
    }

    // INTERIM: replaced by the day brief's line summary.
    public func daySummary(_ day: HistoryDayFacts) -> String? {
        guard let recap = day.recap.flatMap({ Self.nonEmpty($0.summary) }) else { return nil }
        if headline(day).fromRecap, let rest = Self.nonEmpty(Self.firstSentence(of: recap).rest) { return rest }
        return recap
    }

    /// The day's headline and whether it came from the recap.
    func headline(_ day: HistoryDayFacts) -> (text: String?, fromRecap: Bool) {
        let longest = day.conversations
            .filter { $0.transcribedMs > 0 }
            .min { $0.transcribedMs != $1.transcribedMs ? $0.transcribedMs > $1.transcribedMs : $0.id < $1.id }
        guard let longest else { return (nil, false) }
        let title = Self.nonEmpty(longest.title)
        if let title, longest.durationMs <= Self.longTitleMs { return (title, false) }
        if let recap = day.recap.flatMap({ Self.nonEmpty($0.summary) }),
            let sentence = Self.nonEmpty(Self.firstSentence(of: recap).sentence)
        {
            return (Self.cut(sentence, to: Self.headlineCharacters), true)
        }
        // No recap: the title, however long its conversation; an untitled one says nothing.
        return (title, false)
    }

    // INTERIM: replaced by chapter tags.
    public func dayTags(_ day: HistoryDayFacts) -> [String] {
        Self.rankedTags([day.conversations])
    }

    // INTERIM: replaced by the week brief's headline.
    public func weekHeadline(_ days: [HistoryDayFacts]) -> String? { nil }

    // INTERIM: replaced by the week brief's line summary.
    public func weekSummary(_ days: [HistoryDayFacts]) -> String? {
        func talk(_ day: HistoryDayFacts) -> Int64 {
            day.conversations.reduce(Int64(0)) { $0 + $1.transcribedMs }
        }
        let ranked: [HistoryDayFacts] = days.filter { talk($0) > 0 }.sorted { a, b in
            let (ta, tb) = (talk(a), talk(b))
            return ta != tb ? ta > tb : a.dateKey < b.dateKey
        }
        var titles: [String] = []
        var seen: Set<String> = []
        for day in ranked {
            guard let title = dayHeadline(day) else { continue }
            let key = title.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            titles.append(title)
            if titles.count == Self.weekSummaryTitles { break }
        }
        return titles.isEmpty ? nil : titles.joined(separator: Self.separator)
    }

    // INTERIM: replaced by chapter tags over the week.
    public func weekTags(_ days: [HistoryDayFacts]) -> [String] {
        Self.rankedTags(days.map(\.conversations))
    }

    // INTERIM: no week brief exists until the brief stage.
    public func weekBrief(_ days: [HistoryDayFacts]) -> HistoryBrief? { nil }

    // INTERIM: no month brief exists until the brief stage.
    public func monthBrief(_ days: [HistoryDayFacts]) -> HistoryBrief? { nil }

    // --- helpers ------------------------------------------------------------------------------

    /// The first sentence of a recap and what follows it. A recap may be bullet lines; a leading
    /// bullet mark is not part of the sentence.
    static func firstSentence(of text: String) -> (sentence: String, rest: String) {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = body.first, "-•*".contains(first) {
            body = body.dropFirst().drop(while: { $0 == " " })
        }
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            let next = body.index(after: index)
            if character == "\n" { return (String(body[..<index]), String(body[next...])) }
            if ".!?".contains(character), next == body.endIndex || body[next].isWhitespace {
                return (String(body[...index]), String(body[next...]))
            }
            index = next
        }
        return (String(body), "")
    }

    /// At most about `limit` characters, cut at a word boundary with an ellipsis; a sentence
    /// that fits keeps its end but not its full stop.
    static func cut(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else {
            return trimmed.last == "." ? String(trimmed.dropLast()) : trimmed
        }
        let prefix = trimmed.prefix(limit + 1)
        let cutAt = prefix.lastIndex(where: \.isWhitespace) ?? trimmed.index(trimmed.startIndex, offsetBy: limit)
        let kept = trimmed[..<cutAt].trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        return kept + "…"
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// One entry per conversation across days: a conversation that runs past 5 AM is in two
    /// days' facts, and its time adds up.
    static func mergedConversations(_ groups: [[HistoryConversationFact]]) -> [HistoryConversationFact] {
        var order: [String] = []
        var byId: [String: HistoryConversationFact] = [:]
        for conversation in groups.joined() {
            if var existing = byId[conversation.id] {
                existing.overlapMs += conversation.overlapMs
                existing.transcribedMs += conversation.transcribedMs
                existing.durationMs = max(existing.durationMs, conversation.durationMs)
                if existing.title == nil { existing.title = conversation.title }
                existing.tags = Array(Set(existing.tags).union(conversation.tags))
                byId[conversation.id] = existing
            } else {
                order.append(conversation.id)
                byId[conversation.id] = conversation
            }
        }
        return order.compactMap { byId[$0] }
    }

    /// Tags ranked by the summed overlapping duration of the conversations carrying them. Ties
    /// by name, case-insensitively; the first spelling seen is kept.
    static func rankedTags(_ groups: [[HistoryConversationFact]]) -> [String] {
        var weight: [String: Int64] = [:]
        var spelling: [String: String] = [:]
        var counted: Set<String> = []
        for conversation in mergedConversations(groups) {
            for tag in Set(conversation.tags.compactMap(nonEmpty)) {
                let key = tag.lowercased()
                if spelling[key] == nil { spelling[key] = tag }
                // A conversation that carries a tag twice (two spellings) counts once.
                let pair = "\(conversation.id)\u{1}\(key)"
                guard !counted.contains(pair) else { continue }
                counted.insert(pair)
                weight[key, default: 0] += conversation.overlapMs
            }
        }
        return weight.keys.sorted {
            weight[$0]! != weight[$1]! ? weight[$0]! > weight[$1]! : $0 < $1
        }.map { spelling[$0]! }
    }
}

// MARK: - Assembly

public enum HistoryPeriodAssembler {
    /// Tags a row shows.
    public static let rowTags = 3
    /// Follow-up lines a week row shows.
    public static let weekRowFollowUps = 2

    /// The week `firstDateKey...lastDateKey` (whole, as `HistoryCalendar.week` makes it). Days
    /// after `todayKey` are not listed (plan 5.4); a day with no facts is "Nothing recorded".
    public static func week(
        firstDateKey: String, lastDateKey: String, days: [String: HistoryDayFacts], todayKey: String,
        sources: some HistoryPeriodSources = InterimHistoryPeriodSources()
    ) -> HistoryPeriod<HistoryWeekRow> {
        let listed = HistoryCalendar.days(in: firstDateKey...lastDateKey).filter { $0 <= todayKey }
        let facts = listed.map { days[$0] ?? HistoryDayFacts(dateKey: $0, isToday: $0 == todayKey) }
        let rows = facts.map { weekRow($0, sources: sources) }
        let followUps = facts.flatMap(\.followUps)
        return HistoryPeriod(
            firstDateKey: firstDateKey, lastDateKey: lastDateKey, brief: sources.weekBrief(facts),
            tagCounts: [], rows: rows, followUpTotal: followUps.count,
            followUpOpen: followUps.filter { !$0.line.done }.count)
    }

    public static func weekRow(_ day: HistoryDayFacts, sources: some HistoryPeriodSources) -> HistoryWeekRow {
        let ordered = day.followUps.sorted(by: HistoryPlacedFollowUp.displayOrder)
        let shown = Array(ordered.prefix(weekRowFollowUps))
        let state = day.state
        // A day with nothing to read has nothing to headline: its state says what it is.
        let hasText: Bool
        switch state {
        case .nothingRecorded, .notTranscribedYet: hasText = false
        case .recorded, .today: hasText = true
        }
        return HistoryWeekRow(
            dateKey: day.dateKey, state: state,
            headline: hasText ? sources.dayHeadline(day) : nil,
            summary: hasText ? sources.daySummary(day) : nil,
            tags: hasText ? Array(sources.dayTags(day).prefix(rowTags)) : [],
            followUps: shown.map(\.line), moreFollowUps: ordered.count - shown.count)
    }

    /// The calendar month containing `dateKey`: one row per week overlapping it
    /// (`HistoryCalendar.weeks(inMonthOf:)`, a straddling week whole), weeks that start after
    /// `todayKey` left out. The month's own totals and tag counts cover only its own days.
    public static func month(
        containing dateKey: String, firstWeekday: Int, days: [String: HistoryDayFacts], todayKey: String,
        sources: some HistoryPeriodSources = InterimHistoryPeriodSources()
    ) -> HistoryPeriod<HistoryMonthRow> {
        let range = HistoryCalendar.month(containing: dateKey)
        func facts(_ keys: [String]) -> [HistoryDayFacts] {
            keys.filter { $0 <= todayKey }.map { days[$0] ?? HistoryDayFacts(dateKey: $0, isToday: $0 == todayKey) }
        }
        var rows: [HistoryMonthRow] = []
        for week in HistoryCalendar.weeks(inMonthOf: dateKey, firstWeekday: firstWeekday)
        where week.lowerBound <= todayKey {
            let weekDays = facts(HistoryCalendar.days(in: week))
            let followUps = weekDays.flatMap(\.followUps)
            rows.append(
                HistoryMonthRow(
                    firstDateKey: week.lowerBound, lastDateKey: week.upperBound,
                    isCurrentWeek: week.contains(todayKey),
                    hasRecordings: weekDays.contains { $0.recordings > 0 },
                    headline: sources.weekHeadline(weekDays), summary: sources.weekSummary(weekDays),
                    tags: Array(sources.weekTags(weekDays).prefix(rowTags)),
                    followUpTotal: followUps.count, followUpOpen: followUps.filter { !$0.line.done }.count))
        }
        let monthDays = facts(HistoryCalendar.days(in: range))
        let followUps = monthDays.flatMap(\.followUps)
        return HistoryPeriod(
            firstDateKey: range.lowerBound, lastDateKey: range.upperBound, brief: sources.monthBrief(monthDays),
            tagCounts: tagCounts(monthDays, sources: sources), rows: rows, followUpTotal: followUps.count,
            followUpOpen: followUps.filter { !$0.line.done }.count)
    }

    /// Each tag with the number of days it appears on (plan 5.2), most days first, ties by name.
    public static func tagCounts(_ days: [HistoryDayFacts], sources: some HistoryPeriodSources) -> [HistoryTagCount] {
        var count: [String: Int] = [:]
        var spelling: [String: String] = [:]
        for day in days {
            for tag in Set(sources.dayTags(day)) {
                let key = tag.lowercased()
                if spelling[key] == nil { spelling[key] = tag }
                count[key, default: 0] += 1
            }
        }
        return count.keys
            .sorted { count[$0]! != count[$1]! ? count[$0]! > count[$1]! : $0 < $1 }
            .map { HistoryTagCount(name: spelling[$0]!, days: count[$0]!) }
    }
}

// MARK: - Bounds

extension HistoryBounds {
    /// The day keys of every recording's start (plan 7.10), in the zone the timeline gives it.
    public static func of(startsMs: [Int64], timeline: ZoneTimeline, todayDateKey: String) -> HistoryBounds {
        let days = Set(startsMs.map { timeline.dayKey(forMs: $0) })
        return HistoryBounds(firstDateKey: days.min(), todayDateKey: todayDateKey, recordedDays: days)
    }
}

/// What invalidates cached bounds (plan 7.10): the number of recordings, and the first and last
/// start. Anything else — a transcript landing, a regroup — leaves the recorded days as they were.
public struct HistoryBoundsKey: Equatable, Sendable {
    public var count: Int
    public var firstStartMs: Int64?
    public var lastStartMs: Int64?

    public init(startsMs: [Int64]) {
        count = startsMs.count
        firstStartMs = startsMs.min()
        lastStartMs = startsMs.max()
    }
}
