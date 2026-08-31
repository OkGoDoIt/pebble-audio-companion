import Foundation
import GRDB
import SegmentStore
import Testing

@testable import AppDB

@Suite struct StoresTests {
    @Test func tagRenameIsGlobal() async throws {
        let db = try AppDatabase.inMemory()
        let store = TagStore(db: db)
        let tagId = try await store.addTag(conversationId: "c1", name: "travel", source: "ai")
        let sameId = try await store.addTag(conversationId: "c2", name: "travel", source: "user")
        #expect(tagId == sameId)

        try await store.renameTag(tagId: tagId, to: "trips")
        let c1Tags = try await store.tags(forConversation: "c1")
        let c2Tags = try await store.tags(forConversation: "c2")
        #expect(c1Tags.map(\.name) == ["trips"])
        #expect(c2Tags.map(\.name) == ["trips"])
        // Sources survive the rename.
        #expect(c1Tags[0].source == "ai")
        #expect(c2Tags[0].source == "user")
    }

    @Test func tagRenameOntoExistingNameMerges() async throws {
        let db = try AppDatabase.inMemory()
        let store = TagStore(db: db)
        let travel = try await store.addTag(conversationId: "c1", name: "travel", source: "user")
        let trips = try await store.addTag(conversationId: "c2", name: "trips", source: "user")
        _ = try await store.addTag(conversationId: "c1", name: "trips", source: "user")

        try await store.renameTag(tagId: travel, to: "trips")
        let tags = try await store.listTags()
        #expect(tags.map(\.name) == ["trips"])
        #expect(tags[0].id == trips)
        #expect(tags[0].count == 2)  // c1 (deduped) + c2
    }

    @Test func tagSuggestionsExcludeConversationsOwnTags() async throws {
        let db = try AppDatabase.inMemory()
        let store = TagStore(db: db)
        _ = try await store.addTag(conversationId: "c1", name: "work", source: "user")
        _ = try await store.addTag(conversationId: "c2", name: "family", source: "user")
        _ = try await store.addTag(conversationId: "c2", name: "dining", source: "user")
        let suggestions = try await store.suggestions(forConversation: "c1")
        #expect(Set(suggestions.map(\.name)) == ["family", "dining"])
    }

    @Test func followUpToggle() async throws {
        let db = try AppDatabase.inMemory()
        let store = FollowUpStore(db: db)
        let item = try await store.add(
            text: "Send Dana the new firmware build", conversationId: "c1", nowMs: 1_000)
        #expect(try await store.openCount() == 1)
        #expect(try await store.toggle(id: item.id) == true)
        #expect(try await store.openCount() == 0)
        #expect(try await store.toggle(id: item.id) == false)
        let open = try await store.list(done: false)
        #expect(open.map(\.id) == [item.id])
        #expect(open[0].sourceConversationId == "c1")
    }

    @Test func askHistoryTrimsToFiveNewest() async throws {
        let db = try AppDatabase.inMemory()
        let store = AskHistoryStore(db: db)
        for i in 1...7 {
            _ = try await store.save(
                question: "q\(i)", answerText: "a\(i)",
                citations: [AskCitation(segmentId: "s\(i)", number: 1)],
                scopeDescription: "Today", nowMs: Int64(i) * 1_000)
        }
        let recent = try await store.recent()
        #expect(recent.map(\.question) == ["q7", "q6", "q5", "q4", "q3"])
        #expect(recent[0].citations == [AskCitation(segmentId: "s7", number: 1)])
        let total = try await db.reader.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ask_history") ?? -1
        }
        #expect(total == 5)

