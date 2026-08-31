import Foundation
import Testing

/// `AppRouter` is the whole deep-link surface — widgets, Siri, Spotlight, the loss notification
/// and every `companion://` URL land here. It had no tests, which is how `pendingLibraryTag`
/// came to be written by `navigate(to:)` and read by nothing at all.
@Suite("app router") @MainActor
struct AppRouterTests {

    // MARK: - The tag filter that used to be dropped

    /// `companion://library?tag=travel` selected the Library tab and silently discarded the
    /// filter: the property was set, and no screen ever looked at it.
    @Test func libraryTagSurvivesTheDeepLink() throws {
        let router = AppRouter()
        let url = try #require(URL(string: "companion://library?tag=travel"))
        let route = try #require(Route.parse(url))

        router.navigate(to: route)

        #expect(router.selectedTab == .library)
        #expect(router.consumePendingLibraryTag() == "travel")
    }

    /// Consumed exactly once: coming back to Library later must not re-apply a filter the user
    /// has since tapped off.
    @Test func theTagIsConsumedOnlyOnce() {
        let router = AppRouter()
        router.navigate(to: .library(tag: "work"))

        #expect(router.consumePendingLibraryTag() == "work")
        #expect(router.consumePendingLibraryTag() == nil)
        #expect(router.pendingLibraryTag == nil)
    }

    /// A bare `companion://library` asks for the Library and nothing more, so it must not look
    /// like a request to filter by an empty tag.
    @Test func aBareLibraryLinkAsksForNoFilter() {
        let router = AppRouter()
        router.navigate(to: .library(tag: nil))

        #expect(router.selectedTab == .library)
        #expect(router.consumePendingLibraryTag() == nil)
    }

    // MARK: - The rest of the route space

    @Test func searchCarriesItsQuery() {
        let router = AppRouter()
        router.navigate(to: .search(query: "ferry"))

        #expect(router.selectedTab == .library)
        #expect(router.pendingSearchQuery == "ferry")
        #expect(router.libraryPath.isEmpty)
    }

    /// A bare search link opens the search state with nothing typed — an empty string, not nil,
    /// because nil means "nobody asked".
    @Test func aBareSearchLinkStillOpensSearch() {
        let router = AppRouter()
        router.navigate(to: .search(query: nil))
        #expect(router.pendingSearchQuery == "")
    }

    @Test func conversationAndNoteOpenInsideLibrary() {
        let router = AppRouter()
        router.navigate(to: .conversation(id: "coffee-dana", atMs: nil))
        #expect(router.selectedTab == .library)
        #expect(router.libraryPath == [.conversation(id: "coffee-dana", atMs: nil)])

        router.navigate(to: .note(id: "meeting-notes"))
        #expect(router.libraryPath == [.note(id: "meeting-notes")])
    }

    @Test func liveReplacesTheTodayStack() {
        let router = AppRouter()
        router.selectedTab = .settings
        router.todayPath = [.conversation(id: "x", atMs: nil)]

        router.navigate(to: .live)

        #expect(router.selectedTab == .today)
        #expect(router.todayPath == [.live])
    }

    @Test func askOpensAsASheetAndLeavesTheTabAlone() {
        let router = AppRouter()
        router.selectedTab = .settings
        router.navigate(to: .ask(scope: "today", query: "what did we decide"))

        #expect(router.selectedTab == .settings)
        #expect(router.askSheet == .ask(scope: "today", query: "what did we decide"))
    }

    @Test func settingsPushesOnlyTheNamedPage() {
        let router = AppRouter()
        router.navigate(to: .settings(.watch))
        #expect(router.settingsPath == [.settings(.watch)])

        router.navigate(to: .settings(nil))
        #expect(router.settingsPath.isEmpty)
    }

    /// A screen reached from Today keeps pushing inside Today. Hard-coding `libraryPath` here
    /// pushed a note nobody could see and rewrote the Library stack behind the user's back.
    @Test func pushUsesTheStackTheUserIsActuallyIn() {
        let router = AppRouter()
        router.selectedTab = .today
        router.push(.note(id: "n1"))
        #expect(router.todayPath == [.note(id: "n1")])
        #expect(router.libraryPath.isEmpty)

        router.selectedTab = .settings
        router.push(.note(id: "n2"))
        #expect(router.settingsPath == [.note(id: "n2")])
    }
}
