import AppDB
import Foundation
import Transcription

// The History demo world (`-demo-data`, previews, the gallery). It reproduces the approved
// mockups exactly, so the screen can be compared against them screenshot for screenshot:
//
// - Tuesday September 22, "an ordinary day" — round10-background-audio (left)
// - Thursday September 17, "a travel day" — round10-background-audio (right)
// - Saturday September 26, today with the Live card — round3-today-and-week-text-tags
// - the week of September 20 — round5-week-followup-state
// - September — round4-white-blocks-followups
//
// plus the states of plan 5.8: a day drawn from conversations while topics are prepared
// (Monday 21), a day not transcribed yet (Thursday 24), a day with nothing recorded (Monday 14),
// and a day that changes time zone mid-flight (Friday 18).
//
// Two things differ from the mockups on purpose. Causes of lost audio are ones the app can
// record: the mockups' "watch out of range" is not something the app knows, so those gaps say
// "watch buffer filled while disconnected" (plan 5.3). And the demo's clock is fixed at 11:41 AM
// on Saturday September 26, the mockups' "now", so the demo looks the same whenever it is run.
// Times are wall-clock times in the device's zone, as the mockups draw them.

@MainActor
final class MockHistory: HistoryDataSource {
    static let todayKey = "2026-09-26"
    /// The `MockWorld` conversation a tapped moment opens until the moment route exists.
    static let demoConversationID = "app-redesign"
    static let firstKey = "2026-09-01"
    /// 11:41 AM on today, the mockups' "now".
    static let nowMinutes = 11 * 60 + 41

    /// What the screen asked for, so tests and previews can see the battery rules being used.
    private(set) var prefetched: [String] = []
    private(set) var isVisible = true
    /// A world where nothing has ever been recorded (plan 5.8), for DEBUG `-historyEmpty`.
    let isEmptyArchive: Bool
    /// A world where the brief pass has not run yet (AI off, or not reached these days), for
    /// DEBUG `-historyNoBriefs`: the week and month pages on their fallbacks.
    let withoutBriefs: Bool

    init(isEmptyArchive: Bool = false, withoutBriefs: Bool = false) {
        self.isEmptyArchive = isEmptyArchive
        self.withoutBriefs = withoutBriefs
    }

    func bounds() async -> HistoryBounds {
        if isEmptyArchive {
            return HistoryBounds(firstDateKey: nil, todayDateKey: Self.todayKey, recordedDays: [])
        }
        return HistoryBounds(firstDateKey: Self.firstKey, todayDateKey: Self.todayKey, recordedDays: Self.recordedDays)
    }

    func day(_ dateKey: String) -> AsyncStream<HistoryDayPage> {
        let page = Self.page(for: dateKey)
        return AsyncStream { continuation in
            continuation.yield(page)
            continuation.finish()
        }
    }

    func week(firstDateKey: String, lastDateKey: String) -> AsyncStream<HistoryPeriod<HistoryWeekRow>> {
        let period = withoutBriefs
            ? Self.weekWithoutBriefs(firstDateKey: firstDateKey, lastDateKey: lastDateKey)
            : Self.week(firstDateKey: firstDateKey, lastDateKey: lastDateKey)
        return AsyncStream { continuation in
            continuation.yield(period)
            continuation.finish()
        }
    }

    func month(containing dateKey: String) -> AsyncStream<HistoryPeriod<HistoryMonthRow>> {
        let period = withoutBriefs ? Self.monthWithoutBriefs(containing: dateKey) : Self.month(containing: dateKey)
        return AsyncStream { continuation in
            continuation.yield(period)
            continuation.finish()
        }
    }

    /// Every demo chapter carrying the topic, newest first — read from the same demo days the
    /// Day pages draw, so the list and the days agree.
    func tagResults(tag: String) async -> [HistoryTagResult] {
        guard !isEmptyArchive else { return [] }
        return Self.recordedDays.sorted(by: >).flatMap { key in
            Self.page(for: key).day.items.reversed().compactMap { item -> HistoryTagResult? in
                guard case .chapter(let block) = item, block.tags.contains(tag) else { return nil }
                return HistoryTagResult(
                    dateKey: key, startMs: block.startMs, endMs: block.endMs, zoneID: block.zoneID,
                    title: HistoryLabels.chapterTitle(block), summary: block.summary,
                    conversationId: block.chapterId)
            }
        }
    }

    func prefetch(days: [String]) {
        prefetched.append(contentsOf: days)
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
    }

    // MARK: - Follow-ups

    /// Every follow-up line the demo days draw, as follow-ups the mock world can open. Created
    /// a week before `now`; the done ones were ticked off a day later.
    static func demoFollowUps(now: Date) -> [FollowUp] {
        let created = Int64(now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970 * 1000)
        var seen: Set<String> = []
        return recordedDays.sorted().flatMap { key in
            page(for: key).day.items.flatMap { item -> [FollowUp] in
                guard case .chapter(let block) = item else { return [] }
                return block.followUps.compactMap { line in
                    guard seen.insert(line.id).inserted else { return nil }
                    return FollowUp(
                        id: line.id, text: line.text, done: line.done,
                        sourceConversationId: demoConversationID, sourceSegmentId: nil,
                        createdAtMs: created,
                        completedAtMs: line.done ? created + 86_400_000 : nil)
                }
            }
        }
    }