        try await store.clear()
        #expect(try await store.recent().isEmpty)
    }

    @Test func speakerRenameByPersonAppliesEverywhere() async throws {
        let db = try AppDatabase.inMemory()
        let store = PeopleStore(db: db)
        let dana = try await store.createPerson(name: "Dana")
        try await store.assign(conversationId: "c1", label: "Speaker 1", personId: dana.id)
        try await store.assign(conversationId: "c2", label: "Speaker 2", personId: dana.id)

        try await store.renamePerson(id: dana.id, to: "Dana K.")
        let c1 = try await store.assignments(forConversation: "c1")
        let c2 = try await store.assignments(forConversation: "c2")
        #expect(c1.map(\.personName) == ["Dana K."])
        #expect(c2.map(\.personName) == ["Dana K."])

        // Reassigning a label is an upsert, not a duplicate row.
        let sam = try await store.createPerson(name: "Sam")
        try await store.assign(conversationId: "c1", label: "Speaker 1", personId: sam.id)
        let updated = try await store.assignments(forConversation: "c1")
        #expect(updated.map(\.personName) == ["Sam"])
    }

    @Test func pauseJournalOpenAndClose() async throws {
        let db = try AppDatabase.inMemory()
        let journal = PauseJournal(db: db)
        let opened = try await journal.begin(source: .statusCard, atMs: 1_000)
        #expect(opened.endMs == nil)

        // A second Pause ack while paused does not stack a new interval.
        let again = try await journal.begin(source: .intent, atMs: 2_000)
        #expect(again.id == opened.id)
        #expect(try await journal.all().count == 1)

        try await journal.end(atMs: 3_000)
        #expect(try await journal.openInterval() == nil)
        let all = try await journal.all()
        #expect(all == [PauseInterval(id: opened.id, startMs: 1_000, endMs: 3_000, source: "statusCard")])

        // Day-overlap query: closed interval overlaps [0, 10s) but not [5s, 6s);
        // an open interval overlaps everything after its start.
        #expect(try await journal.intervals(overlappingMs: 0, 10_000).count == 1)
        #expect(try await journal.intervals(overlappingMs: 5_000, 6_000).isEmpty)
        _ = try await journal.begin(source: .liveScreen, atMs: 5_000)
        #expect(try await journal.intervals(overlappingMs: 6_000, 7_000).count == 1)
    }

    @Test func notesCrud() async throws {
        let db = try AppDatabase.inMemory()
        let store = NotesStore(db: db)
        let note = try await store.create(
            conversationId: "c1", templateId: "meeting-notes", title: "Meeting notes",
            body: "Stop for the night.", citationsJson: "[{\"segmentId\":\"s1\",\"number\":1}]",
            provider: "openai", model: "gpt", nowMs: 1_000)
        #expect(try await store.get(id: note.id)?.editedAtMs == nil)

        try await store.update(id: note.id, title: "Meeting notes", body: "Edited.", nowMs: 2_000)
        let edited = try await store.get(id: note.id)
        #expect(edited?.body == "Edited.")
        #expect(edited?.editedAtMs == 2_000)
        #expect(try await store.list(conversationId: "c1").count == 1)

        try await store.delete(id: note.id)
        #expect(try await store.list(conversationId: "c1").isEmpty)
    }

    @Test func customTemplatesListInCreationOrder() async throws {
        let db = try AppDatabase.inMemory()
        let store = CustomTemplateStore(db: db)
        let first = try await store.add(title: "Retro", prompt: "Summarize as a retro", nowMs: 1_000)
        _ = try await store.add(title: "Standup", prompt: "Summarize as a standup", nowMs: 2_000)
        #expect(try await store.list().map(\.title) == ["Retro", "Standup"])
        try await store.delete(id: first.id)
        #expect(try await store.list().map(\.title) == ["Standup"])
    }

    @Test func coverageDayStoreRoundTrips() async throws {
        let db = try AppDatabase.inMemory()
        let store = CoverageDayStore(db: db)
        let spans = [
            CoverageSpan(kind: .recorded, startMs: 0, endMs: 60_000),
            CoverageSpan(kind: .off, startMs: 60_000, endMs: 120_000),
        ]
        try await store.save(
            DayCoverage(
                dateKey: "2026-03-10", timeZoneID: "UTC", spans: spans,
                totalRecordedMs: 60_000, totalMissingMs: 0))
        #expect(try await store.load(dateKey: "2026-03-10") == spans)
        // Upsert replaces.
        try await store.save(
            DayCoverage(
                dateKey: "2026-03-10", timeZoneID: "UTC", spans: [spans[0]],
                totalRecordedMs: 60_000, totalMissingMs: 0))
        #expect(try await store.load(dateKey: "2026-03-10") == [spans[0]])
    }

    @Test func tagObservationEmitsOnWrite() async throws {
        let db = try AppDatabase.inMemory()
        let store = TagStore(db: db)
        var iterator = store.observeTags().makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial == [])
        _ = try await store.addTag(conversationId: "c1", name: "travel", source: "user")
        let updated = try await iterator.next()
        #expect(updated?.map(\.name) == ["travel"])
    }
}

