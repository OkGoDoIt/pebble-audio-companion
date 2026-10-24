import AppDB
import Foundation
import SwiftUI
import Testing

@MainActor @Suite struct MarkedMomentsTests {
    @Test func momentsAreReachableFromALinkAndStayInTheCurrentStack() {
        let route = Route.markedMoments
        #expect(Route.parse(route.url) == route)
        let router = AppRouter()
        router.push(route)
        #expect(router.todayPath == [route])
        router.navigate(to: route)
        #expect(router.selectedTab == .library)
        #expect(router.libraryPath == [route])
    }

    @Test func nearbyWordsIncludeAnOverlappingTurnButExcludeDistantAndUnfinishedSpeech() {
        func turn(_ text: String, start: Int64, duration: Int64, live: Bool = false) -> TranscriptItem {
            .turn(TranscriptTurn(id: text, speakerLabel: "S1", name: "You", role: .you,
                text: text, startedAt: Date(timeIntervalSince1970: Double(start) / 1000),
                isInProgress: live, mediaOffsetMs: 0, mediaEndMs: duration))
        }
        let words = MarkedMomentContext.quote(in: [
            turn("Too early", start: 1_000, duration: 1_000),
            turn("Overlapping", start: 10_000, duration: 50_000),
            turn("Nearby", start: 79_000, duration: 1_000),
            turn("Still changing", start: 81_000, duration: 1_000, live: true),
            turn("Too late", start: 100_000, duration: 1_000)
        ], at: 80_000)
        #expect(words == "Overlapping\n\nNearby")
    }

    @Test func aLiveMarkIsVisibleBeforeTheStoredConversationEndCatchesUp() {
        let mark = Moment(id: "live", wallMs: 200, onAudioClock: true, createdAtMs: 200)
        let row = ConversationListRow(id: "live", startMs: 100, endMs: 150, isLive: true)
        #expect(LiveTodayDataSource.conversationRow(row, moments: [mark], nowMs: 200).moments == [mark])
        var closed = row
        closed.isLive = false
        #expect(LiveTodayDataSource.conversationRow(closed, moments: [mark], nowMs: 200).moments.isEmpty)
        let previous = ConversationListRow(id: "previous", startMs: 50, endMs: 100, isLive: false)
        let boundary = Moment(id: "boundary", wallMs: 100, onAudioClock: true, createdAtMs: 100)
        #expect(LiveTodayDataSource.conversationRow(previous, moments: [boundary]).moments.isEmpty)
        #expect(LiveTodayDataSource.conversationRow(row, moments: [boundary]).moments == [boundary])
    }