    // MARK: - Days

    static let emptyKey = "2026-09-14"

    static var recordedDays: Set<String> {
        Set(HistoryCalendar.days(in: firstKey...todayKey)).subtracting([emptyKey])
    }

    static func page(for dateKey: String) -> HistoryDayPage {
        #if DEBUG
        if let units = unitDays[dateKey] { return units }
        #endif
        switch dateKey {
        case "2026-09-22": return ordinaryDay()
        case "2026-09-17": return travelDay()
        case todayKey: return today()
        case "2026-09-21": return conversationsDay()
        case "2026-09-24": return notTranscribedDay()
        case "2026-09-18": return zoneChangeDay()
        case "2026-09-19": return nightDay()
        default:
            if recordedDays.contains(dateKey) { return plainDay(dateKey) }
            return nothingRecorded(dateKey)
        }
    }

    /// Round 10, left: "An ordinary day".
    static func ordinaryDay() -> HistoryDayPage {
        var s = Script("2026-09-22")
        s.chapter(
            (8, 12), (9, 0), "Coffee and sprint planning",
            "Ordering coffee, then the sprint board and which bug to take first.",
            tags: ["work"], people: ["Sam"])
        s.chapter(
            (9, 5), (10, 15), "Tile samples and a locked supplier login",
            "Comparing two tile samples for the kitchen and what each costs, then a supplier portal that kept refusing the login. Priya knows a fitter who could help.",
            tags: ["apartment", "budget"], followUps: [("Ask Priya for the fitter’s number", true)])
        s.chapter(
            (10, 20), (11, 0), "Dentist appointment and launch dates", "The checkup against the launch calendar.",
            tags: ["errands", "launch"])
        s.gap(.paused, (11, 0), (11, 30), pausedBy: .you)
        s.chapter(
            (11, 30), (12, 55), "Deploying the build to the phone",
            "Mostly quiet, with check-ins as the deploy ran and was verified. The new build fixed the crash on older dates, and the battery numbers looked normal afterwards.",
            tags: ["work"])
        s.gap(.noConversation, (13, 15), (14, 0), descriptor: "music", openable: true)
        s.chapter(
            (14, 0), (14, 56), "Invoice details with the vendor",
            "Order numbers and the contact.", tags: ["budget"], missingMinutes: 4,
            followUps: [("Confirm the billing contact", true), ("Send the order number", false)])
        s.chapter(
            (15, 10), (15, 48), "Workshop travel and the hotel",
            "Train times to the venue, two nights near it.", tags: ["travel"])
        s.chapter(
            (16, 0), (17, 50), "Site visit, then the budget review",
            "A visit in the rain to the kitchen showroom: the second layout is bigger but costs more. Then going through the budget line by line with Dana, settling on the smaller layout, with the extra cupboard still open.",
            tags: ["apartment"], people: ["Dana"], followUps: [("Reply to the vendor by Friday", false)])
        s.chapter(
            (18, 10), (20, 15), "Dinner and board games",
            "Choosing a place to eat and ending up at the noodle bar. Talk about Leo’s new job and Sam’s marathon training, then a long game night: two rounds of a card game and a rematch, with plans to do it again next week.",
            tags: ["dining", "games"], people: ["Leo", "Sam"])
        s.chapter((20, 20), (20, 38), "Walking home", nil)
        s.gap(.audioMissing, (20, 38), (21, 30), causes: [.watchBufferFull])
        s.gap(.notTranscribedYet, (21, 30), (21, 44), openable: true)
        return s.page(
            brief: "Sprint planning over coffee, tile samples and a vendor call, a rainy site visit and a budget review, then dinner and board games.",
            leading: .quiet, trailing: .quiet)
    }

    /// Round 10, right: "A travel day".
    static func travelDay() -> HistoryDayPage {
        var s = Script("2026-09-17")
        s.chapter(
            (7, 30), (8, 10), "Breakfast and the last bag", "Weighing the luggage; what stays behind.",
            tags: ["travel"])
        s.chapter(
            (8, 30), (10, 45), "The drive and the check-in line",
            "Heavy traffic on the way to the airport, then a long line at check-in after the kiosks went down. Bags were tagged by hand at the counter, and there was just enough time left to clear security and reach the gate.",
            tags: ["travel"], people: ["Priya"], followUps: [("Send Priya the workshop agenda", false)])
        s.gap(.paused, (10, 45), (11, 30), pausedBy: .you)
        s.chapter(
            (11, 30), (12, 10), "At the gate", "Boarding delayed; a call with Dana about the slides.", tags: ["travel", "work"])
        s.gap(.audioMissing, (12, 10), (15, 40), causes: [.watchBufferFull])
        s.chapter(
            (15, 40), (16, 20), "Landing and the taxi line", "The bag carousel, then finding the shuttle.",
            tags: ["travel"])
        s.gap(.noConversation, (16, 20), (17, 40), descriptor: "TV or video", openable: true)
        s.chapter(
            (19, 30), (20, 30), "Dinner near the hotel",
            "A quick meal near the airport hotel and a plan for the morning’s second flight.",
            tags: ["dining", "travel"])
        return s.page(
            brief: "Packing and the drive to the airport, a long check-in line, then the first flight. Dinner near the hotel after landing.",
            leading: .quiet, trailing: .quiet)
    }

