import Foundation

// Weeks and months (plan 5.4, 5.5, 7.10 "Weeks and months"), assembled from per-day FACTS and
// the briefs written about them.
//
// Every piece of text on a week or month row is a thing WRITTEN to be that short (plan 7.4): a
// day's headline and line (`recaps.headline` / `lineSummary`), a week's and a month's brief
// (`period_briefs`). Until one exists — the brief stage has not reached that day yet, AI is off,
// the answer was refused — the row falls back to other short things that are already true of the
// day: the title of its most-talked conversation, the recap whole (the view clamps it to two
// lines). Never to a cut: the first version headed each day with its recap's first sentence cut
// at sixty characters ("The day began with a long planning…") and put the rest of the recap
// under it ("Later, you worked with friends…"), and that is the screen Roger reported. The facts
// themselves — which days were recorded, what is waiting, which follow-ups were said when — are
// not text and are not affected by any of this.
//
// Pure: no database, file or clock. `HistoryReader` (CompanionRuntime) gathers the facts and
// the briefs.

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
    /// Stored audio inside the day whose recording is still waiting for its transcript (media
    /// time, not the wall span its recordings cover).
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
    /// The whole conversation's length, start to end, whatever day it runs into.
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
    /// The day's brief (`DayBrief`), only while it was written about the recap's CURRENT text.
    public var headline: String?
    public var lineSummary: String?

    public init(summary: String, updatedAtMs: Int64, headline: String? = nil, lineSummary: String? = nil) {
        self.summary = summary
        self.updatedAtMs = updatedAtMs
        self.headline = headline
        self.lineSummary = lineSummary
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

// MARK: - The words

/// Where a week or month row's words come from: the briefs written about the period, keyed by
/// `PeriodBriefKey`, and the day facts' own briefs, with short fallbacks for what is not written
/// yet (see the file header).
///
/// - Day headline: the day's headline; else the title of the TITLED conversation with the most
///   transcribed time inside the day (a title is already a short phrase); else none.
/// - Day summary: the day's line; else its recap whole — never the recap minus a sentence.
/// - Week headline (the month's row): the week brief's headline; else the headlines of the two
///   days with the most talk, distinct, joined — or only the first, when two would not fit the
///   row's two lines; else the titles of the week's two most-talked titled conversations, the
///   same way; else none (the row then has no title line at all). Week summary: the week
///   brief's line, else none.
/// - The week's and the month's in-brief card: their briefs' paragraphs, else none ("No summary
///   yet").
/// - Tags: conversation tags, ranked by the overlapping duration of the conversations carrying
///   them (cards are conversations; there is no separate chapter layer to tag).
public struct HistoryPeriodSources: Sendable {
    public static let separator = " · "
    /// How many day headlines a week row falls back to.
    public static let weekHeadlineDays = 2
    /// The longest fallback week headline that is two headlines joined: what the month row's
    /// headline holds (two lines of 16 pt semibold, about 36 characters each). Two day headlines
    /// run 25–40 characters apiece, so one line — the brief's own headline is one — would have
    /// meant the first alone nearly always. Past this, the first alone: a second one clipped
    /// mid-word would be the cut this file exists to avoid.
    public static let joinedHeadlineCharacters = 72

    /// Written week and month briefs, by `PeriodBriefKey`.
    public var briefs: [String: HistoryBrief]

    public init(briefs: [String: HistoryBrief] = [:]) {
        self.briefs = briefs
    }

    /// A day on the week page.
    public func dayHeadline(_ day: HistoryDayFacts) -> String? {
        if let headline = Self.nonEmpty(day.recap?.headline) { return headline }
        let titled = day.conversations
            .filter { $0.transcribedMs > 0 && Self.nonEmpty($0.title) != nil }
            .min { $0.transcribedMs != $1.transcribedMs ? $0.transcribedMs > $1.transcribedMs : $0.id < $1.id }
        return Self.nonEmpty(titled?.title)
    }

    public func daySummary(_ day: HistoryDayFacts) -> String? {
        Self.nonEmpty(day.recap?.lineSummary) ?? Self.nonEmpty(day.recap?.summary)
    }

    /// Every tag of the day, most prominent first. The row shows the first three; the month's
    /// tag counts use all of them.
    public func dayTags(_ day: HistoryDayFacts) -> [String] {
        Self.rankedTags([day.conversations])
    }

    /// A week on the month page. `firstDateKey` is the week's first day.
    public func weekHeadline(firstDateKey: String, _ days: [HistoryDayFacts]) -> String? {
        if let headline = Self.nonEmpty(weekBriefRow(firstDateKey)?.headline) { return headline }
        func talk(_ day: HistoryDayFacts) -> Int64 {
            day.conversations.reduce(Int64(0)) { $0 + $1.transcribedMs }
        }
        let ranked = days.filter { talk($0) > 0 }.sorted { a, b in
            let (ta, tb) = (talk(a), talk(b))
            return ta != tb ? ta > tb : a.dateKey < b.dateKey
        }
        if let fromDays = Self.joined(ranked.compactMap(dayHeadline)) { return fromDays }
        // No day has a headline of its own: the week's own most-talked titled conversations.
        // (A day's headline already falls back to its most-talked titled conversation, so this
        // is for talk no single day ranks — a conversation whose words are spread across days,
        // or one not yet counted as transcribed talk on any.) Never a placeholder in its place:
        // "No summary yet" as a title over a row with tags and follow-ups is what Roger reported.
        let titled = Self.mergedConversations(days.map(\.conversations))
            .filter { Self.nonEmpty($0.title) != nil }
            .sorted { a, b in
                if a.transcribedMs != b.transcribedMs { return a.transcribedMs > b.transcribedMs }
                if a.overlapMs != b.overlapMs { return a.overlapMs > b.overlapMs }
                return a.id < b.id
            }
        return Self.joined(titled.compactMap { Self.nonEmpty($0.title) })
    }

    /// The first `weekHeadlineDays` distinct phrases, joined when they fit the row's two lines,
    /// else the first alone. Nil when there are none.
    static func joined(_ phrases: [String]) -> String? {
        var picked: [String] = []
        var seen: Set<String> = []
        for phrase in phrases where seen.insert(phrase.lowercased()).inserted {
            picked.append(phrase)
            if picked.count == weekHeadlineDays { break }
        }
        guard let first = picked.first else { return nil }
        let joined = picked.joined(separator: separator)
        return joined.count <= joinedHeadlineCharacters ? joined : first
    }

    public func weekSummary(firstDateKey: String, _ days: [HistoryDayFacts]) -> String? {
        Self.nonEmpty(weekBriefRow(firstDateKey)?.lineSummary)
    }

    public func weekTags(_ days: [HistoryDayFacts]) -> [String] {
        Self.rankedTags(days.map(\.conversations))
    }

    /// The in-brief card of a week page: its brief, when one was written with a paragraph.
    public func weekBrief(firstDateKey: String) -> HistoryBrief? {
        card(briefs[PeriodBriefKey.week(firstDateKey: firstDateKey)])
    }

    /// The in-brief card of a month page.
    public func monthBrief(containing dateKey: String) -> HistoryBrief? {
        card(briefs[PeriodBriefKey.month(containing: dateKey)])
    }

    private func weekBriefRow(_ firstDateKey: String) -> HistoryBrief? {
        briefs[PeriodBriefKey.week(firstDateKey: firstDateKey)]
    }

    private func card(_ brief: HistoryBrief?) -> HistoryBrief? {
        guard let brief, !brief.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return brief
    }

    // --- helpers ------------------------------------------------------------------------------

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
    /// Tag pills the month's in-brief card carries (plan 5.2: "a row of tag pills"). On the real
    /// backup September carried 94 tags, 70 of them on a single day — a wall of pills, not a row.
    public static let monthTagPills = 8

    /// The week `firstDateKey...lastDateKey` (whole, as `HistoryCalendar.week` makes it). Days
    /// after `todayKey` are not listed (plan 5.4); a day with no facts is "Nothing recorded".
    public static func week(
        firstDateKey: String, lastDateKey: String, days: [String: HistoryDayFacts], todayKey: String,
        sources: HistoryPeriodSources = HistoryPeriodSources()
    ) -> HistoryPeriod<HistoryWeekRow> {
        let listed = HistoryCalendar.days(in: firstDateKey...lastDateKey).filter { $0 <= todayKey }
        let facts = listed.map { days[$0] ?? HistoryDayFacts(dateKey: $0, isToday: $0 == todayKey) }
        let rows = facts.map { weekRow($0, sources: sources) }
        let followUps = facts.flatMap(\.followUps)
        return HistoryPeriod(
            firstDateKey: firstDateKey, lastDateKey: lastDateKey, brief: sources.weekBrief(firstDateKey: firstDateKey),
            tagCounts: [], rows: rows, followUpTotal: followUps.count,
            followUpOpen: followUps.filter { !$0.line.done }.count)
    }

    public static func weekRow(_ day: HistoryDayFacts, sources: HistoryPeriodSources) -> HistoryWeekRow {
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
        sources: HistoryPeriodSources = HistoryPeriodSources()
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
                    headline: sources.weekHeadline(firstDateKey: week.lowerBound, weekDays),
                    summary: sources.weekSummary(firstDateKey: week.lowerBound, weekDays),
                    tags: Array(sources.weekTags(weekDays).prefix(rowTags)),
                    followUpTotal: followUps.count, followUpOpen: followUps.filter { !$0.line.done }.count))
        }
        let monthDays = facts(HistoryCalendar.days(in: range))
        let followUps = monthDays.flatMap(\.followUps)
        return HistoryPeriod(
            firstDateKey: range.lowerBound, lastDateKey: range.upperBound, brief: sources.monthBrief(containing: dateKey),
            tagCounts: Array(tagCounts(monthDays, sources: sources).prefix(monthTagPills)), rows: rows,
            followUpTotal: followUps.count,
            followUpOpen: followUps.filter { !$0.line.done }.count)
    }

    /// Each tag with the number of days it appears on (plan 5.2), most days first, ties by name.
    public static func tagCounts(_ days: [HistoryDayFacts], sources: HistoryPeriodSources) -> [HistoryTagCount] {
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
