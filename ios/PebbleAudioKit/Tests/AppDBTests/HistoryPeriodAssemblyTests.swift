import Foundation
import Testing

@testable import AppDB

// Weeks and months from per-day facts (plan 5.4, 5.5, 5.6): the day-state roll-up, which words
// head a day and a week (the written briefs, and the fallbacks before they exist), how tags are
// ranked, follow-up order and the "more" count, the month's tag day-counts and totals, and a week
// that straddles two months.

private let minute: Int64 = 60_000

private func conversation(
    _ id: String, _ title: String?, tags: [String] = [], overlap: Int64, transcribed: Int64? = nil
) -> HistoryConversationFact {
    HistoryConversationFact(
        id: id, title: title, tags: tags, overlapMs: overlap * minute, transcribedMs: (transcribed ?? overlap) * minute)
}

private func followUp(_ id: String, done: Bool, at: Int64, snoozed: Bool = false) -> HistoryPlacedFollowUp {
    HistoryPlacedFollowUp(line: HistoryFollowUpLine(id: id, text: "text \(id)", done: done, isSnoozed: snoozed), atMs: at)
}

private func recorded(
    _ key: String, conversations: [HistoryConversationFact] = [], recap: String? = nil,
    headline: String? = nil, line: String? = nil, followUps: [HistoryPlacedFollowUp] = []
) -> HistoryDayFacts {
    HistoryDayFacts(
        dateKey: key, recordings: 4, transcribedRecordings: 4, conversations: conversations,
        recap: recap.map { HistoryRecapFact(summary: $0, updatedAtMs: 1, headline: headline, lineSummary: line) },
        followUps: followUps)
}

@Suite struct HistoryPeriodAssemblyTests {

    // MARK: - Day state