    /// Round 3, left: today while recording.
    static func today() -> HistoryDayPage {
        var s = Script(todayKey, isToday: true)
        s.chapter(
            (8, 40), (9, 30), "Breakfast and the kitchen plans",
            "Which worktop to order and who fits the sink, over breakfast.",
            tags: ["apartment", "dining"], people: ["Dana"])
        s.chapter(
            (9, 45), (11, 10), "Contract paperwork with the fitter",
            "Going through the quote line by line and agreeing the start date.",
            tags: ["apartment"], followUps: [("Send the vendor a signed form", false)])
        s.live((11, 20), (11, 41))
        return s.page(
            brief: "Kitchen questions over breakfast, then the paperwork with the fitter. A start date is agreed.",
            briefUpdated: (11, 15), leading: .quiet, trailing: nil,
            liveLine: "they said the shop closes at noon on Saturdays, so we should go now")
    }

    /// Plan 5.8: transcribed, chapters not made yet. The day is cut into conversation-sized
    /// pieces, each led by its time and carrying the first words said in it — no titles (a
    /// conversation's title describes hours, not the piece).
    static func conversationsDay() -> HistoryDayPage {
        var s = Script("2026-09-21")
        s.piece((8, 5), (8, 40), "Okay, the overnight deploy finished, let me check the logs before anything else.")
        s.piece((9, 10), (9, 52), "The numbers from last night look right, but the battery graph has a gap around three.")
        s.piece((9, 52), (10, 30), "Can you pull up the live data again? I want to see it tick over once.")
        s.piece((10, 30), (10, 52), nil)
        // Quiet that carries a few seconds of lost audio: the loss is said, in amber.
        s.gap(.quiet, (10, 52), (11, 2), missingSeconds: 20)
        s.gap(.notRecording, (11, 30), (13, 40))
        s.piece((13, 40), (14, 25), "There are four thousand photos in here and half of them are screenshots.")
        s.gap(.noConversation, (14, 25), (15, 20), openable: true)
        // One genuinely long stretch: a two-and-a-half-hour testing session, drawn full height.
        s.piece(
            (15, 20), (17, 50), "Right, try it again with the watch off the charger.",
            missingMinutes: 3)
        s.piece((18, 5), (18, 30), "Should we order something or go out? I don't mind either.")
        s.piece(
            (20, 30), (21, 25), "Okay, who's starting? Youngest goes first, that's the rule.",
            followUps: [("Send Leo the show list", true), ("Clear out photo storage", true)])
        s.piece((21, 25), (22, 15), "You have to watch the second season, the first one is slow but it gets better.")
        s.piece((22, 15), (22, 45), "Send me that list before you forget.")
        return s.page(
            brief: "Live-data verification after the deploy, photo storage cleanup, then games and show recommendations.",
            leading: .notListening, trailing: .quiet, topics: .preparing)
    }

    /// Plan 5.8: recorded, not transcribed — dashed cards over the recorded stretches.
    static func notTranscribedDay() -> HistoryDayPage {
        var s = Script("2026-09-24")
        s.gap(.notTranscribedYet, (8, 0), (12, 30), openable: true)
        s.gap(.transcriptionFailed, (13, 0), (13, 20), failure: TranscriptionFailureKind.audioUnreadable.rawValue, openable: true)
        s.gap(.notTranscribedYet, (13, 20), (21, 50), openable: true)
        return s.page(brief: nil, leading: .quiet, trailing: .quiet)
    }

