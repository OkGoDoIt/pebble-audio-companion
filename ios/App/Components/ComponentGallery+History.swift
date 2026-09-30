import AppDB
import SwiftUI

/// The History tab's components in every state (plan 7.12: every new component gets a gallery
/// entry). Rendered as sections of `ComponentGallery`.
struct HistoryComponentGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            section("History · brief cards") {
                BriefCard(
                    title: Copy.History.dayInBrief,
                    text: "Sprint planning over coffee, a broken login and a vendor call, a rainy site visit and a budget review, then dinner and a movie.",
                    footer: Copy.History.followUpCount(total: 4, open: 2))
                BriefCard(
                    title: Copy.History.todaySoFar,
                    text: "Contract questions over breakfast, then the paperwork with the vendor.",
                    footer: Copy.History.followUpCount(total: 1, open: 1) + " · "
                        + Copy.History.updated("11:15 AM"))
                BriefCard(
                    title: Copy.History.monthInBrief,
                    text: "The office move: packing and the trip mid-month, then venue hunting and invoices.",
                    tagCounts: [
                        .init(name: "apartment", days: 14), .init(name: "travel", days: 9),
                        .init(name: "banking", days: 6), .init(name: "family", days: 5),
                    ])
                BriefCard(title: Copy.History.dayInBrief, text: nil, note: Copy.History.topicsPreparing)
                BriefCard(
                    title: Copy.History.dayInBrief, text: nil,
                    placeholder: Copy.History.waitingToTranscribe)
            }

            section("History · pills and follow-ups") {
                HStack(spacing: 5) {
                    TagChip(text: "apartment", tone: .topic)
                    TagChip(text: "banking", tone: .topic)
                    TagChip(text: "Mira", tone: .person)
                    TagChip(text: "Oliver", tone: .person)
                }
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        FollowUpLine(text: "Send the order number", done: false, more: 1)
                        FollowUpLine(text: "Ask Simon for the agent’s number", done: true)
                        FollowUpLine(text: "Email the vendor about the larger room", done: false, size: .row)
                        FollowUpLine(text: "Fix the crash on older dates", done: true, size: .row)
                    }
                }
            }

            section("History · chapter cards") {
                ForEach(Samples.cards, id: \.id) { block in
                    ChapterCard(block: block)
                        .frame(minHeight: TimelineGeometry.minHeight(
                            for: TimelineSpan(startMs: block.startMs, endMs: block.endMs)))
                }
                LiveChapterCard(
                    live: HistoryLiveBlock(
                        startMs: Samples.at(11, 20), endMs: Samples.at(11, 41), zoneID: Samples.zone),
                    lastLine: "they said the shop closes at noon on Saturdays, so we should go now")
                PendingChapterCard(gap: Samples.gap(.notTranscribedYet, 21, 30, 21, 44))
                PendingChapterCard(
                    gap: Samples.gap(
                        .transcriptionFailed, 21, 30, 21, 44,
                        failure: "the provider could not read the audio"))
            }

            section("History · gaps") {
                ForEach(Samples.gaps, id: \.id) { gap in
                    TimelineGap(gap: gap)
                        .frame(height: 60)
                        .padding(.leading, Tokens.Timeline.gutter)
                        .background(alignment: .leading) {
                            TimelineAxis().padding(.leading, Tokens.Timeline.axisX)
                        }
                }
                ZoneChangeDivider(change: HistoryZoneChange(atMs: 0, zoneID: "Asia/Jakarta"))
                    .padding(.leading, Tokens.Timeline.gutter)
                TimelineEdgeLine(
                    edge: HistoryEdge(atMs: Samples.at(8, 12), kind: .quiet), leading: true,
                    zoneID: Samples.zone)
                TimelineEdgeLine(
                    edge: HistoryEdge(atMs: Samples.at(21, 44), kind: .notListening),
                    leading: false, zoneID: Samples.zone)
            }

            section("History · week and month rows") {
                ListCard {
                    ForEach(Samples.weekRows) { WeekDayRow(row: $0) }
                }
                ListCard {
                    ForEach(Samples.monthRows) { MonthWeekRow(row: $0, todayKey: "2026-09-26") }
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(AppFont.sectionHeader)
                .foregroundStyle(Tokens.meta)
                .kerning(0.4)
            content()
        }
    }

    /// Sample data in New York time on 2026-09-22.
    enum Samples {
        static let zone = "America/New_York"

        static func at(_ hour: Int, _ minute: Int) -> Int64 {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let date = calendar.date(
                from: DateComponents(year: 2026, month: 9, day: 22, hour: hour, minute: minute))!
            return Int64(date.timeIntervalSince1970 * 1000)
        }

        static func gap(
            _ kind: HistoryGap.Kind, _ h0: Int, _ m0: Int, _ h1: Int, _ m1: Int,
            pausedBy: HistoryPauseActor? = nil, causes: [HistoryLossCause] = [],
            descriptor: String? = nil, deletedBy: HistoryDeletionCause? = nil,
            failure: String? = nil, openable: Bool = false
        ) -> HistoryGap {
            HistoryGap(
                id: "\(kind)-\(h0)\(m0)-\(descriptor ?? "")-\(deletedBy?.rawValue ?? "")-\(openable)",
                kind: kind, startMs: at(h0, m0), endMs: at(h1, m1),
                zoneID: zone, pausedBy: pausedBy, lossCauses: causes, descriptor: descriptor,
                deletedBy: deletedBy, failureReason: failure, isOpenable: openable)
        }

        static let cards: [HistoryChapterBlock] = [
            HistoryChapterBlock(
                id: "g1", startMs: at(8, 12), endMs: at(9, 0), zoneID: zone, source: .chapter,
                title: "Coffee and sprint planning",
                summary: "Ordering coffee, then sticker ideas and which one to print first.",
                tags: ["design"], people: ["Oliver"]),
            HistoryChapterBlock(
                id: "g2", startMs: at(14, 0), endMs: at(14, 56), zoneID: zone, source: .chapter,
                title: "Invoice details with the vendor",
                summary: "Order numbers and the contact.", tags: ["banking"],
                missingMs: 4 * 60_000,
                followUps: [
                    .init(id: "f1", text: "Send the order number", done: false),
                    .init(id: "f2", text: "Confirm the billing contact", done: true),
                ]),
            HistoryChapterBlock(
                id: "g3", startMs: at(15, 10), endMs: at(15, 30), zoneID: zone, source: .chapter,
                title: "A short chapter with three follow-ups",
                summary: "Short chapters show no summary.", tags: ["work"],
                followUps: [
                    .init(id: "f3", text: "Book the studio", done: false),
                    .init(id: "f4", text: "Pay the deposit", done: false),
                    .init(id: "f5", text: "Return the lease draft", done: true),
                ]),
            HistoryChapterBlock(
                id: "g4", startMs: at(16, 0), endMs: at(16, 40), zoneID: zone,
                source: .conversation, title: nil, summary: nil,
                snippet: "Can you pull up the live data again? I want to see it tick over once."),
        ]

        static let gaps: [HistoryGap] = [
            gap(.quiet, 12, 55, 14, 0),
            gap(.quiet, 17, 40, 19, 30),
            gap(.paused, 11, 0, 11, 30, pausedBy: .you),
            gap(.audioMissing, 20, 38, 21, 30, causes: [.watchBufferFull]),
            gap(.audioMissing, 12, 10, 15, 40),
            gap(.notRecording, 13, 0, 15, 10),
            gap(.noConversation, 13, 15, 14, 0, descriptor: "music", openable: true),
            gap(.noConversation, 13, 15, 14, 0, openable: true),
            gap(.deleted, 13, 0, 13, 40, deletedBy: .user),
            gap(.deleted, 13, 0, 13, 40, deletedBy: .retention),
        ]

        static let weekRows: [HistoryWeekRow] = [
            HistoryWeekRow(
                dateKey: "2026-09-22", state: .recorded,
                headline: "Office search and vendor invoices",
                summary: "Sprint planning over coffee, invoice details with the vendor, a rainy visit and a budget review.",
                tags: ["apartment", "banking", "travel"],
                followUps: [
                    .init(id: "w1", text: "Send the order number", done: false),
                    .init(id: "w2", text: "Reply to the vendor by Friday", done: false),
                ],
                moreFollowUps: 2),
            HistoryWeekRow(dateKey: "2026-09-24", state: .notTranscribedYet(waitingMs: 13 * 3_600_000)),
            HistoryWeekRow(dateKey: "2026-09-25", state: .nothingRecorded),
            HistoryWeekRow(
                dateKey: "2026-09-26", state: .today(isLive: true),
                summary: "Recording now. Contract paperwork with the vendor so far.", tags: ["apartment"],
                followUps: [.init(id: "w3", text: "Send the vendor a signed form", done: false)]),
        ]

        static let monthRows: [HistoryMonthRow] = [
            HistoryMonthRow(
                firstDateKey: "2026-09-20", lastDateKey: "2026-09-26", isCurrentWeek: true,
                hasRecordings: true, headline: "Venue hunting, vendor invoices, workshop prep",
                summary: "Two site visits, a budget review and the invoices behind it.",
                tags: ["apartment", "banking", "conference"], followUpTotal: 16, followUpOpen: 11),
            HistoryMonthRow(
                firstDateKey: "2026-08-30", lastDateKey: "2026-09-05", isCurrentWeek: false,
                hasRecordings: false),
        ]
    }
}
