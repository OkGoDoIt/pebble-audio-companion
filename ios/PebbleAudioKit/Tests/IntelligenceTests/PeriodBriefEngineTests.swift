import AppDB
import Foundation
import Testing

@testable import Intelligence

// The brief pass (`PeriodBriefEngine`): day headlines, then weeks, then months — each written
// once for what it read, in that order, at most `maxCallsPerPass` calls a run, the current week
// and month on their cadence, a failure on its backoff, and nothing at all when nothing is owed.

/// Answers every brief prompt with a well-formed reply, and records what it was asked.
private final class BriefHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [AiRunRequest] = []
    /// Never reset, so every answer is different from every earlier one.
    private var _answered = 0
    private var _fail = false
    private var _dayReply: String?

    var requests: [AiRunRequest] { lock.withLock { _requests } }
    var promptIds: [String] { requests.map(\.prompt.id) }
    var fail: Bool {
        get { lock.withLock { _fail } }
        set { lock.withLock { _fail = newValue } }
    }
    /// Overrides the day answer (nil: a good one).
    var dayReply: String? {
        get { lock.withLock { _dayReply } }
        set { lock.withLock { _dayReply = newValue } }
    }

    func reset() { lock.withLock { _requests = [] } }

    func run(_ request: AiRunRequest) throws -> RoutedAiResult {
        let (shouldFail, day, count) = lock.withLock { () -> (Bool, String?, Int) in
            _requests.append(request)
            _answered += 1
            return (_fail, _dayReply, _answered)
        }
        if shouldFail { throw URLError(.notConnectedToInternet) }
        let text: String
        switch request.prompt.id {
        case DayBrief.templateId:
            text = day ?? #"{"headline":"Headline number \#(count)","lineSummary":"Line number \#(count)."}"#
        default:
            text = #"{"text":"Brief number \#(count). It went well.","headline":"Period number \#(count)","lineSummary":"Line number \#(count)."}"#
        }
        return RoutedAiResult(
            text: text, modeUsed: .remoteOnly, providerId: "fake", modelUsed: "fake-model", inputTokens: nil,
            outputTokens: nil)
    }
}

private let hour: Int64 = 60 * 60_000

