import AppDB
import Foundation
import Testing

@testable import SearchKit

// Port of `core/search/.../TranscriptIndexTest.kt` (2 cases), run against the PERSISTENT FTS5
// index (plan 4.7 / D7 fix) over an in-memory AppDatabase instead of the KMP in-memory map.

@Suite struct TranscriptIndexTests {
    private func makeIndex() throws -> TranscriptIndex {
        TranscriptIndex(database: try AppDatabase.inMemory())
    }

    @Test func searchMatchesTitleAndTags() throws {
        let index = try makeIndex()
        try index.upsert([
            IndexItem(
                id: "seg-1",
                kind: .conversation,
                title: "Budget review",
                summary: "Discussed Q3 numbers",
                tags: ["work", "budget"],
                contentCreationDateMs: 1
            )
        ])
        let hits = try index.search("budget", limit: 5)
        #expect(hits.count == 1)
        #expect(hits.first?.id == "seg-1")
        #expect(hits.first?.kind == .conversation)
        #expect(hits.first?.title == "Budget review")
    }

    @Test func excludedItemsAreNotReturned() throws {
        let index = try makeIndex()
        try index.upsert([
            IndexItem(
                id: "hidden",
                kind: .conversation,
                title: "Secret meeting",
                contentCreationDateMs: 1,
                excluded: true
            )
        ])
        #expect(try index.search("secret", limit: 5).isEmpty)
    }
}
