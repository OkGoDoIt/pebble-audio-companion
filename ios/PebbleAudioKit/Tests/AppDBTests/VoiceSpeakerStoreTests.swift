import Foundation
import Testing
@testable import AppDB

@Suite struct VoiceSpeakerStoreTests {
    private func ready() async throws -> (AppDatabase, VoiceSpeakerStore) {
        let db = try AppDatabase.inMemory()
        let identity = VoiceIdentityStore(db: db)
        try await identity.setMode(.local)
        for segment in ["seg-1-a-1", "seg-2-a-1"] {
            _ = try await identity.prepareSource(segmentId: segment, revision: "r")
            try await db.writer.write { d in
                try d.execute(sql: """
                    INSERT INTO voice_print_sources(segmentId,recipeID,sourceRevision,sourceGeneration,analyzedJSON,matchedCorpus)
                    VALUES (?,'recipe','r',1,'[]',0)
                    """, arguments: [segment])
            }
        }
        return (db, VoiceSpeakerStore(db: db))
    }
    private func crop(_ start: Int64, _ end: Int64) -> VoiceSpeakerCrop { VoiceSpeakerCrop(startMs: start, endMs: end, confidencePercent: 90) }
    private func draft(_ crops: [VoiceSpeakerCrop]) -> VoiceSpeakerDraft {
        VoiceSpeakerDraft(crops: crops, sealedVoice: Data([1]), recipeJSON: Data("{}".utf8))
    }

    /// What a person said stands when a recording is sorted again, unchanged or not.
    @Test func decisionsSurviveARecordingBeingSortedAgain() async throws {
        let (_, store) = try await ready()
        let first = draft([crop(0, 3_000), crop(3_000, 6_000)])
        try await store.replaceSpeakers([("seg-1-a-1", [first])])
        var inputs = try await store.clusterInputs(minimumCrops: 1)
        let id = try #require(inputs.first?.id)
        try await store.decide(speakers: [id], kind: .ignored, personId: nil)

        try await store.replaceSpeakers([("seg-1-a-1", [first])])
        inputs = try await store.clusterInputs(minimumCrops: 1)
        #expect(inputs.map(\.id) == [id], "Same crops, same row")
        #expect(inputs.first?.ignored == true)

        try await store.replaceSpeakers([("seg-1-a-1", [draft([crop(0, 3_000), crop(3_000, 6_000), crop(6_000, 9_000)])])])
        inputs = try await store.clusterInputs(minimumCrops: 1)
        #expect(inputs.first?.id != id, "More heard, a new row")
        #expect(inputs.first?.ignored == true, "Which takes over what was said")
    }

    @Test func aNewAnswerReplacesTheOldOne() async throws {
        let (db, store) = try await ready()
        let dana = try await PeopleStore(db: db).createPerson(name: "Dana")
        let sam = try await PeopleStore(db: db).createPerson(name: "Sam")
        try await store.replaceSpeakers([("seg-1-a-1", [draft([crop(0, 3_000)])])])
        let id = try #require(try await store.clusterInputs(minimumCrops: 1).first?.id)
        try await store.decide(speakers: [id], kind: .confirmed, personId: dana.id)
        #expect(try await store.clusterInputs(minimumCrops: 1).first?.person == dana.id)
        try await store.decide(speakers: [id], kind: .confirmed, personId: sam.id)
        #expect(try await store.clusterInputs(minimumCrops: 1).first?.person == sam.id)
        try await store.decide(speakers: [id], kind: .rejected, personId: sam.id)
        let input = try #require(try await store.clusterInputs(minimumCrops: 1).first)
        #expect(input.person == nil && input.rejected == [sam.id])
    }

    @Test func deletingAPersonTakesWhatWasSaidAboutThem() async throws {
        let (db, store) = try await ready()
        let dana = try await PeopleStore(db: db).createPerson(name: "Dana")
        try await store.replaceSpeakers([("seg-1-a-1", [draft([crop(0, 3_000)])])])
        let id = try #require(try await store.clusterInputs(minimumCrops: 1).first?.id)
        try await store.decide(speakers: [id], kind: .confirmed, personId: dana.id)
        try await db.writer.write { try $0.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [dana.id]) }
        #expect(try await store.clusterInputs(minimumCrops: 1).first?.person == nil)
    }

    /// Only a change in who a speaker is makes a recording be named again.
    @Test func onlyAChangedNameMarksARecording() async throws {
        let (db, store) = try await ready()
        let dana = try await PeopleStore(db: db).createPerson(name: "Dana")
        try await store.replaceSpeakers([("seg-1-a-1", [draft([crop(0, 3_000)])]), ("seg-2-a-1", [draft([crop(0, 3_000)])])])
        let ids = try await store.clusterInputs(minimumCrops: 1).map(\.id)
        func assignments(person: String?, score: Double = 0.7) -> [VoiceSpeakerAssignment] {
            ids.map { VoiceSpeakerAssignment(speakerId: $0, clusterId: ids[0], personId: person, score: score,
                                             suggestedPersonId: nil, suggestedScore: nil, ignored: false) }
        }
        #expect(try await store.applyClusters(assignments(person: dana.id)) == 2)
        #expect(try await store.applyClusters(assignments(person: dana.id)) == 0)
        #expect(try await store.applyClusters(assignments(person: dana.id, score: 0.8)) == 0, "Only a better score")
        #expect(try await store.applyClusters(assignments(person: nil)) == 2)
    }

    @Test func aRecordingsIdSaysWhenItWasHeard() {
        #expect(VoiceSpeakerStore.heardAt("seg-1793857917060-2930a5af-578") == 1_793_857_917_060)
        #expect(VoiceSpeakerStore.heardAt("anything") == 0)
    }

    @Test func aSpeakerIsLabelledByTheCropsMostlyInsideALabel() {
        let crops = [crop(0, 3_000), crop(3_000, 6_000), crop(6_000, 9_000)]
        let tally = VoiceSpeakerStore.labelledCrops(crops, labels: [(1_000..<6_000, "dana"), (8_500..<9_000, "sam")])
        #expect(tally == ["dana": 2], "A sliver of a crop isn't that crop")
    }
}
