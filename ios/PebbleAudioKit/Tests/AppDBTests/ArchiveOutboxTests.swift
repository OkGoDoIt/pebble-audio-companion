import Foundation
import GRDB
import Testing

@testable import AppDB

// The archive sync's outbox (`ArchiveOutbox.swift`): what a change to the library leaves for the
// server, and what the server's answer clears. The behaviours that matter are the ones the
// server cannot repair: an expiry sent as a delete loses a month of memory on the server, a
// delete sent as an expiry keeps something the person deleted, and an answer applied twice (or
// to a newer version) drops a change on the floor.

@Suite("archive outbox")
struct ArchiveOutboxTests {
    func linked() async throws -> (AppDatabase, ArchiveOutbox) {
        let db = try AppDatabase.inMemory()
        let outbox = ArchiveOutbox(db: db)
        try await outbox.setActive(true)
        return (db, outbox)
    }

    func conversation(
        _ id: String, segment: String, startMs: Int64 = testEpochMs,
        endMs: Int64 = testEpochMs + 60_000, live: Bool = false, provisional: Bool = false
    ) -> GroupedConversation {
        GroupedConversation(
            id: id, startMs: startMs, endMs: endMs, timeZoneID: "Asia/Jakarta", isLive: live,
            members: [ConversationMember(segmentId: segment)], isProvisional: provisional)
    }

    func apply(_ db: AppDatabase, _ conversations: [GroupedConversation]) async throws {
        try await db.writer.write { d in _ = try ConversationGrouper.apply(conversations, in: d) }
    }

    @Test func nothingIsRecordedUntilAServerIsLinkedAndUnlinkingForgetsIt() async throws {
        let db = try AppDatabase.inMemory()
        let outbox = ArchiveOutbox(db: db)
        let followUps = FollowUpStore(db: db)
        _ = try await followUps.add(text: "Call the plumber")
        #expect(try await outbox.counts().pending == 0)

        try await outbox.setActive(true)
        let item = try await followUps.add(text: "Book the car service")
        let row = try #require(try await outbox.row(kind: .followUp, id: item.id))
        #expect(row.op == .upsert && row.pending)

        // The first sync after linking sends the whole library, the earlier item included.
        try await outbox.markEverything()
        #expect(try await outbox.counts().pending == 2)

        try await outbox.setActive(false)
        #expect(try await outbox.row(kind: .followUp, id: item.id) == nil)
    }

    @Test func aReplayedAnswerClearsNothingTwiceAndNeverClearsANewerChange() async throws {
        let (db, outbox) = try await linked()
        let followUps = FollowUpStore(db: db)
        let item = try await followUps.add(text: "Send the invoice")
        let sent = try #require(try await outbox.row(kind: .followUp, id: item.id))
        let key = ArchiveItemKey(kind: .followUp, entityId: item.id, version: sent.version)
        try await outbox.markInFlight([ArchiveSentItem(key: key, hash: "h1", pieceKey: nil)])

        #expect(try await outbox.acknowledge([key]) == 1)
        // The same answer delivered again (a background session replaying after a relaunch).
        #expect(try await outbox.acknowledge([key]) == 0)
        let cleared = try #require(try await outbox.row(kind: .followUp, id: item.id))
        #expect(!cleared.pending && cleared.sentHash == "h1")

        // A change after the batch was built: a newer version, which the old answer must not
        // clear — even within the same millisecond, the version only goes up.
        try await followUps.setText(id: item.id, "Send the invoice today")
        let changed = try #require(try await outbox.row(kind: .followUp, id: item.id))
        #expect(changed.pending && changed.version > sent.version)
        #expect(try await outbox.acknowledge([key]) == 0)
        #expect(try await outbox.row(kind: .followUp, id: item.id)?.pending == true)

        // An answer for the new version clears it; the hash stays the last one sent with it.
        let newer = ArchiveItemKey(kind: .followUp, entityId: item.id, version: changed.version)
        #expect(try await outbox.acknowledge([newer]) == 1)
        #expect(try await outbox.row(kind: .followUp, id: item.id)?.sentHash == "h1")
    }

    @Test func aRejectedItemParksAfterItsAttemptsAndANewChangeStartsItOver() async throws {
        let (db, outbox) = try await linked()
        let followUps = FollowUpStore(db: db)
        let item = try await followUps.add(text: "Renew the passport")
        for attempt in 1...ArchiveOutbox.maxAttempts {
            let parked = try await outbox.reject(
                kind: .followUp, id: item.id, reason: "payload: text missing")
            #expect(parked == (attempt == ArchiveOutbox.maxAttempts))
        }
        #expect(try await outbox.pending(limit: 10).isEmpty)
        let counts = try await outbox.counts()
        #expect(counts.parked == 1 && counts.lastParkedError == "payload: text missing")

        try await followUps.setText(id: item.id, "Renew the passport this week")
        #expect(try await outbox.pending(limit: 10).map(\.entityId) == [item.id])
    }

