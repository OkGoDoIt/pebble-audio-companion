import Foundation
import GRDB
import Testing

@testable import AppDB

@Suite struct SpeakerCorrectionStoreTests {
    @Test func selfIsExplicitStableAndIndependentOfDisplayName() async throws {
        let db = try AppDatabase.inMemory()
        let people = PeopleStore(db: db)
        let literalYou = try await people.createPerson(name: "You")
        let roger = try await people.createPerson(name: "Roger")
        #expect(try await people.currentUserPersonId() == nil)
        #expect(try await people.listPeople().allSatisfy { !$0.person.isCurrentUser })
        try await people.assign(conversationId: "c", label: "1", personId: roger.id)
        try await people.setCurrentUser(personId: roger.id)
        try await people.renamePerson(id: roger.id, to: "You")
        #expect(try await people.currentUserPersonId() == roger.id)
        #expect(try await people.assignments(forConversation: "c").first?.isCurrentUser == true)
        let both = try await people.listPeople().map(\.person)
        #expect(both.count == 2)
        #expect(both.first { $0.id == literalYou.id }?.isCurrentUser == false)
        #expect(both.first { $0.id == roger.id }?.isCurrentUser == true)
        try await people.setCurrentUser(personId: literalYou.id)
        #expect(try await people.assignments(forConversation: "c").first?.isCurrentUser == false)
    }

    @Test func overlappingEditsPreserveOutsideAudioAndBlockSmearing() async throws {
        let db = try AppDatabase.inMemory()
        let store = SpeakerCorrectionStore(db: db)
        let alex = try await PeopleStore(db: db).createPerson(name: "Alex")
        let sam = try await PeopleStore(db: db).createPerson(name: "Sam")
        try await store.set(segmentId: "seg", startMediaMs: 100, endMediaMs: 1_000, personId: alex.id)
        try await store.set(segmentId: "seg", startMediaMs: 400, endMediaMs: 600, personId: sam.id)
        let snapshot = try await store.snapshot(segmentIds: ["seg"])
        #expect(snapshot.corrections.map(\.startMediaMs) == [100, 400, 600])
        #expect(snapshot.corrections.map(\.endMediaMs) == [400, 600, 1_000])
        #expect(snapshot.resolve(segmentId: "seg", startMediaMs: 100, endMediaMs: 400) == .named(alex))
        #expect(snapshot.resolve(segmentId: "seg", startMediaMs: 400, endMediaMs: 600) == .named(sam))
        #expect(snapshot.resolve(segmentId: "seg", startMediaMs: 100, endMediaMs: 1_000) == .partial)
        #expect(snapshot.resolve(segmentId: "seg", startMediaMs: 0, endMediaMs: 200) == .partial)
        #expect(snapshot.resolve(segmentId: "seg", startMediaMs: 1_000, endMediaMs: 1_100) == nil)
        #expect(snapshot.resolve(segmentId: "another", startMediaMs: 400, endMediaMs: 600) == nil)
        // Retranscription/grouping needs no mutation: the decision belongs to these samples.
        #expect(snapshot.resolve(segmentId: "seg", startMediaMs: 410, endMediaMs: 590) == .named(sam))
    }

    @Test func unnamedIsAnExplicitLockAndIdenticalSavesDoNotPublishChanges() async throws {
        let db = try AppDatabase.inMemory()
        let store = SpeakerCorrectionStore(db: db)
        let sam = try await PeopleStore(db: db).createPerson(name: "Sam")
        try await store.set(segmentId: "s", startMediaMs: 0, endMediaMs: 100, personId: sam.id)
        try await store.set(segmentId: "s", startMediaMs: 100, endMediaMs: 200, personId: sam.id)
        var snapshot = try await store.snapshot(segmentIds: ["s"])
        #expect(snapshot.resolve(segmentId: "s", startMediaMs: 0, endMediaMs: 200) == .named(sam))
        let before = snapshot.revision
        try await store.set(segmentId: "s", startMediaMs: 0, endMediaMs: 200, personId: sam.id)
        #expect(try await store.snapshot(segmentIds: ["s"]).revision == before)
        try await store.set(segmentId: "s", startMediaMs: 50, endMediaMs: 150, personId: nil)
        snapshot = try await store.snapshot(segmentIds: ["s"])
        #expect(snapshot.resolve(segmentId: "s", startMediaMs: 50, endMediaMs: 150) == .unnamed)
        #expect(snapshot.resolve(segmentId: "s", startMediaMs: 40, endMediaMs: 150) == .partial)
        let lockedRevision = snapshot.revision
        try await store.set(segmentId: "s", startMediaMs: 50, endMediaMs: 150, personId: nil)
        #expect(try await store.snapshot(segmentIds: ["s"]).revision == lockedRevision)
    }

