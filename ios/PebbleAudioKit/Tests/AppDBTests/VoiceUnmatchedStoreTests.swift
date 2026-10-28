import Foundation
import GRDB
import Testing
@testable import AppDB

/// Unnamed voices live and die with the recording-derived evidence they came from.
@Suite struct VoiceUnmatchedStoreTests {
    private func crop(_ start: Int64, segment: String = "s", revision: String = "r", recipe: String = "recipe") -> VoiceUnmatchedCrop {
        VoiceUnmatchedCrop(segmentId: segment, startMediaMs: start, endMediaMs: start + 2_000, sourceRevision: revision,
                           recipeID: recipe, embeddingJSON: Data("sealed".utf8), speechConfidence: 0.9)
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
    @Test func ignoredAudioStaysIgnoredAcrossReanalysisWithoutLearningItsEmbedding() async throws {
        let (db, voice, unmatched) = try await ready()
        let fingerprint = try await unmatched.fingerprint()
        let before = try await unmatched.recent(limit: 10)
        try await unmatched.ignore(segmentId: "s", startMediaMs: 3_000, endMediaMs: 5_000)
        try await unmatched.ignore(segmentId: "s", startMediaMs: 3_000, endMediaMs: 5_000)
        #expect(try await unmatched.fingerprint() != fingerprint)
        #expect(Set(try await unmatched.recent(limit: 10).map(\.startMediaMs)) == [0, 6_000])
        #expect(Set(try await unmatched.excludingIgnored(before).map(\.startMediaMs)) == [0, 6_000],
                "A stale naming sheet cannot teach or name the ignored crop")
        try await voice.setMode(.off)
        try await voice.setMode(.local)
        _ = try await voice.prepareSource(segmentId: "s", revision: "new-audio-revision")
        // New IDs, changed model recipe, slightly different crop boundaries, identical vectors.
        let repeated = crop(3_100, revision: "new-audio-revision", recipe: "new-model")
        let adjacent = crop(5_000, revision: "new-audio-revision")
        let elsewhere = crop(3_000, segment: "another-recording")
        try await db.writer.write { d in try VoiceUnmatchedStore.insert(d, [repeated, adjacent, elsewhere]) }
        #expect(Set(try await unmatched.recent(limit: 10).map(\.id)) == [adjacent.id, elsewhere.id])
        try await db.reader.read { (d: Database) throws -> Void in
            #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM voice_ignored_clips") == 1)
            for table in ["voice_examples", "speaker_corrections", "voice_suppressions", "voice_auto_attributions"] {
                #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(table)") == 0)
            }
        }
        try await voice.deleteSource(segmentId: "s")
        try await unmatched.ignore(segmentId: "s", startMediaMs: 3_000, endMediaMs: 5_000)
        #expect(try await db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM voice_ignored_clips") } == 0,
                "Deleting the recording clears decisions, and stale UI cannot recreate them")
    }

    @Test func ignoringAWholeGroupPersistsAfterReopeningTheDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.sqlite")
        let clips = [crop(0), crop(3_000), crop(6_000), crop(9_000)]
        do {
            let db = try AppDatabase.open(at: url)
            _ = try await VoiceIdentityStore(db: db).prepareSource(segmentId: "s", revision: "r")
            try await db.writer.write { d in try VoiceUnmatchedStore.insert(d, clips) }
            try await VoiceUnmatchedStore(db: db).ignore(clips)
        }
        let reopened = try AppDatabase.open(at: url)
        try await reopened.writer.write { d in try VoiceUnmatchedStore.insert(d, clips) }
        #expect(try await VoiceUnmatchedStore(db: reopened).recent(limit: 10).isEmpty)
        #expect(try await VoiceUnmatchedStore(db: reopened).excludingIgnored(clips).isEmpty)
    }

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
