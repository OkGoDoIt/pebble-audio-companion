import AppDB
import Foundation
import Testing
import Transcription

@testable import CompanionRuntime

@Suite("legacy names before retranscription")
struct LegacySpeakerMigrationTests {
    private func database() async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO conversations (id, startMs, endMs, timezone, state)
                VALUES ('c', 0, 1000, 'UTC', 'closed');
                INSERT INTO conversation_segments (conversationId, segmentId, ordinal, startMediaMs, endMediaMs)
                VALUES ('c', 's', 0, 100, 500), ('c', 'neighbor', 1, NULL, NULL);
                """)
        }
        return db
    }

    private func transcript(_ turns: [TranscriptSegment]) -> SegmentTranscript {
        SegmentTranscript(segmentId: "s", text: "old transcript", modeUsed: .remoteOnly,
                          providerId: "openai", createdAtMs: 1, segments: turns)
    }

    @Test func anchorsOnlyThePieceAndPreservesNewerDecisionsAndNeighborNames() async throws {
        let db = try await database()
        let people = PeopleStore(db: db)
        let original = try await people.createPerson(name: "Alex")
        let neighbor = try await people.createPerson(name: "Blair")
        try await people.assign(conversationId: "c", label: "1", personId: original.id)
        try await people.assign(conversationId: "c", label: "neighbor#1", personId: neighbor.id)
        let corrections = SpeakerCorrectionStore(db: db)
        try await corrections.set(segmentId: "s", startMediaMs: 150, endMediaMs: 200, personId: nil)
        let outcome = try await LegacySpeakerMigration.anchorBeforeReprocessing(
            segmentId: "s", transcript: transcript([
                TranscriptSegment(text: "first", startMs: 100, endMs: 300, speaker: "1"),
                TranscriptSegment(text: "second", startMs: 400, endMs: 600, speaker: "1"),
            ]), database: db, nowMs: 2)
        #expect(outcome.anchoredRanges == 3)
        #expect(outcome.unanchoredAssignments == 0)
        let identity = try await corrections.snapshot(segmentIds: ["s"])
        #expect(identity.resolve(segmentId: "s", startMediaMs: 100, endMediaMs: 150) == .named(original))
        #expect(identity.resolve(segmentId: "s", startMediaMs: 150, endMediaMs: 200) == .unnamed)
        #expect(identity.resolve(segmentId: "s", startMediaMs: 200, endMediaMs: 300) == .named(original))
        #expect(identity.resolve(segmentId: "s", startMediaMs: 400, endMediaMs: 500) == .named(original))
        #expect(identity.resolve(segmentId: "s", startMediaMs: 500, endMediaMs: 600) == nil)
        let remaining = try await people.assignments(forConversation: "c")
        #expect(remaining.count == 1)
        #expect(remaining.first?.label == "neighbor#1" && remaining.first?.personId == neighbor.id)
        // A replacement transcript's different numeric label does not change the human anchor.
        #expect(SpeakerAttribution.person(
            segmentId: "s", startMediaMs: 200, endMediaMs: 300, speaker: "new-label",
            identity: identity, legacyAssignments: remaining)?.id == original.id)
    }

    @Test func untimedTargetDropsUnsafeNameButKeepsBroadNameOnUntimedNeighbor() async throws {
        let db = try await database()
        let people = PeopleStore(db: db)
        let person = try await people.createPerson(name: "Alex")
        try await people.assign(conversationId: "c", label: "Speaker 1", personId: person.id)
        let outcome = try await LegacySpeakerMigration.anchorBeforeReprocessing(
            segmentId: "s", transcript: transcript([]), database: db, nowMs: 2)
        #expect(outcome.anchoredRanges == 0 && outcome.unanchoredAssignments == 1)
        let remaining = try await people.assignments(forConversation: "c")
        #expect(remaining.count == 1)
        #expect(remaining.first?.label == "neighbor#1" && remaining.first?.personId == person.id)
        #expect(SpeakerAssignment.match(SpeakerKey(segmentId: "s", label: "1"), in: remaining) == nil)
    }

    @Test func overlappingDifferentPeopleAreNotForcedIntoOneIdentity() async throws {
        let db = try await database()
        let people = PeopleStore(db: db)
        let first = try await people.createPerson(name: "Alex")
        let second = try await people.createPerson(name: "Blair")
        try await people.assign(conversationId: "c", label: "s#1", personId: first.id)
        try await people.assign(conversationId: "c", label: "s#2", personId: second.id)
        _ = try await LegacySpeakerMigration.anchorBeforeReprocessing(
            segmentId: "s", transcript: transcript([
                TranscriptSegment(text: "first", startMs: 100, endMs: 250, speaker: "1"),
                TranscriptSegment(text: "second", startMs: 200, endMs: 300, speaker: "2"),
            ]), database: db, nowMs: 2)
        let identity = try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"])
        #expect(identity.resolve(segmentId: "s", startMediaMs: 100, endMediaMs: 200) == .named(first))
        #expect(identity.resolve(segmentId: "s", startMediaMs: 200, endMediaMs: 250) == nil)
        #expect(identity.resolve(segmentId: "s", startMediaMs: 250, endMediaMs: 300) == .named(second))
    }
}
