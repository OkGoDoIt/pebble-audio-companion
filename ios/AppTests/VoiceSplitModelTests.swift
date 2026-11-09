import AppDB
import CompanionRuntime
import Foundation
import Testing

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
