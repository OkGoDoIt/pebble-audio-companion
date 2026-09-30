import AppDB
import CoreGraphics
import Foundation
import SegmentStore
import StatusUI
import Testing
import Transcription

// What History says (plan 5.1, 5.3, 5.9): its times, titles, gap labels and spoken labels. The
// mockups' exact strings are the expectations, with the no-break space before a meridiem read
// as the space it draws as.

@Suite("History formatting and labels")
struct HistoryFormatTests {
    private let us = Locale(identifier: "en_US")
    private let newYork = TimeZone(identifier: "America/New_York")!

    /// Epoch ms of a wall-clock time on 2026-09-22 in New York.
    private func at(_ hour: Int, _ minute: Int, day: Int = 22) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: Times and durations

    @Test func aRangeWritesASharedMeridiemOnce() {
        #expect(plain(HistoryFormat.timeRange(at(9, 5), at(10, 15), zone: newYork, locale: us)) == "9:05 – 10:15 AM")
        #expect(plain(HistoryFormat.timeRange(at(14, 0), at(14, 56), zone: newYork, locale: us)) == "2:00 – 2:56 PM")
    }

    @Test func aRangeAcrossNoonWritesBothMeridiems() {
        #expect(plain(HistoryFormat.timeRange(at(11, 40), at(12, 10), zone: newYork, locale: us)) == "11:40 AM – 12:10 PM")
        #expect(plain(HistoryFormat.timeRange(at(11, 30), at(12, 55), zone: newYork, locale: us)) == "11:30 AM – 12:55 PM")
    }

    @Test func aRangeInsideOneMinuteIsThatMinute() {
        #expect(plain(HistoryFormat.timeRange(at(17, 31), at(17, 31) + 40_000, zone: newYork, locale: us)) == "5:31 PM")
    }

    @Test func aMeridiemNeverWrapsAwayFromItsTime() {
        let range = HistoryFormat.timeRange(at(9, 5), at(10, 15), zone: newYork, locale: us)
        #expect(range.hasSuffix("10:15\u{00A0}AM"))
        #expect(!range.contains("\u{202F}") && !range.contains("\u{2009}"))
    }

    @Test func aRangeIsReadInTheZoneItIsGiven() {
        let jakarta = TimeZone(identifier: "Asia/Jakarta")!
        // 9:05 AM New York is 8:05 PM in Jakarta.
        #expect(plain(HistoryFormat.timeRange(at(9, 5), at(10, 15), zone: jakarta, locale: us)) == "8:05 – 9:15 PM")
    }

    @Test func aTwentyFourHourLocaleKeepsItsOwnTimes() {
        let gb = Locale(identifier: "en_GB")
        let range = HistoryFormat.timeRange(at(9, 5), at(14, 15), zone: newYork, locale: gb)
        #expect(range.contains("09:05") && range.contains("14:15"))
        #expect(!range.contains("AM") && !range.contains("PM"))
    }

    @Test func singleTimesAndSpokenRanges() {
        #expect(plain(HistoryFormat.time(at(11, 20), zone: newYork, locale: us)) == "11:20 AM")
        #expect(plain(HistoryFormat.spokenTimeRange(at(10, 15), at(11, 20), zone: newYork, locale: us)) == "10:15 to 11:20 AM")
    }

    @Test func durationsReadLikeTheMockups() {
        #expect(HistoryFormat.duration(ms: 70 * 60_000) == "1 hr 10 min")
        #expect(HistoryFormat.duration(ms: 48 * 60_000) == "48 min")
        #expect(HistoryFormat.duration(ms: 120 * 60_000) == "2 hr")
        #expect(HistoryFormat.duration(ms: 210 * 60_000) == "3 hr 30 min")
        #expect(HistoryFormat.duration(ms: 20_000) == "under 1 min")
        #expect(HistoryFormat.duration(ms: 40_000) == "1 min")
        #expect(HistoryFormat.spokenDuration(ms: 65 * 60_000) == "1 hour 5 minutes")
        #expect(HistoryFormat.spokenDuration(ms: 60 * 60_000) == "1 hour")
        #expect(HistoryFormat.spokenDuration(ms: 1 * 60_000) == "1 minute")
    }

