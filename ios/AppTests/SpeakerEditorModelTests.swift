import AppDB
import Foundation
import Testing

@Suite("speaker correction editor") @MainActor
struct SpeakerEditorModelTests {
    private enum Failure: Error { case disk }
    private final class Source: PeopleDataSource {
        var registry: [Person] = []
        var failSave = false
        var failLoad = false
        var created = 0
        var saves: [(String?, Bool)] = []
        var suspend = false
        var resume: CheckedContinuation<Void, Never>?
        func people() async throws -> [Person] { if failLoad { throw Failure.disk }; return registry }
        func createPerson(name: String) async throws -> Person {
            created += 1
            let p = Person(id: "new-\(created)", name: name)
            registry.append(p)
            return p
        }
        func assignPassage(_ turn: TranscriptTurn, personId: String?, makeCurrentUser: Bool) async throws {
            if suspend { await withCheckedContinuation { resume = $0 } }
            if failSave { throw Failure.disk }
            saves.append((personId, makeCurrentUser))
        }
        func assignedPerson(conversationId: String, turn: TranscriptTurn) async throws -> Person? { nil }
        func setCurrentUser(personId: String?) async throws {}
        func assign(conversationId: String, label: String, personName: String) async throws {}
        func assignedPerson(conversationId: String, label: String) async throws -> Person? { nil }
        func renamePerson(id: String, to newName: String) async throws { if failSave { throw Failure.disk } }
        func unassign(conversationId: String, label: String) async throws {}
        func deletePerson(id: String) async throws { if failSave { throw Failure.disk } }
    }
    private var turn: TranscriptTurn {
        TranscriptTurn(id: "t", speakerLabel: "s#1", name: "Speaker 1", role: .unresolved,
                       text: "A test passage.", segmentId: "s", sourceStartMs: 100, sourceEndMs: 200)
    }
    @Test func failedSaveKeepsErrorAndRetryReusesCreatedPerson() async {
        let source = Source()
        let editor = SpeakerEditorModel(source: source)
        await editor.load(conversationId: "c", turn: turn)
        source.failSave = true
        #expect(await editor.createAndChoose(name: "Sam", for: turn) == false)
        #expect(editor.errorMessage != nil)
        #expect(!editor.isSaving)
        source.failSave = false
        #expect(await editor.createAndChoose(name: "Sam", for: turn))
        #expect(source.created == 1)
        #expect(source.saves.last?.0 == "new-1")
    }
    @Test func sameNamesSelectByIdAndLiteralYouDoesNotBecomeSelf() async {
        let source = Source()
        source.registry = [Person(id: "a", name: "Sam"), Person(id: "b", name: "Sam"),
                           Person(id: "other", name: "You")]
        let editor = SpeakerEditorModel(source: source)
        await editor.load(conversationId: "c", turn: turn)
        #expect(await editor.choose(source.registry[1], for: turn))
        #expect(source.saves.last?.0 == "b")
        #expect(await editor.chooseMe(for: turn))
        #expect(source.saves.last?.0 == "new-1")
        #expect(source.saves.last?.1 == true)
    }
    @Test func existingSelfSurvivesDisplayNameChange() async {
        let source = Source()
        source.registry = [Person(id: "me", name: "Roger", isCurrentUser: true)]
        let editor = SpeakerEditorModel(source: source)
        await editor.load(conversationId: "c", turn: turn)
        #expect(await editor.chooseMe(for: turn))
        #expect(source.saves.last?.0 == "me")
        #expect(source.created == 0)
    }
    @Test func missingTimingAndFailedLoadDoNotWrite() async {
        let source = Source()
        let model = SpeakerEditorModel(source: source)
        source.failLoad = true
        await model.load(conversationId: "c", turn: turn)
        #expect(!model.loaded)
        #expect(await model.choose(nil, for: turn) == false)
        source.failLoad = false
        await model.load(conversationId: "c", turn: turn)
        var untimed = turn
        untimed.sourceEndMs = nil
        #expect(await model.choose(nil, for: untimed) == false)
        #expect(source.saves.isEmpty)
    }
    @Test func pendingSaveRejectsASecondDecision() async {
        let source = Source()
        let model = SpeakerEditorModel(source: source)
        await model.load(conversationId: "c", turn: turn)
        source.suspend = true
        let first = Task { await model.choose(nil, for: turn) }
        while source.resume == nil { await Task.yield() }
        #expect(model.isSaving)
        #expect(await model.chooseMe(for: turn) == false)
        source.resume?.resume()
        #expect(await first.value)
        #expect(source.saves.count == 1)
        #expect(source.created == 0)
    }
}