    /// The three ops, end to end through the writes that make them.
    @Test func userDeletesAreDeletesRetentionIsExpiryAndExpiryIsNotUndoneByItsOwnCascade()
        async throws
    {
        let (db, outbox) = try await linked()
        let followUps = FollowUpStore(db: db)
        let notes = NotesStore(db: db)
        let day = LogicalDay.dateKey(forMs: testEpochMs, timeZoneID: "Asia/Jakarta")
        try await apply(db, [
            conversation("conv-seg-old", segment: "seg-old"),
            conversation("conv-seg-new", segment: "seg-new", startMs: testEpochMs + 120_000,
                endMs: testEpochMs + 180_000),
        ])
        #expect(try await outbox.row(kind: .conversation, id: "conv-seg-old")?.op == .upsert)
        #expect(try await outbox.row(kind: .transcript, id: "conv-seg-old")?.op == .upsert)
        #expect(try await outbox.row(kind: .coverage, id: day)?.op == .upsert)

        let said = try await followUps.add(
            text: "Pay the deposit", conversationId: "conv-seg-old", segmentId: "seg-old")
        let note = try await notes.create(
            conversationId: "conv-seg-old", templateId: "summary", title: "Summary", body: "…")
        let mine = try await followUps.add(text: "Water the plants")

        // The person deletes a follow-up: delete.
        try await followUps.delete(id: mine.id)
        #expect(try await outbox.row(kind: .followUp, id: mine.id)?.op == .delete)

        // Retention ages `seg-old` out: everything the server should keep is marked expired
        // FIRST, and the cascade's own deletes — the follow-up, the note, the conversation
        // leaving the grouping — do not turn it into a delete.
        try await outbox.markExpiring(segmentId: "seg-old")
        try await followUps.delete(id: said.id)
        try await notes.delete(id: note.id)
        try await apply(db, [
            conversation("conv-seg-new", segment: "seg-new", startMs: testEpochMs + 120_000,
                endMs: testEpochMs + 180_000)
        ])
        #expect(try await outbox.row(kind: .conversation, id: "conv-seg-old")?.op == .expire)
        #expect(try await outbox.row(kind: .transcript, id: "conv-seg-old")?.op == .expire)
        #expect(try await outbox.row(kind: .followUp, id: said.id)?.op == .expire)
        #expect(try await outbox.row(kind: .note, id: note.id)?.op == .expire)
        #expect(try await outbox.row(kind: .coverage, id: day)?.op == .expire)
        // ...and an expiry is final for upserts: what is regenerated about an aged-out day is
        // never sent over what the server kept.
        try await db.writer.write { d in
            try ArchiveOutbox.enqueue(d, kind: .coverage, id: day, op: .upsert)
        }
        #expect(try await outbox.row(kind: .coverage, id: day)?.op == .expire)

        // The person deletes a conversation retention had already marked: the delete wins.
        try await outbox.markExpiring(segmentId: "seg-new")
        try await outbox.markUserDelete(conversationId: "conv-seg-new")
        #expect(try await outbox.row(kind: .conversation, id: "conv-seg-new")?.op == .delete)
        #expect(try await outbox.row(kind: .transcript, id: "conv-seg-new")?.op == .delete)

        // A conversation re-cut away (its id gone, nobody deleted anything) is a delete.
        try await apply(db, [
            conversation("conv-seg-a", segment: "seg-a"),
        ])
        try await apply(db, [
            conversation("conv-seg-b", segment: "seg-a"),
        ])
        #expect(try await outbox.row(kind: .conversation, id: "conv-seg-a")?.op == .delete)
        #expect(try await outbox.row(kind: .conversation, id: "conv-seg-b")?.op == .upsert)
    }

    @Test func theLiveConversationsCreepingEndIsNotAChangeButClosingAndSettlingAre()
        async throws
    {
        let (db, outbox) = try await linked()
        try await apply(db, [conversation("conv-seg-1", segment: "seg-1", live: true,
            provisional: true)])
        let first = try #require(try await outbox.row(kind: .conversation, id: "conv-seg-1"))
        try await outbox.acknowledge([
            ArchiveItemKey(kind: .conversation, entityId: "conv-seg-1", version: first.version)
        ])

        // The watch keeps recording: the end moves, nothing else does.
        try await apply(db, [conversation("conv-seg-1", segment: "seg-1",
            endMs: testEpochMs + 90_000, live: true, provisional: true)])
        #expect(try await outbox.row(kind: .conversation, id: "conv-seg-1")?.pending == false)

        // It stops being provisional with no stored row changing: marked.
        try await apply(db, [conversation("conv-seg-1", segment: "seg-1",
            endMs: testEpochMs + 90_000, live: true, provisional: false)])
        let settled = try #require(try await outbox.row(kind: .conversation, id: "conv-seg-1"))
        #expect(settled.pending && settled.hint == "p0")
        try await outbox.acknowledge([
            ArchiveItemKey(kind: .conversation, entityId: "conv-seg-1", version: settled.version)
        ])

        // It closes: marked.
        try await apply(db, [conversation("conv-seg-1", segment: "seg-1",
            endMs: testEpochMs + 95_000)])
        #expect(try await outbox.row(kind: .conversation, id: "conv-seg-1")?.pending == true)
    }

    @Test func aSpeakersNewNameMarksEveryConversationAndTranscriptItIsIn() async throws {
        let (db, outbox) = try await linked()
        try await apply(db, [conversation("conv-seg-1", segment: "seg-1")])
        let people = PeopleStore(db: db)
        let person = try await people.createPerson(name: "Rodger")
        try await people.assign(conversationId: "conv-seg-1", label: "1", personId: person.id)
        for row in try await outbox.pending(limit: 50) {
            try await outbox.acknowledge([
                ArchiveItemKey(kind: row.kind, entityId: row.entityId, version: row.version)
            ])
        }
        try await people.renamePerson(id: person.id, to: "Roger")
        let pending = Set(try await outbox.pending(limit: 50).map { "\($0.kind.rawValue):\($0.entityId)" })
        #expect(pending == ["person:\(person.id)", "conversation:conv-seg-1", "transcript:conv-seg-1"])

        // Deleting the person takes the assignment with it (a foreign-key cascade), and both
        // the person and the conversation's people list are news.
        try await people.deletePerson(id: person.id)
        #expect(try await outbox.row(kind: .person, id: person.id)?.op == .delete)
        #expect(try await outbox.row(kind: .transcript, id: "conv-seg-1")?.pending == true)
    }
}
