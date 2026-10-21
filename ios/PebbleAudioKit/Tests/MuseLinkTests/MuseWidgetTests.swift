import Foundation
import Testing

@testable import MuseLink

/// Widgets Muse places in an answer (`[[hatch_widget:<id>]]`). Meta doesn't document their wire
/// form, so the reader is loose; these pin the kinds Muse described and what a screen without
/// widgets shows for each.
struct MuseWidgetTests {
    private func json(_ text: String) -> MuseJSON { MuseJSON.parse(Data(text.utf8))! }
    private func options(_ labels: String...) -> [MuseWidget.Option] { labels.map { MuseWidget.Option($0) } }

    @Test func optionButtonsAreAChoiceThatSendsTheirOwnWords() {
        let widgets = MuseWidget.collect(json(#"""
            [{"widget_id":"widget-3abb","kind":"options","options":["A: 12","B: 14","C: 16"],"button_style":"dotted_lines"}]
            """#))
        #expect(widgets == [MuseWidget(id: "widget-3abb", kind: "options", options: options("A: 12", "B: 14", "C: 16"))])
        #expect(widgets[0].options[1].reply == "B: 14")
        #expect(widgets[0].plainText(elsewhere: "In the Muse app") == "A: 12\nB: 14\nC: 16")
    }

    @Test func buttonsKeyedByIDOrNestedInASpecAreFound() {
        #expect(MuseWidget.collect(json(#"{"widget-9":{"type":"buttons","buttons":[{"text":"Yes"},{"text":"No"}]}}"#))
            == [MuseWidget(id: "widget-9", kind: "buttons", options: options("Yes", "No"))])
        #expect(MuseWidget.collect(json(#"[{"id":"w1","spec":{"props":{"choices":[{"label":{"text":"Red"}},"Blue"]}}}]"#))
            == [MuseWidget(id: "w1", options: options("Red", "Blue"))])
    }

    @Test func listRowsThatSendAMessageArePickedAndTheRestRead() {
        let list = MuseWidget.collect(json(#"""
            [{"widget_id":"l1","kind":"list","title":"Coffee near you","items":[
              {"title":"Blue Bottle","subtitle":"4 min walk","type":"send_message","data":{"text":"Tell me more about Blue Bottle"}},
              {"title":"Ritual","subtitle":"Open until 6","type":"link","data":{"url":"https://example.com"}}]}]
            """#))
        let widget = try! #require(list.first)
        #expect(widget.title == "Coffee near you")
        #expect(widget.options == [MuseWidget.Option("Blue Bottle", reply: "Tell me more about Blue Bottle")])
        #expect(widget.lines == ["Ritual \u{00B7} Open until 6"])
        #expect(widget.plainText(elsewhere: "In the Muse app") == "Coffee near you\nRitual \u{00B7} Open until 6\nBlue Bottle\nIn the Muse app")
    }

    @Test func aMapReadsAsItsPlaces() {
        let map = MuseWidget.collect(json(#"""
            [{"widget_id":"m","kind":"map","motivation":"Bakeries open now","elements":[
              {"kind":"rich_place","place_id":"123","name":"Tartine","category":"Bakery","coordinate":{"latitude":37.76,"longitude":-122.42}},
              {"kind":"marker","coordinate":{"latitude":37.7,"longitude":-122.4}}]}]
            """#))
        #expect(map == [MuseWidget(id: "m", kind: "map", title: "Bakeries open now", lines: ["Tartine \u{00B7} Bakery"])])
        #expect(MuseWidget.substitute("Here:\n[[hatch_widget:m]]", widgets: map, elsewhere: "In the Muse app")
            == "Here:\nBakeries open now\nTartine \u{00B7} Bakery\nIn the Muse app")
    }

    @Test func anHTMLCardSaysItsFallbackText() {
        let card = MuseWidget.collect(json(#"""
            [{"widget_id":"h","kind":"html","display_text":"Packing list","fallback_text":"Packing checklist, 12 items","html":"<ul><li>Socks</li></ul>"}]
            """#))
        #expect(card.first?.title == "Packing checklist, 12 items")
        #expect(card.first?.isChoice == false)
        #expect(card.first?.plainText(elsewhere: "In the Muse app") == "Packing checklist, 12 items\nIn the Muse app")
    }

    @Test func aPlaceholderBecomesTheWidgetsWords() {
        let widget = MuseWidget(id: "widget-3abb", options: options("A: 12", "B: 14", "C: 16"))
        let text = "What is 2 times 7?\n\nTap your answer:\n\n[[hatch_widget:widget-3abb]]"
        #expect(MuseWidget.substitute(text, widgets: [widget]) == "What is 2 times 7?\n\nTap your answer:\n\nA: 12\nB: 14\nC: 16")
        // The same widget named without its prefix, and a lone widget whatever its id.
        #expect(MuseWidget.substitute("[[hatch_widget:widget-3abb]]", widgets: [MuseWidget(id: "3abb", options: options("x", "y"))]) == "x\ny")
        #expect(MuseWidget.substitute("[[hatch_widget:other]]", widgets: [widget]) == "A: 12\nB: 14\nC: 16")
    }

    @Test func anUnknownWidgetStaysUntilItsContentsCome() {
        let text = "One [[hatch_widget:a]] two [[hatch_widget:b]]"
        let a = MuseWidget(id: "a", options: options("1", "2"))
        let b = MuseWidget(id: "b", options: options("3", "4"))
        #expect(MuseWidget.substitute(text, widgets: [a, b]) == "One 1\n2 two 3\n4")
        #expect(MuseWidget.substitute(text, widgets: [a, MuseWidget(id: "c")]) == "One 1\n2 two [[hatch_widget:b]]")
        #expect(MuseWidget.removingPlaceholders(text) == "One  two ")
    }

    @Test func theQuestionIsTheLastLineThatAsks() {
        let text = "Got it, here's a test question:\n\nWhat is 2 times 7?\n\nTap your answer:\n\n[[hatch_widget:widget-w]]"
        #expect(MuseWidget.question(before: "w", in: text) == "What is 2 times 7?")
        #expect(MuseWidget.question(before: "w", in: "Pick a time:\n[[hatch_widget:w]]\nLater?") == "Pick a time:")
    }

    @Test func theShapeShowsLayoutNotWords() {
        let shape = MuseWidget.shape(json(#"[{"widget_id":"widget-3abb","kind":"options","options":["A: 12","B: 14"]}]"#))
        #expect(shape == #"[1x{kind:"options",options:[2xs5],widget_id:s11}]"#)
        #expect(!shape.contains("12"))
    }

    @Test func aReplyCarriesItsWidgets() throws {
        var turn = MuseTurn()
        _ = try turn.acknowledge(["result": ["message_id": "u1"]])
        let delta = try #require(MuseLinkSession.chatEvent(Data(#"""
            {"type":"event","event_name":"delta.text_append","payload":{"message_id":"a1","reply_to_message_id":"u1",
             "text":"Pick:\n[[hatch_widget:w1]]","widgets":[{"id":"w1","options":["Tea","Coffee"]}]}}
            """#.utf8)))
        _ = try turn.feed(delta)
        #expect(turn.replies.first?.widgets == [MuseWidget(id: "w1", options: options("Tea", "Coffee"))])
    }
}