@Suite struct PeriodBriefEngineTests {
    private struct World {
        let db: AppDatabase
        let recaps: DailyRecapStore
        let briefs: PeriodBriefStore
        let harness: BriefHarness
        let clock: TestWallClock
        let today: Box
        let engine: PeriodBriefEngine
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String
        init(_ value: String) { _value = value }
        var value: String {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private func world(today: String = "2026-10-15", maxCalls: Int = 8, aiOff: Bool = false) throws -> World {
        let db = try AppDatabase.inMemory()
        let clock = TestWallClock(ms: 1_800_000_000_000)
        let recaps = DailyRecapStore(db: db, nowMs: { clock.now })
        let briefs = PeriodBriefStore(db: db)
        let harness = BriefHarness()
        let box = Box(today)
        let run: PeriodBriefEngine.RunAi = { @Sendable request in try harness.run(request) }
        let engine = PeriodBriefEngine(
            recaps: recaps, briefs: briefs, run: aiOff ? nil : run,
            todayKey: { box.value }, firstWeekday: { 1 }, nowMs: { clock.now }, maxCallsPerPass: maxCalls)
        return World(db: db, recaps: recaps, briefs: briefs, harness: harness, clock: clock, today: box, engine: engine)
    }

    private func recap(_ world: World, _ dateKey: String, _ text: String? = nil) async throws {
        try await world.recaps.save(DailyRecap(dateKey: dateKey, text: text ?? "What happened on \(dateKey)."))
    }

    @Test("days, then their week, then their month; then nothing, and not a single call")
    func fullOrderThenSettled() async throws {
        let w = try world()
        try await recap(w, "2026-09-21")
        try await recap(w, "2026-09-22")
        let first = try await w.engine.refresh()
        #expect(w.harness.promptIds == ["day-brief", "day-brief", "week-brief", "month-brief"])
        #expect(first.calls == 4 && first.wrote && first.nextDueAtMs == nil && first.failure == nil)
        // Newest day first.
        #expect(w.harness.requests.first?.transcripts.first?.text == "What happened on 2026-09-22.")

        let saved = try await w.recaps.load(dateKey: "2026-09-22")
        #expect(saved?.headline != nil && saved?.briefOfHash == RecapCondenser.fingerprint(saved!.text))
        let stored = try await w.briefs.load(keys: [
            PeriodBriefKey.week(firstDateKey: "2026-09-20"), PeriodBriefKey.month(containing: "2026-09-21"),
        ])
        #expect(stored.count == 2 && stored.values.allSatisfy { $0.text != nil && $0.sourceHash != nil })
        // The week read its days' headlines, lines and recaps, oldest first.
        let weekInput = w.harness.requests[2].transcripts.first!.text
        #expect(weekInput.contains("Headline: Headline number 2"))
        #expect(weekInput.range(of: "Monday 21")!.lowerBound < weekInput.range(of: "Tuesday 22")!.lowerBound)
        // The month read the week's brief.
        #expect(w.harness.requests[3].transcripts.first!.text.contains("Headline: Period number 3"))

        w.harness.reset()
        let second = try await w.engine.refresh()
        #expect(w.harness.requests.isEmpty)
        #expect(second == .nothingOwed)
    }

    @Test("with AI off nothing is owed")
    func aiOff() async throws {
        let w = try world(aiOff: true)
        try await recap(w, "2026-09-21")
        #expect(try await w.engine.refresh() == .nothingOwed)
    }

    @Test("the backfill fills newest first, a capped number of calls a run, and says it is owed now")
    func backfillCap() async throws {
        let w = try world(maxCalls: 2)
        for day in ["2026-09-21", "2026-09-22", "2026-09-29"] { try await recap(w, day) }
        var outcome = try await w.engine.refresh()
        #expect(outcome.calls == 2 && outcome.nextDueAtMs == w.clock.now)
        #expect(w.harness.promptIds == ["day-brief", "day-brief"])
        // A week waits for all its days: the week of the 20th is not briefed from the 22nd alone.
        outcome = try await w.engine.refresh()
        #expect(w.harness.promptIds == ["day-brief", "day-brief", "day-brief", "week-brief"])
        #expect(outcome.nextDueAtMs == w.clock.now)
        var runs = 2
        while try await w.engine.refresh().nextDueAtMs != nil { runs += 1 }
        #expect(runs < 10)
        // Three days, two weeks, one month.
        #expect(w.harness.promptIds.filter { $0 == "week-brief" }.count == 2)
        #expect(w.harness.promptIds.filter { $0 == "month-brief" }.count == 1)
        #expect(w.harness.requests.count == 6)
    }

    @Test("a week with a single recorded day is briefed from it")
    func singleDayWeek() async throws {
        let w = try world()
        try await recap(w, "2026-09-24")
        _ = try await w.engine.refresh()
        #expect(w.harness.promptIds == ["day-brief", "week-brief", "month-brief"])
    }

    @Test("an unusable headline is stamped and never asked again; the week still reads the recap")
    func unusableIsStamped() async throws {
        let w = try world()
        w.harness.dayReply = #"{"headline":"The day began with a long planning session","lineSummary":"Later, you worked."}"#
        try await recap(w, "2026-09-27")
        _ = try await w.engine.refresh()
        let saved = try await w.recaps.load(dateKey: "2026-09-27")
        #expect(saved?.headline == nil && saved?.lineSummary == nil)
        #expect(saved?.briefOfHash == RecapCondenser.fingerprint(saved!.text))
        #expect(w.harness.promptIds == ["day-brief", "week-brief", "month-brief"])
        #expect(w.harness.requests[1].transcripts.first!.text.contains("Recap: What happened on 2026-09-27."))
        w.harness.reset()
        _ = try await w.engine.refresh()
        #expect(w.harness.requests.isEmpty)
    }

    @Test("a regenerated past day rewrites its day, week and month at once")
    func pastChange() async throws {
        let w = try world()
        try await recap(w, "2026-09-21")
        _ = try await w.engine.refresh()
        w.harness.reset()
        try await recap(w, "2026-09-21", "A different account of the 21st.")
        let outcome = try await w.engine.refresh()
        #expect(w.harness.promptIds == ["day-brief", "week-brief", "month-brief"])
        #expect(outcome.nextDueAtMs == nil)
    }

    @Test("the current week is rewritten at most every three hours, the current month once a day")
    func currentCadence() async throws {
        let w = try world(today: "2026-09-22")
        try await recap(w, "2026-09-21")
        try await recap(w, "2026-09-22")
        _ = try await w.engine.refresh()
        let written = w.clock.now
        w.harness.reset()

        // Today's recap moves on half an hour later: its headline at once, the week and month
        // keep what they have and say when they are due.
        w.clock.advance(byMs: hour / 2)
        try await recap(w, "2026-09-22", "The 22nd so far, now with dinner.")
        var outcome = try await w.engine.refresh()
        #expect(w.harness.promptIds == ["day-brief"])
        #expect(outcome.nextDueAtMs == written + PeriodBriefEngine.currentWeekIntervalMs)

        // Not yet.
        w.harness.reset()
        w.clock.advance(byMs: hour)
        outcome = try await w.engine.refresh()
        #expect(w.harness.requests.isEmpty)

        // Three hours after the week was written: the week. The month waits out its day.
        w.clock.now = written + PeriodBriefEngine.currentWeekIntervalMs
        outcome = try await w.engine.refresh()
        #expect(w.harness.promptIds == ["week-brief"])
        #expect(outcome.nextDueAtMs == written + PeriodBriefEngine.currentMonthIntervalMs)

        w.harness.reset()
        w.clock.now = written + PeriodBriefEngine.currentMonthIntervalMs
        outcome = try await w.engine.refresh()
        #expect(w.harness.promptIds == ["month-brief"])
        #expect(outcome.nextDueAtMs == nil)
    }

    @Test("a past month whose last week is being lived keeps the month's pace")
    func straddlingMonth() async throws {
        let w = try world(today: "2026-10-01")
        try await recap(w, "2026-09-29")
        _ = try await w.engine.refresh()
        #expect(w.harness.promptIds == ["day-brief", "week-brief", "month-brief"])
        w.harness.reset()
        // Four hours on, the week (Sep 27 – Oct 3, current) changes and is rewritten; September —
        // past, but reading this week — is not rewritten with it.
        w.clock.advance(byMs: 4 * hour)
        try await recap(w, "2026-09-29", "The 29th, retold.")
        let outcome = try await w.engine.refresh()
        #expect(w.harness.promptIds == ["day-brief", "week-brief"])
        #expect(outcome.nextDueAtMs != nil)
    }

    @Test("a failed call is backed off, returned, and not retried inside its wait")
    func failureBackoff() async throws {
        let w = try world()
        try await recap(w, "2026-09-21")
        w.harness.fail = true
        let outcome = try await w.engine.refresh()
        #expect(outcome.failure == PeriodBriefFailed(key: "day:2026-09-21", kind: .noConnection))
        #expect(outcome.nextDueAtMs == w.clock.now + PeriodBriefEngine.firstFailureBackoffMs)
        #expect(outcome.failure?.description.contains("URLError") == false, "the kind, never the error's words")
        let saved = try await w.recaps.load(dateKey: "2026-09-21")
        #expect(saved?.briefOfHash == nil, "a failure is not an attempt")

        w.harness.reset()
        w.harness.fail = false
        _ = try await w.engine.refresh()
        #expect(w.harness.requests.isEmpty)
        w.clock.advance(byMs: PeriodBriefEngine.firstFailureBackoffMs)
        _ = try await w.engine.refresh()
        #expect(w.harness.promptIds == ["day-brief", "week-brief", "month-brief"])
    }

    @Test("a failed week keeps its backoff in the table, and a changed AI configuration lifts it")
    func periodFailureIsStored() async throws {
        let w = try world(maxCalls: 1)
        try await recap(w, "2026-09-21")
        _ = try await w.engine.refresh()  // the day
        w.harness.fail = true
        let outcome = try await w.engine.refresh()
        #expect(outcome.failure?.key == PeriodBriefKey.week(firstDateKey: "2026-09-20"))
        let row = try await w.briefs.load(keys: [PeriodBriefKey.week(firstDateKey: "2026-09-20")]).values.first
        #expect(row?.attempts == 1 && row?.lastError == "noConnection" && row?.text == nil && row?.sourceHash == nil)
        w.harness.fail = false
        w.harness.reset()
        _ = try await w.engine.refresh()
        #expect(w.harness.requests.isEmpty, "inside its wait")
        await w.engine.resetFailureBackoff()
        _ = try await w.engine.refresh()
        #expect(w.harness.promptIds == ["week-brief"])
    }

    @Test("a period with nothing left to describe loses its brief")
    func orphansAreRemoved() async throws {
        let w = try world()
        try await recap(w, "2026-09-21")
        try await recap(w, "2026-10-05")
        _ = try await w.engine.refresh()
        try await w.recaps.delete(dateKey: "2026-09-21")
        let outcome = try await w.engine.refresh()
        #expect(outcome.wrote)
        let left = try await w.briefs.all().map(\.periodKey).sorted()
        #expect(left == [PeriodBriefKey.month(containing: "2026-10-05"), PeriodBriefKey.week(firstDateKey: "2026-10-04")])
    }

    @Test("a headline is never written over a recap regenerated while the call was in flight")
    func guardedOnText() async throws {
        let w = try world()
        try await recap(w, "2026-09-21")
        try await w.recaps.saveDayBrief(
            dateKey: "2026-09-21", sourceText: "Some older text.", headline: "Stale", lineSummary: nil)
        let saved = try await w.recaps.load(dateKey: "2026-09-21")
        #expect(saved?.headline == nil && saved?.briefOfHash == nil)
    }
}
