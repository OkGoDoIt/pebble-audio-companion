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

    // MARK: - Query construction

    /// A natural-language QUESTION is not a search box query. Every token used to be ANDed
    /// together, so "do I have any travel plans for the rest of this year?" demanded a single
    /// transcript containing all seventeen of those words — which nothing satisfies. The query
    /// matched nothing, silently, and Ask's retrieval fell through to whatever happened to be
    /// first in the library.
    @Test func aQuestionsFunctionWordsDoNotVetoItsContentWords() throws {
        let index = try makeIndex()
        try index.upsert([
            IndexItem(
                id: "conv-1", kind: .conversation, title: "Conversation",
                fullText: "the travel dates moved, so we book the flights to Lisbon next week",
                contentCreationDateMs: 1)
        ])
        let question = "do I have any travel plans for the rest of this year?"

        // ANDing every word demands "plans", "rest" and "year" as well — so the transcript that
        // plainly answers the question is not returned at all.
        #expect(try index.search(question, limit: 5, mode: .all).isEmpty)
        // Recall mode finds it on the content words it does share.
        #expect(try index.search(question, limit: 5, mode: .any).count == 1)
    }

    /// The limit that keyword retrieval cannot be argued out of, recorded so nobody mistakes
    /// `.any` for a solution to it: a conversation about a trip that never says "travel" is
    /// invisible to a question that only says "travel". This is precisely why `AskCorpusPlanner`
    /// reads the whole scope when it fits and sweeps it when it does not, and why keyword
    /// relevance is confined to choosing what to sacrifice past the sweep ceiling.
    @Test func recallModeStillCannotBridgeADifferentVocabulary() throws {
        let index = try makeIndex()
        try index.upsert([
            IndexItem(
                id: "conv-1", kind: .conversation, title: "Conversation",
                fullText: "we should book the flights to Lisbon before the visa expires",
                contentCreationDateMs: 1)
        ])
        #expect(
            try index.search("any travel plans this year?", limit: 5, mode: .any).isEmpty)
    }

    @Test func stopWordsAreStrippedFromAMultiTermQuery() {
        #expect(TranscriptIndex.ftsQuery("the flights to Lisbon") == "\"flights\"* \"Lisbon\"*")
        #expect(
            TranscriptIndex.ftsQuery("the flights to Lisbon", mode: .any)
                == "\"flights\"* OR \"Lisbon\"*")
    }

    /// Stripping is for narrowing a query, never for emptying it: a search for a single common
    /// word still searches for that word.
    @Test func aQueryThatIsNothingButStopWordsStillSearchesForThem() {
        #expect(TranscriptIndex.ftsQuery("the") == "\"the\"*")
        #expect(TranscriptIndex.ftsQuery("what about that") == "\"what\"* \"about\"* \"that\"*")
        #expect(TranscriptIndex.ftsQuery("   ") == nil)
    }

    @Test func quotesInAQueryCannotBreakOutOfTheMatchExpression() {
        #expect(TranscriptIndex.ftsQuery("say \"hello\"") == "\"say\"* \"hello\"*")
        let index = try? makeIndex()
        #expect((try? index?.search("OR AND \"x\" *", limit: 5)) != nil)
    }

    /// Ranking still has to mean something under `.any`: matching more of the query must beat
    /// matching less of it.
    @Test func recallModeStillRanksTheBestMatchFirst() throws {
        let index = try makeIndex()
        try index.upsert([
            IndexItem(
                id: "conv-weak", kind: .conversation, title: "Conversation",
                fullText: "the flights were delayed again", contentCreationDateMs: 1),
            IndexItem(
                id: "conv-strong", kind: .conversation, title: "Conversation",
                fullText: "flights booked to Lisbon, visa sorted, hotel confirmed",
                contentCreationDateMs: 2),
        ])
        let hits = try index.search("Lisbon flights hotel", limit: 5, mode: .any)
        #expect(hits.count == 2)
        #expect(hits.first?.id == "conv-strong")
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
