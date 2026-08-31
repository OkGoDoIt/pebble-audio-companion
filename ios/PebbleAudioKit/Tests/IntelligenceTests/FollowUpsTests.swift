import Foundation
import Testing
import AppDB

@testable import Intelligence

// Ports the KMP action-item parser cases (AiEvalHarnessTest's parser set) and pins the
// DB-backed store contract (FileActionItemStore semantics on the follow_ups table).
//
// One deliberate divergence from KMP, mandated by plan Part 4.5 (anti-B4): the lenient parser
// REJECTS lines with residual markdown/list structure instead of cleaning them. The KMP
// `actionItemParserCleansMarkdownAndSkipsPreamble` case therefore inverts here — its
// markdown-laden input must produce NO items rather than cleaned ones.

@Suite struct ActionItemParserTests {
    @Test func actionItemParserExtractsChecklistLines() {
        let items = ActionItemParser.parse(
            raw: "- Follow up with Sarah\n* Send deck\n[ ] Book room",
            sourceSegmentId: "seg-1",
            nowMs: 1000)
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.sourceSegmentId == "seg-1" })
        #expect(items[0].text == "Follow up with Sarah")
        #expect(items[1].text == "Send deck")
        #expect(items[2].text == "Book room")
        #expect(items.map(\.id) == ["seg-1-action-0", "seg-1-action-1", "seg-1-action-2"])
    }

    /// Supersedes KMP's actionItemParserCleansMarkdownAndSkipsPreamble (anti-B4): markdown
    /// structure is grounds for rejection, never cleanup — `**Owner:**` fragments and numbered
    /// scraps must not ship as items.
    @Test func actionItemParserRejectsResidualMarkdownAndSkipsPreamble() {
        let items = ActionItemParser.parse(
            raw: """
                Here are the action items I found:

                - [ ] **Improve transcription UI formatting** — **Owner:** Roger/team
                  - Show transcribed segments in **blue**.
                2. **Research timestamp support** - **Owner:** Roger
                """,
            sourceSegmentId: "seg-178",
            nowMs: 1000)
        #expect(items.isEmpty)
        #expect(ActionItemParser.displayText(items) == "No action items found.")
    }

    /// Companion to the rejection case: clean checklist lines survive alongside rejected ones.
    @Test func actionItemParserKeepsCleanLinesWhenMarkdownLinesAreRejected() {
        let items = ActionItemParser.parse(
            raw: """
                - Ship the display fix. Owner: Roger. Due: Friday.
                - **Bold nonsense** — **Owner:** nobody
                - Book the demo room
                """,
            sourceSegmentId: "seg-9",
            nowMs: 1000)
        #expect(items.map(\.text) == [
            "Ship the display fix. Owner: Roger. Due: Friday.",
            "Book the demo room",
        ])
        #expect(items.map(\.id) == ["seg-9-action-0", "seg-9-action-1"])
    }

    @Test func actionItemParserPrefersStructuredJson() {
        let items = ActionItemParser.parse(
            raw: """
                {
                  "items": [
                    {
                      "task": "Ship the display fix",
                      "owner": "Roger/team",
                      "due": "Friday",
                      "sourceSegmentId": "seg-2"
                    }
                  ]
                }
                """,
            sourceSegmentId: "seg-1",
            nowMs: 1000)
        #expect(items.count == 1)
        #expect(items[0].text == "Ship the display fix. Owner: Roger/team. Due: Friday")
        #expect(items[0].sourceSegmentId == "seg-2")
        #expect(
            ActionItemParser.displayText(items)
                == "- [ ] Ship the display fix. Owner: Roger/team. Due: Friday")
    }

    @Test func actionItemParserAcceptsEmptyStructuredJson() {
        let items = ActionItemParser.parse(
            raw: #"{"items": []}"#, sourceSegmentId: "seg-1", nowMs: 1000)
        #expect(items.isEmpty)
        #expect(ActionItemParser.displayText(items) == "No action items found.")
    }

    @Test func actionItemParserReturnsEmptyForNoActionItems() {
        #expect(
            ActionItemParser.parse(
                raw: "No action items found.", sourceSegmentId: "seg-1", nowMs: 1000
            ).isEmpty)
    }

    /// Structured decode treats an empty string as "unknown" and skips blank tasks, keeping the
    /// original index in the id (KMP mapIndexedNotNull behavior).
    @Test func structuredParserSkipsBlankTasksKeepingOriginalIndexIds() {
        let items = ActionItemParser.parse(
            raw: """
                {"items": [
                    {"task": "  ", "owner": "", "due": "", "sourceSegmentId": ""},
                    {"task": "Call Sam", "owner": "", "due": "", "sourceSegmentId": ""}
                ]}
                """,
            sourceSegmentId: "seg-1",
            nowMs: 1000)
        #expect(items.count == 1)
        #expect(items[0].id == "seg-1-action-1")
        #expect(items[0].text == "Call Sam")
        #expect(items[0].sourceSegmentId == "seg-1")
    }

    /// The strict schema for structured-output providers: additionalProperties false at both
    /// levels, every key required, all strings.
    @Test func structuredOutputSchemaIsStrict() throws {
        #expect(ActionItemParser.structuredOutputSchemaName == "action_items")
        let root = try JSONSerialization.jsonObject(
            with: Data(ActionItemParser.structuredOutputSchemaJSON.utf8)) as? [String: Any]
        let rootObj = try #require(root)
        #expect(rootObj["additionalProperties"] as? Bool == false)
        #expect(rootObj["required"] as? [String] == ["items"])
        let props = try #require(rootObj["properties"] as? [String: Any])
        let itemsArray = try #require(props["items"] as? [String: Any])
        let itemSchema = try #require(itemsArray["items"] as? [String: Any])
        #expect(itemSchema["additionalProperties"] as? Bool == false)
        #expect(
            Set(itemSchema["required"] as? [String] ?? [])
                == ["task", "owner", "due", "sourceSegmentId"])
    }
}