    @Test("the roll-up: nothing, waiting, recorded, all-failed, today")
    func dayStates() {
        #expect(HistoryDayFacts(dateKey: "2026-09-20").state == .nothingRecorded)
        #expect(
            HistoryDayFacts(dateKey: "2026-09-20", recordings: 3, transcribedRecordings: 0, waitingMs: 13 * 60 * minute).state
                == .notTranscribedYet(waitingMs: 13 * 60 * minute))
        // One recording transcribed: the day has something to read, so it is recorded.
        #expect(
            HistoryDayFacts(dateKey: "2026-09-20", recordings: 3, transcribedRecordings: 1, waitingMs: minute).state
                == .recorded)
        // Every recording failed: nothing is on its way, so it is not "waiting".
        #expect(HistoryDayFacts(dateKey: "2026-09-20", recordings: 2, transcribedRecordings: 0, waitingMs: 0).state == .recorded)
        #expect(HistoryDayFacts(dateKey: "2026-09-26", isToday: true, isLive: true).state == .today(isLive: true))
        #expect(HistoryDayFacts(dateKey: "2026-09-26", isToday: true).state == .today(isLive: false))
    }

    // MARK: - Week rows

    @Test("without a written headline, the title of the most-talked TITLED conversation")
    func headlineChoice() {
        let sources = HistoryPeriodSources()
        let day = recorded(
            "2026-09-22",
            conversations: [
                conversation("a", "Coffee", overlap: 50, transcribed: 20),
                // Longer on the clock, shorter in words: the words decide.
                conversation("b", "Garden planning", overlap: 40, transcribed: 35),
                conversation("c", "Walking home", overlap: 10),
            ])
        #expect(sources.dayHeadline(day) == "Garden planning")

        // The longest talk has no title yet: the most-talked conversation that HAS one. A title
        // is already a short phrase, which is all the row asks for.
        let untitled = recorded(
            "2026-09-22", conversations: [conversation("a", nil, overlap: 90), conversation("b", "Short", overlap: 5)])
        #expect(sources.dayHeadline(untitled) == "Short")

        // Nothing transcribed: nothing to headline.
        let wordless = recorded("2026-09-22", conversations: [conversation("a", "Title", overlap: 30, transcribed: 0)])
        #expect(sources.dayHeadline(wordless) == nil)
    }

    @Test("summary is the recap; tags are ranked by the time of the conversations carrying them")
    func summaryAndTags() {
        let day = recorded(
            "2026-09-22",
            conversations: [
                conversation("a", "A", tags: ["banking", "work"], overlap: 30),
                conversation("b", "B", tags: ["apartment"], overlap: 45),
                conversation("c", "C", tags: ["banking", "Travel"], overlap: 20),
                conversation("d", "D", tags: ["games"], overlap: 5),
            ],
            recap: "Garden work and a bank transfer.")
        let row = HistoryPeriodAssembler.weekRow(day, sources: HistoryPeriodSources())
        #expect(row.summary == "Garden work and a bank transfer.")
        // banking 50 > apartment 45 > work 30 > Travel 20 > games 5; three shown.
        #expect(row.tags == ["banking", "apartment", "work"])
        #expect(HistoryPeriodSources().dayTags(day) == ["banking", "apartment", "work", "Travel", "games"])
    }

    @Test("follow-ups: open first, then done, each by time; the rest counted as more")
    func followUpOrder() {
        let day = recorded(
            "2026-09-22",
            followUps: [
                followUp("done-early", done: true, at: 100),
                followUp("open-late", done: false, at: 900),
                followUp("snoozed-mid", done: false, at: 500, snoozed: true),
                followUp("done-late", done: true, at: 1_000),
                followUp("open-early", done: false, at: 200),
            ])
        let row = HistoryPeriodAssembler.weekRow(day, sources: HistoryPeriodSources())
        #expect(row.followUps.map(\.id) == ["open-early", "snoozed-mid"])
        #expect(row.moreFollowUps == 3)
    }

    @Test("a day with nothing to read carries no text, whatever its conversations say")
    func stateRowsCarryNoText() {
        let waiting = HistoryDayFacts(
            dateKey: "2026-09-24", recordings: 2, transcribedRecordings: 0, waitingMs: 30 * minute,
            conversations: [conversation("a", "Stale title", tags: ["x"], overlap: 30)],
            recap: HistoryRecapFact(summary: "old", updatedAtMs: 1))
        let row = HistoryPeriodAssembler.weekRow(waiting, sources: HistoryPeriodSources())
        #expect(row.state == .notTranscribedYet(waitingMs: 30 * minute))
        #expect(row.headline == nil && row.summary == nil && row.tags.isEmpty)
    }

    @Test("a week lists its days oldest first, stops at today, and totals its follow-ups")
    func weekAssembly() {
        let days: [String: HistoryDayFacts] = [
            "2026-09-20": recorded("2026-09-20", followUps: [followUp("1", done: true, at: 1)]),
            "2026-09-22": recorded(
                "2026-09-22", conversations: [conversation("a", "Viewing", overlap: 60)],
                followUps: [followUp("2", done: false, at: 2), followUp("3", done: false, at: 3)]),
            "2026-09-23": HistoryDayFacts(
                dateKey: "2026-09-23", isToday: true, isLive: true, recordings: 1, transcribedRecordings: 0,
                waitingMs: minute),
        ]
        let week = HistoryPeriodAssembler.week(
            firstDateKey: "2026-09-20", lastDateKey: "2026-09-26", days: days, todayKey: "2026-09-23")
        #expect(week.rows.map(\.dateKey) == ["2026-09-20", "2026-09-21", "2026-09-22", "2026-09-23"])
        #expect(week.rows.map(\.state) == [.recorded, .nothingRecorded, .recorded, .today(isLive: true)])
        #expect(week.rows[2].headline == "Viewing")
        #expect(week.followUpTotal == 3 && week.followUpOpen == 2)
        #expect(week.brief == nil && week.tagCounts.isEmpty)
    }

    // MARK: - Month

    @Test("a day's written headline and line head it; before they exist, a title and the recap whole")
    func theWrittenBriefHeadsTheDay() {
        let sources = HistoryPeriodSources()
        let recap = "The day began with a long planning session and some reading, followed by errands. "
            + "Later, you worked with friends on the new garden."
        let talk = [conversation("a", "Errands in town", overlap: 60), conversation("b", nil, overlap: 90)]

        let written = recorded(
            "2026-09-27", conversations: talk, recap: recap, headline: "Office in Unit 4 and Fernwood",
            line: "Signed a new office lease in Unit 4; weighed short terms.")
        #expect(sources.dayHeadline(written) == "Office in Unit 4 and Fernwood")
        #expect(sources.daySummary(written) == "Signed a new office lease in Unit 4; weighed short terms.")

        // Not written yet: never the recap's first sentence cut short (the screen Roger reported:
        // "The day began with a long planning…" over "Later, you worked with friends…").
        let pending = recorded("2026-09-27", conversations: talk, recap: recap)
        #expect(sources.dayHeadline(pending) == "Errands in town")
        #expect(sources.daySummary(pending) == recap, "the recap whole; the view clamps it to two lines")
        // No titled conversation either: no headline at all, rather than a cut.
        let bare = recorded("2026-09-27", conversations: [conversation("b", nil, overlap: 90)], recap: recap)
        #expect(sources.dayHeadline(bare) == nil)
        #expect(sources.daySummary(bare) == recap)

        // A headline but no usable line: the recap under it, whole.
        let headlineOnly = recorded("2026-09-27", conversations: talk, recap: recap, headline: "Road trip to Denver")
        #expect(sources.daySummary(headlineOnly) == recap)

        // Whatever the text, no headline is ever a cut and none is the recap's opening.
        for day in [written, pending, bare, headlineOnly] {
            let headline = sources.dayHeadline(day)
            #expect(headline?.hasSuffix("…") != true)
            #expect(headline.map { recap.hasPrefix($0) } != true)
        }
    }

    @Test("today's row keeps its state; its summary follows the day's rule")
    func todayRow() {
        var today = recorded(
            "2026-09-30", conversations: [conversation("a", "Lunch", overlap: 20)], recap: "Lunch and a walk.",
            line: "Lunch near the office; a walk through the park.")
        today.isToday = true
        let row = HistoryPeriodAssembler.weekRow(today, sources: HistoryPeriodSources())
        #expect(row.state == .today(isLive: false))
        #expect(row.summary == "Lunch near the office; a walk through the park.")
        today.recap?.lineSummary = nil
        #expect(HistoryPeriodAssembler.weekRow(today, sources: HistoryPeriodSources()).summary == "Lunch and a walk.")
    }

    @Test("a week's brief heads its month row and fills the week and month cards")
    func writtenBriefs() {
        let days: [String: HistoryDayFacts] = [
            "2026-09-21": recorded("2026-09-21", conversations: [conversation("a", "Garden planning", overlap: 90)])
        ]
        let sources = HistoryPeriodSources(briefs: [
            PeriodBriefKey.week(firstDateKey: "2026-09-20"): HistoryBrief(
                text: "Garden work took the week.", headline: "Garden work and banking",
                lineSummary: "Two workdays and the shopping behind them.", updatedAtMs: 5),
            PeriodBriefKey.month(containing: "2026-09-01"): HistoryBrief(
                text: "The garden project.", headline: "The move", lineSummary: nil, updatedAtMs: 6),
        ])
        let month = HistoryPeriodAssembler.month(
            containing: "2026-09-22", firstWeekday: 1, days: days, todayKey: "2026-09-26", sources: sources)
        let row = month.rows.first { $0.firstDateKey == "2026-09-20" }!
        #expect(row.headline == "Garden work and banking")
        #expect(row.summary == "Two workdays and the shopping behind them.")
        #expect(month.brief?.text == "The garden project.")
        let week = HistoryPeriodAssembler.week(
            firstDateKey: "2026-09-20", lastDateKey: "2026-09-26", days: days, todayKey: "2026-09-26",
            sources: sources)
        #expect(week.brief?.text == "Garden work took the week.")
        // A brief with only a row's words (its paragraph was refused) is no card.
        let rowOnly = HistoryPeriodSources(briefs: [
            PeriodBriefKey.week(firstDateKey: "2026-09-20"): HistoryBrief(
                text: "", headline: "Garden work", lineSummary: nil, updatedAtMs: 5)
        ])
        #expect(rowOnly.weekBrief(firstDateKey: "2026-09-20") == nil)
        #expect(rowOnly.weekHeadline(firstDateKey: "2026-09-20", []) == "Garden work")
    }

    @Test("before its brief, a week row is headed by its two most-talked days' headlines; no summary")
    func monthRowFallback() {
        let days: [String: HistoryDayFacts] = [
            "2026-09-20": recorded("2026-09-20", conversations: [conversation("x", "Coffee", overlap: 20)]),
            "2026-09-21": recorded(
                "2026-09-21",
                conversations: [
                    conversation("a", "Garden planning", overlap: 90),
                    conversation("b", "Bank transfer", overlap: 40),
                ]),
            "2026-09-22": recorded(
                "2026-09-22",
                conversations: [conversation("c", "garden planning", overlap: 80), conversation("d", "Dinner", overlap: 30)]),
            "2026-09-23": recorded(
                "2026-09-23",
                conversations: [conversation("e", "A whole day", overlap: 200, transcribed: 60)],
                recap: "Budget review and report checks. More.", headline: "Budget review"),
        ]
        let month = HistoryPeriodAssembler.month(
            containing: "2026-09-22", firstWeekday: 1, days: days, todayKey: "2026-09-26")
        let week = month.rows.first { $0.firstDateKey == "2026-09-20" }!
        // 21st (130 min): Garden planning; 22nd (110): the same headline again, skipped; 23rd
        // (60): its written headline. Two phrases, never a sentence; no summary until the brief.
        #expect(week.headline == "Garden planning · Budget review")
        #expect(week.summary == nil)
        #expect(week.isCurrentWeek)
        #expect(week.hasRecordings)

        // Two that would not fit one line: the first alone, never a clipped second.
        var long = days
        long["2026-09-23"]?.recap?.headline = "Budget review and the quarterly report"
        let longWeek = HistoryPeriodAssembler.month(
            containing: "2026-09-22", firstWeekday: 1, days: long, todayKey: "2026-09-26"
        ).rows.first { $0.firstDateKey == "2026-09-20" }!
        #expect(longWeek.headline == "Garden planning")
    }

    @Test("tag counts are the days a tag appears on; month totals cover only the month's days")
    func monthTagCountsAndTotals() {
        let days: [String: HistoryDayFacts] = [
            // August 30 and 31 belong to the first week row but not to September.
            "2026-08-31": recorded(
                "2026-08-31", conversations: [conversation("x", "X", tags: ["setup"], overlap: 10)],
                followUps: [followUp("aug", done: false, at: 1)]),
            "2026-09-01": recorded(
                "2026-09-01", conversations: [conversation("a", "A", tags: ["setup", "work"], overlap: 10)],
                followUps: [followUp("s1", done: true, at: 2)]),
            "2026-09-02": recorded(
                "2026-09-02", conversations: [conversation("b", "B", tags: ["work"], overlap: 10)],
                followUps: [followUp("s2", done: false, at: 3)]),
            "2026-09-03": recorded(
                "2026-09-03",
                conversations: [
                    conversation("c", "C", tags: ["Work"], overlap: 10),
                    conversation("d", "D", tags: ["work", "family"], overlap: 10),
                ]),
        ]
        let month = HistoryPeriodAssembler.month(
            containing: "2026-09-10", firstWeekday: 1, days: days, todayKey: "2026-09-03")
        // work on 3 days (twice on the 3rd counts once), setup on 1 September day, family on 1.
        #expect(month.tagCounts == [
            HistoryTagCount(name: "work", days: 3), HistoryTagCount(name: "family", days: 1),
            HistoryTagCount(name: "setup", days: 1),
        ])
        #expect(month.followUpTotal == 2 && month.followUpOpen == 1)
        // The card carries a row of pills, not every tag of the month.
        var many: [String: HistoryDayFacts] = [:]
        for day in 1...3 {
            let key = "2026-09-0\(day)"
            many[key] = recorded(key, conversations: [
                conversation("c\(day)", "C", tags: (0..<6).map { "tag\(day)-\($0)" } + ["common"], overlap: 10)
            ])
        }
        let crowded = HistoryPeriodAssembler.month(containing: "2026-09-10", firstWeekday: 1, days: many, todayKey: "2026-09-03")
        #expect(crowded.tagCounts.count == HistoryPeriodAssembler.monthTagPills)
        #expect(crowded.tagCounts.first == HistoryTagCount(name: "common", days: 3))
        // The first week row, whole, does include August's follow-up.
        #expect(month.rows.map(\.firstDateKey) == ["2026-08-30"])
        #expect(month.rows[0].followUpTotal == 3 && month.rows[0].followUpOpen == 2)
        #expect(month.brief == nil)
    }

    @Test("a week that straddles two months is a row of both, whole")
    func straddlingWeek() {
        let days: [String: HistoryDayFacts] = [
            "2026-09-29": recorded("2026-09-29", conversations: [conversation("a", "End of September", overlap: 30)]),
            "2026-10-01": recorded("2026-10-01", conversations: [conversation("b", "Start of October", overlap: 20)]),
        ]
        let september = HistoryPeriodAssembler.month(
            containing: "2026-09-15", firstWeekday: 1, days: days, todayKey: "2026-10-03")
        let october = HistoryPeriodAssembler.month(
            containing: "2026-10-15", firstWeekday: 1, days: days, todayKey: "2026-10-03")
        let last = september.rows.last!
        let first = october.rows.first!
        #expect(last.firstDateKey == "2026-09-27" && last.lastDateKey == "2026-10-03")
        #expect(first == last)
        #expect(first.headline == "End of September · Start of October")  // the 29th has more talk
        // October's own days only: weeks after today are not listed.
        #expect(october.rows.count == 1)
        #expect(september.rows.count == 5)
    }

    @Test("monday-first weeks come from the calendar")
    func mondayFirst() {
        let month = HistoryPeriodAssembler.month(
            containing: "2026-09-10", firstWeekday: 2, days: [:], todayKey: "2026-09-30")
        #expect(month.rows.first?.firstDateKey == "2026-08-31")
        #expect(month.rows.allSatisfy { !$0.hasRecordings })
    }

    // MARK: - Bounds

    @Test("bounds: recorded days are the day keys of recording starts")
    func bounds() {
        let zone = "Asia/Jakarta"
        let timeline = ZoneTimeline(segments: [], currentZoneID: zone)
        let fourAm = LogicalDay.bounds(ofDateKey: "2026-09-22", timeZoneID: zone)!.startMs - 60 * minute
        let noon = fourAm + 8 * 60 * minute
        let bounds = HistoryBounds.of(startsMs: [noon, fourAm, noon + minute], timeline: timeline, todayDateKey: "2026-09-30")
        #expect(bounds.recordedDays == ["2026-09-21", "2026-09-22"])
        #expect(bounds.firstDateKey == "2026-09-21")
        #expect(HistoryBounds.of(startsMs: [], timeline: timeline, todayDateKey: "2026-09-30").firstDateKey == nil)
        #expect(HistoryBoundsKey(startsMs: [3, 1, 2]) == HistoryBoundsKey(startsMs: [1, 2, 3]))
        #expect(HistoryBoundsKey(startsMs: [1, 2]) != HistoryBoundsKey(startsMs: [1, 2, 3]))
    }
}