    @Test func invalidOrMissingPersonRollsBackCorrectionAndCurrentUserTogether() async throws {
        let db = try AppDatabase.inMemory()
        let people = PeopleStore(db: db)
        let store = SpeakerCorrectionStore(db: db)
        let person = try await people.createPerson(name: "Sam")
        try await store.set(segmentId: "s", startMediaMs: 0, endMediaMs: 100, personId: person.id,
                            makeCurrentUser: true)
        let before = try await store.snapshot(segmentIds: ["s"])
        await #expect(throws: (any Error).self) {
            try await store.set(segmentId: "s", startMediaMs: 0, endMediaMs: 100,
                                personId: "missing", makeCurrentUser: true)
        }
        await #expect(throws: SpeakerCorrectionError.invalidRange) {
            try await store.set(segmentId: "s", startMediaMs: -1, endMediaMs: 100, personId: nil)
        }
        await #expect(throws: SpeakerCorrectionError.invalidRange) {
            try await store.set(segmentId: "s", startMediaMs: 100, endMediaMs: 100, personId: nil)
        }
        await #expect(throws: SpeakerCorrectionError.missingCurrentUser) {
            try await store.set(segmentId: "s", startMediaMs: 0, endMediaMs: 100,
                                personId: nil, makeCurrentUser: true)
        }
        #expect(try await store.snapshot(segmentIds: ["s"]) == before)
        #expect(try await people.currentUserPersonId() == person.id)
        #expect(before.resolve(segmentId: "s", startMediaMs: 0, endMediaMs: 100)
                == .named(Person(id: person.id, name: person.name, isCurrentUser: true)))
    }

    @Test func deletionClearsOnlyItsAudioAndPersonDeletionLeavesUnnamedLocks() async throws {
        let db = try AppDatabase.inMemory()
        let people = PeopleStore(db: db)
        let store = SpeakerCorrectionStore(db: db)
        let person = try await people.createPerson(name: "Sam")
        try await store.set(segmentId: "s", startMediaMs: 0, endMediaMs: 100, personId: person.id,
                            makeCurrentUser: true)
        try await store.set(segmentId: "other", startMediaMs: 0, endMediaMs: 100, personId: nil)
        try await store.removeRange(segmentId: "s", startMediaMs: 40, endMediaMs: 60)
        var snapshot = try await store.snapshot(segmentIds: ["s", "other"])
        #expect(snapshot.resolve(segmentId: "s", startMediaMs: 40, endMediaMs: 60) == nil)
        #expect(snapshot.resolve(segmentId: "s", startMediaMs: 0, endMediaMs: 100) == .partial)
        #expect(snapshot.corrections.filter { $0.segmentId == "s" }.count == 2)
        try await people.deletePerson(id: person.id)
        snapshot = try await store.snapshot(segmentIds: ["s", "other"])
        #expect(snapshot.currentUserPersonId == nil)
        #expect(snapshot.corrections.count == 3)
        #expect(snapshot.resolve(segmentId: "s", startMediaMs: 0, endMediaMs: 40) == .unnamed)
        #expect(snapshot.resolve(segmentId: "s", startMediaMs: 60, endMediaMs: 100) == .unnamed)
        try await store.delete(segmentId: "other")
        #expect(try await store.snapshot(segmentIds: ["other"]).corrections.isEmpty)
    }

    @Test func rangeAndSelfChangesEnqueueOnlyAffectedConversationPieces() async throws {
        let db = try AppDatabase.inMemory()
        try await addPieces(db)
        let people = PeopleStore(db: db)
        let store = SpeakerCorrectionStore(db: db)
        let outbox = ArchiveOutbox(db: db)
        let person = try await people.createPerson(name: "Sam")
        try await outbox.setActive(true)
        try await outbox.clearAll()
        try await store.set(segmentId: "s", startMediaMs: 10, endMediaMs: 100, personId: person.id)
        #expect(Set(try await outbox.pending(limit: 20).map(\.entityId)) == ["c1"])
        #expect(Set(try await outbox.pending(limit: 20).map(\.kind)) == [.conversation, .transcript])
        #expect(try await store.affectedConversationIds(segmentId: "s", startMediaMs: 10, endMediaMs: 100) == ["c1"])
        #expect(try await people.conversationIds(assignedTo: person.id) == ["c1"])
        #expect(try await store.snapshot(conversationId: "c2").resolve(
            segmentId: "s", startMediaMs: 100, endMediaMs: 200) == nil)
        try await outbox.clearAll()
        try await people.setCurrentUser(personId: person.id)
        #expect(Set(try await outbox.pending(limit: 20).map(\.entityId)) == ["c1"])
        let revision = try await store.snapshot(segmentIds: []).revision
        try await outbox.clearAll()
        try await people.setCurrentUser(personId: person.id)
        #expect(try await outbox.pending(limit: 20).isEmpty)
        #expect(try await store.snapshot(segmentIds: []).revision == revision)
        try await people.renamePerson(id: person.id, to: "Alex")
        #expect(Set(try await outbox.pending(limit: 20).map(\.entityId)) == ["c1", person.id])
        try await outbox.clearAll()
        try await people.deletePerson(id: person.id)
        #expect(Set(try await outbox.pending(limit: 20).map(\.entityId)) == ["c1", person.id])
    }

    @Test func detailObservesManualCorrectionAndSelfRoleChanges() async throws {
        let db = try AppDatabase.inMemory()
        try await addPieces(db)
        let people = PeopleStore(db: db)
        let person = try await people.createPerson(name: "Roger")
        var observations = ConversationQueries(db: db).observeDetail(id: "c1").makeAsyncIterator()
        let first = try await observations.next()
        try await SpeakerCorrectionStore(db: db).set(
            segmentId: "s", startMediaMs: 10, endMediaMs: 50, personId: person.id)
        let named = try await observations.next()
        #expect(named??.identityRevision != first??.identityRevision)
        try await people.setCurrentUser(personId: person.id)
        let selfNamed = try await observations.next()
        #expect(selfNamed??.identityRevision != named??.identityRevision)
    }

    @Test func upgradePreservesLegacyNamesWithoutGuessingSelf() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        var database: AppDatabase? = try AppDatabase.open(at: url)
        let person = try await PeopleStore(db: #require(database)).createPerson(name: "You")
        try await PeopleStore(db: #require(database)).assign(conversationId: "legacy", label: "Speaker 1", personId: person.id)
        try await #require(database).writer.write { d in
            let triggers = try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'identity_%'")
            for trigger in triggers { try d.execute(sql: "DROP TRIGGER \(trigger)") }
            try d.execute(sql: """
                DROP TABLE speaker_corrections;
                DROP TABLE speaker_identity_state;
                DELETE FROM grdb_migrations WHERE identifier = 'speaker-identity-foundation-v1';
                """)
        }
        try database?.writer.close()
        database = nil
        let reopened = try AppDatabase.open(at: url)
        let people = PeopleStore(db: reopened)
        #expect(try await people.assignments(forConversation: "legacy").map(\.personId) == [person.id])
        #expect(try await people.currentUserPersonId() == nil)
        #expect(try await SpeakerCorrectionStore(db: reopened).snapshot(segmentIds: ["s"]).corrections.isEmpty)
        try reopened.writer.close()
    }

    private func addPieces(_ db: AppDatabase) async throws {
        try await db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO conversations (id, startMs, endMs, timezone, state)
                VALUES ('c1', 0, 100, 'UTC', 'closed'), ('c2', 100, 200, 'UTC', 'closed');
                INSERT INTO conversation_segments (conversationId, segmentId, ordinal, startMediaMs, endMediaMs)
                VALUES ('c1', 's', 0, 0, 100), ('c2', 's', 0, 100, 200);
                """)
        }
    }
}
