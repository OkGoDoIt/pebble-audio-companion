import Foundation
import GRDB
import Testing
@testable import AppDB

/// Unnamed voices live and die with the recording-derived evidence they came from.
@Suite struct VoiceUnmatchedStoreTests {
    private func crop(_ start: Int64, segment: String = "s", revision: String = "r") -> VoiceUnmatchedCrop {
        VoiceUnmatchedCrop(segmentId: segment, startMediaMs: start, endMediaMs: start + 2_000, sourceRevision: revision,
                           recipeID: "recipe", embeddingJSON: Data("sealed".utf8), speechConfidence: 0.9)
    }

    private func ready() async throws -> (AppDatabase, VoiceIdentityStore, VoiceUnmatchedStore) {
        let db = try AppDatabase.inMemory()
        let voice = VoiceIdentityStore(db: db)
        try await voice.setMode(.local)
        _ = try await voice.prepareSource(segmentId: "s", revision: "r")
        try await VoiceHistoryPlanStore(db: db).create(runID: "scan", fromMs: 0, toMs: 9_000)
        try await voice.enqueueJob(runID: "scan", segmentId: "s", startMediaMs: 0, endMediaMs: 9_000, recipeID: "recipe")
        let job = try #require(try await voice.claimNextJob())
        #expect(try await voice.advanceJob(id: job.id, expectedCursorMediaMs: 0, nextCursorMediaMs: 9_000,
                                           attributions: [], unmatched: [crop(0), crop(3_000), crop(6_000)]))
        return (db, voice, VoiceUnmatchedStore(db: db))
    }

    @Test func aNamedRangeIsNoLongerUnnamedAndAReReadRecordingLosesItsCrops() async throws {
        let (db, voice, unmatched) = try await ready()
        #expect(try await unmatched.recent(limit: 10).count == 3)
        let person = try await PeopleStore(db: db).createPerson(name: "Dana")
        try await SpeakerCorrectionStore(db: db).set(segmentId: "s", startMediaMs: 3_000, endMediaMs: 5_000, personId: person.id)
        #expect(Set(try await unmatched.recent(limit: 10).map(\.startMediaMs)) == [0, 6_000])
        _ = try await voice.prepareSource(segmentId: "s", revision: "r2")
        #expect(try await unmatched.recent(limit: 10).isEmpty, "A new revision of the recording drops them")
    }

    @Test func turningRecognitionOffForgetsEveryUnnamedVoice() async throws {
        let (_, voice, unmatched) = try await ready()
        try await voice.setMode(.off)
        #expect(try await unmatched.recent(limit: 10).isEmpty)
    }

    @Test func deletingTheRecordingForgetsItsUnnamedVoices() async throws {
        let (_, voice, unmatched) = try await ready()
        try await voice.deleteSource(segmentId: "s")
        #expect(try await unmatched.recent(limit: 10).isEmpty)
    }
}

extension VoiceUnmatchedStoreTests {
    @Test func theFingerprintMovesWhenTheUnnamedSetCouldChange() async throws {
        let (db, _, unmatched) = try await ready()
        let first = try await unmatched.fingerprint()
        #expect(try await unmatched.fingerprint() == first, "Nothing changed")
        let person = try await PeopleStore(db: db).createPerson(name: "Dana")
        try await SpeakerCorrectionStore(db: db).set(segmentId: "s", startMediaMs: 3_000, endMediaMs: 5_000, personId: person.id)
        let named = try await unmatched.fingerprint()
        #expect(named != first, "A name set over a crop changes what is unnamed")
        try await unmatched.remove(ids: [try #require(try await unmatched.recent(limit: 1).first).id])
        #expect(try await unmatched.fingerprint() != named)
    }
}