    /// A day that changes zone: morning coffee at the gate in one zone, a long
    /// stretch with the watch off, then the evening in another, whose hour labels are
    /// read in the new zone. The flight is also the demo's tall gap, for checking that its label
    /// stays pinned on screen while it scrolls past.
    static func zoneChangeDay() -> HistoryDayPage {
        var s = Script("2026-09-18", zoneID: "Europe/Lisbon")
        s.chapter(
            (7, 10), (8, 0), "Coffee at the gate", "The second leg, and the workshop agenda one more time.",
            tags: ["travel", "work"])
        // The flight: the watch was off, so nothing was recording — not quiet, not lost.
        s.gap(.notRecording, (8, 0), (17, 30))
        s.zoneChange(at: (17, 30), to: "Europe/Athens")
        s.chapter(
            (17, 30), (18, 40), "Finding the hotel",
            "The driver took the long way around; the front desk had the room ready.",
            tags: ["travel"])
        s.chapter(
            (19, 0), (20, 10), "Dinner downstairs",
            "Noodles at the place on the corner, and a list of what the talk still needs.",
            tags: ["dining", "work"], followUps: [("Print the workshop handouts", false)])
        s.chapter(
            (20, 30), (21, 30), "Unpacking", "Clothes away, the slides checked, an early night.",
            tags: ["travel"])
        return s.page(
            brief: "The second leg of the flight, then the hotel and dinner on the corner.",
            leading: .notListening, trailing: .quiet)
    }

    /// A night as the phone draws one, piece for piece: thirteen labelled
    /// status blocks between a card ending 10:13 PM and the next at 12:33 AM, then a run of
    /// seconds-long pieces after 12:47. The two pairs he circled are here too: quiet then "no
    /// conversation", both carrying loss, and two "Audio missing" blocks back to back. They are
    /// moved earlier and later in the evening so all of it fits one day. Plus a stretch of paused
    /// and quiet long enough to name both, for the two-class label.
    static func nightDay() -> HistoryDayPage {
        var s = Script("2026-09-19")
        s.chapter((18, 0), (18, 40), "Dinner and the week ahead",
                  "What is left for the workshop, and who presents on Monday.", tags: ["work"])
        // Paused 1 hr 10 min, then quiet 50 min: both named.
        s.gap(.paused, (18, 40), (19, 50), pausedBy: .you)
        s.gap(.quiet, (19, 50), (20, 40))
        s.chapter((20, 40), (21, 2), "Calling the kitchen fitter", "The quote and the start date.",
                  tags: ["apartment"])
        // Circled: "Quiet · 7 min · under 1 min missing" over "No conversation · 18 min · under 1 min missing".
        s.gap(.quiet, (21, 2), (21, 9), missingSeconds: 20)
        s.gap(.noConversation, (21, 9), (21, 27), openable: true, missingSeconds: 20)
        s.chapter((21, 27), (22, 13), "Planning the drive to the venue",
                  "Which route, when to leave, and whether the projector fits in the trunk.", tags: ["travel"])
        // The thirteen blocks.
        s.gapS(.paused, (22, 13, 0), (22, 51, 0), pausedBy: .watchPowerSave)
        s.gapS(.quiet, (22, 51, 0), (22, 58, 0), missingSeconds: 90)
        s.gapS(.notRecording, (22, 58, 0), (22, 58, 20))
        s.gapS(.audioMissing, (22, 58, 20), (22, 58, 50), causes: [.watchBufferFull])
        s.gapS(.notRecording, (22, 58, 50), (22, 59, 10))
        s.gapS(.audioMissing, (22, 59, 10), (22, 59, 40), causes: [.watchBufferFull])
        s.gapS(.notRecording, (22, 59, 40), (23, 0, 0))
        s.gapS(.quiet, (23, 0, 0), (23, 0, 40), missingSeconds: 15)
        s.gapS(.paused, (23, 0, 40), (23, 9, 40), pausedBy: .watchPowerSave)
        s.gapS(.notRecording, (23, 14, 0), (23, 14, 20))
        s.gapS(.paused, (23, 14, 20), (23, 56, 20), pausedBy: .watchPowerSave)
        s.gapS(.notRecording, (24, 2, 0), (24, 2, 20))
        s.gapS(.paused, (24, 2, 20), (24, 16, 20), pausedBy: .watchPowerSave)
        s.piece((24, 33), (24, 47), "Are you still up? I can't find the charger.")
        // After it: quiet with loss, the circled pair of "Audio missing" blocks, then seconds.
        s.gapS(.quiet, (24, 47, 0), (24, 50, 0), missingSeconds: 60)
        s.gapS(.audioMissing, (24, 50, 0), (25, 0, 0), causes: [.watchBufferFull])
        s.gapS(.audioMissing, (25, 0, 0), (25, 21, 0), causes: [.connectionReset])
        s.gapS(.notRecording, (25, 21, 0), (25, 21, 20))
        s.gapS(.audioMissing, (25, 21, 20), (25, 21, 40), causes: [.watchBufferFull])
        s.gapS(.notRecording, (25, 21, 40), (25, 22, 0))
        s.gapS(.audioMissing, (25, 22, 0), (25, 22, 20), causes: [.watchBufferFull])
        s.gapS(.notRecording, (25, 22, 20), (25, 22, 40))
        s.gapS(.quiet, (25, 22, 40), (25, 23, 0), missingSeconds: 10)
        return s.page(
            brief: "Dinner, the kitchen fitter and the drive to plan; then a long night with the watch resting.",
            leading: .quiet, trailing: .notListening)
    }

