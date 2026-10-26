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
        func assignCurrentUserPassage(_ turn: TranscriptTurn, displayName: String) async throws -> Person {
            let person: Person
            if let current = registry.first(where: \.isCurrentUser) { person = current }
            else { person = try await createPerson(name: displayName) }
            try await assignPassage(turn, personId: person.id, makeCurrentUser: true)
            return person
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
        await editor.load(conversationId: "c", turns: [turn])
        source.failSave = true
        #expect(await editor.createAndChoose(name: "Sam", for: [turn]) == false)
        #expect(editor.errorMessage != nil)
        #expect(!editor.isSaving)
        source.failSave = false
        #expect(await editor.createAndChoose(name: "Sam", for: [turn]))
        #expect(source.created == 1)
        #expect(source.saves.last?.0 == "new-1")
    }
    @Test func sameNamesSelectByIdAndLiteralYouDoesNotBecomeSelf() async {
        let source = Source()
        source.registry = [Person(id: "a", name: "Sam"), Person(id: "b", name: "Sam"),
                           Person(id: "other", name: "You")]
        let editor = SpeakerEditorModel(source: source)
        await editor.load(conversationId: "c", turns: [turn])
        #expect(await editor.choose(source.registry[1], for: [turn]))
        #expect(source.saves.last?.0 == "b")
        #expect(await editor.chooseMe(for: [turn], name: "Roger"))
        #expect(source.saves.last?.0 == "new-1")
        #expect(source.saves.last?.1 == true)
    }
    @Test func existingSelfSurvivesDisplayNameChange() async {
        let source = Source()
        source.registry = [Person(id: "me", name: "Roger", isCurrentUser: true)]
        let editor = SpeakerEditorModel(source: source)
        await editor.load(conversationId: "c", turns: [turn])
        #expect(await editor.chooseMe(for: [turn], name: "Roger"))
        #expect(source.saves.last?.0 == "me")
        #expect(source.created == 0)
    }
    @Test func missingTimingAndFailedLoadDoNotWrite() async {
        let source = Source()
        let model = SpeakerEditorModel(source: source)
        source.failLoad = true
        await model.load(conversationId: "c", turns: [turn])
        #expect(!model.loaded)
        #expect(await model.choose(nil, for: [turn]) == false)
        source.failLoad = false
        await model.load(conversationId: "c", turns: [turn])
        var untimed = turn
        untimed.sourceEndMs = nil
        #expect(await model.choose(nil, for: [untimed]) == false)
        #expect(source.saves.isEmpty)
    }
    @Test func pendingSaveRejectsASecondDecision() async {
        let source = Source()
        let model = SpeakerEditorModel(source: source)
        await model.load(conversationId: "c", turns: [turn])
        source.suspend = true
        let first = Task { await model.choose(nil, for: [turn]) }
        while source.resume == nil { await Task.yield() }
        #expect(model.isSaving)
        #expect(await model.chooseMe(for: [turn], name: "Roger") == false)
        source.resume?.resume()
        #expect(await first.value)
        #expect(source.saves.count == 1)
        #expect(source.created == 0)
    }

    @Test func severalParagraphsGetOneNameAndOneSelfIdentity() async {
        let source = Source()
        let editor = SpeakerEditorModel(source: source)
        let turns = ["a", "b", "c"].map {
            TranscriptTurn(id: $0, speakerLabel: "s#1", name: "Speaker 1", role: .unresolved,
                           text: "Paragraph \($0).", segmentId: "s", sourceStartMs: 100, sourceEndMs: 200)
        }
        await editor.load(conversationId: "c", turns: turns)
        #expect(await editor.chooseMe(for: turns, name: "Roger"))
        #expect(source.created == 1, "One person for the whole selection")
        #expect(source.saves.count == 3)
        #expect(source.saves.map(\.1) == [true, false, false], "Only the first save makes them the current user")
        #expect(Set(source.saves.map(\.0)) == ["new-1"])
        #expect(await editor.choose(nil, for: turns))
        #expect(source.saves.suffix(3).allSatisfy { $0.0 == nil })
    }

    @Test func aSelectionWithAnUntimedParagraphSavesNothing() async {
        let source = Source()
        let editor = SpeakerEditorModel(source: source)
        let untimed = TranscriptTurn(id: "u", speakerLabel: "s#1", name: "Speaker 1", role: .unresolved,
                                     text: "No timing.", segmentId: "s")
        await editor.load(conversationId: "c", turns: [turn, untimed])
        #expect(await editor.choose(nil, for: [turn, untimed]) == false)
        #expect(source.saves.isEmpty)
    }

    @Test func oneSaveLearnsEachClearParagraphAndRechecksRecentRecordingsOnce() async {
        let source = Source()
        let voice = VoiceTestSource()
        voice.state = VoiceSettingsDisplay(enabled: true, modelsReady: true)
        let editor = SpeakerEditorModel(source: source, voice: voice)
        let turns = (0..<7).map { index in
            TranscriptTurn(id: "p\(index)", speakerLabel: "s#1", name: "Speaker 1", role: .unresolved,
                           text: "Paragraph \(index).", segmentId: "s",
                           sourceStartMs: Int64(index) * 40_000, sourceEndMs: Int64(index) * 40_000 + 3_000 + Int64(index) * 1_000)
        }
        let short = TranscriptTurn(id: "short", speakerLabel: "s#1", name: "Speaker 1", role: .unresolved,
                                   text: "Yes.", segmentId: "s", sourceStartMs: 500_000, sourceEndMs: 501_000)
        await editor.load(conversationId: "c", turns: turns + [short])
        #expect(editor.voiceAvailable)
        let dana = Person(id: "dana", name: "Dana")
        source.registry = [dana]
        #expect(await editor.choose(dana, for: turns + [short], rememberVoice: true))
        #expect(source.saves.count == 8, "Every paragraph is named, the one-word one included")
        #expect(voice.enrollmentPeople.count == 5, "The five longest clear paragraphs teach the voice")
        #expect(voice.learnedRechecks == ["dana"], "One recheck per save, not one per paragraph")
        #expect(editor.learnNotice == nil)
    }

    @Test func allByThisSpeakerStaysInTheRecordingAndKeepsEarlierDecisions() {
        func turn(_ id: String, _ segment: String, _ label: String, person: String? = nil) -> TranscriptItem {
            .turn(TranscriptTurn(id: id, speakerLabel: label, name: "Speaker", role: .unresolved, text: id,
                                 segmentId: segment, personId: person, sourceStartMs: 0, sourceEndMs: 3_000))
        }
        let transcript = [turn("a", "s1", "2"), turn("b", "s1", "1"), turn("c", "s1", "2"),
                          turn("d", "s1", "2", person: "sam"), turn("e", "s2", "2"), turn("f", "s1", "2")]
        guard case .turn(let picked) = transcript[0] else { return }
        let whole = ConversationScreen.wholeSpeaker(of: [picked], in: transcript)
        #expect(whole.map(\.id) == ["a", "c", "f"],
                "Same label in the same recording only; d was already named Sam, e is another recording's 2")
    }

    @Test func onlyAnAllRecognizedSamePersonSelectionOffersThatsThem() {
        func turn(_ id: String, person: String?, match: Bool, role: SpeakerRole = .other) -> TranscriptTurn {
            TranscriptTurn(id: id, speakerLabel: "1", name: person == "me" ? "You" : "Dana", role: role, text: id,
                           segmentId: "s", personId: person, isVoiceMatch: match, sourceStartMs: 0, sourceEndMs: 3_000)
        }
        #expect(ConversationScreen.recognizedPerson(of: [turn("a", person: "dana", match: true),
                                                         turn("b", person: "dana", match: true)])?.id == "dana")
        #expect(ConversationScreen.recognizedPerson(of: [turn("a", person: "me", match: true, role: .you)])?.isCurrentUser == true)
        #expect(ConversationScreen.recognizedPerson(of: [turn("a", person: "dana", match: true),
                                                         turn("b", person: "dana", match: false)]) == nil,
                "A name the person chose isn't something to confirm")
        #expect(ConversationScreen.recognizedPerson(of: [turn("a", person: "dana", match: true),
                                                         turn("b", person: "sam", match: true)]) == nil)
    }
}
