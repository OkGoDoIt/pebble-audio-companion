import Foundation
import Testing
@testable import AppDB

@Suite struct VoiceArchiveRevocationTests {
    private func ready() async throws -> (AppDatabase, VoiceIdentityStore, Person) {
        let db = try AppDatabase.inMemory()
        let store = VoiceIdentityStore(db: db)
        let person = try await PeopleStore(db: db).createPerson(name: "Alex")
        try await store.setMode(.local)
        _ = try await store.prepareSource(segmentId: "s", revision: "digest")
        let token = try #require(try await store.workContext(segmentId: "s")).token
        #expect(try await store.commitExample(VoiceConfirmedExample(personId: person.id,
            confirmationID: "human", sessionID: "session", segmentId: "s", startMediaMs: 0,
            endMediaMs: 2_000, sourceRevision: "digest", recipeID: "recipe", recipeJSON: Data("{}".utf8),
            embeddingJSON: Data("{}".utf8), qualityJSON: Data("{}".utf8)), token: token))
        return (db, store, person)
    }
    private func insert(_ store: VoiceIdentityStore, person: Person, run: String,
                        start: Int64 = 3_000, created: Int64 = 1) async throws {
        let token = try #require(try await store.workContext(segmentId: "s")).token
        #expect(try await store.commitAutomatic(VoiceAutomaticAttribution(personId: person.id,
            segmentId: "s", startMediaMs: start, endMediaMs: start + 2_000, sourceRevision: "digest",
            recipeID: "recipe", score: 0.9, margin: 0.2, calibrationID: "test", runID: run,
            createdAtMs: created), token: token))
    }

    @Test func forgettingExpiredEvidenceStillRevokesArchiveAndSurvivesRelinking() async throws {
        let (db, voice, person) = try await ready()
        let outbox = ArchiveOutbox(db: db), records = VoiceArchiveRevocationStore(db: db)
        try await outbox.setActive(true)
        try await insert(voice, person: person, run: "old")
        let before = try #require(try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"])
            .automaticAttributions.first?.attribution)
        #expect(before.archiveOriginID != nil && before.archiveGeneration == 0)
        try await voice.expireSource(segmentId: "s")
        #expect(try await records.all().isEmpty)
        try await voice.forgetProfile(personId: person.id)
        let revoke = try #require(try await records.all().last)
        #expect(revoke.scope == .person && revoke.targetID == person.id)
        #expect(revoke.originID == before.archiveOriginID && revoke.generation > before.archiveGeneration)
        #expect(try await records.load(id: revoke.id) == revoke)
        #expect(try await outbox.pending(limit: 100).contains { $0.entityId == revoke.id })
        try await outbox.setActive(false)
        try await outbox.setActive(true)
        _ = try await outbox.markEverything()
        #expect(try await outbox.pending(limit: 100).contains { $0.entityId == revoke.id })
    }

    @Test func monotonicGenerationSeparatesOldNamesFromFreshMatchesDespiteClockRollback() async throws {
        let (db, voice, person) = try await ready()
        try await insert(voice, person: person, run: "old", created: 10_000)
        try await voice.clearAutomatic(nowMs: 1)
        let revoke = try #require(try await VoiceArchiveRevocationStore(db: db).all().last)
        #expect(revoke.scope == .all && revoke.targetID == nil)
        try await insert(voice, person: person, run: "new", start: 6_000, created: 0)
        let newer = try #require(try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"])
            .automaticAttributions.first?.attribution)
        #expect(newer.archiveGeneration == revoke.generation)
        #expect(newer.archiveOriginID == revoke.originID)
        #expect(newer.createdAtMs < 10_000)
    }

    @Test func undoRevokesOnlyItsRunAndPreservesALaterExplicitPass() async throws {
        let (db, voice, person) = try await ready()
        try await insert(voice, person: person, run: "earlier")
        try await insert(voice, person: person, run: "later")
        try await voice.undoRun("earlier")
        let rows = try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"]).automaticAttributions
        #expect(rows.map { $0.attribution.runID } == ["later"])
        let revoke = try #require(try await VoiceArchiveRevocationStore(db: db).all().last)
        #expect(revoke.scope == .run && revoke.targetID == "earlier")
    }

    @Test func contradictoryHumanCorrectionRevokesSavedEvidenceButKeepsManualName() async throws {
        let (db, _, person) = try await ready()
        try await SpeakerCorrectionStore(db: db).set(segmentId: "s", startMediaMs: 0,
            endMediaMs: 2_000, personId: nil)
        let revokes = try await VoiceArchiveRevocationStore(db: db).all()
        #expect(revokes.contains { $0.scope == .person && $0.targetID == person.id })
        let snapshot = try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"])
        #expect(snapshot.resolve(segmentId: "s", startMediaMs: 0, endMediaMs: 2_000) == .unnamed)
    }
}
