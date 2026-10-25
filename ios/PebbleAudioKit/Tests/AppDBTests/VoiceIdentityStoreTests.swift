import Foundation
import GRDB
import Testing
@testable import AppDB

@Suite struct VoiceIdentityStoreTests {
    private func ready() async throws -> (AppDatabase, VoiceIdentityStore, Person) {
        let db = try AppDatabase.inMemory()
        let store = VoiceIdentityStore(db: db)
        let person = try await PeopleStore(db: db).createPerson(name: "Alex")
        try await store.setMode(.local)
        _ = try await store.prepareSource(segmentId: "s", revision: "digest-v1")
        return (db, store, person)
    }
    private func token(_ store: VoiceIdentityStore) async throws -> VoiceWorkToken {
        try #require(try await store.workContext(segmentId: "s")).token
    }
    private func example(_ person: Person, id: String = UUID().uuidString, start: Int64 = 0) -> VoiceConfirmedExample {
        VoiceConfirmedExample(id: id, personId: person.id, confirmationID: "human-\(id)", sessionID: "session",
            segmentId: "s", startMediaMs: start, endMediaMs: start + 2_000, sourceRevision: "digest-v1",
            recipeID: "recipe", recipeJSON: Data("{\"model\":\"pinned\"}".utf8),
            embeddingJSON: Data("{\"values\":[0.6,0.8]}".utf8), qualityJSON: Data("{\"duration\":2}".utf8), createdAtMs: 10)
    }
    private func auto(_ person: Person, run: String = "run", start: Int64 = 3_000, end: Int64 = 5_000,
                      disposition: VoiceAttributionDisposition = .recognized) -> VoiceAutomaticAttribution {
        VoiceAutomaticAttribution(personId: person.id, segmentId: "s", startMediaMs: start, endMediaMs: end,
            sourceRevision: "digest-v1", recipeID: "recipe", score: 0.91, margin: 0.2,
            calibrationID: "evaluation-1", runID: run, disposition: disposition, createdAtMs: 20)
    }
    private func enroll(_ store: VoiceIdentityStore, _ person: Person) async throws {
        #expect(try await store.commitExample(example(person), token: token(store)))
    }