    /// The card title of a filler day the demo has no script for. Not a real title, so the
    /// no-briefs world never heads a week with it.
    static let fillerTitle = "A morning conversation"

    /// Filler days in September's first two weeks carry the conversations those weeks were
    /// about (the month page's rows), so the no-briefs month heads them the way the live source
    /// would — from a conversation title — rather than with nothing.
    static func plainTitle(_ dateKey: String) -> String {
        switch dateKey {
        case "2026-09-01", "2026-09-03", "2026-09-05": return "Getting the watch streaming"
        case "2026-09-02", "2026-09-04": return "First transcripts through"
        case "2026-09-06", "2026-09-08", "2026-09-10", "2026-09-12": return "Battery and speed fixes"
        case "2026-09-07", "2026-09-09", "2026-09-11": return "Dentist appointment"
        default: return fillerTitle
        }
    }

    /// Any other recorded day in the demo range: one card from the week's headline.
    static func plainDay(_ dateKey: String) -> HistoryDayPage {
        let row = (weekRows + travelWeekRows).first { $0.dateKey == dateKey }
        var s = Script(dateKey)
        s.chapter(
            (9, 0), (10, 30), row?.headline ?? plainTitle(dateKey), row?.summary,
            tags: row?.tags ?? [])
        return s.page(brief: row?.summary, leading: .quiet, trailing: .quiet)
    }

    static func nothingRecorded(_ dateKey: String) -> HistoryDayPage {
        HistoryDayPage(
            day: HistoryDay(
                dateKey: dateKey, zoneID: TimeZone.current.identifier, isToday: dateKey == todayKey,
                hasRecordings: false, leadingEdge: nil, items: [], trailingEdge: nil),
            brief: nil, followUpTotal: 0, followUpOpen: 0, topics: .ready)
    }

    // MARK: - Week (round 5)

    static let weekRows: [HistoryWeekRow] = [
        row("2026-09-20", "Site tour and a long debugging day",
            "Phone testing, a larger kitchen showroom, lunch with Sam, then crash fixes for older dates.",
            ["apartment", "work", "dining"],
            [("Fix the crash on older dates", true), ("Email the vendor about the larger room", false),
             ("Book the tile fitter", true), ("Send the build to Sam", true), ("Check the paint samples", true)]),
        row("2026-09-21", "Deploy checks and board games",
            "Live-data verification after the deploy, photo storage cleanup, then games and show recommendations.",
            ["work", "photos", "games"],
            [("Clear out photo storage", true), ("Send Leo the show list", true)]),
        row("2026-09-22", "Kitchen samples and vendor invoices",
            "Sprint planning over coffee, invoice details with the vendor, a rainy visit and a budget review.",
            ["apartment", "budget", "travel"],
            [("Ask Priya for the fitter’s number", true), ("Send the order number", false),
             ("Confirm the billing contact", true), ("Reply to the vendor by Friday", false)]),
        row("2026-09-23", "Launch content readiness",
            "Approvals for the launch material through most of the day, supplies and errands around it.",
            ["launch", "errands"], [("Get final sign-off on the slides", false)]),
        HistoryWeekRow(dateKey: "2026-09-24", state: .notTranscribedYet(waitingMs: 13 * 3_600_000)),
        row("2026-09-25", "Showroom visit and the kitchen quote",
            "A morning at the showroom, the fitter’s quote after lunch, a quiet evening in.",
            ["apartment", "budget"],
            [("Pick the worktop color", true), ("Return the signed quote", false),
             ("Book the fitter for next week", false)]),
        row("2026-09-26", nil, "Recording now. Contract paperwork with the vendor so far.", ["apartment"],
            [("Send the vendor a signed form", false)], state: .today(isLive: true)),
    ]

    /// The week of the workshop trip (round 4's travel week).
    static let travelWeekRows: [HistoryWeekRow] = [
        row("2026-09-13", "Workshop slides and packing lists",
            "Finishing the slides and sorting what to pack, then dinner with Leo and Dana.", ["travel", "work"],
            [("Book the airport taxi", true), ("Return the library books", true)]),
        HistoryWeekRow(dateKey: "2026-09-14", state: .nothingRecorded),
        row("2026-09-15", "Rehearsal and a last dinner out",
            "A run-through of the talk by noon; the kitchen measurements; dinner at the corner place.",
            ["work", "apartment"], [("Send the fitter the kitchen measurements", false)]),
        row("2026-09-16", "Dentist checkup and a quiet evening",
            "The dentist in the morning, then packing the carry-on.", ["errands", "travel"], []),
        row("2026-09-17", "Check-in line and the flight",
            "Packing and the drive to the airport, a long check-in line, then the first flight.",
            ["travel"], [("Send Priya the workshop agenda", false)]),
        row("2026-09-18", "Arrival and the workshop hotel",
            "The second leg of the flight, then the hotel and dinner on the corner.",
            ["travel", "work"], [("Print the workshop handouts", false)]),
        row("2026-09-19", "First workshop day",
            "Coffee, the first sessions and a walk to the market; the drive to plan for tomorrow.",
            ["work", "travel"], [("Send Sam the session notes", false), ("Find a print shop", true)]),
    ]

