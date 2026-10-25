import AppDB
import Foundation
import Testing

@MainActor final class VoiceTestSource: VoiceRecognitionDataSource {
    enum Failure: Error { case unavailable }
    var state = VoiceSettingsDisplay()
    var snapshotOverride: (@MainActor () async throws -> VoiceSettingsDisplay)?
    var failPreparation = false
    var failEnrollment = false
    var preparationCount = 0
    var enabledValues: [Bool] = []
    var enrollmentPeople: [String] = []
    var scopes: [Int?] = []
    var cancelled = false
    var removedExampleIDs: [String] = []
    func snapshot() async throws -> VoiceSettingsDisplay {
        if let snapshotOverride { return try await snapshotOverride() }
        return state
    }
    func updates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func prepareModels(progress: @escaping @Sendable (Double) -> Void) async throws {
        preparationCount += 1
        if failPreparation { throw Failure.unavailable }
        progress(1)
        state.modelsReady = true
    }
    func setEnabled(_ enabled: Bool) async throws { enabledValues.append(enabled); state.enabled = enabled }
    func currentUser(name: String) async throws -> Person { Person(id: "me", name: name, isCurrentUser: true) }
    func enrollPCM(personId: String, pcm16LE: Data, sessionID: String) async throws -> Int {
        if failEnrollment { throw Failure.unavailable }
        enrollmentPeople.append(personId)
        return 2
    }
    func enrollPassage(personId: String, turn: TranscriptTurn) async throws -> Int { 1 }
    func cancelEnrollment() async { cancelled = true }
    func recognizeHistory(days: Int?) async throws { scopes.append(days) }
    func cancelRun(id: String) async throws {}
    func undoRun(id: String) async throws {}
    func clearAutomaticNames() async throws {}
    func forgetVoice(personId: String) async throws { state.people.removeAll { $0.id == personId } }
    func removeExamples(ids: [String]) async throws {
        removedExampleIDs = ids
        for index in state.people.indices { state.people[index].examples.removeAll { ids.contains($0.id) } }
    }
}

@Suite("voice settings and enrollment") @MainActor
struct VoiceSettingsModelTests {
    @Test func turningOffNeverDownloadsAndPreservesPeople() async {
        let source = VoiceTestSource()
        source.state.enabled = true
        source.state.people = [VoicePersonDisplay(person: Person(id: "me", name: "Roger", isCurrentUser: true), examples: [])]
        let model = VoiceSettingsModel(source: source)
        #expect(await model.enable(false))
        #expect(source.preparationCount == 0)
        #expect(!model.display.enabled)
        #expect(model.display.people.count == 1)
    }
    @Test func failedDownloadCannotEnableRecognition() async {
        let source = VoiceTestSource()
        source.failPreparation = true
        let model = VoiceSettingsModel(source: source)
        #expect(await model.enable(true) == false)
        #expect(source.enabledValues.isEmpty)
        #expect(model.errorMessage != nil)
        #expect(!model.working)
        #expect(model.downloadProgress == nil)
    }
    @Test func enrollmentFailureDoesNotTurnOnRecognitionAndCanRetry() async {
        let source = VoiceTestSource(), pcm = Data(repeating: 1, count: 320_000)
        let model = VoiceSettingsModel(source: source)
        source.failEnrollment = true
        #expect(await model.saveEnrollment(name: "Roger", person: nil, pcm: pcm, sessionID: "s") == false)
        #expect(source.enabledValues.isEmpty)
        source.failEnrollment = false
        #expect(await model.saveEnrollment(name: "Roger", person: nil, pcm: pcm, sessionID: "s"))
        #expect(source.enrollmentPeople == ["me"])
        #expect(model.display.enabled)
    }
    @Test func addingSampleToAnotherPersonNeverReassignsSelf() async {
        let source = VoiceTestSource()
        let editor = VoiceSettingsModel(source: source)
        #expect(await editor.saveEnrollment(name: "ignored", person: Person(id: "sam", name: "Sam"),
                                            pcm: Data(), sessionID: "s"))
        #expect(source.enrollmentPeople == ["sam"])
    }
    @Test func historyScopesAndForgetAreExplicit() async {
        let source = VoiceTestSource()
        let profile = VoicePersonDisplay(person: Person(id: "sam", name: "Sam"), examples: [])
        source.state.people = [profile]
        let model = VoiceSettingsModel(source: source)
        await model.recognizeHistory(days: 7)
        await model.recognizeHistory(days: nil)
        #expect(source.scopes.count == 2)
        #expect(source.scopes[0] == 7)
        #expect(source.scopes[1] == nil)
        await model.forget(profile)
        #expect(model.display.people.isEmpty)
        await model.cancelEnrollment()
        #expect(source.cancelled)
    }

    @Test func staleRefreshCannotRestoreAnOlderModeOrError() async {
        let source = VoiceTestSource()
        var continuations: [CheckedContinuation<VoiceSettingsDisplay, any Error>] = []
        source.snapshotOverride = { try await withCheckedThrowingContinuation { continuations.append($0) } }
        let model = VoiceSettingsModel(source: source)
        let old = Task { await model.refresh() }
        while continuations.count < 1 { await Task.yield() }
        let latest = Task { await model.refresh() }
        while continuations.count < 2 { await Task.yield() }
        continuations[1].resume(returning: VoiceSettingsDisplay(enabled: true))
        await latest.value
        continuations[0].resume(throwing: VoiceTestSource.Failure.unavailable)
        await old.value
        #expect(model.display.enabled)
        #expect(model.errorMessage == nil)
        #expect(model.loaded)
    }

    @Test func oneConfirmationIsOneVisibleSampleWithAllEvidenceRemovedTogether() async {
        func example(_ id: String, start: Int64, end: Int64, confirmation: String = "one") -> VoiceConfirmedExample {
            VoiceConfirmedExample(id: id, personId: "me", confirmationID: confirmation, sessionID: "session",
                segmentId: "enrollment:session", startMediaMs: start, endMediaMs: end, sourceRevision: "r",
                recipeID: "recipe", recipeJSON: Data(), embeddingJSON: Data(), qualityJSON: Data(), createdAtMs: 100)
        }
        let groups = VoiceExampleDisplay.grouped([
            example("1", start: 0, end: 2_500), example("2", start: 2_500, end: 5_000),
            example("3", start: 0, end: 2_500), example("4", start: 6_000, end: 8_000),
            example("5", start: 0, end: 1_000, confirmation: "two")])
        #expect(groups.count == 2)
        let sample = groups.first { $0.id == "one" }!
        #expect(sample.durationSeconds == 7)
        #expect(sample.exampleIDs == ["1", "2", "3", "4"])
        let source = VoiceTestSource()
        await VoiceSettingsModel(source: source).remove(sample)
        #expect(source.removedExampleIDs == sample.exampleIDs)
    }

    @Test func speakerPreviewStopsAtThePassagesEnd() {
        let model = PlayerModel()
        model.durationMs = 10_000
        model.play(fromMs: 1_000, untilMs: 2_000)
        model.apply(progress: PlaybackProgress(playing: true, positionMs: 2_100, durationMs: 10_000))
        #expect(!model.playing)
        #expect(model.positionMs == 2_000)
        model.stop()
    }
}
