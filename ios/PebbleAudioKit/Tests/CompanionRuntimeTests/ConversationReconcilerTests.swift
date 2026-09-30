import AppDB
import Foundation
import GRDB
import Intelligence
import Testing

// `ConversationReconciler`: what is attached to a conversation stays attached when the grouping
// moves under it. A conversation's id is its start position, a rebuild can cut, join or move
// any of them, and the first rebuild after conversations became topic-sized re-cut them all —
// while follow-ups, notes, tags, speaker names and titles go on naming conversations by id.
//
// (The type lives in AppDB. Its tests live here because they need the stores that write every
// kind of row it moves, and those are spread over AppDB and Intelligence.)

@Suite("conversation reconciler — records follow their moment, or their conversation")
struct ConversationReconcilerTests {
    private let db: AppDatabase
    private let reconciler: ConversationReconciler
    private let followUps: FollowUpStore
    private let candidates: FollowUpCandidateStore
    private let notes: NotesStore
    private let tags: TagStore
    private let people: PeopleStore
    private let annotations: AnnotationStore
    private let extractions: FollowUpExtractionStore

    init() throws {
        let db = try AppDatabase.inMemory()
        self.db = db
        reconciler = ConversationReconciler(db: db)
        followUps = FollowUpStore(db: db)
        candidates = FollowUpCandidateStore(db: db)
        notes = NotesStore(db: db)
        tags = TagStore(db: db)
        people = PeopleStore(db: db)
        annotations = try AnnotationStore(db: db, nowMs: { 1_000 })
        extractions = try FollowUpExtractionStore(db: db)
    }

    // MARK: Harness

    private func piece(_ id: String, from: Int64? = nil, to: Int64? = nil) -> ConversationMember {
        ConversationMember(segmentId: id, startMediaMs: from, endMediaMs: to)
    }

    private func conversation(
        _ id: String, _ members: ConversationMember..., startMs: Int64 = 0
    ) -> GroupedConversation {
        GroupedConversation(
            id: id, startMs: startMs, endMs: startMs + 1, timeZoneID: "UTC", isLive: false,
            members: members)
    }

    /// Persists a grouping the way a rebuild does.
    private func persist(_ grouping: [GroupedConversation]) async throws {
        try await db.writer.write { d in _ = try ConversationGrouper.apply(grouping, in: d) }
    }

    private func followUp(
        _ id: String, in conversationId: String?, segment: String?, at startMs: Int64?,
        origin: FollowUpOrigin = .ai
    ) async throws {
        try await followUps.upsertExtracted(
            FollowUp(
                id: id, text: "Do \(id)", done: false, sourceConversationId: conversationId,
                sourceSegmentId: segment, createdAtMs: 1, sourceStartMs: startMs,
                sourceEndMs: startMs.map { $0 + 4_000 }, origin: origin))
    }

    private func source(of followUpId: String) async throws -> String? {
        try await followUps.load(id: followUpId)?.sourceConversationId
    }

    /// Every `conversation_tags` pair of a conversation, tombstones included.
    private func tagSources(_ conversationId: String) async throws -> [String: String] {
        try await db.reader.read { d in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(
                d,
                sql: """
                    SELECT t.name AS name, ct.source AS source
                    FROM conversation_tags ct JOIN tags t ON t.id = ct.tagId
                    WHERE ct.conversationId = ?
                    """,
                arguments: [conversationId])
            {
                out[row["name"]] = row["source"]
            }
            return out
        }
    }