    static func week(firstDateKey: String, lastDateKey: String) -> HistoryPeriod<HistoryWeekRow> {
        if firstDateKey == "2026-09-20" {
            return HistoryPeriod(
                firstDateKey: firstDateKey, lastDateKey: lastDateKey,
                brief: HistoryBrief(
                    text: "The kitchen renovation took most of the week: two showroom visits, a budget review and the invoices behind them. Launch approvals filled Wednesday, and a showroom visit on Friday settled the kitchen quote. Game night twice.",
                    headline: "Kitchen renovation and launch prep",
                    lineSummary: "Two showroom visits, a budget review, and launch approvals midweek.",
                    updatedAtMs: 0),
                rows: weekRows, followUpTotal: 16, followUpOpen: 7)
        }
        if firstDateKey == "2026-09-13" {
            return HistoryPeriod(
                firstDateKey: firstDateKey, lastDateKey: lastDateKey,
                brief: HistoryBrief(
                    text: "Workshop slides and packing, a rehearsal and a last dinner out, then a long check-in line and two flights. The first days away went on the workshop, the hotel and the way to the venue.",
                    headline: "The workshop trip",
                    lineSummary: "Packing and the flights, then the first workshop days.",
                    updatedAtMs: 0),
                rows: travelWeekRows, followUpTotal: 21, followUpOpen: 4)
        }
        // Other weeks: a row per recorded day, not past today.
        let rows = HistoryCalendar.days(in: firstDateKey...lastDateKey)
            .filter { $0 <= todayKey }
            .map { key in
                recordedDays.contains(key)
                    ? HistoryWeekRow(dateKey: key, state: .recorded, headline: "A day of recordings")
                    : HistoryWeekRow(dateKey: key, state: .nothingRecorded)
            }
        return HistoryPeriod(firstDateKey: firstDateKey, lastDateKey: lastDateKey, rows: rows)
    }

    /// The week before the brief pass has reached it (`-historyNoBriefs`), by the live source's
    /// own rules (`HistoryPeriodSources`): each day headed by its most-talked titled
    /// conversation — a day of untitled stretches by nothing — with its recap whole under it,
    /// and no week brief.
    static func weekWithoutBriefs(firstDateKey: String, lastDateKey: String) -> HistoryPeriod<HistoryWeekRow> {
        var period = week(firstDateKey: firstDateKey, lastDateKey: lastDateKey)
        period.brief = nil
        period.rows = period.rows.map { row in
            switch row.state {
            case .recorded, .today:
                var fallback = row
                let page = page(for: row.dateKey)
                fallback.headline = longestTitledChapter(page)?.title
                fallback.summary = page.brief?.text ?? row.summary
                return fallback
            case .nothingRecorded, .notTranscribedYet:
                return row
            }
        }
        return period
    }

    /// The month before its briefs: each week headed by its two most-talked days' headlines
    /// (the first alone when two would not fit a line), no summary, no month brief.
    static func monthWithoutBriefs(containing dateKey: String) -> HistoryPeriod<HistoryMonthRow> {
        var period = month(containing: dateKey)
        period.brief = nil
        period.rows = period.rows.map { row in
            var fallback = row
            let days = HistoryCalendar.days(in: row.firstDateKey...row.lastDateKey)
                .filter { $0 <= todayKey && recordedDays.contains($0) }
                .compactMap { key -> (title: String, ms: Int64)? in
                    guard let block = longestTitledChapter(page(for: key)), let title = block.title,
                        title != fillerTitle
                    else { return nil }
                    return (title, talkMs(page(for: key)))
                }
                .sorted { $0.ms > $1.ms }
            var headlines: [String] = []
            for day in days where !headlines.contains(where: { $0.lowercased() == day.title.lowercased() }) {
                headlines.append(day.title)
                if headlines.count == HistoryPeriodSources.weekHeadlineDays { break }
            }
            let joined = headlines.joined(separator: HistoryPeriodSources.separator)
            fallback.headline = headlines.isEmpty
                ? nil : joined.count <= HistoryPeriodSources.joinedHeadlineCharacters ? joined : headlines.first
            fallback.summary = nil
            return fallback
        }
        return period
    }

    private static func chapters(_ page: HistoryDayPage) -> [HistoryChapterBlock] {
        page.day.items.compactMap { item in
            if case .chapter(let block) = item { return block } else { return nil }
        }
    }

    private static func longestTitledChapter(_ page: HistoryDayPage) -> HistoryChapterBlock? {
        chapters(page).filter { $0.title != nil }.max { $0.endMs - $0.startMs < $1.endMs - $1.startMs }
    }

    private static func talkMs(_ page: HistoryDayPage) -> Int64 {
        chapters(page).reduce(0) { $0 + ($1.endMs - $1.startMs) }
    }

