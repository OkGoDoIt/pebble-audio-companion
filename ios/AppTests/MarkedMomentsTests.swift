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
