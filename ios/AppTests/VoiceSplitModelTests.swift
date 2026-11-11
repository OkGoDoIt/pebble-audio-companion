import AppDB
import CompanionRuntime
import Foundation
import Testing
import Transcription

@MainActor @Suite struct VoiceSplitModelTests {
    func clip(_ id: String, start: Int64) -> UnknownVoiceClip {
        UnknownVoiceClip(id: id, segmentId: "same-recording", startMs: start, endMs: start + 3_000, heardAt: nil)
    }
    @Test func twoVoicesInOneRecordingBothAppearAndCanBeSelectedIndependently() {
        let crops = ["1", "2"].enumerated().map { index,id in
            VoiceUnmatchedCrop(id: id,segmentId: "same-recording",startMediaMs: Int64(index)*3_000,
                endMediaMs: Int64(index+1)*3_000,sourceRevision: "r",recipeID: "r",embeddingJSON: Data(),speechConfidence: 1)
        }
        let group = VoiceRecognitionService.UnknownVoiceGroup(clusterId: 1,crops: crops)
        let display = UnknownVoiceDisplay.build(group,people: [],wallMs: { _,_ in 1_000 },transcript: { _ in nil })
        #expect(display.recordingCount == 1)
        #expect(display.clips.count == 2)
        #expect(Set(display.clips.map(\.id)) == ["1","2"])
    }
    @Test func manualPartitionPreservesEveryClipAndFailedSaveKeepsTheDraft() async {
        let source = VoiceTestSource()
        source.splitDraft = VoiceSplitDraft(id: "draft",groups: [[clip("a",start: 0),clip("b",start: 3_000),clip("c",start: 6_000)]])
        let model = VoiceSplitModel(source: source)
        await model.load("voice")
        model.separate(["b"],from: 0)
        #expect(model.draft?.groups.map(\.count) == [1,2])
        #expect(model.draft?.groups.first?.first?.id == "b")
        #expect(model.draft?.clipCount == 3)
        source.failSplit = true
        #expect(await model.save() == nil)
        #expect(model.error != nil)
        #expect(model.draft?.clipCount == 3)
        source.failSplit = false
        #expect(await model.save() != nil)
        #expect(source.savedSplit?.groups.map(\.count) == [1,2])
    }
    private final class People: PeopleDataSource {
        var registry = [Person(id: "dana", name: "Dana")]
        func people() async throws -> [Person] { registry }
        func createPerson(name: String) async throws -> Person {
            let person = Person(id: "new-\(registry.count)", name: name)
            registry.append(person)
            return person
        }
        func assignPassage(_ turn: TranscriptTurn, personId: String?, makeCurrentUser: Bool) async throws {}
        func assignCurrentUserPassage(_ turn: TranscriptTurn, displayName: String) async throws -> Person { registry[0] }
        func assignedPerson(conversationId: String, turn: TranscriptTurn) async throws -> Person? { nil }
        func setCurrentUser(personId: String?) async throws {}
        func assign(conversationId: String, label: String, personName: String) async throws {}
        func assignedPerson(conversationId: String, label: String) async throws -> Person? { nil }
        func renamePerson(id: String, to newName: String) async throws {}
        func unassign(conversationId: String, label: String) async throws {}
        func deletePerson(id: String) async throws {}
    }
    @Test func groupsNamedWhileSplittingAreNamedOnSaveAndTheRestStayUnnamed() async {
        let source = VoiceTestSource(), people = People()
        source.splitDraft = VoiceSplitDraft(id: "draft",groups: [[clip("a",start: 0),clip("b",start: 3_000)],
            [clip("c",start: 6_000)],[clip("d",start: 9_000)],[clip("e",start: 12_000)]])
        let model = VoiceSplitModel(source: source, people: people)
        await model.load("voice")
        #expect(!model.hasNames)
        model.setName(.person(people.registry[0]), for: 0)
        model.setName(.someoneNew("Sam"), for: 2)
        model.setName(.someoneNew("sam"), for: 3)
        // Taking a clip out of a named group leaves the name on what stays.
        model.separate(["b"], from: 0)
        #expect(model.name(of: 0) == nil)
        #expect(model.name(of: 1) == .person(people.registry[0]))
        #expect(model.name(of: 3) == .someoneNew("Sam"))
        let notice = await model.save()
        #expect(notice?.message == "Named Dana and Sam")
        #expect(people.registry.map(\.name) == ["Dana","Sam"], "The same new name is one person")
        #expect(source.namedUnknown.map(\.0) == ["child-1","child-3","child-4"])
        #expect(source.namedUnknown.map(\.1) == ["dana","new-1","new-1"])
        #expect(source.namedUnknown.allSatisfy { $0.2 == nil })
        notice?.action?()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(source.undone.map(\.0) == ["child-1","child-3","child-4"])
    }
    @Test func namesAreListedWithAnOxfordComma() {
        #expect(VoiceSplitModel.list(["Dana"]) == "Dana")
        #expect(VoiceSplitModel.list(["Dana","Sam","Oliver"]) == "Dana, Sam, and Oliver")
    }
    @Test func tinySavedGroupsRemainInTheNamingQueue() async {
        let source = VoiceTestSource()
        source.state.enabled = true
        var voice = UnknownVoiceDisplay(id: "repair",recordingCount: 1,detail: "",clips: [clip("a",start: 0)],speechMs: 3_000)
        voice.repaired = true
        source.unknown = [voice]
        let model = VoiceSettingsModel(source: source)
        await model.refresh()
        #expect(model.toName.map(\.id) == ["repair"])
    }
}