@Suite struct ActionItemStoreTests {
    private func makeStore(clock: TestWallClock = TestWallClock(ms: 1000)) throws
        -> (ActionItemStore, AppDatabase)
    {
        let db = try AppDatabase.inMemory()
        return (ActionItemStore(db: db, nowMs: { clock.now }), db)
    }

    @Test func savesLoadsListsAndDeletes() async throws {
        let (store, _) = try makeStore()
        let a = ActionItem(
            id: "seg-1-action-0", text: "Call Sam", sourceSegmentId: "seg-1", createdAtMs: 100)
        let b = ActionItem(
            id: "seg-1-action-1", text: "Email Lee", sourceSegmentId: "seg-1", createdAtMs: 200)
        try await store.save(a)
        try await store.save(b)

        #expect(try await store.load(id: "seg-1-action-0") == a)
        // Newest first.
        #expect(try await store.list() == [b, a])

        try await store.delete(id: "seg-1-action-0")
        #expect(try await store.load(id: "seg-1-action-0") == nil)
        #expect(try await store.list() == [b])
    }

    @Test func saveStampsZeroCreatedAtWithClockAndUpserts() async throws {
        let clock = TestWallClock(ms: 5000)
        let (store, _) = try makeStore(clock: clock)
        let saved = try await store.save(
            ActionItem(id: "seg-1-action-0", text: "Call Sam", sourceSegmentId: "seg-1",
                       createdAtMs: 0))
        #expect(saved.createdAtMs == 5000)

        // Re-running extraction overwrites the same id, never duplicates.
        try await store.save(
            ActionItem(id: "seg-1-action-0", text: "Call Sam today", sourceSegmentId: "seg-1",
                       createdAtMs: 6000))
        let items = try await store.list()
        #expect(items.count == 1)
        #expect(items[0].text == "Call Sam today")
    }

    @Test func setDoneFlipsAndReturnsItem() async throws {
        let (store, _) = try makeStore()
        try await store.save(
            ActionItem(id: "seg-1-action-0", text: "Call Sam", sourceSegmentId: "seg-1",
                       createdAtMs: 100))
        let done = try await store.setDone(id: "seg-1-action-0", true)
        #expect(done?.done == true)
        #expect(try await store.setDone(id: "missing", true) == nil)
    }

    @Test func extractedItemsSurfaceThroughFollowUpStoreAndDeleteAllSparesUserRows() async throws {
        let (store, db) = try makeStore()
        let followUps = FollowUpStore(db: db)
        try await followUps.add(text: "Hand-written follow-up", nowMs: 50)
        try await store.save(
            ActionItem(id: "seg-1-action-0", text: "Call Sam", sourceSegmentId: "seg-1",
                       createdAtMs: 100))

        // Extracted items land in the same table the Today card reads.
        let all = try await followUps.list()
        #expect(all.map(\.text).contains("Call Sam"))

        try await store.deleteAll()
        #expect(try await store.list() == [])
        let remaining = try await followUps.list()
        #expect(remaining.map(\.text) == ["Hand-written follow-up"])
    }
}