    @Test func livePinsAppearWithoutSpeechAndKeepTheirSavedIdentity() {
        let marks = [50, 100, 150, 200].map {
            Moment(id: "m-\($0)", wallMs: Int64($0), onAudioClock: true, createdAtMs: 0)
        }
        let result = TranscriptItems.insertingMoments(marks, into: [], startMs: 100, endMs: 200, timeZone: .gmt)
        #expect(result.map(\.id) == ["moment-m-100", "moment-m-150"])
        #expect(result.compactMap { item in
            if case .moment(let marker) = item { return marker.momentId }
            return nil
        } == ["m-100", "m-150"])
    }

    @Test func renderContextualMomentSurfaces() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/mockups/moments/built", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let start: Int64 = 1_792_777_200_000
        let marks = [
            Moment(id: "first", wallMs: start + 60_000, onAudioClock: true, createdAtMs: 0),
            Moment(id: "second", wallMs: start + 64_000, onAudioClock: true, createdAtMs: 0,
                   note: "A useful idea to revisit together"),
            Moment(id: "quiet", wallMs: start + 360_000, onAudioClock: false, createdAtMs: 0)
        ]
        let day = HistoryDay(dateKey: "2026-10-23", zoneID: TimeZone.current.identifier, isToday: false, hasRecordings: true,
            leadingEdge: nil, items: [
                .chapter(HistoryChapterBlock(id: "c", startMs: start, endMs: start + 300_000,
                    zoneID: TimeZone.current.identifier, source: .chapter, title: "Planning the weekend", summary: nil)),
                .gap(HistoryGap(id: "quiet", kind: .quiet, startMs: start + 300_000, endMs: start + 600_000, zoneID: TimeZone.current.identifier))
            ], trailingEdge: nil)
        let transcript = TranscriptItems.insertingMoments(Array(marks.prefix(2)), into: [
            .turn(TranscriptTurn(id: "words", speakerLabel: "S1", name: "You", role: .you,
                text: "Let's take the early train and spend the afternoon by the water.",
                startedAt: Date(timeIntervalSince1970: Double(start) / 1000))),
            .turn(TranscriptTurn(id: "tail", speakerLabel: "S1", name: "You", role: .you,
                text: "I'll check the train times…", startedAt: Date(timeIntervalSince1970: Double(start + 70_000) / 1000),
                isInProgress: true))
        ], startMs: start, endMs: start + 300_000, timeZone: .current)
        for width in [375.0, 820.0, 1024.0] {
            for dark in [false, true] {
                for large in [false, true] where !large || width == 375 {
                    let view = VStack(alignment: .leading, spacing: 16) {
                        Text("Today · Conversations").font(AppFont.sectionTitle)
                        Card {
                            TodayConversationRow(row: ConversationRowDisplay(id: "c", title: "Planning the weekend",
                                meta: "12:40 AM · 5 min so far", snippet: "“I'll check the train times…”", isLive: true,
                                moments: Array(marks.prefix(2))), onOpen: {})
                        }
                        Text("History · Day").font(AppFont.sectionTitle)
                        DayTimeline(day: day, entries: HistoryDayPage.entries(for: day), moments: marks)
                        Text("History · Week").font(AppFont.sectionTitle)
                        Card {
                            WeekDayRow(row: HistoryWeekRow(dateKey: "2026-10-23", state: .recorded,
                                headline: "Plans for the weekend", summary: "Decided on a day by the water.", momentCount: 3))
                        }
                        Text("Live transcript").font(AppFont.sectionTitle)
                        TranscriptView(transcript: transcript, provenance: "Live transcript", timeZone: .current)
                    }
                    .padding(16).frame(width: width).background(Tokens.ground)
                    .environment(AppRouter()).environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
                    try render(view, width: width).write(to: output.appendingPathComponent(
                        "context-\(Int(width))-\(dark ? "dark" : "light")\(large ? "-large-type" : "").png"))
                }
            }
        }
    }

    private func render(_ content: some View, width: CGFloat) throws -> Data {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return try #require(renderer.uiImage?.pngData())
    }

    /// Render the real components, not a parallel HTML mock. These PNGs are for visual review
    /// of phone/tablet widths and accessibility type; assertions only check successful rendering.
    @Test func renderMomentSurfaces() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/mockups/moments/built", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var moment = Moment(id: "review", wallMs: 1_792_777_792_457, onAudioClock: true,
                            createdAtMs: 0, note: "That idea for the weekend", wasRecording: true)
        moment.review = MomentReview(summary: "A plan for an afternoon by the water.", suggestions: [
            MomentSuggestion(kind: "reminder", text: "Check the early train times for Saturday."),
            MomentSuggestion(kind: "next_step", text: "What did we decide about the weekend trip?")
        ])
        moment.reviewState = "reviewed"
        let context = MarkedMomentContext(title: "Planning the weekend",
            quote: "We could take the early train and spend the afternoon by the water. Let's check the times for Saturday.",
            status: "Words around your mark", target: CitationTarget(conversationId: "demo",
                conversationTitle: "Planning the weekend", focus: .moment(segmentId: "seg", atWallMs: moment.wallMs),
                mediaOffsetMs: 12_000))
        for width in [375.0, 430.0, 820.0, 1024.0] {
            for dark in [false, true] {
                let view = VStack(alignment: .leading, spacing: 18) {
                    Text("Marked moments").font(.largeTitle.bold()).padding(.horizontal, 20)
                    MomentRow(moment: moment, source: PreviewMomentsSource(), refresh: 0,
                              initialContext: context, open: {}).padding(.horizontal, 20)
                    MomentDetailSheet(moment: moment, source: PreviewMomentsSource(), initialContext: context).detailContent
                }
                .padding(.vertical, 24).frame(width: width).background(Tokens.ground)
                .environment(AppRouter()).environment(\.colorScheme, dark ? .dark : .light)
                let png = try render(view, width: width)
                try png.write(to: output.appendingPathComponent("moments-\(Int(width))-\(dark ? "dark" : "light").png"))
            }
        }
        let large = MomentDetailSheet(moment: moment, source: PreviewMomentsSource(), initialContext: context)
            .detailContent.frame(width: 375).background(Tokens.ground)
            .environment(AppRouter()).environment(\.dynamicTypeSize, .accessibility3)
        try render(large, width: 375).write(to: output.appendingPathComponent("moments-large-type.png"))
    }
}