    private static func row(
        _ key: String, _ headline: String?, _ summary: String, _ tags: [String],
        _ followUps: [(String, Bool)], state: HistoryDayState = .recorded
    ) -> HistoryWeekRow {
        let ordered = Script.ordered(followUps, prefix: key)
        return HistoryWeekRow(
            dateKey: key, state: state, headline: headline, summary: summary, tags: tags,
            followUps: Array(ordered.prefix(2)), moreFollowUps: max(0, ordered.count - 2))
    }

    // MARK: - Month (round 4)

    static func month(containing dateKey: String) -> HistoryPeriod<HistoryMonthRow> {
        let range = HistoryCalendar.month(containing: dateKey)
        guard range.lowerBound == "2026-09-01" else {
            return HistoryPeriod(firstDateKey: range.lowerBound, lastDateKey: range.upperBound, rows: [])
        }
        let rows: [HistoryMonthRow] = [
            HistoryMonthRow(
                firstDateKey: "2026-08-30", lastDateKey: "2026-09-05", isCurrentWeek: false,
                hasRecordings: true, headline: "Setting up the watch",
                summary: "Getting the watch streaming and the first transcripts through.",
                tags: ["setup", "work"], followUpTotal: 6, followUpOpen: 0),
            HistoryMonthRow(
                firstDateKey: "2026-09-06", lastDateKey: "2026-09-12", isCurrentWeek: false,
                hasRecordings: true, headline: "Performance work and a dentist visit",
                summary: "Battery and speed fixes, and a dentist appointment that moved twice.",
                tags: ["work", "errands", "family"], followUpTotal: 18, followUpOpen: 2),
            HistoryMonthRow(
                firstDateKey: "2026-09-13", lastDateKey: "2026-09-19", isCurrentWeek: false,
                hasRecordings: true, headline: "The workshop trip",
                summary: "Packing and the flights, then the first workshop days.",
                tags: ["travel", "work", "apartment"], followUpTotal: 21, followUpOpen: 4),
            HistoryMonthRow(
                firstDateKey: "2026-09-20", lastDateKey: "2026-09-26", isCurrentWeek: true,
                hasRecordings: true, headline: "Kitchen renovation and launch prep",
                summary: "Two showroom visits, a budget review, and launch approvals midweek.",
                tags: ["apartment", "budget", "launch"], followUpTotal: 16, followUpOpen: 11),
        ]
        return HistoryPeriod(
            firstDateKey: range.lowerBound, lastDateKey: range.upperBound,
            brief: HistoryBrief(
                text: "The kitchen renovation: samples and a workshop trip mid-month, then the showroom visits and the invoices behind them. App performance work ran through the first two weeks, and launch approvals through the last.",
                headline: "Kitchen renovation and a workshop", lineSummary: "Performance work, a workshop trip, then the kitchen.",
                updatedAtMs: 0),
            tagCounts: [
                HistoryTagCount(name: "apartment", days: 14), HistoryTagCount(name: "travel", days: 9),
                HistoryTagCount(name: "budget", days: 6), HistoryTagCount(name: "family", days: 5),
            ],
            rows: rows, followUpTotal: 61, followUpOpen: 17)
    }
}

// MARK: - Building a demo day

/// Writes a day in wall-clock times, filling the time between items with quiet the way the day
/// builder does, so a script reads like the mockup it copies.
private struct Script {
    typealias Clock = (Int, Int)

    let dateKey: String
    let zoneID: String
    let isToday: Bool
    var currentZoneID: String
    var items: [HistoryItem] = []
    var cursor: Int64?
    var followUps: [HistoryFollowUpLine] = []
    var serial = 0

    init(_ dateKey: String, isToday: Bool = false, zoneID: String = TimeZone.current.identifier) {
        self.dateKey = dateKey
        self.zoneID = zoneID
        self.isToday = isToday
        self.currentZoneID = zoneID
    }