    private func count(_ table: String) async throws -> Int {
        try await db.reader.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    // The library before and after a cut: one conversation over two segments becomes three.
    private var whole: [GroupedConversation] {
        [
            conversation("conv-seg-1", piece("seg-1"), piece("seg-2")),
            conversation("conv-seg-9", piece("seg-9"), startMs: 9_000),
        ]
    }
    private var cut: [GroupedConversation] {
        [
            conversation("conv-seg-1", piece("seg-1", to: 600_000)),
            conversation(
                "conv-seg-1-m600000", piece("seg-1", from: 600_000), piece("seg-2", to: 300_000),
                startMs: 600),
            conversation("conv-seg-2-m300000", piece("seg-2", from: 300_000), startMs: 1_200),
            conversation("conv-seg-9", piece("seg-9"), startMs: 9_000),
        ]
    }

    // MARK: Moments

    @Test("a follow-up goes to the conversation that now owns the moment it was said")
    func followUpsFollowTheirMoment() async throws {
        try await persist(whole)
        try await followUp("early", in: "conv-seg-1", segment: "seg-1", at: 100_000)
        try await followUp("late", in: "conv-seg-1", segment: "seg-1", at: 700_000)
        try await followUp("next", in: "conv-seg-1", segment: "seg-2", at: 50_000)
        try await followUp("tail", in: "conv-seg-1", segment: "seg-2", at: 800_000)
        // Found in the text but not in a timed turn: no offset to place it by.
        try await followUp("unplaced-1", in: "conv-seg-1", segment: "seg-1", at: nil)
        try await followUp("unplaced-2", in: "conv-seg-1", segment: "seg-2", at: nil)
        // Written by hand on the conversation's screen: no moment at all.
        try await followUp("typed", in: "conv-seg-1", segment: nil, at: nil, origin: .user)
        try await followUp("elsewhere", in: "conv-seg-9", segment: "seg-9", at: 5_000)
        try await candidates.save(
            FollowUpCandidate(
                id: "conv-seg-1-action-aa", conversationId: "conv-seg-1", segmentId: "seg-1",
                task: "pending", startMs: 700_000, createdAtMs: 1))
        try await candidates.save(
            FollowUpCandidate(
                id: "conv-seg-1-action-bb", conversationId: "conv-seg-1", segmentId: "seg-1",
                task: "decided", startMs: 700_000, createdAtMs: 1, state: .kept))

        try await persist(cut)
        let outcome = try await reconciler.reconcile(previous: whole, current: cut)

        #expect(try await source(of: "early") == "conv-seg-1")
        #expect(try await source(of: "late") == "conv-seg-1-m600000")
        #expect(try await source(of: "next") == "conv-seg-1-m600000")
        #expect(try await source(of: "tail") == "conv-seg-2-m300000")
        // Still inside a segment its conversation owns part of: it stays.
        #expect(try await source(of: "unplaced-1") == "conv-seg-1")
        // Its conversation owns none of that segment any more: the segment's start.
        #expect(try await source(of: "unplaced-2") == "conv-seg-1-m600000")
        #expect(try await source(of: "typed") == "conv-seg-1")
        #expect(try await source(of: "elsewhere") == "conv-seg-9")
        #expect(outcome.followUpsRepointed == 4)
        // Offsets are untouched: still media ms in the segment.
        #expect(try await followUps.load(id: "late")?.sourceStartMs == 700_000)

        // The pending proposal moves with its moment; the decided one is history.
        #expect(
            try await candidates.list(conversationId: "conv-seg-1-m600000").map(\.task)
                == ["pending"])
        #expect(try await candidates.list(conversationId: "conv-seg-1").map(\.task) == ["decided"])
        #expect(outcome.candidatesRepointed == 1)
        #expect(outcome.superseded.isEmpty)
    }

    @Test("it looks only at conversations whose pieces changed")
    func unchangedConversationsAreNotExamined() async throws {
        try await persist(whole)
        // Deliberately wrong, in a conversation nothing happens to.
        try await followUp("stray", in: "conv-seg-1", segment: "seg-9", at: 0)
        let same = try await reconciler.reconcile(previous: whole, current: whole)
        #expect(same.isEmpty)

        try await persist(cut)
        _ = try await reconciler.reconcile(previous: whole, current: cut)
        // seg-9's conversation did not change, so rows about seg-9 were not read.
        #expect(try await source(of: "stray") == "conv-seg-1")
        // The once-a-launch sweep is what reads everything.
        #expect(try await reconciler.sweep().followUpsRepointed == 1)
        #expect(try await source(of: "stray") == "conv-seg-9")
    }

    // MARK: A conversation whose id went away

    /// Two conversations sharing `seg-1`, then joined: the second one's id is gone and the
    /// first holds its start.
    private var parted: [GroupedConversation] {
        [
            conversation("conv-seg-1", piece("seg-1", to: 600_000)),
            conversation("conv-seg-1-m600000", piece("seg-1", from: 600_000), startMs: 600),
        ]
    }
    private var joined: [GroupedConversation] { [conversation("conv-seg-1", piece("seg-1"))] }
    private let gone = "conv-seg-1-m600000"
    private let successor = "conv-seg-1"

