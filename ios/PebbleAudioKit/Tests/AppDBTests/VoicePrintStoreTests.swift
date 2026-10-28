import Foundation
import GRDB
import Testing
@testable import AppDB

/// Analysed audio keeps each turn's voice print, so new voices rename what was already checked
/// instead of sending it back through the models.
@Suite struct VoicePrintStoreTests {
    private func ready() async throws -> (AppDatabase, VoiceIdentityStore, Person) {
        let db = try AppDatabase.inMemory()
        let store = VoiceIdentityStore(db: db)
        let person = try await PeopleStore(db: db).createPerson(name: "Alex")
        try await store.setMode(.local)
        _ = try await store.prepareSource(segmentId: "s", revision: "digest-v1")
        try await enroll(store, person)
        return (db, store, person)
    }
    private func token(_ store: VoiceIdentityStore) async throws -> VoiceWorkToken {
        try #require(try await store.workContext(segmentId: "s")).token
    }
    private func enroll(_ store: VoiceIdentityStore, _ person: Person, start: Int64 = 50_000) async throws {
        let id = UUID().uuidString
        #expect(try await store.commitExample(VoiceConfirmedExample(id: id, personId: person.id,
            confirmationID: "human-\(id)", sessionID: "session", segmentId: "s", startMediaMs: start,
            endMediaMs: start + 2_000, sourceRevision: "digest-v1", recipeID: "recipe",
            recipeJSON: Data("{\"model\":\"pinned\"}".utf8), embeddingJSON: Data("{\"values\":[0.6,0.8]}".utf8),
            qualityJSON: Data("{\"duration\":2}".utf8), createdAtMs: 10), token: token(store)))
    }
    private func name(_ person: Person, run: String = "run", start: Int64 = 3_000, end: Int64 = 5_000) -> VoiceAutomaticAttribution {
        VoiceAutomaticAttribution(personId: person.id, segmentId: "s", startMediaMs: start, endMediaMs: end,
            sourceRevision: "digest-v1", recipeID: "recipe", score: 0.91, margin: 0.2,
            calibrationID: "evaluation-1", runID: run, createdAtMs: 20)
    }
    private func print(run: String = "run", start: Int64 = 3_000, end: Int64 = 5_000) -> VoiceTurnPrint {
        VoiceTurnPrint(startMediaMs: start, endMediaMs: end, speechConfidence: 0.9, runID: run,
                       recipeJSON: Data("{\"model\":\"pinned\"}".utf8), sealedEmbedding: Data("{\"sealed\":1}".utf8))
    }
    private func count(_ db: AppDatabase, _ table: String) async throws -> Int {
        try await db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }
    private func names(_ db: AppDatabase) async throws -> [(id: String, person: String, start: Int64)] {
        try await db.reader.read { d in
            try Row.fetchAll(d, sql: "SELECT id, personId, startMediaMs FROM voice_auto_attributions ORDER BY startMediaMs")
                .map { (id: $0["id"], person: $0["personId"], start: $0["startMediaMs"]) }
        }
    }
    /// One analysed ten-second window of "s" for `run`, with these names and prints.
    private func analyse(_ store: VoiceIdentityStore, run: String = "run", names: [VoiceAutomaticAttribution] = [],
                         prints: [VoiceTurnPrint], matchedCorpus: Int64? = nil, explicit: Bool = false) async throws {
        try await store.enqueueJob(runID: run, segmentId: "s", startMediaMs: 0, endMediaMs: 10_000,
                                   recipeID: "recipe", explicitRerun: explicit)
        let job = try #require(try await store.claimNextJob())
        let corpus = try await store.configuration().corpusRevision
        #expect(try await store.advanceJob(id: job.id, expectedCursorMediaMs: 0, nextCursorMediaMs: 10_000,
            attributions: names, window: 0..<10_000, prints: prints, matchedCorpus: matchedCorpus ?? corpus))
    }

    @Test func printsMergeIntoAnalysedAudioAndGoWithTheRecording() async throws {
        let (db, store, _) = try await ready()
        try await store.enqueueJob(runID: "run", segmentId: "s", startMediaMs: 0, endMediaMs: 20_000, recipeID: "recipe")
        let job = try #require(try await store.claimNextJob())
        let corpus = try await store.configuration().corpusRevision
        #expect(try await store.advanceJob(id: job.id, expectedCursorMediaMs: 0, nextCursorMediaMs: 10_000,
            attributions: [], window: 0..<10_000, prints: [print()], matchedCorpus: corpus))
        _ = try #require(try await store.claimNextJob())
        #expect(try await store.advanceJob(id: job.id, expectedCursorMediaMs: 10_000, nextCursorMediaMs: 20_000,
            attributions: [], window: 10_000..<20_000, prints: [print(start: 12_000, end: 14_000)], matchedCorpus: corpus))
        let prints = VoicePrintStore(db: db)
        #expect(try await prints.analyzed(segmentId: "s", recipeID: "recipe", token: job.token) == [0..<20_000])
        #expect(try await count(db, "voice_turn_prints") == 2)
        // A print outside its window is refused with the window.
        try await store.enqueueJob(runID: "other", segmentId: "s", startMediaMs: 20_000, endMediaMs: 30_000, recipeID: "recipe")
        let next = try #require(try await store.claimNextJob())
        await #expect(throws: VoiceIdentityError.invalidRecord) {
            try await store.advanceJob(id: next.id, expectedCursorMediaMs: 20_000, nextCursorMediaMs: 30_000,
                attributions: [], window: 20_000..<30_000, prints: [print(run: "other")], matchedCorpus: corpus)
        }
        // A re-read recording keeps nothing derived from the old audio.
        _ = try await store.prepareSource(segmentId: "s", revision: "digest-v2")
        #expect(try await count(db, "voice_turn_prints") == 0)
        #expect(try await count(db, "voice_print_sources") == 0)
    }

    @Test func turningRecognitionOffClearsEveryPrint() async throws {
        let (db, store, _) = try await ready()
        try await analyse(store, prints: [print()])
        #expect(try await count(db, "voice_turn_prints") == 1)
        try await store.setMode(.off)
        #expect(try await count(db, "voice_turn_prints") == 0)
        #expect(try await count(db, "voice_print_sources") == 0)
    }

    @Test func newVoicesKeepTheWorkAndLeaveTheNamesToBeMatchedAgain() async throws {
        let (db, store, person) = try await ready()
        try await analyse(store, names: [name(person)], prints: [print()])
        try await store.enqueueJob(runID: "later", segmentId: "s", startMediaMs: 10_000, endMediaMs: 20_000, recipeID: "recipe")
        let prints = VoicePrintStore(db: db)
        #expect(try await prints.stale(corpusRevision: store.configuration().corpusRevision, maxPrints: 10, maxSources: 10).isEmpty)
        try await enroll(store, person, start: 60_000)
        // The queued work is still wanted: new voices only change the names.
        #expect(try await store.claimNextJob()?.runID == "later")
        let stale = try await prints.stale(corpusRevision: store.configuration().corpusRevision, maxPrints: 10, maxSources: 10)
        #expect(stale.map(\.segmentId) == ["s"])
        #expect(stale.first?.prints.count == 1 && stale.first?.analyzed == [0..<10_000])
        #expect(try await store.pendingRecordingCount() == 1)
        #expect(try await count(db, "voice_auto_attributions") == 1)
    }

    @Test func namesFromPrintsChangeOnlyWhatDiffers() async throws {
        let (db, store, alex) = try await ready()
        let sam = try await PeopleStore(db: db).createPerson(name: "Sam")
        try await enroll(store, sam, start: 70_000)
        try await analyse(store, names: [name(alex), name(alex, start: 6_000, end: 8_000)],
                          prints: [print(), print(start: 6_000, end: 8_000)])
        let kept = try await names(db).first!.id
        try await enroll(store, alex, start: 60_000)
        let config = try await store.configuration()
        let prints = VoicePrintStore(db: db)
        let source = try #require(try await prints.stale(corpusRevision: config.corpusRevision, maxPrints: 10, maxSources: 10).first)
        let renamed = try await prints.commitNames([(source, [name(alex), name(sam, start: 6_000, end: 8_000)])],
            corpusRevision: config.corpusRevision, configGeneration: config.generation)
        #expect(renamed == ["s"])
        let after = try await names(db)
        #expect(after.map(\.person) == [alex.id, sam.id])
        #expect(after.first?.id == kept, "A name that stays is not rewritten")
        #expect(try await prints.stale(corpusRevision: config.corpusRevision, maxPrints: 10, maxSources: 10).isEmpty)
        #expect(try await store.pendingRecordingCount() == 0)
        // Matching the same names again changes nothing.
        try await enroll(store, sam, start: 80_000)
        let next = try await store.configuration()
        let again = try #require(try await prints.stale(corpusRevision: next.corpusRevision, maxPrints: 10, maxSources: 10).first)
        #expect(try await prints.commitNames([(again, [name(alex), name(sam, start: 6_000, end: 8_000)])],
            corpusRevision: next.corpusRevision, configGeneration: next.generation).isEmpty)
        // Names read before the voices changed again are not saved.
        try await enroll(store, alex, start: 90_000)
        #expect(try await prints.commitNames([(again, [])], corpusRevision: next.corpusRevision,
            configGeneration: next.generation).isEmpty)
        #expect(try await names(db).count == 2)
    }

    @Test func aStoppedRunKeepsItsNamesAndAnUndoneOneGivesThemUp() async throws {
        let (db, store, alex) = try await ready()
        try await analyse(store, prints: [print()])
        try await store.cancelRun("run")
        try await enroll(store, alex, start: 60_000)
        let prints = VoicePrintStore(db: db)
        var config = try await store.configuration()
        var source = try #require(try await prints.stale(corpusRevision: config.corpusRevision, maxPrints: 10, maxSources: 10).first)
        #expect(try await prints.commitNames([(source, [name(alex)])], corpusRevision: config.corpusRevision,
            configGeneration: config.generation) == ["s"])
        try await store.undoRun("run")
        #expect(try await names(db).isEmpty)
        try await enroll(store, alex, start: 70_000)
        config = try await store.configuration()
        source = try #require(try await prints.stale(corpusRevision: config.corpusRevision, maxPrints: 10, maxSources: 10).first)
        #expect(try await prints.commitNames([(source, [name(alex)])], corpusRevision: config.corpusRevision,
            configGeneration: config.generation).isEmpty)
        #expect(try await names(db).isEmpty)
    }

    @Test func clearedNamesWaitForAHistoryRunToBeMatchedAgain() async throws {
        let (db, store, alex) = try await ready()
        try await analyse(store, names: [name(alex)], prints: [print()])
        try await store.clearAutomatic()
        try await enroll(store, alex, start: 60_000)
        let prints = VoicePrintStore(db: db)
        #expect(try await prints.stale(corpusRevision: store.configuration().corpusRevision, maxPrints: 10, maxSources: 10).isEmpty)
        #expect(try await store.pendingRecordingCount() == 0)
        // Asking for history again reads the prints, not the audio.
        try await store.enqueueJob(runID: "history", segmentId: "s", startMediaMs: 0, endMediaMs: 10_000,
                                   recipeID: "recipe", explicitRerun: true)
        let job = try #require(try await store.claimNextJob())
        #expect(try await prints.analyzed(segmentId: "s", recipeID: "recipe", token: job.token) == [0..<10_000])
        #expect(try await store.adoptAnalyzed(id: job.id, expectedCursorMediaMs: 0, nextCursorMediaMs: 10_000))
        let source = try #require(try await prints.stale(corpusRevision: store.configuration().corpusRevision,
                                                         maxPrints: 10, maxSources: 10).first)
        #expect(source.prints.map(\.runID) == ["history"])
        #expect(try await store.jobs(runID: "history").first?.state == .done)
    }

    @Test func aNameMatchedAgainstOlderVoicesIsNotSavedButItsPrintIs() async throws {
        let (db, store, alex) = try await ready()
        let old = try await store.configuration().corpusRevision
        try await store.enqueueJob(runID: "run", segmentId: "s", startMediaMs: 0, endMediaMs: 10_000, recipeID: "recipe")
        let job = try #require(try await store.claimNextJob())
        try await enroll(store, alex, start: 60_000)
        #expect(try await store.advanceJob(id: job.id, expectedCursorMediaMs: 0, nextCursorMediaMs: 10_000,
            attributions: [name(alex)], window: 0..<10_000, prints: [print()], matchedCorpus: old))
        #expect(try await names(db).isEmpty)
        #expect(try await count(db, "voice_turn_prints") == 1)
        #expect(try await VoicePrintStore(db: db).stale(corpusRevision: store.configuration().corpusRevision,
                                                        maxPrints: 10, maxSources: 10).count == 1)
    }

    /// A history run over analysed audio used to delete every name it covered and add them back
    /// as it went: the conversations showed no names meanwhile and were all sent to the archive
    /// again. Names on analysed audio now stay and are updated from the prints in place.
    @Test func anExplicitRerunKeepsTheNamesOnAnalysedAudio() async throws {
        let (db, store, alex) = try await ready()
        try await analyse(store, names: [name(alex)], prints: [print()])
        let analysed = try #require(try await names(db).first?.id)
        #expect(try await store.commitAutomatic(name(alex, run: "older", start: 20_000, end: 22_000), token: token(store)))
        try await store.enqueueJob(runID: "history", segmentId: "s", startMediaMs: 0, endMediaMs: 30_000,
                                   recipeID: "recipe", explicitRerun: true)
        #expect(try await names(db).map(\.id) == [analysed], "Only the name on audio without prints is cleared for the rerun")
    }
}