    /// A wall-clock time on the day, in the zone the day started in. Hours past 24 run into
    /// the early morning the logical day still owns.
    func ms(_ clock: Clock) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneID) ?? .current
        let noon = HistoryFormat.noon(of: dateKey, zone: calendar.timeZone)
        let midnight = calendar.startOfDay(for: noon)
        let date = calendar.date(byAdding: .minute, value: clock.0 * 60 + clock.1, to: midnight)!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private mutating func nextID(_ kind: String) -> String {
        serial += 1
        return "\(dateKey)-\(kind)-\(serial)"
    }

    /// Quiet from the last item to `start`, as the day builder fills it.
    private mutating func fill(to start: Int64) {
        if let cursor, start > cursor {
            items.append(.gap(HistoryGap(
                id: nextID("quiet"), kind: .quiet, startMs: cursor, endMs: start, zoneID: currentZoneID)))
        }
    }

    static func ordered(_ lines: [(String, Bool)], prefix: String) -> [HistoryFollowUpLine] {
        let all = lines.enumerated().map { index, line in
            HistoryFollowUpLine(id: "\(prefix)-fu-\(index)", text: line.0, done: line.1)
        }
        return all.filter { !$0.done } + all.filter(\.done)
    }

    mutating func chapter(
        _ from: Clock, _ to: Clock, _ title: String?, _ summary: String?, tags: [String] = [],
        people: [String] = [], missingMinutes: Int = 0, followUps: [(String, Bool)] = [],
        source: HistoryChapterBlock.Source = .chapter
    ) {
        let start = ms(from), end = ms(to)
        fill(to: start)
        let id = nextID("chapter")
        let lines = Self.ordered(followUps, prefix: id)
        self.followUps += lines
        items.append(.chapter(HistoryChapterBlock(
            id: id, startMs: start, endMs: end, zoneID: currentZoneID, source: source, title: title,
            summary: summary, tags: tags, people: people, missingMs: Int64(missingMinutes) * 60_000,
            followUps: lines)))
        cursor = end
    }

    /// A piece of conversation no chapter covers: no title, its first words as the snippet.
    mutating func piece(
        _ from: Clock, _ to: Clock, _ snippet: String?, missingMinutes: Int = 0,
        followUps: [(String, Bool)] = []
    ) {
        let start = ms(from), end = ms(to)
        fill(to: start)
        let id = nextID("piece")
        let lines = Self.ordered(followUps, prefix: id)
        self.followUps += lines
        items.append(.chapter(HistoryChapterBlock(
            id: id, startMs: start, endMs: end, zoneID: currentZoneID, source: .conversation,
            title: nil, summary: nil, snippet: snippet, missingMs: Int64(missingMinutes) * 60_000,
            followUps: lines)))
        cursor = end
    }

    mutating func gap(
        _ kind: HistoryGap.Kind, _ from: Clock, _ to: Clock, pausedBy: HistoryPauseActor? = nil,
        causes: [HistoryLossCause] = [], descriptor: String? = nil, failure: String? = nil,
        openable: Bool = false, missingSeconds: Int = 0
    ) {
        let start = ms(from), end = ms(to)
        fill(to: start)
        var gap = HistoryGap(
            id: nextID("gap"), kind: kind, startMs: start, endMs: end, zoneID: currentZoneID,
            pausedBy: pausedBy, lossCauses: causes, descriptor: descriptor, failureReason: failure,
            isOpenable: openable)
        gap.missingMs = Int64(missingSeconds) * 1000
        items.append(.gap(gap))
        cursor = end
    }

    /// A gap given to the second (`gap` works in whole minutes).
    mutating func gapS(
        _ kind: HistoryGap.Kind, _ from: (Int, Int, Int), _ to: (Int, Int, Int),
        pausedBy: HistoryPauseActor? = nil, causes: [HistoryLossCause] = [],
        missingSeconds: Int = 0
    ) {
        let start = ms((from.0, from.1)) + Int64(from.2) * 1000
        let end = ms((to.0, to.1)) + Int64(to.2) * 1000
        fill(to: start)
        var gap = HistoryGap(
            id: nextID("gap"), kind: kind, startMs: start, endMs: end, zoneID: currentZoneID,
            pausedBy: pausedBy, lossCauses: causes)
        gap.missingMs = Int64(missingSeconds) * 1000
        items.append(.gap(gap))
        cursor = end
    }

    mutating func live(_ from: Clock, _ to: Clock) {
        let start = ms(from), end = ms(to)
        fill(to: start)
        items.append(.live(HistoryLiveBlock(startMs: start, endMs: end, zoneID: currentZoneID)))
        cursor = end
    }

    mutating func zoneChange(at clock: Clock, to zone: String) {
        let at = ms(clock)
        fill(to: at)
        currentZoneID = zone
        items.append(.zoneChange(HistoryZoneChange(atMs: at, zoneID: zone)))
        cursor = at
    }

    func page(
        brief: String?, briefUpdated: Clock? = nil, leading: HistoryEdge.Kind?,
        trailing: HistoryEdge.Kind?, topics: HistoryTopicsState = .ready, liveLine: String? = nil
    ) -> HistoryDayPage {
        let first = items.first?.startMs ?? ms((5, 0))
        let last = items.last?.endMs ?? ms((5, 0))
        let day = HistoryDay(
            dateKey: dateKey, zoneID: zoneID, isToday: isToday, hasRecordings: true,
            leadingEdge: leading.map { HistoryEdge(atMs: first, kind: $0) },
            items: items,
            trailingEdge: isToday ? nil : trailing.map { HistoryEdge(atMs: last, kind: $0) })
        return HistoryDayPage(
            day: day,
            brief: brief.map { HistoryBrief(text: $0, updatedAtMs: briefUpdated.map(ms) ?? 0) },
            followUpTotal: followUps.count, followUpOpen: followUps.filter { !$0.done }.count,
            topics: topics, liveLine: liveLine)
    }
}
