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

    /// Ask is a tab, not a sheet. The link selects it and leaves the request for the screen to
    /// pick up, because the screen outlives any one link now: a second "ask about this
    /// conversation" has to re-scope a view model that is already on screen.
    @Test func askSelectsItsTabAndLeavesTheRequestToBeConsumed() {
        let router = AppRouter()
        router.selectedTab = .settings
        router.navigate(to: .ask(scope: "today", query: "what did we decide"))

        #expect(router.selectedTab == .ask)
        #expect(router.askPath.isEmpty)
        #expect(router.consumePendingAsk() == .ask(scope: "today", query: "what did we decide"))
        #expect(router.consumePendingAsk() == nil)
    }

    /// One Ask conversation is a pushed child screen, so it is a route: back and the edge
    /// swipe are the system's, and history rows and new questions both go through it.
    @Test func anAskConversationIsPushedOntoTheAskTab() {
        let router = AppRouter()
        router.selectedTab = .today
        router.navigate(to: .askThread(id: "thread-7", question: nil))

        #expect(router.selectedTab == .ask)
        #expect(router.askPath == [.askThread(id: "thread-7", question: nil)])
        #expect(router.pendingAsk == nil)
    }

    /// Both halves of the route survive the URL — the id that names a saved conversation, and
    /// the question a brand-new one opens with.
    @Test func theAskConversationRouteRoundTripsThroughItsURL() throws {
        for route in [
            Route.askThread(id: "thread-7", question: nil),
            Route.askThread(id: nil, question: "what did we decide"),
        ] {
            #expect(Route.parse(route.url) == route)
        }
        // A link naming neither is not a conversation, and must not open an empty one.
        let empty = try #require(URL(string: "companion://askthread"))
        #expect(Route.parse(empty) == nil)
    }

    // MARK: - Where the transcript lands: citation or moment

    /// A citation link spells exactly what it always did — no `fk` — and reads back as a
    /// citation. Every chip, note and Shortcut written before the style existed depends on this.
    @Test func aCitationLinkIsUnchangedByTheStyle() throws {
        let focus = TranscriptFocus(segmentId: "seg-1", startMs: 1_000, endMs: 2_000)
        #expect(focus.style == .citation)
        let route = Route.conversation(id: "conv-seg-1", atMs: 500, focus: focus)
        #expect(
            route.url.absoluteString
                == "companion://conversation/conv-seg-1?t=500&s=seg-1&fs=1000&fe=2000")
        #expect(Route.parse(route.url) == route)

        // A link from before the style existed parses as a citation.
        let old = try #require(
            URL(string: "companion://conversation/conv-seg-1?t=500&s=seg-1&fs=1000&fe=2000"))
        #expect(Route.parse(old) == route)
        // And one with no stretch at all, the oldest shape, still names just the member.
        let bare = try #require(URL(string: "companion://conversation/conv-seg-1?s=seg-1"))
        #expect(
            Route.parse(bare)
                == .conversation(
                    id: "conv-seg-1", atMs: nil, focus: TranscriptFocus(segmentId: "seg-1")))
    }

    @Test func aMomentLinkRoundTripsCompactly() throws {
        let focus = TranscriptFocus.moment(segmentId: "seg-2", atWallMs: 1_727_700_000_000)
        #expect(focus.style == .moment)
        #expect(focus.startMs == 1_727_700_000_000 && focus.endMs == 1_727_700_000_000)
        let route = Route.conversation(id: "conv-seg-1", atMs: 61_000, focus: focus)
        #expect(
            route.url.absoluteString
                == "companion://conversation/conv-seg-1?t=61000&s=seg-2"
                + "&fs=1727700000000&fe=1727700000000&fk=m")
        #expect(Route.parse(route.url) == route)
    }

    /// An `fk` this build does not know is read as what the link meant before `fk` existed,
    /// rather than dropping the focus or failing the link.
    @Test func anUnknownFocusKindReadsAsACitation() throws {
        let url = try #require(URL(string: "companion://conversation/c?s=seg&fs=1&fe=2&fk=zz"))
        guard case .conversation(_, _, let focus)? = Route.parse(url) else {
            Issue.record("not a conversation route")
            return
        }
        #expect(focus?.style == .citation)
        #expect(focus?.startMs == 1 && focus?.endMs == 2)
    }

    /// Opening at a moment is still a conversation open: it lands where every conversation
    /// does, with the focus intact.
    @Test func aMomentOpensInsideLibraryLikeAnyConversation() {
        let router = AppRouter()
        let route = Route.conversation(
            id: "conv-1", atMs: 0, focus: .moment(segmentId: "seg-1", atWallMs: 42))
        router.navigate(to: route)
        #expect(router.selectedTab == .library)
        #expect(router.libraryPath == [route])
    }

    /// The one-liner History writes: both clocks in the right slots, and the link survives.
    @Test func theMomentHelperBuildsTheConversationRoute() {
        let route = Route.moment(
            conversationId: "conv-a", segmentId: "b", atWallMs: 1_727_700_000_000,
            mediaOffsetMs: 95_000)
        #expect(
            route
                == .conversation(
                    id: "conv-a", atMs: 95_000,
                    focus: TranscriptFocus(
                        segmentId: "b", startMs: 1_727_700_000_000, endMs: 1_727_700_000_000,
                        style: .moment)))
        #expect(Route.parse(route.url) == route)
        // No audio to cue: the transcript still lands, the player stays at its default.
        let silent = Route.moment(
            conversationId: "conv-a", segmentId: "b", atWallMs: 5, mediaOffsetMs: nil)
        #expect(Route.parse(silent.url) == silent)
    }

    /// From a wall time straight to a route, through the data source.
    @Test func aWallTimeResolvesToAMomentRoute() async throws {
        let world = MockWorld.shared
        let display = try #require(try await world.display(id: "coffee-dana"))
        let start = try #require(display.startedAt)
        let wallMs = Int64(start.timeIntervalSince1970 * 1000) + 60_000

        let route = try #require(await Route.moment(atWallMs: wallMs, in: world))
        guard case .conversation(let id, let atMs, let focus) = route else {
            Issue.record("not a conversation route")
            return
        }
        #expect(id == "coffee-dana")
        #expect(atMs != nil)
        #expect(focus?.style == .moment)
        #expect(focus?.startMs == wallMs)
        // A time nobody recorded anywhere near opens nothing.
        #expect(await Route.moment(atWallMs: 0, in: world) == nil)
    }

    @Test func followUpsOpenInTheirOwnTab() {
        let router = AppRouter()
        router.selectedTab = .today
        router.navigate(to: .followUps(scope: "archived"))
        #expect(router.selectedTab == .followUps)
        #expect(router.followUpsPath.isEmpty)
        #expect(router.consumePendingFollowUpScope() == "archived")
        #expect(router.consumePendingFollowUpScope() == nil)

        router.navigate(to: .followUp(id: "fu-1"))
        #expect(router.selectedTab == .followUps)
        #expect(router.followUpsPath == [.followUp(id: "fu-1")])
    }

    /// The widget links straight to an item, so the round trip has to survive the URL.
    @Test func aFollowUpLinkRoundTrips() throws {
        let route = Route.followUp(id: "conv-1-action-9f2")
        #expect(route.url.absoluteString == "companion://followup/conv-1-action-9f2")
        #expect(Route.parse(route.url) == route)
        #expect(Route.parse(URL(string: "companion://followups?scope=completed")!)
            == .followUps(scope: "completed"))
        #expect(Route.parse(URL(string: "companion://followups")!) == .followUps(scope: nil))
        #expect(Route.parse(URL(string: "companion://followup")!) == nil)
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