@Suite struct ConversationQueriesTests {
    /// Builds a two-day library: conv-s1 (2 members, one still pending, tagged, one open
    /// follow-up) on day one; conv-s3 (complete, mostly quiet with a missing minute) on day two.
    func makeFixture() async throws -> (AppDatabase, day1: String, day2: String) {
        let db = try AppDatabase.inMemory()
        let zone = "UTC"
        let day1 = "2026-03-10"
        let day2 = "2026-03-11"
        let day1Start = LogicalDay.bounds(ofDateKey: day1, timeZoneID: zone)!.startMs
        let day2Start = LogicalDay.bounds(ofDateKey: day2, timeZoneID: zone)!.startMs

        let s1 = makeSegment(
            id: "s1", stream: 1, startTimeMs: day1Start + minutesMs(360),
            durationSamples: minutesSamples(10), tz: zone)
        let s2 = makeSegment(
            id: "s2", stream: 1, startTimeMs: day1Start + minutesMs(360),
            firstSample: minutesSamples(12), durationSamples: minutesSamples(10), tz: zone)
        let s3start = day2Start + minutesMs(360)
        let s3 = makeSegment(
            id: "s3", stream: 9, startTimeMs: s3start,
            durationSamples: minutesSamples(20), tz: zone)
        try await ConversationGrouper.rebuild(
            segments: [s1, s2, s3], pauses: [], openSegmentId: nil,
            fallbackTimeZoneID: zone, db: db)

        try await db.writer.write { d in
            for (segment, state) in [("s1", "Complete"), ("s2", "Pending"), ("s3", "Complete")] {
                try d.execute(
                    sql: """
                        INSERT INTO transcription_tasks
                            (segmentId, state, attempts, retryable, createdAtMs, updatedAtMs,
                             providerId)
                        VALUES (?, ?, 0, 1, 0, 0, 'soniox')
                        """,
                    arguments: [segment, state])
            }
            try d.execute(
                sql: "INSERT INTO annotations (conversationId, title, summary, isFinal, sourceCharCount, finalAttempts, updatedAtMs) VALUES ('conv-s1', 'Coffee with Dana', 'Trip planning.', 1, 100, 1, 0)"
            )
        }
        _ = try await TagStore(db: db).addTag(
            conversationId: "conv-s1", name: "work", source: "ai")
        _ = try await FollowUpStore(db: db).add(
            text: "Book the walkthrough", conversationId: "conv-s1", nowMs: 1_000)

        // Day-2 coverage: 15 of conv-s3's 20 minutes quiet (>60%) and 1 minute missing.
        try await CoverageDayStore(db: db).save(
            DayCoverage(
                dateKey: day2, timeZoneID: zone,
                spans: [
                    CoverageSpan(kind: .recorded, startMs: s3start, endMs: s3start + minutesMs(4)),
                    CoverageSpan(
                        kind: .missing, startMs: s3start + minutesMs(4),
                        endMs: s3start + minutesMs(5)),
                    CoverageSpan(
                        kind: .quiet, startMs: s3start + minutesMs(5),
                        endMs: s3start + minutesMs(20)),
                ],
                totalRecordedMs: minutesMs(4), totalMissingMs: minutesMs(1)))
        return (db, day1, day2)
    }

    @Test func librarySectionsProjectionsAndAggregation() async throws {
        let (db, day1, day2) = try await makeFixture()
        let sections = try await ConversationQueries(db: db).library()
        #expect(sections.map(\.dateKey) == [day2, day1])

        let s3Row = sections[0].rows[0]
        #expect(s3Row.id == "conv-s3")
        #expect(s3Row.lifecycle == .complete)
        #expect(s3Row.mostlyQuiet)
        #expect(s3Row.hasMissingAudio)
        #expect(s3Row.title == nil)

        let s1Row = sections[1].rows[0]
        #expect(s1Row.id == "conv-s1")
        #expect(s1Row.title == "Coffee with Dana")
        #expect(s1Row.summary == "Trip planning.")
        #expect(s1Row.lifecycle == .capturedWaiting)
        #expect(s1Row.tags == ["work"])
        #expect(s1Row.followUpCount == 1 && s1Row.openFollowUpCount == 1)
        #expect(!s1Row.mostlyQuiet && !s1Row.hasMissingAudio)
        #expect(s1Row.durationMs == minutesMs(22))
    }

    @Test func libraryFilters() async throws {
        let (db, _, _) = try await makeFixture()
        let queries = ConversationQueries(db: db)

        func ids(_ filter: LibraryFilter, tag: String? = nil) async throws -> [String] {
            try await queries.library(filter: filter, tagName: tag)
                .flatMap(\.rows).map(\.id)
        }
        #expect(try await ids(.all) == ["conv-s3", "conv-s1"])
        #expect(try await ids(.untranscribed) == ["conv-s1"])
        #expect(try await ids(.withFollowUps) == ["conv-s1"])
        #expect(try await ids(.withMissingAudio) == ["conv-s3"])
        #expect(try await ids(.all, tag: "work") == ["conv-s1"])
        #expect(try await ids(.all, tag: "family") == [])
    }

    @Test func detailListsMembersWithProvenance() async throws {
        let (db, _, _) = try await makeFixture()
        let detail = try await ConversationQueries(db: db).detail(id: "conv-s1")
        let members = try #require(detail?.members)
        #expect(members.map(\.segmentId) == ["s1", "s2"])
        #expect(members.map(\.ordinal) == [0, 1])
        #expect(members.map(\.state) == [.complete, .pending])
        #expect(members[0].providerId == "soniox")
        #expect(try await ConversationQueries(db: db).detail(id: "nope") == nil)
    }

    @Test func lifecycleAggregationPrecedence() {
        typealias Q = ConversationQueries
        #expect(Q.aggregateLifecycle([.running, .complete]) == .transcribing)
        #expect(Q.aggregateLifecycle([.uploading, .failed]) == .transcribing)
        #expect(Q.aggregateLifecycle([.pending, .failed]) == .capturedWaiting)
        #expect(Q.aggregateLifecycle([nil, .complete]) == .capturedWaiting)
        #expect(Q.aggregateLifecycle([.disabled]) == .capturedWaiting)
        #expect(Q.aggregateLifecycle([.failed, .complete]) == .failed)
        #expect(Q.aggregateLifecycle([.complete, .noSpeech]) == .complete)
    }
}
