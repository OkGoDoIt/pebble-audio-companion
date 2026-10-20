import AppDB
import Foundation
import Intelligence
import Testing

// "Notify me when my recap is ready": what it says, when it fires, and that it fires from the
// point a recap is written. The OS notification center is faked; nothing is posted.

private final class FakePoster: RecapNotificationPosting, @unchecked Sendable {
    var authorized = true
    var posted: [RecapNotificationContent] = []
    func isAuthorized() async -> Bool { authorized }
    func post(_ content: RecapNotificationContent) async { posted.append(content) }
}

@Suite("recap-ready notification", .serialized)
struct RecapNotificationTests {
    /// Wednesday 21 October 2026, 10:00 in New York: yesterday is Tuesday the 20th.
    private static let nowMs: Int64 = 1_792_591_200_000
    private static let zone = "America/New_York"
    private static let yesterday = "2026-10-20"
    private static let today = "2026-10-21"

    private static func recap(
        _ dateKey: String = "2026-10-20", text: String = "Lease talk with Sam, then a long walk.",
        headline: String? = "Lease call with Sam", briefDone: Bool = true
    ) -> DailyRecap {
        DailyRecap(
            dateKey: dateKey, text: text, headline: headline,
            briefOfHash: briefDone ? RecapCondenser.fingerprint(text) : nil)
    }

    // MARK: - What it says

    @Test func itIsNamedForTheDayAndCarriesTheHeadline() throws {
        #expect(RecapNotificationRules.candidateDay(nowMs: Self.nowMs, timeZoneID: Self.zone) == Self.yesterday)
        let content = try #require(RecapNotificationRules.content(for: Self.recap(), timeZoneID: Self.zone))
        #expect(content.title == "Tuesday’s recap")
        #expect(content.body == "Lease call with Sam")
        #expect(content.route == .history(date: Self.yesterday, level: nil))
        #expect(content.identifier == "recap-2026-10-20")
    }

    @Test func emptyNothingRecordedAndHeadlinePendingDoNotNotify() {
        #expect(RecapNotificationRules.content(for: Self.recap(text: "  "), timeZoneID: Self.zone) == nil)
        #expect(
            RecapNotificationRules.content(
                for: Self.recap(text: "Nothing was recorded today.", headline: nil),
                timeZoneID: Self.zone) == nil)
        #expect(
            RecapNotificationRules.content(
                for: Self.recap(headline: "No conversations"), timeZoneID: Self.zone) == nil)
        // The headline is still owed: wait for it rather than post without it.
        #expect(
            RecapNotificationRules.content(
                for: Self.recap(headline: nil, briefDone: false), timeZoneID: Self.zone) == nil)
        // A long recap that merely mentions "nothing was recorded" is a real day.
        let long = String(repeating: "We planned the move in detail. ", count: 12)
            + "Nothing was recorded about the budget."
        #expect(RecapNotificationRules.saysNothingRecorded(long) == false)
    }

    @Test func aBriefThatFoundNoHeadlineFallsBackToTheRecapsFirstSentence() throws {
        let content = try #require(
            RecapNotificationRules.content(
                for: Self.recap(text: "Lease talk with Sam. Then a walk.", headline: nil),
                timeZoneID: Self.zone))
        #expect(content.body == "Lease talk with Sam.")
    }

    // MARK: - When it fires

    private func notifier(
        enabled: Bool = true, poster: FakePoster, recaps: [String: DailyRecap],
        suite: String
    ) -> RecapReadyNotifier {
        RecapReadyNotifier(
            isEnabled: { enabled }, recap: { recaps[$0] }, poster: poster, defaultsSuite: suite,
            nowMs: { Self.nowMs }, timeZoneID: { Self.zone })
    }

    private func scratchDefaults() throws -> (UserDefaults, String) {
        let suite = "recap-notify-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func oncePerDayFromTheFirstWriteThatShowsTheDayIsOver() async throws {
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let poster = FakePoster()
        let recaps = [Self.yesterday: Self.recap(), Self.today: Self.recap(Self.today)]
        let subject = notifier(poster: poster, recaps: recaps, suite: suite)

        // Today's first recap is what says yesterday is finished.
        await subject.recapWritten(dateKey: Self.today)
        #expect(poster.posted.map(\.dateKey) == [Self.yesterday])
        // Every later write — today's refreshes, yesterday's headline — says nothing new.
        await subject.recapWritten(dateKey: Self.today)
        await subject.recapWritten(dateKey: Self.yesterday)
        #expect(poster.posted.count == 1)
        // And it is remembered across launches.
        let relaunched = self.notifier(poster: poster, recaps: recaps, suite: suite)
        await relaunched.recapWritten(dateKey: Self.today)
        #expect(poster.posted.count == 1)
    }

    @Test func offOrUnauthorizedPostsNothingAndAnOlderDaySaysNothing() async throws {
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let poster = FakePoster()
        let recaps = [Self.yesterday: Self.recap(), "2026-10-17": Self.recap("2026-10-17")]

        await notifier(enabled: false, poster: poster, recaps: recaps, suite: suite)
            .recapWritten(dateKey: Self.yesterday)
        #expect(poster.posted.isEmpty)

        // A recap rewritten for a day long past does not announce itself days later.
        await notifier(poster: poster, recaps: recaps, suite: suite)
            .recapWritten(dateKey: "2026-10-17")
        #expect(poster.posted.isEmpty)

        // No permission: nothing posted, and nothing remembered — it posts once allowed.
        poster.authorized = false
        let subject = notifier(poster: poster, recaps: recaps, suite: suite)
        await subject.recapWritten(dateKey: Self.yesterday)
        #expect(poster.posted.isEmpty)
        poster.authorized = true
        await subject.recapWritten(dateKey: Self.yesterday)
        #expect(poster.posted.map(\.dateKey) == [Self.yesterday])
    }

    @Test func aHeadlineThatLandsLaterIsWhatSetsItOff() async throws {
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let poster = FakePoster()
        var recaps = [Self.yesterday: Self.recap(headline: nil, briefDone: false)]
        await notifier(poster: poster, recaps: recaps, suite: suite)
            .recapWritten(dateKey: Self.yesterday)
        #expect(poster.posted.isEmpty)
        recaps[Self.yesterday] = Self.recap()
        await notifier(poster: poster, recaps: recaps, suite: suite)
            .recapWritten(dateKey: Self.yesterday)
        #expect(poster.posted.first?.body == "Lease call with Sam")
    }

    // MARK: - Where it listens

    /// The hook is the store itself: a digest save and a headline save both report their day.
    @Test func theRecapStoreReportsEveryWriteOfARecapOrItsHeadline() async throws {
        final class Heard: @unchecked Sendable { var keys: [String] = [] }
        let heard = Heard()
        let store = DailyRecapStore(
            db: try AppDatabase.inMemory(), nowMs: { Self.nowMs },
            didWrite: { heard.keys.append($0) })
        let saved = try await store.save(DailyRecap(dateKey: Self.yesterday, text: "A day."))
        try await store.saveDayBrief(
            dateKey: Self.yesterday, sourceText: saved.text, headline: "A day", lineSummary: nil)
        #expect(heard.keys == [Self.yesterday, Self.yesterday])
        #expect(try await store.load(dateKey: Self.yesterday)?.headline == "A day")
    }
}
