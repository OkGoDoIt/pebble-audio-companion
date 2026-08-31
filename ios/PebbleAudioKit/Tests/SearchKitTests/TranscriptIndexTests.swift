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

    /// The scope pill's bug, reproduced: 60 conversations mention "budget", and the one the
    /// window is asking about is deliberately the WORST match of them all — it would sit far
    /// below a global `LIMIT 40`, so filtering the unscoped top 40 down to the window found
    /// nothing and the pill quietly under-reported.
    @Test func scopedSearchFindsAMatchBelowTheGlobalLimit() throws {
        let index = try makeIndex()
        var items: [IndexItem] = (0..<60).map { i in
            IndexItem(
                id: "loud-\(i)",
                kind: .conversation,
                title: "Budget budget budget \(i)",
                summary: "budget budget budget budget budget",
                tags: ["budget"],
                fullText: "budget budget budget budget budget budget budget",
                contentCreationDateMs: Int64(i)
            )
        }
        // One faint mention, in a long document so bm25 ranks it last.
        items.append(
            IndexItem(
                id: "todays-quiet-one",
                kind: .conversation,
                title: "Standup",
                fullText: String(repeating: "unrelated chatter ", count: 400) + " budget",
                contentCreationDateMs: 99
            )
        )
        try index.upsert(items)

        // What the old code saw: 40 global hits, none of them the one in the window.
        let global = try index.search("budget", limit: 40)
        #expect(global.count == 40)
        #expect(!global.contains { $0.id == "todays-quiet-one" })

        // Pushing the window into the query spends the limit on rows the caller can use.
        let scoped = try index.search(
            "budget", limit: 40, kinds: [.conversation], within: ["todays-quiet-one"])
        #expect(scoped.map(\.id) == ["todays-quiet-one"])

        // A window with nothing in it is empty, not unrestricted.
        #expect(try index.search("budget", limit: 40, within: []).isEmpty)
        // And nil still means the whole library.
        #expect(try index.search("budget", limit: 40, within: nil).count == 40)
    }

    @Test func scopedSearchKeepsKindsAndIdsIndependent() throws {
        let index = try makeIndex()
        try index.upsert([
            IndexItem(id: "c-1", kind: .conversation, title: "Budget review",
                      contentCreationDateMs: 1),
            IndexItem(id: "n-1", kind: .note, title: "Budget note", contentCreationDateMs: 2),
            IndexItem(id: "c-2", kind: .conversation, title: "Budget again",
                      contentCreationDateMs: 3),
        ])
        #expect(
            try index.search("budget", limit: 10, kinds: [.conversation]).map(\.id).sorted()
                == ["c-1", "c-2"]
        )
        #expect(try index.search("budget", limit: 10, within: ["n-1"]).map(\.id) == ["n-1"])
        #expect(
            try index.search("budget", limit: 10, kinds: [.note], within: ["c-1"]).isEmpty
        )
    }

    /// Ids reach SQLite as a JSON array, so a quote or backslash in one must not silently
    /// truncate the array into a window that matches nothing.
    @Test func idsWithJsonPunctuationSurviveTheRoundTrip() throws {
        let index = try makeIndex()
        let awkward = #"quote"and\slash"#
        try index.upsert([
            IndexItem(id: awkward, kind: .conversation, title: "Budget review",
                      contentCreationDateMs: 1)
        ])
        #expect(try index.search("budget", limit: 10, within: [awkward]).map(\.id) == [awkward])
        #expect(TranscriptIndex.jsonArray(["a", "b"]) == #"["a","b"]"#)
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
