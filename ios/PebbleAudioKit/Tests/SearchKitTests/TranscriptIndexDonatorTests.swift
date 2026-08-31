import AppDB
import Foundation
import Testing

@testable import SearchKit

// Port of `app/.../TranscriptIndexDonatorTest.kt` (3 cases), retargeted to the rebuild's entity
// model: segments → conversations, daily digests → recaps, action items → follow-ups. The KMP
// `spotlightDonate/Remove/RemoveAll` closures are the `SpotlightIndexing` fake; the app index
// is the real persistent FTS5 one over an in-memory AppDatabase.

private final class FakeSpotlight: SpotlightIndexing, @unchecked Sendable {
    var donations: [SpotlightDonation] = []
    var removedIdentifiers: [String] = []
    var cleared = false

    func donate(_ donations: [SpotlightDonation]) async throws {
        self.donations.append(contentsOf: donations)
    }

    func remove(uniqueIdentifiers: [String]) async throws {
        removedIdentifiers.append(contentsOf: uniqueIdentifiers)
    }

    func removeAll() async throws {
        cleared = true
    }
}

@Suite struct TranscriptIndexDonatorTests {
    private func makeFixture() throws -> (SpotlightDonator, TranscriptIndex, FakeSpotlight) {
        let index = TranscriptIndex(database: try AppDatabase.inMemory())
        let spotlight = FakeSpotlight()
        return (SpotlightDonator(index: index, spotlight: spotlight), index, spotlight)
    }

    @Test func donatesAllDocumentKindsToSearchAndPlatformHook() async throws {
        let (donator, index, spotlight) = try makeFixture()

        try await donator.donateConversation(
            conversationId: "seg-1",
            title: "Budget review",
            summary: "Discussed Q3 budget.",
            tags: ["budget"],
            createdAtMs: 10
        )
        try await donator.donateRecap(dateKey: "2026-06-26", text: "Daily recap", createdAtMs: 20)
        try await donator.donateFollowUp(
            id: "action-1",
            text: "Send the budget note",
            sourceConversationId: "seg-1",
            createdAtMs: 30
        )

        #expect(
            spotlight.donations.map { [$0.entityId, $0.kind.rawValue] } == [
                ["seg-1", "conversation"],
                ["day-2026-06-26", "recap"],
                ["action-1", "followup"],
            ]
        )
        // Deep links follow the plan 6.8 routes; follow-ups open their source conversation.
        #expect(
            spotlight.donations.map { $0.deepLinkURL } == [
                "companion://conversation/seg-1",
                "companion://today?date=2026-06-26",
                "companion://conversation/seg-1",
            ]
        )
        #expect(try index.search("q3").map { $0.id } == ["seg-1"])
        #expect(try index.search("recap").map { $0.id } == ["day-2026-06-26"])
        #expect(try index.search("send").map { $0.id } == ["action-1"])
    }

    @Test func redonatingSameDayReplacesTheRecapInsteadOfAccumulating() async throws {
        let (donator, index, spotlight) = try makeFixture()

        // Recaps regenerate during the day under the same dateKey; both writes must land on
        // the same document id so the index holds one entry per day, not a copy per refresh.
        try await donator.donateRecap(
            dateKey: "2026-06-26", text: "Morning recap", createdAtMs: 20
        )
        try await donator.donateRecap(
            dateKey: "2026-06-26", text: "Evening recap", createdAtMs: 90
        )

        let hits = try index.search("recap")
        #expect(hits.count == 1)
        #expect(hits.first?.id == "day-2026-06-26")
        #expect(hits.first?.snippet.contains("Evening recap") == true)
        #expect(spotlight.donations.map { $0.entityId } == ["day-2026-06-26", "day-2026-06-26"])
    }

    @Test func removeAllClearsIndexAndPlatformHook() async throws {
        let (donator, index, spotlight) = try makeFixture()

        try await donator.donateConversation(
            conversationId: "seg-1",
            title: "Private meeting",
            createdAtMs: 10
        )
        try await donator.removeAll()

        #expect(spotlight.cleared)
        #expect(try index.search("private").isEmpty)
    }
}