    @Test("notes, the person's tags and speaker names move to the successor; the model's go")
    func aSupersededConversationHandsOver() async throws {
        try await persist(parted)
        let note = try await notes.create(
            conversationId: gone, templateId: "summary", title: "Notes", body: "Body")
        try await followUp("typed", in: gone, segment: nil, at: nil, origin: .user)
        // (Saved before the tags below: a save adopts the annotation's own tag list, and these
        // carry none.)
        try await annotations.save(
            ConversationAnnotation(
                conversationId: gone, title: "The match", summary: "Penalties.", isFinal: true))
        try await annotations.save(
            ConversationAnnotation(
                conversationId: successor, title: "The fence", summary: "Primer.", isFinal: true))
        // Tags on the one that goes: the person's, one they removed, the model's.
        try await tags.addTag(conversationId: gone, name: "holiday", source: TagSource.user)
        let work = try await tags.addTag(conversationId: gone, name: "work", source: TagSource.ai)
        try await tags.removeTag(conversationId: gone, tagId: work)
        try await tags.addTag(conversationId: gone, name: "football", source: TagSource.ai)
        try await tags.addTag(conversationId: gone, name: "family", source: TagSource.user)
        // On the successor already: the model proposed two of the same names, and the person
        // had added a third themselves.
        try await tags.addTag(conversationId: successor, name: "holiday", source: TagSource.ai)
        try await tags.addTag(conversationId: successor, name: "work", source: TagSource.ai)
        try await tags.addTag(conversationId: successor, name: "family", source: TagSource.user)
        try await tags.addTag(conversationId: successor, name: "fence", source: TagSource.ai)

        let alex = try await people.createPerson(name: "Alex")
        let sam = try await people.createPerson(name: "Sam")
        try await people.assign(conversationId: gone, label: "Speaker 1", personId: alex.id)
        try await people.assign(conversationId: gone, label: "Speaker 2", personId: alex.id)
        try await people.assign(conversationId: successor, label: "Speaker 2", personId: sam.id)

        try await extractions.save(
            FollowUpExtractionState(conversationId: gone, settled: true, itemCount: 1))
        try await extractions.save(
            FollowUpExtractionState(conversationId: successor, settled: true, itemCount: 0))

        try await persist(joined)
        let outcome = try await reconciler.reconcile(previous: parted, current: joined)
        #expect(outcome.superseded == [gone: successor])

        #expect(try await notes.get(id: note.id)?.conversationId == successor)
        #expect(outcome.notesMoved == 1)
        #expect(try await source(of: "typed") == successor)

        // The person's decisions win on the successor; the model's old tags are gone; nothing
        // is left under the old id.
        #expect(
            try await tagSources(successor) == [
                "holiday": TagSource.user, "work": TagSource.removed,
                "family": TagSource.user, "fence": TagSource.ai,
            ])
        #expect(try await tagSources(gone).isEmpty)
        #expect(outcome.tagsMoved == 2)

