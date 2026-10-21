import Testing

@testable import CompanionRuntime

/// Muse's Markdown as the watch shows it, and the property the watch depends on: it only ever
/// appends, so no partial rendering may change once sent.
struct WatchAnswerTextTests {
    @Test func markdownBecomesPlainText() {
        let answer = """
            ## Your morning

            **Lunch** with *Sam* at noon. See [the menu](https://example.com/menu) first.
            - Bring the `slides`
            * Call Ana 📞
            2 * 3 is 6.
            """
        #expect(WatchAnswerText.render(answer, final: true) == """
            Your morning

            Lunch with Sam at noon. See the menu first.
            \u{2022} Bring the slides
            \u{2022} Call Ana 📞
            2 * 3 is 6.
            """)
    }

    @Test func aWidgetStillWaitingForItsContentsIsHeldThenDropped() {
        let answer = "Tap your answer:\n\n[[hatch_widget:widget-1]]\n\nOr say it."
        #expect(WatchAnswerText.render(answer, final: false) == "Tap your answer:")
        #expect(WatchAnswerText.render(answer, final: true) == "Tap your answer:\n\nOr say it.")
        // Half a placeholder on the last line holds from its first "[".
        #expect(WatchAnswerText.render("Tap your answer: [[hatch_wid", final: false) == "Tap your answer: ")
    }

    @Test func otherMarkersGoAndTheirNamesCanBeLogged() {
        let answer = "First part.\n[[hatch_split]]\nSecond part [[cite:web-3]]."
        #expect(WatchAnswerText.render(answer, final: true) == "First part.\n\nSecond part .")
        #expect(WatchAnswerText.markerNames(answer) == ["hatch_split", "cite"])
        // Ordinary brackets are text.
        #expect(WatchAnswerText.render("Use [[ and ]] like [[This one]].", final: true) == "Use [[ and ]] like [[This one]].")
    }

    @Test func musesBubblesAttachmentsAndCitationsReadPlainly() {
        let answer = "Here it is.<message_break/>Second bubble, with a source【4†L10-L12】.\n![Trip plan.pdf](sandbox://workspace/trip.pdf)\n![](sandbox://workspace/a.png)"
        #expect(WatchAnswerText.render(answer, final: true)
            == "Here it is.\n\nSecond bubble, with a source.\n\u{1F4CE} Trip plan.pdf\n\u{1F4CE} Attachment")
        // Half a tag or citation waits for the rest.
        #expect(WatchAnswerText.render("Here it is.<message_br", final: false) == "Here it is.")
        #expect(WatchAnswerText.render("A source【4†L1", final: false) == "A source")
    }

    @Test func blankLinesCollapse() {
        #expect(WatchAnswerText.render("One.\n\n\n\nTwo.\n\n", final: true) == "One.\n\nTwo.")
    }

    @Test func everyPartialRenderingIsAPrefixOfTheNext() {
        let answer = """
            ## Plan
            Here is **what I found** for _you_, with a [link](https://x.y/z) and an emoji 🎉.

            - First thing
            - Second thing
            1. Numbered
            Total: 2 * 3 = 6
            """
        var previous = ""
        for end in answer.indices.dropFirst() + [answer.endIndex] {
            let rendered = WatchAnswerText.render(String(answer[..<end]), final: false)
            #expect(rendered.hasPrefix(previous), "\(String(answer[..<end]).debugDescription)")
            previous = rendered
        }
        #expect(WatchAnswerText.render(answer, final: true).hasPrefix(previous))
    }
}
