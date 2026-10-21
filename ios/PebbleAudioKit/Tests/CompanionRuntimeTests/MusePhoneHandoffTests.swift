import Foundation
import MuseLink
import Testing

@testable import CompanionRuntime

/// Where a phone notification about a Muse answer leads, for each kind of thing an answer can
/// hold that only the phone can open.
struct MusePhoneHandoffTests {
    let chat = URL(string: "https://muse.ai/thread/chat-1")!

    private func plan(_ raw: String, widgets: [MuseWidget] = [], truncated: Bool = false) -> MusePhoneHandoff? {
        MusePhoneHandoffPlanner.plan(raw: raw, widgets: widgets, truncated: truncated, chat: chat)
    }

    @Test func plainTextAndButtonsStayOnTheWatch() {
        #expect(plan("It's 72°F and sunny.") == nil)
        let buttons = MuseWidget(id: "w", options: [MuseWidget.Option("Yes"), MuseWidget.Option("No")])
        #expect(plan("Book it?\n[[hatch_widget:w]]", widgets: [buttons]) == nil)
        // A citation is a source, not something to open.
        #expect(plan("Paris is the capital【source†L1-L2】.") == nil)
    }

    @Test func oneLinkOpensItself() throws {
        let handoff = try #require(plan("Here's the form: [Renew your passport](https://travel.state.gov/renew)."))
        #expect(handoff.title == "Muse sent a link")
        #expect(handoff.body == "Renew your passport")
        #expect(handoff.url.absoluteString == "https://travel.state.gov/renew")
        #expect(handoff.actions.map(\.title) == ["Open in Muse"])
        #expect(handoff.watchLine == "Link sent to your phone")
        // A bare link counts too, named by its site.
        #expect(plan("See https://example.com/menu for the menu.")?.body == "example.com")
    }

    @Test func severalLinksOpenTheChatWithAButtonEach() throws {
        let handoff = try #require(plan("Options: [Delta](https://delta.com/a) or [United](https://united.com/b)."))
        #expect(handoff.title == "Muse sent links")
        #expect(handoff.url == chat)
        #expect(handoff.actions.map(\.title) == ["Open Delta", "Open United"])
        #expect(handoff.body == "Delta, United")
    }

    @Test func aMapWithOnePlaceOpensMapsAndACardOpensMuse() throws {
        let place = MuseWidget(
            id: "m", kind: "map", title: "Bakery near you", lines: ["Tartine · Bakery"],
            places: [MuseWidget.Place(name: "Tartine", latitude: 37.76, longitude: -122.42)])
        let map = try #require(plan("Closest:\n[[hatch_widget:m]]", widgets: [place]))
        #expect(map.title == "Muse sent a place")
        #expect(map.url.host == "maps.apple.com")
        #expect(map.url.query?.contains("ll=37.76,-122.42") == true)
        #expect(map.watchLine == "Place sent to your phone")

        let card = MuseWidget(id: "h", kind: "html", title: "Packing checklist, 12 items")
        let handoff = try #require(plan("[[hatch_widget:h]]", widgets: [card]))
        #expect(handoff.title == "Muse sent a card")
        #expect(handoff.body == "Packing checklist, 12 items")
        #expect(handoff.url == chat)
        #expect(handoff.watchLine == "Card sent to your phone")
    }

    @Test func aListOfLinksIsACardWithItsLinks() throws {
        let list = MuseWidget(
            id: "l", kind: "list", title: "Coffee near you", lines: ["Ritual · Open until 6"],
            links: [MuseWidget.Link(title: "Ritual", url: "https://ritual.coffee")])
        let handoff = try #require(plan("[[hatch_widget:l]]", widgets: [list]))
        #expect(handoff.title == "Muse sent a card")
        #expect(handoff.actions.map(\.title) == ["Open Ritual"])
    }

    @Test func aFileOpensMuse() throws {
        let handoff = try #require(plan("Here it is:\n![Trip plan](sandbox://workspace/trip.pdf)"))
        #expect(handoff.title == "Muse sent a file")
        #expect(handoff.body == "Trip plan")
        #expect(handoff.url == chat)
    }

    @Test func anAnswerTooLongForTheWatchOpensMuse() throws {
        let handoff = try #require(plan("A long history of Rome.", truncated: true))
        #expect(handoff.title == "Muse's full answer")
        #expect(handoff.watchLine == "The rest is on your phone")
    }

    @Test func aLoneNumberCallsAndALoneAddressOpensMaps() throws {
        let call = try #require(plan("The pharmacy's number is (415) 555-0100."))
        #expect(call.title == "Muse sent a number")
        #expect(call.url.absoluteString == "tel:4155550100")
        let address = try #require(plan("It's at 1 Infinite Loop, Cupertino, CA 95014."))
        #expect(address.title == "Muse sent an address")
        #expect(address.url.host == "maps.apple.com")
    }

    @Test func everyTitleStartsWithMuseForTheWatchToRecognise() {
        let titles = [
            plan("[a](https://a.com)"), plan("[a](https://a.com) [b](https://b.com)"),
            plan("x", truncated: true), plan("![f](sandbox://workspace/f)"),
        ].compactMap { $0?.title }
        #expect(titles.count == 4)
        #expect(titles.allSatisfy { $0.hasPrefix("Muse") })
    }

    @Test func theWatchChatOpensAsAThreadAndTheMainChatAsTheChat() {
        #expect(MusePhoneHandoffPlanner.chatURL(watchChatID: "abc-123")?.absoluteString == "https://muse.ai/thread/abc-123")
        #expect(MusePhoneHandoffPlanner.chatURL(watchChatID: nil)?.absoluteString == "https://muse.ai/chat")
    }
}