        let speakers = try await people.assignments(forConversation: successor)
        #expect(
            speakers.map { "\($0.label)=\($0.personName)" } == ["Speaker 1=Alex", "Speaker 2=Sam"])
        #expect(outcome.speakerAssignmentsMoved == 1)
        // The name that lost to the successor's own is left where it was, not deleted.
        #expect(
            try await people.assignments(forConversation: gone).map(\.label) == ["Speaker 2"])

        #expect(try await annotations.load(gone) == nil)
        #expect(try await annotations.load(successor)?.title == "The fence")
        #expect(outcome.annotationsRemoved == 1 && outcome.titlesMoved == 0)
        #expect(try await extractions.load(gone) == nil)
        #expect(try await extractions.load(successor)?.settled == true)
    }

    @Test("a title the person typed moves to a successor that has none of its own")
    func aTypedTitleMoves() async throws {
        try await persist(parted)
        try await annotations.save(
            ConversationAnnotation(
                conversationId: gone, title: "The match", summary: "Penalties.", isFinal: true))
        let typed = try await annotations.setUserTitle("Sunday football", conversationId: gone)
        try await annotations.save(
            ConversationAnnotation(
                conversationId: successor, title: "The fence", summary: "Primer.",
                tags: ["fence"], isFinal: true, sourceKey: "seg-1@0-600000"))

        try await persist(joined)
        let outcome = try await reconciler.reconcile(previous: parted, current: joined)
        #expect(outcome.titlesMoved == 1)
        let kept = try #require(try await annotations.load(successor))
        #expect(kept.title == "Sunday football")
        #expect(kept.titleEditedAtMs == typed.titleEditedAtMs)
        // Everything else about the successor's annotation is its own.
        #expect(kept.summary == "Primer." && kept.tags == ["fence"])
        #expect(try await annotations.load(gone) == nil)
    }

    @Test("a successor with no annotation gets the typed title alone; one with its own keeps it")
    func aTypedTitleAndTheSuccessorsOwn() async throws {
        try await persist(parted)
        try await annotations.setUserTitle("Sunday football", conversationId: gone)
        try await persist(joined)
        _ = try await reconciler.reconcile(previous: parted, current: joined)
        let carried = try #require(try await annotations.load(successor))
        #expect(carried.title == "Sunday football" && carried.titleEditedAtMs != nil)
        #expect(carried.summary == nil && !carried.isFinal && carried.sourceKey == nil)

        // Parted and joined again, with a typed title on each: the successor's stands.
        try await persist(parted)
        try await annotations.setUserTitle("Penalties", conversationId: gone)
        try await persist(joined)
        let outcome = try await reconciler.reconcile(previous: parted, current: joined)
        #expect(outcome.titlesMoved == 0 && outcome.annotationsRemoved == 1)
        #expect(try await annotations.load(successor)?.title == "Sunday football")
    }

    @Test("running it twice changes nothing the second time")
    func itIsIdempotent() async throws {
        try await persist(parted)
        try await followUp("late", in: successor, segment: "seg-1", at: 700_000)
        try await notes.create(
            conversationId: gone, templateId: "summary", title: "Notes", body: "Body")
        try await tags.addTag(conversationId: gone, name: "holiday", source: TagSource.user)
        try await annotations.setUserTitle("Sunday football", conversationId: gone)

        // Cut further, then joined: both shapes of change, each run twice.
        try await persist(joined)
        let first = try await reconciler.reconcile(previous: parted, current: joined)
        #expect(!first.isEmpty)
        let snapshot = try await (
            source(of: "late"), notes.list(conversationId: successor).count,
            tagSources(successor), annotations.load(successor)
        )
        let second = try await reconciler.reconcile(previous: parted, current: joined)
        #expect(second.isEmpty)
        #expect(try await reconciler.sweep().isEmpty)
        #expect(try await source(of: "late") == snapshot.0)
        #expect(try await notes.list(conversationId: successor).count == snapshot.1)
        #expect(try await tagSources(successor) == snapshot.2)
        #expect(try await annotations.load(successor) == snapshot.3)
    }

    @Test("nothing a person made is ever deleted, whatever the grouping does")
    func nothingPersonMadeIsLost() async throws {
        try await persist(whole)
        for (index, position) in [(0, 100_000), (1, 700_000), (2, 850_000)] {
            try await followUp("fu-\(index)", in: "conv-seg-1", segment: "seg-1", at: Int64(position))
        }
        try await followUp("typed", in: "conv-seg-1", segment: nil, at: nil, origin: .user)
        try await notes.create(
            conversationId: "conv-seg-1", templateId: "summary", title: "Notes", body: "Body")
        try await tags.addTag(conversationId: "conv-seg-1", name: "holiday", source: TagSource.user)

        // Cut, joined, cut differently, emptied, restored.
        let recut = [
            conversation("conv-seg-1", piece("seg-1", to: 800_000)),
            conversation("conv-seg-1-m800000", piece("seg-1", from: 800_000), piece("seg-2")),
            conversation("conv-seg-9", piece("seg-9"), startMs: 9_000),
        ]
        var previous = whole
        for grouping in [cut, whole, recut, [], whole, cut] {
            // Things get attached to whatever conversations exist along the way.
            for conversation in previous where conversation.id != "conv-seg-9" {
                try await notes.create(
                    conversationId: conversation.id, templateId: "summary", title: "N", body: "B")
                try await tags.addTag(
                    conversationId: conversation.id, name: "t-\(conversation.id)",
                    source: TagSource.user)
            }
            try await persist(grouping)
            _ = try await reconciler.reconcile(previous: previous, current: grouping)
            _ = try await reconciler.sweep()
            previous = grouping
        }

        #expect(try await followUps.list(scope: .all).count == 4)
        // The one it began with, and one per conversation that existed before each rebuild.
        #expect(try await count("notes") == 1 + (1 + 3 + 1 + 2 + 0 + 1))
        let userPairs = try await db.reader.read { d in
            try Int.fetchOne(
                d, sql: "SELECT COUNT(DISTINCT tagId) FROM conversation_tags WHERE source = 'user'")
        }
        // holiday + one per distinct conversation id that ever existed.
        #expect(userPairs == 1 + 4)
        // And every follow-up with a moment is in the conversation that owns it.
        #expect(try await source(of: "fu-0") == "conv-seg-1")
        #expect(try await source(of: "fu-1") == "conv-seg-1-m600000")
        #expect(try await source(of: "fu-2") == "conv-seg-1-m600000")
    }

    // MARK: No successor

    @Test("a conversation with no successor is left entirely alone")
    func noSuccessorMeansNoAction() async throws {
        try await persist(parted)
        try await annotations.save(
            ConversationAnnotation(
                conversationId: gone, title: "The match", summary: "Penalties.", tags: ["football"],
                isFinal: true))
        try await tags.addTag(conversationId: gone, name: "holiday", source: TagSource.user)
        try await notes.create(
            conversationId: gone, templateId: "summary", title: "Notes", body: "Body")
        try await followUp("late", in: gone, segment: "seg-1", at: 700_000)
        try await extractions.save(FollowUpExtractionState(conversationId: gone, settled: true))

        // The grouping is momentarily empty — a rebuild over a store that could not be listed.
        // Nothing may be torn down: the same ids come back on the next rebuild.
        try await persist([])
        let emptied = try await reconciler.reconcile(previous: parted, current: [])
        #expect(emptied.isEmpty && emptied.superseded.isEmpty)
        #expect(try await reconciler.sweep().isEmpty)
        #expect(try await annotations.load(gone)?.title == "The match")
        #expect(try await tagSources(gone) == ["holiday": TagSource.user, "football": TagSource.ai])
        #expect(try await notes.list(conversationId: gone).count == 1)
        #expect(try await source(of: "late") == gone)
        #expect(try await extractions.load(gone)?.settled == true)

        try await persist(parted)
        #expect(try await reconciler.reconcile(previous: [], current: parted).isEmpty)
        #expect(try await annotations.load(gone)?.title == "The match")
    }

    // MARK: The launch sweep

    @Test("the sweep heals a rebuild whose reconciliation never ran")
    func sweepWorksFromTheDatabaseAlone() async throws {
        // As the database is after a re-cut that was written and never reconciled: the old
        // grouping is gone, and rows still name it.
        try await persist(cut)
        try await followUp("late", in: "conv-seg-1", segment: "seg-1", at: 700_000)
        try await followUp("tail", in: "conv-seg-2", segment: "seg-2", at: 800_000)
        try await candidates.save(
            FollowUpCandidate(
                id: "conv-seg-2-action-aa", conversationId: "conv-seg-2", segmentId: "seg-2",
                task: "pending", startMs: 100_000, createdAtMs: 1))
        // `conv-seg-2` started at seg-2's first frame, which `conv-seg-1-m600000` holds now.
        let note = try await notes.create(
            conversationId: "conv-seg-2", templateId: "summary", title: "Notes", body: "Body")
        try await tags.addTag(conversationId: "conv-seg-2", name: "holiday", source: TagSource.user)
        try await annotations.save(
            ConversationAnnotation(conversationId: "conv-seg-2", title: "Old", isFinal: true))
        // An id written with an offset, whose position another conversation now holds.
        try await tags.addTag(
            conversationId: "conv-seg-2-m500000", name: "walk", source: TagSource.user)
        // Ids nothing can be read from, or whose audio is gone: untouched.
        try await notes.create(
            conversationId: "imported-7", templateId: "summary", title: "Old", body: "Body")
        try await notes.create(
            conversationId: "conv-seg-deleted", templateId: "summary", title: "Old", body: "Body")

        let outcome = try await reconciler.sweep()
        #expect(try await source(of: "late") == "conv-seg-1-m600000")
        #expect(try await source(of: "tail") == "conv-seg-2-m300000")
        #expect(
            try await candidates.list(conversationId: "conv-seg-1-m600000").map(\.task)
                == ["pending"])
        #expect(try await notes.get(id: note.id)?.conversationId == "conv-seg-1-m600000")
        #expect(try await tagSources("conv-seg-1-m600000") == ["holiday": TagSource.user])
        #expect(try await tagSources("conv-seg-2-m300000") == ["walk": TagSource.user])
        #expect(try await annotations.load("conv-seg-2") == nil)
        #expect(
            outcome.superseded == [
                "conv-seg-2": "conv-seg-1-m600000", "conv-seg-2-m500000": "conv-seg-2-m300000",
            ])
        #expect(try await notes.list(conversationId: "imported-7").count == 1)
        #expect(try await notes.list(conversationId: "conv-seg-deleted").count == 1)
        #expect(try await reconciler.sweep().isEmpty)
    }
}
