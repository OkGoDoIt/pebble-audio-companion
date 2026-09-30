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

    @Test func aiTagsAreAdoptedAndAReRunReplacesItsOwnSet() async throws {
        let db = try AppDatabase.inMemory()
        let store = TagStore(db: db)
        #expect(try await store.applyAiTags(conversationId: "c1", names: ["work", "budget"]))
        #expect(try await store.tags(forConversation: "c1").map(\.name) == ["budget", "work"])
        // Re-running the pass over the same conversation is a no-op, not a write: every
        // library observation would otherwise wake on an unchanged proposal.
        #expect(
            try await store.applyAiTags(conversationId: "c1", names: ["budget", "WORK"]) == false)
        // A different proposal replaces the set rather than piling onto it.
        #expect(try await store.applyAiTags(conversationId: "c1", names: ["budget", "taxes"]))
        #expect(try await store.tags(forConversation: "c1").map(\.name) == ["budget", "taxes"])
    }

    @Test func aRemovedAiTagStaysRemovedAndWhatThePersonAddedIsLeftAlone() async throws {
        let db = try AppDatabase.inMemory()
        let store = TagStore(db: db)
        try await store.applyAiTags(conversationId: "c1", names: ["work", "budget"])
        _ = try await store.addTag(conversationId: "c1", name: "Dana", source: TagSource.user)

        let work = try await store.tags(forConversation: "c1").first { $0.name == "work" }
        try await store.removeTag(conversationId: "c1", tagId: #require(work).id)
        #expect(try await store.tags(forConversation: "c1").map(\.name) == ["budget", "Dana"])

        // The same proposal arrives again on the next pass; it must not undo the removal, and
        // it must not re-source the tag the person typed.
        try await store.applyAiTags(conversationId: "c1", names: ["work", "budget", "Dana"])
        let after = try await store.tags(forConversation: "c1")
        #expect(after.map(\.name) == ["budget", "Dana"])
        #expect(after.first { $0.name == "Dana" }?.source == TagSource.user)
        // A removed name is still offered in the editor — removal is not a ban.
        #expect(try await store.suggestions(forConversation: "c1").map(\.name).contains("work"))
        // ... and it counts for nothing until someone puts it back.
        #expect(try await store.listTags().contains { $0.name == "work" } == false)
    }

    @Test func deletingAConversationStopsItsTagsCounting() async throws {
        let db = try AppDatabase.inMemory()
        let store = TagStore(db: db)
        try await store.applyAiTags(conversationId: "c1", names: ["work"])
        try await store.applyAiTags(conversationId: "c2", names: ["work"])
        #expect(try await store.listTags().first?.count == 2)
        try await store.forgetConversation("c2")
        #expect(try await store.listTags().first?.count == 1)
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
        let open = try await store.list(scope: .open, nowMs: 1_000)
        #expect(open.map(\.id) == [item.id])
        #expect(open[0].sourceConversationId == "c1")
    }

    /// Putting something off must not make it disappear. It used to belong to no scope at all:
    /// excluded from Open, not done, not archived — and the only control for un-snoozing lived
    /// on a screen you could no longer reach.
    @Test func aSnoozedFollowUpIsStillOnTheOpenList() async throws {
        let db = try AppDatabase.inMemory()
        let store = FollowUpStore(db: db)
        let now: Int64 = 1_788_000_000_000
        let item = try await store.add(text: "Call the plumber", nowMs: now)
        try await store.snooze(id: item.id, until: now + 86_400_000, nowMs: now)

        let open = try await store.list(scope: .open, nowMs: now)
        #expect(open.map(\.id) == [item.id])
        #expect(open.first?.isSnoozed(at: now) == true)
        // The count Today and the widget use leaves it out: a deferred thing is not something
        // to put in front of somebody this morning.
        #expect(try await store.openCount(nowMs: now) == 0)
        #expect(try await store.list(scope: .archived).isEmpty)
    }

    /// Snoozed rows sort last within Open, so the "Put off" section lands at the bottom.
    @Test func snoozedRowsSortBehindEverythingElse() async throws {
        let db = try AppDatabase.inMemory()
        let store = FollowUpStore(db: db)
        let now: Int64 = 1_788_000_000_000
        let deferred = try await store.add(text: "Later", nowMs: now)
        try await store.snooze(id: deferred.id, until: now + 86_400_000, nowMs: now)
        let live = try await store.add(text: "Now", nowMs: now)
        #expect(try await store.list(scope: .open, nowMs: now).map(\.id) == [live.id, deferred.id])
    }

    /// The age rule's memory of the person: anything they have answered is theirs, not a
    /// clock's. Restore used to leave no trace, so the next pass filed the row away again.
    @Test func anythingThePersonTouchesIsOffTheAgeRule() async throws {
        let db = try AppDatabase.inMemory()
        let store = FollowUpStore(db: db)
        let now: Int64 = 1_788_000_000_000
        let old = now - 30 * 86_400_000
        for id in ["a", "b"] {
            try await store.upsertExtracted(
                FollowUp(
                    id: id, text: id, done: false, sourceConversationId: nil,
                    sourceSegmentId: nil, createdAtMs: old))
        }
        try await store.setArchived(id: "a", true, nowMs: now)
        try await store.setArchived(id: "a", false, nowMs: now)

        #expect(try await store.archiveStale(olderThanMs: 14 * 86_400_000, nowMs: now) == 1)
        #expect(try await store.load(id: "a")?.archivedAtMs == nil, "restored stays restored")
        #expect(try await store.load(id: "b")?.archivedAtMs != nil, "untouched still ages out")
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

    /// The typo path the speaker sheet now offers a way out of: "Alx" and "Alex" both exist,
    /// and fixing the typo has to fold the two together rather than leave two identical names
    /// in the suggestion list forever.
    @Test func renamingAPersonOntoAnExistingNameMerges() async throws {
        let db = try AppDatabase.inMemory()
        let store = PeopleStore(db: db)
        let alex = try await store.createPerson(name: "Alex")
        let typo = try await store.createPerson(name: "Alx")
        try await store.assign(conversationId: "c1", label: "Speaker 1", personId: alex.id)
        try await store.assign(conversationId: "c2", label: "Speaker 2", personId: typo.id)

        try await store.renamePerson(id: typo.id, to: "Alex")

        let people = try await store.listPeople()
        #expect(people.map(\.person.name) == ["Alex"])
        #expect(people.first?.assignmentCount == 2)
        #expect(try await store.assignments(forConversation: "c2").map(\.personId) == [alex.id])
    }

    @Test func renamingAPersonIgnoresBlankNames() async throws {
        let db = try AppDatabase.inMemory()
        let store = PeopleStore(db: db)
        let sam = try await store.createPerson(name: "Sam")
        try await store.renamePerson(id: sam.id, to: "   ")
        #expect(try await store.listPeople().map(\.person.name) == ["Sam"])
    }

    @Test func unassignClearsOneLabelAndDeletePersonClearsThemAll() async throws {
        let db = try AppDatabase.inMemory()
        let store = PeopleStore(db: db)
        let sam = try await store.createPerson(name: "Sam")
        try await store.assign(conversationId: "c1", label: "Speaker 1", personId: sam.id)
        try await store.assign(conversationId: "c2", label: "Speaker 1", personId: sam.id)

        // Unassign is per conversation: the person survives, and other conversations keep them.
        try await store.unassign(conversationId: "c1", label: "Speaker 1")
        #expect(try await store.assignments(forConversation: "c1").isEmpty)
        #expect(try await store.assignments(forConversation: "c2").count == 1)
        #expect(try await store.listPeople().count == 1)

        // Deleting the person cascades the remaining assignment away.
        try await store.deletePerson(id: sam.id)
        #expect(try await store.assignments(forConversation: "c2").isEmpty)
        #expect(try await store.listPeople().isEmpty)
    }

    /// Regenerating a note must rewrite the SAME row: the open screen, the Spotlight entry and
    /// every citation address it by id, so a new id silently orphans all three.
    @Test func replaceContentRewritesTheNoteInPlace() async throws {
        let db = try AppDatabase.inMemory()
        let store = NotesStore(db: db)
        let note = try await store.create(
            conversationId: "c1", templateId: "meeting-notes", title: "Meeting notes",
            body: "First pass.", citationsJson: "[{\"segmentId\":\"s1\",\"number\":1}]",
            provider: "openai", model: "gpt-a", nowMs: 1_000)
        try await store.update(id: note.id, title: "Mine", body: "Edited.", nowMs: 1_500)

        try await store.replaceContent(
            id: note.id, title: "Mine", body: "Second pass.",
            citationsJson: "[{\"segmentId\":\"s2\",\"number\":1}]",
            provider: "openai", model: "gpt-b", nowMs: 2_000)

        let stored = try await store.get(id: note.id)
        #expect(stored?.id == note.id)
        #expect(stored?.body == "Second pass.")
        #expect(stored?.citationsJson == "[{\"segmentId\":\"s2\",\"number\":1}]")
        #expect(stored?.model == "gpt-b")
        // Regenerated text is freshly generated, not user-edited: the provenance moves to now
        // and the "edited" stamp clears.
        #expect(stored?.createdAtMs == 2_000)
        #expect(stored?.editedAtMs == nil)
        #expect(try await store.list(conversationId: "c1").count == 1)
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

    /// B2, as Roger hit it: a migrated library where 331 segments hold a transcript on disk
    /// but only 5 were ever enqueued. Every conversation announced "Captured · waiting to
    /// transcribe / Next in the queue / [Transcribe Now]" directly above its own transcript.
    @Test func segmentWithDurableTranscriptAndNoTaskRowReadsAsTranscribed() async throws {
        let db = try AppDatabase.inMemory()
        var meta = makeSegment(
            id: "imported", stream: 1, startTimeMs: testEpochMs,
            durationSamples: minutesSamples(10), tz: "UTC")
        meta.transcriptionState = .complete
        try await ConversationGrouper.rebuild(
            segments: [meta], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC", db: db)

        // No row in transcription_tasks at all — the queue never saw this segment.
        let row = try #require(try await ConversationQueries(db: db).library()
            .flatMap(\.rows).first)
        #expect(row.lifecycle == .complete)

        let member = try #require(
            try await ConversationQueries(db: db).detail(id: row.id)?.members.first)
        #expect(member.state == nil)  // queue knows nothing
        #expect(member.segmentState == .complete)  // disk does
    }

    @Test func lifecycleAggregationTrustsTheTranscriptOverTheQueue() {
        typealias Q = ConversationQueries
        func member(task: TranscriptionState?, segment: TranscriptionState?)
            -> ConversationMemberState
        { ConversationMemberState(task: task, segment: segment) }

        // The migration case: transcript on disk, no queue row.
        #expect(Q.aggregateLifecycle([member(task: nil, segment: .complete)]) == .complete)
        #expect(Q.aggregateLifecycle([member(task: nil, segment: .noSpeech)]) == .complete)
        // A stale Pending/Failed/Disabled row cannot un-transcribe a stored transcript.
        #expect(Q.aggregateLifecycle([member(task: .pending, segment: .complete)]) == .complete)
        #expect(Q.aggregateLifecycle([member(task: .failed, segment: .complete)]) == .complete)
        #expect(Q.aggregateLifecycle([member(task: .disabled, segment: .noSpeech)]) == .complete)
        // A genuinely un-transcribed member still reads as waiting…
        #expect(
            Q.aggregateLifecycle([
                member(task: nil, segment: .complete), member(task: nil, segment: .pending),
            ]) == .capturedWaiting)
        // …and a re-transcribe in flight still shows, transcript or not.
        #expect(Q.aggregateLifecycle([member(task: .running, segment: .complete)]) == .transcribing)
        #expect(Q.aggregateLifecycle([member(task: .failed, segment: .pending)]) == .failed)
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

// MARK: - Scoped conversation reads (History plan, Phase 1 step 4)

/// `detail(id:)` used to build the row of EVERY conversation and pick one; `rows(overlappingMs:)`
/// is History's windowed read. Both must return exactly what the whole-library build returns for
/// the same conversations — the whole-library path (`buildRows(db)`, scope `.all`) is unchanged
/// and is the reference.
@Suite struct ScopedConversationReadsTests {
    /// Five conversations over three days and two zones: multi-member, pending and complete
    /// members, a failed member, AI/user/removed tags, open/done/archived follow-ups, an
    /// annotation that gave up, coverage with quiet and missing time, and one still live.
    func makeLibrary() async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        let zone = "UTC"
        let day1 = LogicalDay.bounds(ofDateKey: "2026-03-10", timeZoneID: zone)!.startMs
        let day2 = LogicalDay.bounds(ofDateKey: "2026-03-11", timeZoneID: zone)!.startMs
        let day3 = LogicalDay.bounds(ofDateKey: "2026-03-12", timeZoneID: zone)!.startMs
        let ny = "America/New_York"
        let segments = [
            makeSegment(id: "s1", stream: 1, startTimeMs: day1 + minutesMs(360), durationSamples: minutesSamples(10), tz: zone),
            makeSegment(
                id: "s2", stream: 1, startTimeMs: day1 + minutesMs(360), firstSample: minutesSamples(12),
                durationSamples: minutesSamples(10), tz: zone),
            makeSegment(id: "s4", stream: 2, startTimeMs: day1 + minutesMs(600), durationSamples: minutesSamples(30), tz: zone),
            makeSegment(id: "s3", stream: 9, startTimeMs: day2 + minutesMs(360), durationSamples: minutesSamples(20), tz: zone),
            makeSegment(id: "s6", stream: 4, startTimeMs: day2 + minutesMs(900), durationSamples: minutesSamples(45), tz: ny),
            makeSegment(
                id: "s5", stream: 5, startTimeMs: day3 + minutesMs(120), durationSamples: minutesSamples(5),
                close: nil, tz: zone),
        ]
        try await ConversationGrouper.rebuild(
            segments: segments, pauses: [], openSegmentId: "s5", fallbackTimeZoneID: zone, db: db)

        try await db.writer.write { d in
            for (segment, state) in [
                ("s1", "Complete"), ("s2", "Pending"), ("s3", "Complete"), ("s4", "Failed"),
                ("s6", "Running"),
            ] {
                try d.execute(
                    sql: """
                        INSERT INTO transcription_tasks
                            (segmentId, state, attempts, retryable, createdAtMs, updatedAtMs, providerId)
                        VALUES (?, ?, 2, 1, 0, 0, 'soniox')
                        """,
                    arguments: [segment, state])
            }
            try d.execute(
                sql: """
                    INSERT INTO annotations
                        (conversationId, title, summary, isFinal, sourceCharCount, finalAttempts, updatedAtMs)
                    VALUES ('conv-s1', 'Coffee with Dana', 'Trip planning.', 1, 100, 1, 0),
                           ('conv-s3', NULL, NULL, 0, 0, 3, 0),
                           ('conv-s6', 'Standup', NULL, 1, 10, 1, 0)
                    """)
            try d.execute(sql: "INSERT INTO tags (id, name) VALUES ('t-gone', 'gone')")
            try d.execute(
                sql: "INSERT INTO conversation_tags (conversationId, tagId, source) VALUES ('conv-s4', 't-gone', 'removed')")
        }
        let tags = TagStore(db: db)
        _ = try await tags.addTag(conversationId: "conv-s1", name: "work", source: "ai")
        _ = try await tags.addTag(conversationId: "conv-s1", name: "Travel", source: "user")
        _ = try await tags.addTag(conversationId: "conv-s3", name: "work", source: "user")
        _ = try await tags.addTag(conversationId: "conv-s6", name: "alpha", source: "ai")
        let followUps = FollowUpStore(db: db)
        _ = try await followUps.add(text: "Book the walkthrough", conversationId: "conv-s1", segmentId: "s1", nowMs: 1_000)
        let done = try await followUps.add(text: "Send notes", conversationId: "conv-s1", nowMs: 2_000)
        let archived = try await followUps.add(text: "Old idea", conversationId: "conv-s3", nowMs: 3_000)
        _ = try await followUps.add(text: "Loose end", conversationId: "conv-s5", nowMs: 4_000)
        try await db.writer.write { d in
            try d.execute(sql: "UPDATE follow_ups SET done = 1 WHERE id = ?", arguments: [done.id])
            try d.execute(sql: "UPDATE follow_ups SET archivedAtMs = 5000 WHERE id = ?", arguments: [archived.id])
        }
        let s3start = day2 + minutesMs(360)
        try await CoverageDayStore(db: db).save(
            DayCoverage(
                dateKey: "2026-03-11", timeZoneID: zone,
                spans: [
                    CoverageSpan(kind: .recorded, startMs: s3start, endMs: s3start + minutesMs(4)),
                    CoverageSpan(kind: .missing, startMs: s3start + minutesMs(4), endMs: s3start + minutesMs(5)),
                    CoverageSpan(kind: .quiet, startMs: s3start + minutesMs(5), endMs: s3start + minutesMs(20)),
                ],
                totalRecordedMs: minutesMs(4), totalMissingMs: minutesMs(1)))
        return db
    }

    /// `buildDetail` exactly as it was before it was scoped: the whole-library build, one row
    /// picked out, and the member query (which did not change).
    private static func legacyDetail(_ db: Database, id: String) throws -> ConversationDetail? {
        guard let row = try ConversationQueries.buildRows(db).first(where: { $0.id == id }) else {
            return nil
        }
        let members = try Row.fetchAll(
            db,
            sql: """
                SELECT cs.segmentId AS segmentId, cs.ordinal AS ordinal, tt.state AS state,
                    cs.transcriptionState AS segmentState,
                    tt.providerId AS providerId, tt.modelUsed AS modelUsed,
                    tt.modeUsed AS modeUsed, tt.attempts AS attempts, tt.lastError AS lastError
                FROM conversation_segments cs
                LEFT JOIN transcription_tasks tt ON tt.segmentId = cs.segmentId
                WHERE cs.conversationId = ?
                ORDER BY cs.ordinal
                """,
            arguments: [id]
        ).map { member in
            SegmentProvenance(
                segmentId: member["segmentId"], ordinal: member["ordinal"],
                state: (member["state"] as String?).flatMap(TranscriptionState.init(rawValue:)),
                segmentState: (member["segmentState"] as String?).flatMap(TranscriptionState.init(rawValue:)),
                providerId: member["providerId"], modelUsed: member["modelUsed"],
                modeUsed: member["modeUsed"], attempts: member["attempts"] ?? 0,
                lastError: member["lastError"])
        }
        return ConversationDetail(row: row, members: members)
    }

    @Test("detail(id:) is identical to the whole-library build's row for every conversation")
    func detailMatchesTheWholeLibraryBuild() async throws {
        let db = try await makeLibrary()
        let all = try await db.reader.read { try ConversationQueries.buildRows($0) }
        // The fixture really has the variety it claims.
        #expect(all.count == 5)
        #expect(all.contains { $0.isLive })
        #expect(all.contains { $0.tags.count > 1 })
        #expect(all.contains { $0.hasMissingAudio && $0.mostlyQuiet })
        #expect(all.contains { $0.openFollowUpCount < $0.followUpCount })
        #expect(Set(all.map(\.lifecycle)).count >= 3)
        #expect(Set(all.map(\.timeZoneID)).count == 2)

        let queries = ConversationQueries(db: db)
        for id in all.map(\.id) + ["nope"] {
            let legacy = try await db.reader.read { try Self.legacyDetail($0, id: id) }
            let scoped = try await queries.detail(id: id)
            #expect(scoped == legacy, "\(id)")
        }
        #expect(try await queries.detail(id: "nope") == nil)
    }

    @Test("the detail read touches one conversation, not the library")
    func detailDoesNotScanTheLibrary() async throws {
        let db = try await makeLibrary()
        let (scoped, whole) = try await db.writer.write { d -> ([String], [String]) in
            let scoped = try Self.plans(of: d) { _ = try ConversationQueries.buildDetail(d, id: "conv-s3") }
            let whole = try Self.plans(of: d) { _ = try ConversationQueries.buildRows(d) }
            return (scoped, whole)
        }
        // The whole-library build reads every conversation, member and tag; the detail read
        // searches each table by the one conversation's key.
        #expect(whole.contains { $0.hasPrefix("SCAN c ") || $0 == "SCAN c" }, "\(whole)")
        #expect(!scoped.contains { $0.hasPrefix("SCAN") }, "\(scoped)")
        #expect(scoped.contains { $0.contains("SEARCH c USING INDEX sqlite_autoindex_conversations_1 (id=?)") }, "\(scoped)")
    }

    @Test("the windowed read returns exactly the overlapping conversations, edges included")
    func windowedReadEdges() async throws {
        let db = try AppDatabase.inMemory()
        let base: Int64 = 1_772_400_000_000
        // (id, start, end) in minutes from `base`.
        let conversations: [(String, Int64, Int64?)] = [
            ("ends-at-window-start", 100, 200),
            ("straddles-start", 150, 250),
            ("inside", 250, 300),
            ("starts-at-window-end", 400, 500),
            ("spans-whole-window", 100, 600),
            // No end at all. The grouper always writes one (a live conversation's is its extent
            // so far — see the next test), but the column is nullable, and a row without one must
            // not vanish from every window.
            ("open-inside", 350, nil),
            ("open-after", 450, nil),
            ("open-from-before", 50, nil),
            ("no-length-inside", 300, 300),
            ("no-length-at-start", 200, 200),
            ("no-length-at-end", 400, 400),
            ("after", 500, 520),
        ]
        try await db.writer.write { d in
            for (id, start, end) in conversations {
                try d.execute(
                    sql: "INSERT INTO conversations (id, startMs, endMs, timezone, state) VALUES (?, ?, ?, 'UTC', ?)",
                    arguments: [id, base + minutesMs(start), end.map { base + minutesMs($0) }, end == nil ? "live" : "closed"])
            }
        }
        let queries = ConversationQueries(db: db)
        let window = (base + minutesMs(200))..<(base + minutesMs(400))
        let ids = Set(try await queries.rows(overlappingMs: window).map(\.id))
        #expect(
            ids == [
                "straddles-start", "inside", "spans-whole-window", "open-inside", "open-from-before",
                "no-length-inside", "no-length-at-start",
            ])
        #expect(try await queries.rows(overlappingMs: window.lowerBound..<window.lowerBound).isEmpty)

        // And every row is the whole-library row, in the whole library's order, for any window.
        let all = try await db.reader.read { try ConversationQueries.buildRows($0) }
        func overlaps(_ row: ConversationListRow, _ w: Range<Int64>) -> Bool {
            let hasNoEnd = conversations.first { $0.0 == row.id }!.2 == nil
            let end = hasNoEnd ? Int64.max : row.endMs
            return row.startMs < w.upperBound && (end > w.lowerBound || row.startMs >= w.lowerBound)
        }
        for startMinute in stride(from: Int64(0), through: 620, by: 25) {
            for length in [Int64(1), 50, 100, 300] {
                let w = (base + minutesMs(startMinute))..<(base + minutesMs(startMinute + length))
                let windowed = try await queries.rows(overlappingMs: w)
                #expect(windowed == all.filter { overlaps($0, w) }, "\(startMinute)+\(length)")
            }
        }
    }

    @Test("the windowed read is the whole-library row for every conversation it returns")
    func windowedRowsMatchTheWholeLibraryBuild() async throws {
        let db = try await makeLibrary()
        let all = try await db.reader.read { try ConversationQueries.buildRows($0) }
        let queries = ConversationQueries(db: db)
        for key in ["2026-03-09", "2026-03-10", "2026-03-11", "2026-03-12", "2026-03-13"] {
            let bounds = LogicalDay.bounds(ofDateKey: key, timeZoneID: "UTC")!
            let windowed = try await queries.rows(overlappingMs: bounds.startMs..<bounds.endMs)
            // The grouper always writes an end — a live conversation's is its extent so far,
            // kept current every pass — so here overlap is plain overlap of the stored span.
            #expect(windowed == all.filter { row in
                row.startMs < bounds.endMs && (row.endMs > bounds.startMs || row.startMs >= bounds.startMs)
            }, "\(key)")
        }
        // The live conversation (day 3) is read at its extent so far: in its own day, not the next.
        let day3 = LogicalDay.bounds(ofDateKey: "2026-03-12", timeZoneID: "UTC")!
        let day4 = LogicalDay.bounds(ofDateKey: "2026-03-13", timeZoneID: "UTC")!
        #expect(try await queries.rows(overlappingMs: day3.startMs..<day3.endMs).contains { $0.isLive })
        #expect(try await queries.rows(overlappingMs: day4.startMs..<day4.endMs).isEmpty)
        let everything = try await queries.rows(overlappingMs: Int64.min..<Int64.max)
        #expect(everything == all)
    }

    @Test("the windowed read uses conversations_start and reads the rest by key")
    func windowedReadUsesTheStartIndex() async throws {
        let db = try await makeLibrary()
        let day2 = LogicalDay.bounds(ofDateKey: "2026-03-11", timeZoneID: "UTC")!
        let plans = try await db.writer.write { d in
            try Self.plans(of: d) {
                _ = try ConversationQueries.buildRows(d, scope: .overlapping(day2.startMs..<day2.endMs))
            }
        }
        #expect(plans.contains { $0.contains("SEARCH c USING INDEX conversations_start (startMs<?)") }, "\(plans)")
        #expect(!plans.contains { $0.hasPrefix("SCAN") }, "\(plans)")
    }

    /// The `EXPLAIN QUERY PLAN` detail lines of every statement `body` runs.
    private static func plans(of db: Database, _ body: () throws -> Void) throws -> [String] {
        final class Box { var sql: [String] = [] }
        let box = Box()
        db.trace { event in
            if case .statement(let statement) = event { box.sql.append(statement.expandedSQL) }
        }
        try body()
        db.trace(options: [])
        var lines: [String] = []
        for sql in box.sql where sql.uppercased().hasPrefix("SELECT") {
            for row in try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)") {
                lines.append(row["detail"])
            }
        }
        return lines
    }
}
