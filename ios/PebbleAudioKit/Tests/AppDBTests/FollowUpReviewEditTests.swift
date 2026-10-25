import Foundation
import Testing
@testable import AppDB

@Suite struct FollowUpReviewEditTests {
    private func suggestion() -> FollowUp {
        FollowUp(id: "review", text: "Call Sam", done: false,
            sourceConversationId: "conversation", sourceSegmentId: "segment", createdAtMs: 100,
            quote: "Let's call Sam tomorrow", why: "Book before the deadline",
            dueAtMs: 500, stage: .suggested)
    }

    @Test func savingPreservesProvenanceAndReviewStateAndSurvivesExtraction() async throws {
        let store = FollowUpStore(db: try AppDatabase.inMemory())
        let original = suggestion()
        try await store.upsertExtracted(original)
        try await store.setReviewDetails(id: original.id, text: "  Call Sam about tickets  ",
            dueAtMs: nil, priority: .high, nowMs: 200)
        let saved = try #require(try await store.load(id: original.id))
        #expect(saved.text == "Call Sam about tickets")
        #expect(saved.dueAtMs == nil)
        #expect(saved.priority == .high)
        #expect(saved.stage == .suggested)
        #expect(saved.decidedAtMs == nil)
        #expect(saved.quote == original.quote)
        #expect(saved.sourceConversationId == original.sourceConversationId)
        #expect(saved.editedAtMs == 200)
        try await store.upsertExtracted(original)
        let refreshed = try #require(try await store.load(id: original.id))
        #expect(refreshed.text == saved.text)
        #expect(refreshed.dueAtMs == nil)
        #expect(refreshed.priority == .high)
        try await store.setStage(id: original.id, .reminder, nowMs: 300)
        #expect(try await store.load(id: original.id)?.priority == .high)
    }

    @Test func rejectsMissingDecidedOrEmptyItemsWithoutPartialChanges() async throws {
        let store = FollowUpStore(db: try AppDatabase.inMemory())
        await #expect(throws: (any Error).self) {
            try await store.setReviewDetails(id: "missing", text: "New", dueAtMs: 900, priority: .low)
        }
        let original = suggestion()
        try await store.upsertExtracted(original)
        await #expect(throws: (any Error).self) {
            try await store.setReviewDetails(id: original.id, text: "  ", dueAtMs: nil, priority: .high)
        }
        #expect(try await store.load(id: original.id)?.dueAtMs == 500)
        try await store.setStage(id: original.id, .skipped, nowMs: 200)
        await #expect(throws: (any Error).self) {
            try await store.setReviewDetails(id: original.id, text: "Changed", dueAtMs: nil, priority: .high)
        }
        let saved = try #require(try await store.load(id: original.id))
        #expect(saved.text == original.text)
        #expect(saved.dueAtMs == original.dueAtMs)
        #expect(saved.stage == .skipped)
    }

    @Test func uneditedSuggestionsStillRefreshTheirMetadata() async throws {
        let store = FollowUpStore(db: try AppDatabase.inMemory())
        var item = suggestion()
        try await store.upsertExtracted(item)
        item.dueAtMs = 900
        item.priority = .low
        try await store.upsertExtracted(item)
        #expect(try await store.load(id: item.id)?.dueAtMs == 900)
        #expect(try await store.load(id: item.id)?.priority == .low)
    }
}