    @Test func offIsDefaultAndCancellationCannotPartiallyEnroll() async throws {
        let db = try AppDatabase.inMemory()
        let store = VoiceIdentityStore(db: db)
        #expect(try await store.configuration().mode == .off)
        let person = try await PeopleStore(db: db).createPerson(name: "Alex")
        _ = try await store.prepareSource(segmentId: "s", revision: "digest-v1")
        // Human enrollment is allowed during setup before the person enables recognition.
        #expect(try await !store.commitExamples([example(person), example(person, start: 2_000)],
                                               token: token(store), authorize: { false }))
        #expect(try await store.examples().isEmpty)
        let before = try await store.configuration().corpusRevision
        #expect(try await store.commitExamples([example(person), example(person, start: 2_000)], token: token(store)))
        #expect(try await store.configuration().corpusRevision == before + 1)
        #expect(try await !store.commitAutomatic(auto(person), token: token(store)))
        #expect(try await store.examples().count == 2)
        // A duplicate crop with a new example ID does not grow the profile or revision.
        #expect(try await store.commitExample(example(person), token: token(store)))
        #expect(try await store.configuration().corpusRevision == before + 1)
    }

    @Test func malformedBatchRollsBackAndProfilesAreBounded() async throws {
        let (_, store, person) = try await ready()
        var invalid = example(person, start: 2_000)
        invalid.embeddingJSON = Data("not json".utf8)
        await #expect(throws: VoiceIdentityError.invalidRecord) {
            try await store.commitExamples([example(person), invalid], token: token(store))
        }
        #expect(try await store.examples().isEmpty)
        let examples = (0..<32).map { example(person, start: Int64($0) * 2_000) }
        #expect(try await store.commitExamples(examples, token: token(store)))
        await #expect(throws: VoiceIdentityError.capacityExceeded) {
            try await store.commitExample(example(person, start: 64_000), token: token(store))
        }
        #expect(try await store.profiles().first?.exampleCount == 32)
    }

    @Test func simultaneousSelfSetupCreatesOneExplicitIdentity() async throws {
        let db = try AppDatabase.inMemory()
        let people = PeopleStore(db: db)
        _ = try await people.createPerson(name: "You")
        async let a = people.ensureCurrentUser(displayName: "Roger")
        async let b = SpeakerCorrectionStore(db: db).assignCurrentUser(
            segmentId: "s", startMediaMs: 0, endMediaMs: 100, displayName: "Current user")
        let (first, second) = try await (a, b)
        #expect(first.id == second.id)
        #expect(first.isCurrentUser && second.isCurrentUser)
        #expect(try await people.listPeople().count == 2)
    }

    @Test func automaticNamesAreDistinctFromManualAndSuggestionsAbstain() async throws {
        let (db, store, person) = try await ready()
        try await enroll(store, person)
        #expect(try await store.commitAutomatic(auto(person), token: token(store)))
        #expect(try await store.commitAutomatic(auto(person, start: 6_000, end: 8_000, disposition: .suggestion), token: token(store)))
        var snapshot = try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"])
        #expect(snapshot.resolve(segmentId: "s", startMediaMs: 3_000, endMediaMs: 5_000) == nil)
        if case .named(let match) = snapshot.resolveAutomatic(segmentId: "s", startMediaMs: 3_000, endMediaMs: 5_000) {
            #expect(match.person.id == person.id)
            #expect(match.attribution.score == 0.91)
        } else { Issue.record("Expected recognized automatic identity") }
        #expect(snapshot.resolveAutomatic(segmentId: "s", startMediaMs: 6_000, endMediaMs: 8_000) == nil)
        #expect(snapshot.resolveAutomatic(segmentId: "s", startMediaMs: 4_000, endMediaMs: 6_000) == .partial)
        try await SpeakerCorrectionStore(db: db).set(segmentId: "s", startMediaMs: 3_500, endMediaMs: 4_000, personId: nil)
        snapshot = try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"])
        #expect(snapshot.resolveAutomatic(segmentId: "s", startMediaMs: 3_000, endMediaMs: 5_000) == nil)
        #expect(try await !store.commitAutomatic(auto(person), token: token(store)))
        #expect(try await store.examples().count == 1) // predictions never enroll themselves
    }

    @Test func offAndChangedCorpusRejectLateResultsButKeepDisplayedNames() async throws {
        let (db, store, person) = try await ready()
        try await enroll(store, person)
        let oldToken = try await token(store)
        #expect(try await store.commitAutomatic(auto(person), token: oldToken))
        try await store.setMode(.off)
        #expect(try await !store.commitAutomatic(auto(person, run: "late"), token: oldToken))
        #expect(try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"]).automaticAttributions.count == 1)
        try await store.setMode(.local)
        #expect(try await !store.commitAutomatic(auto(person, run: "late"), token: oldToken))
        let newToken = try await token(store)
        #expect(try await store.commitExample(example(person, start: 10_000), token: newToken))
        #expect(try await !store.commitAutomatic(auto(person, run: "late"), token: newToken))
    }

    @Test func sourceDeletionIsATombstoneAndRedactionRequiresNewDigest() async throws {
        let (db, store, person) = try await ready()
        try await enroll(store, person)
        let old = try await token(store)
        #expect(try await store.commitAutomatic(auto(person), token: old))
        try await store.removeSourceRange(segmentId: "s", startMediaMs: 500, endMediaMs: 1_000)
        #expect(try await store.examples().isEmpty)
        #expect(try await !store.commitAutomatic(auto(person, run: "late"), token: old))
        await #expect(throws: VoiceIdentityError.sourceInvalidated) {
            try await store.prepareSource(segmentId: "s", revision: "digest-v1")
        }
        _ = try await store.prepareSource(segmentId: "s", revision: "digest-v2")
        await #expect(throws: VoiceIdentityError.sourceInvalidated) {
            try await store.prepareSource(segmentId: "s", revision: "digest-v1")
        }
        #expect(try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"]).automaticAttributions.isEmpty)
        try await store.deleteSource(segmentId: "s")
        await #expect(throws: VoiceIdentityError.sourceDeleted) {
            try await store.prepareSource(segmentId: "s", revision: "digest-v3")
        }
    }

    @Test func resumableCursorIsAtomicAndForegroundEnqueueIsIdempotent() async throws {
        let (_, store, person) = try await ready()
        try await enroll(store, person)
        let enqueued = try await store.enqueueJob(runID: "run", segmentId: "s", startMediaMs: 0, endMediaMs: 10_000, recipeID: "recipe")
        let duplicate = try await store.enqueueJob(runID: "another-scan", segmentId: "s", startMediaMs: 0, endMediaMs: 10_000, recipeID: "recipe")
        #expect(duplicate.id == enqueued.id)
        let claimed = try #require(try await store.claimNextJob())
        try await store.resumeInterruptedJobs()
        #expect(try await store.claimNextJob()?.id == claimed.id)
        #expect(try await store.advanceJob(id: claimed.id, expectedCursorMediaMs: 0, nextCursorMediaMs: 5_000, attributions: [auto(person)]))
        #expect(try await !store.advanceJob(id: claimed.id, expectedCursorMediaMs: 0, nextCursorMediaMs: 5_000, attributions: [auto(person)]))
        #expect(try await store.claimNextJob()?.cursorMediaMs == 5_000)
        #expect(try await store.advanceJob(id: claimed.id, expectedCursorMediaMs: 5_000, nextCursorMediaMs: 10_000, attributions: []))
        #expect(try await store.runs().first?.done == 1)
        #expect(try await store.runs().first?.completedMediaMs == 10_000)
    }

    @Test func undoSuppressesReapplicationUntilExplicitRerun() async throws {
        let (db, store, person) = try await ready()
        try await enroll(store, person)
        #expect(try await store.commitAutomatic(auto(person), token: token(store)))
        try await store.undoRun("run")
        #expect(try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"]).automaticAttributions.isEmpty)
        #expect(try await !store.commitAutomatic(auto(person, run: "background-next"), token: token(store)))
        _ = try await store.enqueueJob(runID: "explicit", segmentId: "s", startMediaMs: 3_000, endMediaMs: 5_000, recipeID: "recipe", explicitRerun: true)
        #expect(try await store.commitAutomatic(auto(person, run: "explicit"), token: token(store)))
        #expect(try await !store.commitAutomatic(auto(person), token: token(store))) // undone run itself cannot revive
    }

    @Test func cancellationAndForgetRejectInFlightJobsWithoutDeletingManualNames() async throws {
        let (db, store, person) = try await ready()
        try await enroll(store, person)
        try await SpeakerCorrectionStore(db: db).set(segmentId: "s", startMediaMs: 100, endMediaMs: 200, personId: person.id)
        let job = try await store.enqueueJob(runID: "run", segmentId: "s", startMediaMs: 0, endMediaMs: 10_000, recipeID: "recipe")
        _ = try await store.claimNextJob()
        try await store.cancelRun("run")
        #expect(try await !store.advanceJob(id: job.id, expectedCursorMediaMs: 0, nextCursorMediaMs: 5_000, attributions: [auto(person)]))
        let old = try await token(store)
        try await store.forgetProfile(personId: person.id)
        #expect(try await !store.commitExample(example(person, start: 10_000), token: old))
        #expect(try await store.profiles().isEmpty)
        #expect(try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"]).resolve(segmentId: "s", startMediaMs: 100, endMediaMs: 200) == .named(person))
    }

    @Test func personDeletionCascadesBiometricsAndAutoNames() async throws {
        let (db, store, person) = try await ready()
        try await enroll(store, person)
        #expect(try await store.commitAutomatic(auto(person), token: token(store)))
        try await PeopleStore(db: db).deletePerson(id: person.id)
        #expect(try await store.examples().isEmpty)
        #expect(try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"]).automaticAttributions.isEmpty)
    }

    @Test func wholeWipeClearsStandaloneEnrollmentAndInvalidatesPendingWork() async throws {
        let (db, store, person) = try await ready()
        _ = try await store.prepareSource(segmentId: "enrollment:microphone", revision: "pcm-digest")
        var e = example(person)
        e.segmentId = "enrollment:microphone"; e.sourceRevision = "pcm-digest"
        let context = try #require(try await store.workContext(segmentId: e.segmentId))
        #expect(try await store.commitExample(e, token: context.token))
        try await store.deleteAll()
        #expect(try await store.examples().isEmpty)
        #expect(try await !store.commitExample(e, token: context.token))
        #expect(try await PeopleStore(db: db).listPeople().count == 1)
    }

    @Test func correctingAnEnrolledCropRevokesContradictoryEvidenceAndPredictions() async throws {
        let (db, store, person) = try await ready()
        try await enroll(store, person)
        let old = try await token(store)
        #expect(try await store.commitAutomatic(auto(person), token: old))
        try await SpeakerCorrectionStore(db: db).set(segmentId: "s", startMediaMs: 500, endMediaMs: 1_000, personId: nil)
        #expect(try await store.examples().isEmpty)
        #expect(try await !store.commitAutomatic(auto(person, run: "late"), token: old))
        #expect(try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"]).automaticAttributions.isEmpty)
    }

    @Test func automaticChangesRefreshOnlyOverlappingArchivePiecesAndNamesFollowSelf() async throws {
        let (db, store, person) = try await ready()
        try await enroll(store, person)
        try await db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO conversations(id,startMs,endMs,timezone,state) VALUES
                    ('a',0,6000,'UTC','closed'),('b',6000,10000,'UTC','closed');
                INSERT INTO conversation_segments(conversationId,segmentId,ordinal,startMediaMs,endMediaMs) VALUES
                    ('a','s',0,0,6000),('b','s',0,6000,10000);
                """)
        }
        let outbox = ArchiveOutbox(db: db)
        try await outbox.setActive(true)
        try await outbox.clearAll()
        #expect(try await store.commitAutomatic(auto(person), token: token(store)))
        #expect(Set(try await outbox.pending(limit: 20).map(\.entityId)) == ["a"])
        #expect(try await PeopleStore(db: db).conversationIds(assignedTo: person.id) == ["a"])
        try await outbox.clearAll()
        try await PeopleStore(db: db).setCurrentUser(personId: person.id)
        #expect(Set(try await outbox.pending(limit: 20).map(\.entityId)) == ["a"])
        let snapshot = try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"])
        #expect(snapshot.automaticAttributions.first?.person.isCurrentUser == true)
        try await outbox.clearAll()
        try await PeopleStore(db: db).renamePerson(id: person.id, to: "Roger")
        #expect(Set(try await outbox.pending(limit: 20).map(\.entityId)) == ["a", person.id])
    }

    @Test func recognitionCutoffMovesOnlyWhenEnabledAndRetriesAreBounded() async throws {
        let (_, store, person) = try await ready()
        try await store.setMode(.off)
        try await store.setMode(.local, nowMs: 100)
        try await store.setMode(.local, nowMs: 200)
        #expect(try await store.configuration().enabledAtMs == 100)
        try await store.setMode(.off)
        try await store.setMode(.local, nowMs: 300)
        #expect(try await store.configuration().enabledAtMs == 300)
        try await enroll(store, person)
        _ = try await store.enqueueJob(runID: "retry", segmentId: "s", startMediaMs: 0, endMediaMs: 1_000, recipeID: "recipe")
        for _ in 0..<3 {
            let job = try #require(try await store.claimNextJob())
            try await store.failJob(id: job.id, error: "temporarily unavailable", retryable: true)
        }
        #expect(try await store.claimNextJob() == nil)
        #expect(try await store.jobs(runID: "retry").first?.state == .failed)
    }

    @Test func retentionKeepsConfirmedVoiceButExplicitSourceDeletionRevokesDependentNames() async throws {
        let (db, store, person) = try await ready()
        try await enroll(store, person)
        _ = try await store.prepareSource(segmentId: "other", revision: "other-digest")
        var a = auto(person)
        a.segmentId = "other"; a.sourceRevision = "other-digest"
        let context = try #require(try await store.workContext(segmentId: "other"))
        #expect(try await store.commitAutomatic(a, token: context.token))
        let corpus = try await store.configuration().corpusRevision
        try await store.expireSource(segmentId: "s")
        #expect(try await store.configuration().corpusRevision == corpus)
        #expect(try await store.examples().count == 1)
        #expect(try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["other"]).automaticAttributions.count == 1)
        #expect(try await store.workContext(segmentId: "s") == nil)
        await #expect(throws: VoiceIdentityError.sourceDeleted) {
            try await store.prepareSource(segmentId: "s", revision: "digest-v1")
        }
        try await store.deleteSource(segmentId: "s")
        #expect(try await store.examples().isEmpty)
        #expect(try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["other"]).automaticAttributions.isEmpty)
        #expect(try await !store.commitAutomatic(a, token: context.token))
    }

    @Test func missingDeviceKeyResetsOnlyAcousticStateAndAllowsFreshEnrollment() async throws {
        let (db, store, person) = try await ready()
        try await enroll(store, person)
        let old = try await token(store)
        try await SpeakerCorrectionStore(db: db).set(segmentId: "s", startMediaMs: 0, endMediaMs: 2_000, personId: person.id)
        try await store.resetUnavailableProfiles()
        #expect(try await store.configuration().mode == .off)
        #expect(try await store.examples().isEmpty)
        #expect(try await !store.commitExample(example(person), token: old))
        #expect(try await store.commitExample(example(person), token: token(store)))
        #expect(try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["s"]).resolve(
            segmentId: "s", startMediaMs: 0, endMediaMs: 2_000) == .named(person))
    }
}
