import AppDB
import Foundation
import Intelligence
import Testing

// The History demo world has to obey the same invariants as the real day builder
// (`HistoryDay`'s doc comment), or screenshots taken on it would review a screen that can never
// happen — and it has to say what the mockups say.

@Suite("History demo world")
@MainActor
struct MockHistoryTests {

    private let demoDays = [
        "2026-09-17", "2026-09-18", "2026-09-21", "2026-09-22", "2026-09-24", "2026-09-26",
        "2026-09-20", "2026-09-19",
    ]

    @Test func theLongNightIsOneBlockBetweenItsConversations() {
        let page = MockHistory.page(for: "2026-09-19")
        let stretches = page.entries.compactMap { entry -> HistoryStretch? in
            if case .stretch(let stretch) = entry { return stretch } else { return nil }
        }
        // The night between "Planning the drive" and the 12:33 AM piece: many gaps, one block.
        let night = stretches.max { $0.parts.count < $1.parts.count }
        #expect((night?.parts.count ?? 0) >= 13)
        #expect(night.map { HistoryLabels.stretchText($0, locale: Locale(identifier: "en_US")).title }
            == "Paused · 1 hr 43 min")
        // Every item is in exactly one entry, in order.
        let flattened = page.entries.flatMap { entry -> [String] in
            switch entry {
            case .item(let item): return [item.id]
            case .stretch(let stretch): return stretch.parts.map(\.id)
            }
        }
        #expect(flattened == page.day.items.map(\.id))
    }

    @Test func everyDemoDayTilesWithNoHoleAndNoOverlap() {
        for key in demoDays {
            let items = MockHistory.page(for: key).day.items
            #expect(!items.isEmpty, "\(key)")
            for (a, b) in zip(items, items.dropFirst()) {
                #expect(a.endMs == b.startMs, "\(key): \(a.id) ends \(a.endMs), \(b.id) starts \(b.startMs)")
            }
            for item in items { #expect(item.endMs >= item.startMs, "\(key): \(item.id)") }
            #expect(Set(items.map(\.id)).count == items.count, "\(key): duplicate ids")
        }
    }

    @Test func theOrdinaryDayIsTheMockupsDay() {
        let page = MockHistory.page(for: "2026-09-22")
        #expect(page.followUpTotal == 4 && page.followUpOpen == 2)
        let chapters = page.day.items.compactMap { item -> HistoryChapterBlock? in
            if case .chapter(let block) = item { return block } else { return nil }
        }
        #expect(chapters.count == 9)
        #expect(chapters.first?.title == "Coffee and sprint planning")
        let kinds = page.day.items.compactMap { item -> HistoryGap.Kind? in
            if case .gap(let gap) = item, gap.kind != .quiet { return gap.kind } else { return nil }
        }
        #expect(kinds == [.paused, .noConversation, .audioMissing, .notTranscribedYet])
        #expect(page.day.leadingEdge?.kind == .quiet && page.day.trailingEdge?.kind == .quiet)
    }

    @Test func todayEndsInTheLiveCardAndHasNoTrailingEdge() {
        let page = MockHistory.page(for: MockHistory.todayKey)
        #expect(page.day.isToday)
        #expect(page.day.trailingEdge == nil)
        if case .live = page.day.items.last {} else { Issue.record("today should end live") }
        #expect(page.liveLine != nil)
    }

    @Test func statesOfPlanFiveEight() {
        #expect(MockHistory.page(for: "2026-09-21").topics == .preparing)
        #expect(MockHistory.page(for: "2026-09-24").isWaitingToTranscribe)
        #expect(!MockHistory.page(for: "2026-09-22").isWaitingToTranscribe)
        let empty = MockHistory.page(for: MockHistory.emptyKey)
        #expect(!empty.day.hasRecordings && empty.day.items.isEmpty)
    }

    @Test func theWeekIsRoundFive() {
        let week = MockHistory.week(firstDateKey: "2026-09-20", lastDateKey: "2026-09-26")
        #expect(week.rows.count == 7)
        #expect(week.followUpTotal == 16 && week.followUpOpen == 7)
        // Open first, two shown, the rest counted.
        let sunday = week.rows[0]
        #expect(sunday.followUps.map(\.text) == ["Email the vendor about the larger room", "Fix the crash on older dates"])
        #expect(sunday.moreFollowUps == 3)
    }

    /// The demo's headlines are what the brief pass would let through: short phrases, never a
    /// sentence and never three topics in a list — the screenshots review the real shape.
    @Test func everyDemoHeadlineIsAPhraseTheBriefPassWouldAccept() {
        let week = MockHistory.week(firstDateKey: "2026-09-20", lastDateKey: "2026-09-26")
        let travel = MockHistory.week(firstDateKey: "2026-09-13", lastDateKey: "2026-09-19")
        let month = MockHistory.month(containing: "2026-09-22")
        let headlines = (week.rows + travel.rows).compactMap(\.headline) + month.rows.compactMap(\.headline)
            + [week.brief, travel.brief, month.brief].compactMap { $0?.headline }
        #expect(headlines.count > 15)
        for headline in headlines {
            #expect(HistoryBriefText.headline(headline) == headline, "\(headline)")
            #expect(headline.filter { $0 == "," }.isEmpty, "\(headline): a list, not a phrase")
        }
        for line in month.rows.compactMap(\.summary) {
            #expect(HistoryBriefText.lineSummary(line) == line, "\(line)")
        }
    }

    @Test func withoutBriefsTheWeekAndMonthFallBackHonestly() {
        let week = MockHistory.weekWithoutBriefs(firstDateKey: "2026-09-20", lastDateKey: "2026-09-26")
        #expect(week.brief == nil)
        let sunday = week.rows[0]
        // The most-talked titled conversation, and the day's recap whole.
        #expect(sunday.headline == MockHistory.page(for: "2026-09-20").day.items.compactMap { item -> String? in
            if case .chapter(let block) = item { return block.title } else { return nil }
        }.first)
        #expect(sunday.summary == MockHistory.page(for: "2026-09-20").brief?.text)
        // A day of untitled stretches has no headline — and its recap is still its summary.
        let monday = week.rows[1]
        #expect(monday.headline == nil && monday.summary != nil)
        let month = MockHistory.monthWithoutBriefs(containing: "2026-09-22")
        #expect(month.brief == nil)
        #expect(month.rows.allSatisfy { $0.summary == nil })
        #expect(month.rows.allSatisfy { ($0.headline?.count ?? 0) <= HistoryPeriodSources.joinedHeadlineCharacters })
        // Two days' headlines joined — "Dinner and board games · Site tour and a long
        // debugging day" — never one of them clipped.
        #expect(month.rows.last?.headline?.contains(HistoryPeriodSources.separator) == true)
    }

    @Test func theMonthIsOldestFirstWithNoFutureWeek() {
        let month = MockHistory.month(containing: "2026-09-22")
        #expect(month.rows.map(\.firstDateKey) == ["2026-08-30", "2026-09-06", "2026-09-13", "2026-09-20"])
        #expect(month.rows.last?.isCurrentWeek == true)
        #expect(month.tagCounts.first?.name == "apartment")
    }

    @Test func topicResultsAreNewestFirstAndMatchTheDays() async {
        let results = await MockHistory().tagResults(tag: "apartment")
        #expect(!results.isEmpty)
        let keys = results.map(\.dateKey)
        #expect(keys == keys.sorted(by: >))
        for pair in zip(results, results.dropFirst()) where pair.0.dateKey == pair.1.dateKey {
            #expect(pair.0.startMs > pair.1.startMs)
        }
        #expect(results.contains { $0.title == "Site visit, then the budget review" })
        #expect(await MockHistory().tagResults(tag: "no-such-topic").isEmpty)
        #expect(await MockHistory(isEmptyArchive: true).tagResults(tag: "apartment").isEmpty)
    }

    @Test func aSourceThatDoesNotKnowTopicsAnswersNone() async {
        #expect(await HistoryMomentTapTests.Plain().tagResults(tag: "apartment").isEmpty)
    }
}