    // MARK: Titles

    @Test func aDayIsTitledByItsWeekdayAndDate() {
        let title = HistoryFormat.dayTitle("2026-09-22", todayKey: "2026-09-26", zone: newYork, locale: us)
        #expect(title.title == "Tuesday")
        #expect(title.subtitle == "September 22")
    }

    @Test func todayIsTitledTodayWithItsFullDate() {
        let title = HistoryFormat.dayTitle("2026-09-26", todayKey: "2026-09-26", zone: newYork, locale: us)
        #expect(title.title == "Today")
        #expect(title.subtitle == "Saturday, September 26")
    }

    @Test func yesterdayIsItsWeekdayNotYesterday() {
        let title = HistoryFormat.dayTitle("2026-09-25", todayKey: "2026-09-26", zone: newYork, locale: us)
        #expect(title.title == "Friday")
    }

    @Test func anotherYearAddsTheYear() {
        let title = HistoryFormat.dayTitle("2025-09-22", todayKey: "2026-09-26", zone: newYork, locale: us)
        #expect(title.title == "Monday")
        #expect(title.subtitle == "September 22, 2025")
    }

    @Test func aDateKeyIsItsOwnDateInAnyZone() {
        // The key is already the logical date; far-east and far-west zones must agree on it.
        for zone in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "Asia/Jakarta"] {
            let title = HistoryFormat.dayTitle("2026-09-22", todayKey: "2026-09-26", zone: TimeZone(identifier: zone)!, locale: us)
            #expect(title.subtitle == "September 22", "\(zone)")
        }
    }

    @Test func weekTitles() {
        #expect(HistoryFormat.weekTitle(firstDateKey: "2026-09-20", lastDateKey: "2026-09-26", todayKey: "2026-09-26", locale: us) == "Sep 20 – 26")
        #expect(HistoryFormat.weekTitle(firstDateKey: "2026-09-27", lastDateKey: "2026-10-03", todayKey: "2026-09-26", locale: us) == "Sep 27 – Oct 3")
        let old = HistoryFormat.weekTitle(firstDateKey: "2025-12-28", lastDateKey: "2026-01-03", todayKey: "2026-09-26", locale: us)
        #expect(old.contains("2025") && old.contains("2026"))
    }

    @Test func monthTitles() {
        #expect(HistoryFormat.monthTitle("2026-09-22", todayKey: "2026-09-26", locale: us) == "September")
        #expect(HistoryFormat.monthTitle("2025-09-22", todayKey: "2026-09-26", locale: us) == "September 2025")
    }

    @Test func weekRowDateColumn() {
        let column = HistoryFormat.weekdayAndNumber("2026-09-22", locale: us)
        #expect(column.weekday == "Tue")
        #expect(column.number == "22")
    }

    // MARK: Chapter cards

    private func block(
        _ start: Int64, _ end: Int64, missing: Int64 = 0, approximate: Bool = false,
        followUps: [HistoryFollowUpLine] = []
    ) -> HistoryChapterBlock {
        HistoryChapterBlock(
            id: "c", startMs: start, endMs: end, zoneID: newYork.identifier, source: .chapter,
            title: "Invoice details with the vendor", summary: "Order numbers and the contact.",
            tags: ["banking"], people: ["Mira"], missingMs: missing, timesApproximate: approximate,
            followUps: followUps)
    }

    @Test func aCardsTimeLineCarriesItsLoss() {
        let line = HistoryLabels.chapterTimeLine(block(at(14, 0), at(14, 56), missing: 4 * 60_000), locale: us)
        #expect(plain(line.main) == "2:00 – 2:56 PM · 56 min")
        #expect(line.missing == "4 min missing")
        #expect(HistoryLabels.chapterTimeLine(block(at(14, 0), at(14, 56)), locale: us).missing == nil)
    }

    @Test func approximateTimesSayAbout() {
        let line = HistoryLabels.chapterTimeLine(block(at(14, 0), at(14, 56), approximate: true), locale: us)
        #expect(plain(line.main) == "about 2:00 – 2:56 PM · 56 min")
    }

    @Test func anUntitledCardLeadsWithItsFirstWordsAndKeepsTheTimeGray() {
        var untitled = block(at(15, 20), at(16, 5), missing: 3 * 60_000)
        untitled.source = .conversation
        untitled.title = nil
        untitled.summary = nil
        untitled.snippet = "Right, try it again with the watch off the charger."
        #expect(HistoryLabels.isUntitled(untitled))
        #expect(HistoryLabels.heading(untitled) == .quote("Right, try it again with the watch off the charger."))
        // The same gray time line as a titled card: range, duration, amber loss.
        let line = HistoryLabels.chapterTimeLine(untitled, locale: us)
        #expect(plain(line.main) == "3:20 – 4:05 PM · 45 min")
        #expect(line.missing == "3 min missing")
        #expect(plain(HistoryLabels.compactTimeLine(untitled, locale: us).main) == "3:20 PM · 45 min")
        // Named elsewhere by its words, never by its time or a placeholder "Conversation".
        #expect(HistoryLabels.chapterTitle(untitled, locale: us) == "“Right, try it again with the watch off the charger.”")
        untitled.title = ""
        #expect(HistoryLabels.isUntitled(untitled))
    }

    @Test func withNoWordsTheTitlePositionSaysNotSummarisedYet() {
        var bare = block(at(15, 20), at(16, 5))
        bare.title = nil
        bare.snippet = "   "
        #expect(HistoryLabels.heading(bare) == .placeholder)
        #expect(HistoryLabels.chapterTitle(bare, locale: us) == "Not summarised yet")
        #expect(HistoryLabels.heading(block(at(9, 0), at(10, 0))) == .title("Invoice details with the vendor"))
    }

    @Test func anUntitledCardReadsItsFirstWordsThenItsTime() {
        var untitled = block(at(15, 20), at(16, 5))
        untitled.source = .conversation
        untitled.title = nil
        untitled.summary = nil
        untitled.tags = []
        untitled.people = []
        untitled.snippet = "Right, try it again."
        let label = plain(HistoryLabels.chapterAccessibilityLabel(untitled, locale: us))
        #expect(label == "First words: Right, try it again. 3:20 to 4:05 PM, 45 minutes")
        untitled.snippet = nil
        #expect(plain(HistoryLabels.chapterAccessibilityLabel(untitled, locale: us)) == "Not summarised yet. 3:20 to 4:05 PM, 45 minutes")
    }

    @Test func theLiveCardsTimeLine() {
        let live = HistoryLiveBlock(startMs: at(11, 20), endMs: at(11, 41), zoneID: newYork.identifier)
        #expect(plain(HistoryLabels.liveTimeLine(live, locale: us)) == "11:20 AM · 21 min so far")
    }

    // MARK: Gaps

    private func gap(
        _ kind: HistoryGap.Kind, _ start: Int64, _ end: Int64, pausedBy: HistoryPauseActor? = nil,
        causes: [HistoryLossCause] = [], descriptor: String? = nil,
        deletedBy: HistoryDeletionCause? = nil, failure: String? = nil
    ) -> HistoryGap {
        HistoryGap(
            id: "g", kind: kind, startMs: start, endMs: end, zoneID: newYork.identifier,
            pausedBy: pausedBy, lossCauses: causes, descriptor: descriptor, deletedBy: deletedBy,
            failureReason: failure)
    }

    @Test func aShortQuietIsBare() {
        let text = HistoryLabels.gapText(gap(.quiet, at(10, 0), at(10, 20)), locale: us)
        #expect(text.title == nil && text.detail == nil)
        #expect(!HistoryLabels.isLabelled(gap(.quiet, at(10, 0), at(10, 20))))
    }

    @Test func aQuietOfHalfAnHourIsNamedAndPastNinetyMinutesDated() {
        let hour = HistoryLabels.gapText(gap(.quiet, at(12, 55), at(14, 0)), locale: us)
        #expect(hour.title == "Quiet · 1 hr 5 min")
        #expect(hour.detail == nil)
        let long = HistoryLabels.gapText(gap(.quiet, at(17, 40), at(19, 30)), locale: us)
        #expect(long.title == "Quiet · 1 hr 50 min")
        #expect(plain(long.detail ?? "") == "5:40 – 7:30 PM")
    }

    @Test func aPauseSaysWhoPaused() {
        let text = HistoryLabels.gapText(gap(.paused, at(11, 0), at(11, 30), pausedBy: .you), locale: us)
        #expect(text.title == "Paused · 30 min")
        #expect(plain(text.detail ?? "") == "11:00 – 11:30 AM · you paused capture")
        let power = HistoryLabels.gapText(gap(.paused, at(11, 0), at(11, 30), pausedBy: .watchPowerSave), locale: us)
        #expect(power.detail?.hasSuffix("watch was saving power") == true)
    }

    @Test func missingAudioNamesOnlyARecordedCause() {
        let caused = HistoryLabels.gapText(gap(.audioMissing, at(20, 38), at(21, 30), causes: [.watchBufferFull]), locale: us)
        #expect(caused.title == "Audio missing · 52 min")
        #expect(plain(caused.detail ?? "") == "8:38 – 9:30 PM · watch buffer filled while disconnected")
        let unknown = HistoryLabels.gapText(gap(.audioMissing, at(20, 38), at(21, 30)), locale: us)
        #expect(plain(unknown.detail ?? "") == "8:38 – 9:30 PM")
    }

    @Test func everyLossCauseReadsAsTheRestOfTheAppReadsIt() {
        func watch(_ raw: Int) -> String {
            gapDescription(GapMeta(firstMissingSequence: 0, missingFrameCount: 0, firstMissingSampleIndex: 0, origin: GapMeta.originWatch, reasonRaw: raw))
        }
        #expect(Copy.History.lossCause(.watchBufferFull) == watch(1))
        #expect(Copy.History.lossCause(.watchDictation) == watch(2))
        #expect(Copy.History.lossCause(.stoppedOnWatch) == watch(3))
        #expect(Copy.History.lossCause(.watchBattery) == watch(4))
        #expect(Copy.History.lossCause(.watchAudioFault) == watch(5))
        #expect(Copy.History.lossCause(.connectionReset) == watch(6))
        #expect(Copy.History.lossCause(.watchBufferFull) == "watch buffer filled while disconnected")
        #expect(Copy.History.lossCause(.connectionReset) == "connection was interrupted")
        #expect(Copy.History.lossCause(.phoneMissedAudio) == "phone missed audio")
        for cause in HistoryLossCause.allCases {
            #expect(!Copy.History.lossCause(cause).isEmpty)
            #expect(Copy.History.lossCause(cause) != "audio missing", "\(cause) has no wording")
        }
    }

    @Test func backgroundAudioOnlyWithADescriptor() {
        let described = HistoryLabels.gapText(gap(.noConversation, at(13, 15), at(14, 0), descriptor: "music"), locale: us)
        #expect(described.title == "Background audio · 45 min")
        #expect(plain(described.detail ?? "") == "1:15 – 2:00 PM · music, no conversation")

        let plainGap = HistoryLabels.gapText(gap(.noConversation, at(13, 15), at(14, 0)), locale: us)
        #expect(plainGap.title == "No conversation · 45 min")
        #expect(plainGap.detail == nil)
        let short = HistoryLabels.gapText(gap(.noConversation, at(13, 15), at(13, 35)), locale: us)
        #expect(short.title == nil)
    }

    @Test func notRecordingAndDeletedAreNamedWithTheirRange() {
        let off = HistoryLabels.gapText(gap(.notRecording, at(13, 0), at(15, 10)), locale: us)
        #expect(off.title == "Not recording · 2 hr 10 min")
        #expect(plain(off.detail ?? "") == "1:00 – 3:10 PM")
        let mine = HistoryLabels.gapText(gap(.deleted, at(13, 0), at(13, 40), deletedBy: .user), locale: us)
        #expect(mine.title == "Deleted by you · 40 min")
        let retention = HistoryLabels.gapText(gap(.deleted, at(13, 0), at(13, 40), deletedBy: .retention), locale: us)
        #expect(retention.title == "Removed to save space · 40 min")
    }

    @Test func pendingRecordingsAreCards() {
        let waiting = gap(.notTranscribedYet, at(21, 30), at(21, 44))
        #expect(HistoryLabels.isPendingCard(waiting))
        let text = HistoryLabels.gapText(waiting, locale: us)
        #expect(text.title == "Not transcribed yet")
        #expect(plain(text.detail ?? "") == "9:30 – 9:44 PM · 14 min")
        // The reason is a `TranscriptionFailureKind`, worded as Diagnostics words it.
        let failed = HistoryLabels.gapText(
            gap(.transcriptionFailed, at(21, 30), at(21, 44), failure: TranscriptionFailureKind.providerRefusedAudio.rawValue),
            locale: us)
        #expect(failed.title == "Could not be transcribed")
        #expect(plain(failed.detail ?? "") == "9:30 – 9:44 PM · \(TranscriptionFailureKind.providerRefusedAudio.reason)")
    }

    @Test func lossCarriedInsideAGapIsSaid() {
        var waiting = gap(.notTranscribedYet, at(8, 17), at(16, 17))
        waiting.missingMs = 5 * 60_000
        let text = HistoryLabels.gapText(waiting, locale: us)
        // The loss is its own part, drawn amber after the gray line — never folded into it.
        #expect(plain(text.detail ?? "") == "8:17 AM – 4:17 PM · 8 hr")
        #expect(text.missing == "5 min missing")
        #expect(plain(text.fullDetail ?? "") == "8:17 AM – 4:17 PM · 8 hr · 5 min missing")
        #expect(HistoryLabels.gapAccessibilityLabel(waiting, locale: us).contains("missing"))
        // A short quiet gap is bare — unless it carries loss, which is never left unsaid.
        var quiet = gap(.quiet, at(10, 0), at(10, 5))
        #expect(HistoryLabels.gapText(quiet, locale: us).title == nil)
        quiet.missingMs = 4_000
        #expect(HistoryLabels.gapText(quiet, locale: us).title != nil)
        #expect(HistoryLabels.gapText(quiet, locale: us).missing == "under 1 min missing")
        #expect(!(HistoryLabels.gapText(quiet, locale: us).detail ?? "").contains("missing"))
    }

    @Test func anOpenEndedPauseSaysSince() {
        let text = HistoryLabels.gapText(gap(.paused, at(14, 30), at(15, 5), pausedBy: .you), openEnded: true, locale: us)
        #expect(plain(text.title ?? "") == "Paused since 2:30 PM")
        #expect(text.detail == "you paused capture")
    }

    // MARK: Edges

    @Test func quietEdgesAndNotListeningEdgesSayDifferentThings() {
        #expect(Copy.History.edge(.quiet, leading: true, time: "8:12 AM") == "Quiet until 8:12 AM")
        #expect(Copy.History.edge(.quiet, leading: false, time: "9:44 PM") == "Quiet after 9:44 PM")
        let until = Copy.History.edge(.notListening, leading: true, time: "8:12 AM")
        let after = Copy.History.edge(.notListening, leading: false, time: "9:44 PM")
        #expect(until == "Nothing recorded until 8:12 AM")
        #expect(after == "Nothing recorded after 9:44 PM")
        #expect(!until.lowercased().contains("quiet") && !after.lowercased().contains("quiet"))
    }

    // MARK: Follow-up counts

    @Test func followUpCounts() {
        #expect(Copy.History.followUpCount(total: 4, open: 2) == "4 follow-ups · 2 open")
        #expect(Copy.History.followUpCount(total: 1, open: 1) == "1 follow-up · open")
        #expect(Copy.History.followUpCount(total: 6, open: 0) == "6 follow-ups · all done")
        #expect(Copy.History.followUpCount(total: 1, open: 0) == "1 follow-up · done")
        #expect(Copy.History.followUpCount(total: 0, open: 0) == "No follow-ups")
        #expect(Copy.History.more(3) == "3 more")
    }

    // MARK: Accessibility

    @Test func aGapReadsAsOneSentence() {
        let quiet = HistoryLabels.gapAccessibilityLabel(gap(.quiet, at(10, 15), at(11, 20)), locale: us)
        #expect(plain(quiet) == "Quiet, 1 hour 5 minutes, 10:15 to 11:20 AM")
        let missing = HistoryLabels.gapAccessibilityLabel(
            gap(.audioMissing, at(12, 10), at(15, 40), causes: [.watchBufferFull, .connectionReset]), locale: us)
        #expect(plain(missing) == "Audio missing, 3 hours 30 minutes, 12:10 to 3:40 PM, watch buffer filled while disconnected, connection was interrupted")
        // A bare gap on screen is still spoken: the axis is hidden, so this is its only voice.
        let short = HistoryLabels.gapAccessibilityLabel(gap(.quiet, at(10, 0), at(10, 12)), locale: us)
        #expect(plain(short) == "Quiet, 12 minutes, 10:00 to 10:12 AM")
    }

    @Test func aChapterReadsAsOneElement() {
        let chapter = block(
            at(14, 0), at(14, 56), missing: 4 * 60_000,
            followUps: [
                HistoryFollowUpLine(id: "a", text: "Send the order number", done: false),
                HistoryFollowUpLine(id: "b", text: "Confirm the billing contact", done: true),
            ])
        let label = plain(HistoryLabels.chapterAccessibilityLabel(chapter, locale: us))
        #expect(label == "Invoice details with the vendor, 2:00 to 2:56 PM, 56 minutes, 4 minutes of audio missing, Order numbers and the contact., topic: banking, with Mira, 2 follow-ups, 1 open")
    }

    @Test func aShortChapterDoesNotReadTheSummaryItDoesNotShow() {
        let label = HistoryLabels.chapterAccessibilityLabel(block(at(14, 0), at(14, 18)), locale: us)
        #expect(!label.contains("Order numbers"))
    }

    // MARK: Stretches (one block between conversations)

    private func piece(
        _ kind: HistoryGap.Kind, _ start: Int64, _ end: Int64, missingSeconds: Int64 = 0,
        descriptor: String? = nil, deletedBy: HistoryDeletionCause? = nil, openable: Bool = false
    ) -> HistoryGap {
        HistoryGap(
            id: "p\(start)", kind: kind, startMs: start, endMs: end, zoneID: newYork.identifier,
            pausedBy: kind == .paused ? .watchPowerSave : nil, descriptor: descriptor, deletedBy: deletedBy,
            isOpenable: openable, missingMs: missingSeconds * 1000)
    }

    private func stretch(_ parts: HistoryGap...) -> HistoryStretch { HistoryStretch(parts: parts) }

    @Test func aStretchSaysOnlyItsLargestClassWithoutCauseOrRange() {
        let text = HistoryLabels.stretchText(
            stretch(piece(.paused, at(18, 40), at(19, 50)), piece(.quiet, at(19, 50), at(20, 10))), locale: us)
        #expect(text.title == "Paused · 1 hr 10 min")
        #expect(text.secondLine == nil && text.lossWords == nil && !text.titleIsLoss)
    }

    @Test func aSecondClassIsNamedPastBothThresholds() {
        let two = HistoryLabels.stretchText(
            stretch(piece(.paused, at(18, 40), at(19, 50)), piece(.quiet, at(19, 50), at(20, 40))), locale: us)
        #expect(two.title == "Paused 1 hr 10 min · quiet 50 min")
    }

    @Test func aStretchMostlyLostSaysSoInAmberWithItsRange() {
        let text = HistoryLabels.stretchText(
            stretch(piece(.quiet, at(0, 47, day: 23), at(0, 50, day: 23)),
                    piece(.audioMissing, at(0, 50, day: 23), at(1, 21, day: 23))), locale: us)
        #expect(text.title == "Audio missing · 31 min")
        #expect(text.titleIsLoss)
        #expect(plain(text.secondLine ?? "") == "12:47 – 1:21 AM")
        #expect(text.lossWords == nil)
    }

    @Test func lossOfAMinuteOrMoreIsSaidAfterTheLabelAndLessIsNot() {
        let minutes = HistoryLabels.stretchText(
            stretch(piece(.paused, at(22, 13), at(22, 51)), piece(.quiet, at(22, 51), at(22, 58), missingSeconds: 120)),
            locale: us)
        #expect(minutes.title == "Paused · 38 min")
        #expect(minutes.lossWords == "2 min missing")
        let seconds = HistoryLabels.stretchText(
            stretch(piece(.paused, at(22, 13), at(22, 51)), piece(.quiet, at(22, 51), at(22, 58), missingSeconds: 20)),
            locale: us)
        #expect(seconds.title == "Paused · 38 min")
        #expect(seconds.lossWords == nil)
    }

    @Test func aBareStretchHasNoWordsButStillOpensWhenItCarriesLoss() {
        let calm = stretch(piece(.quiet, at(21, 2), at(21, 9)), piece(.quiet, at(21, 9), at(21, 27)))
        #expect(HistoryLabels.stretchText(calm, locale: us).title == nil)
        #expect(!HistoryLabels.stretchOpensDetail(calm))
        let lossy = stretch(piece(.quiet, at(21, 2), at(21, 9), missingSeconds: 20), piece(.quiet, at(21, 9), at(21, 27)))
        #expect(HistoryLabels.stretchText(lossy, locale: us).title == nil)
        #expect(HistoryLabels.stretchOpensDetail(lossy))
    }

    @Test func aStretchNamesItsQuietAndItsDescribedAndItsDeleted() {
        let noConversation = stretch(
            piece(.quiet, at(13, 0), at(13, 10)), piece(.noConversation, at(13, 10), at(13, 50)))
        #expect(HistoryLabels.stretchText(noConversation, locale: us).title == "No conversation · 50 min")
        let music = stretch(
            piece(.noConversation, at(13, 0), at(13, 45), descriptor: "music"), piece(.quiet, at(13, 45), at(13, 50)))
        #expect(HistoryLabels.stretchText(music, locale: us).title == "Music · 45 min")
        let removed = stretch(piece(.deleted, at(13, 0), at(13, 40), deletedBy: .retention))
        #expect(HistoryLabels.stretchText(removed, locale: us).title == "Removed to save space · 40 min")
    }

    @Test func aSingleOpenablePieceKeepsItsOwnTap() {
        let only = stretch(piece(.noConversation, at(21, 9), at(21, 45), openable: true))
        #expect(only.singleOpenablePiece != nil)
        #expect(!HistoryLabels.stretchOpensDetail(only))
    }

    @Test func aStretchIsOneSpokenElementLossIncluded() {
        let night = stretch(
            piece(.paused, at(22, 13), at(23, 56)),
            piece(.quiet, at(23, 56), at(0, 33, day: 23), missingSeconds: 20))
        #expect(plain(HistoryLabels.stretchAccessibilityLabel(night, locale: us))
            == "Paused 1 hour 43 minutes. 10:13 PM to 12:33 AM. Under a minute of audio missing.")
        let two = stretch(piece(.paused, at(18, 40), at(19, 50)), piece(.quiet, at(19, 50), at(20, 40)))
        #expect(plain(HistoryLabels.stretchAccessibilityLabel(two, locale: us))
            == "Paused 1 hour 10 minutes, quiet 50 minutes. 6:40 to 8:40 PM.")
    }
}
