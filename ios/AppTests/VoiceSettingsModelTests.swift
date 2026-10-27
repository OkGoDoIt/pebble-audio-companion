import AppDB
import CompanionRuntime
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
    var streaming = true
    var watchAudio: WatchVoiceSampleAudio?
    var enrolledKinds: [VoiceSampleKind?] = []
    var watchWindows: [ClosedRange<Int64>] = []
    func enrollPCM(personId: String, pcm16LE: Data, sessionID: String, kind: VoiceSampleKind?) async throws -> Int {
        if failEnrollment { throw Failure.unavailable }
        enrollmentPeople.append(personId)
        enrolledKinds.append(kind)
        return 2
    }
    func watchIsStreaming() async -> Bool { streaming }
    func watchSampleAudio(phoneStartMs: Int64, phoneEndMs: Int64) async -> WatchVoiceSampleAudio? { watchAudio }
    func enrollWatch(personId: String, fromWallMs: Int64, toWallMs: Int64, sessionID: String,
                     kind: VoiceSampleKind?) async throws -> Int {
        if failEnrollment { throw Failure.unavailable }
        enrollmentPeople.append(personId)
        enrolledKinds.append(kind)
        watchWindows.append(fromWallMs...toWallMs)
        return 2
    }
    var learnedRechecks: [String] = []
    var unknown: [UnknownVoiceDisplay] = []
    var namedUnknown: [(String, String, Set<String>?)] = []
    var dismissedUnknown: [String] = []
    func unknownVoices() async -> [UnknownVoiceDisplay] { unknown }
    func nameUnknownVoice(id: String, personId: String, recordings: Set<String>?) async throws -> Int {
        namedUnknown.append((id, personId, recordings))
        return recordings?.count ?? unknown.first { $0.id == id }?.recordingCount ?? 0
    }
    func dismissUnknownVoice(id: String) async throws { dismissedUnknown.append(id) }
    func clipAudio(segmentId: String, startMs: Int64, endMs: Int64) async -> Data? { Data(count: 64_000) }
    var contextRequests: [String] = []
    func clipContextAudio(segmentId: String, startMs: Int64, endMs: Int64) async -> Data? {
        contextRequests.append(segmentId); return Data(count: 320_000)
    }
    func recognizeAfterLearning(personId: String, since earliestMs: Int64?) async { learnedRechecks.append(personId) }
    func enrollPassage(personId: String, turn: TranscriptTurn) async throws -> VoiceEnrollmentOutcome {
        enrollmentPeople.append(personId)
        return VoiceEnrollmentOutcome(personId: personId, examplesAdded: 1, usableSpeechSeconds: 4)
    }
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

/// Samples recorded through the watch: the phone marks the window, the watch's audio for it is
/// what gets learned, and its last seconds may still be on their way when the person stops.
@Suite("voice samples through the watch") @MainActor
struct VoiceWatchSampleRecorderTests {
    final class Clock { var ms: Int64 = 1_000_000 }

    private func recorder(_ source: VoiceTestSource, _ clock: Clock, timeout: TimeInterval = 0.3) -> VoiceWatchSampleRecorder {
        VoiceWatchSampleRecorder(source: source, now: { clock.ms }, pollInterval: .milliseconds(20),
                                 arrivalTimeout: timeout)
    }

    private func audio(seconds: Int, through: Int64) -> WatchVoiceSampleAudio {
        WatchVoiceSampleAudio(pcm16LE: Data(count: seconds * 32_000), receivedThroughWallMs: through,
                              watchFromMs: 5, watchToMs: 15)
    }

    @Test func aWatchThatIsNotStreamingCannotRecordASample() async {
        let source = VoiceTestSource()
        source.streaming = false
        let recorder = recorder(source, Clock())
        await recorder.start()
        #expect(recorder.phase == .idle)
        #expect(recorder.errorMessage?.contains("Start recording on the watch") == true)
    }

    @Test func stoppingWaitsForTheWatchThenUsesWhatArrived() async {
        let source = VoiceTestSource(), clock = Clock()
        let recorder = recorder(source, clock)
        await recorder.start()
        #expect(recorder.phase == .recording)
        clock.ms += 15_000
        // The last two seconds never arrive; the thirteen that did are plenty.
        source.watchAudio = audio(seconds: 13, through: clock.ms - 2_000)
        await recorder.finish()
        #expect(recorder.phase == .ready)
        #expect(recorder.window == 1_000_000...1_015_000)
        #expect(recorder.watchWindow == 5...15, "Enrollment reads the window on the watch's own clock")
    }

    @Test func tooLittleSpeechGoesBackToTheStartWithAReason() async {
        let source = VoiceTestSource(), clock = Clock()
        let recorder = recorder(source, clock)
        await recorder.start()
        clock.ms += 20_000
        source.watchAudio = audio(seconds: 3, through: clock.ms)
        await recorder.finish()
        #expect(recorder.phase == .idle && recorder.window == nil)
        #expect(recorder.errorMessage?.contains("enough speech") == true)
    }

    @Test func nothingArrivingSaysTheWatchDidNotDeliver() async {
        let source = VoiceTestSource(), clock = Clock()
        let recorder = recorder(source, clock)
        await recorder.start()
        clock.ms += 20_000
        await recorder.finish()
        #expect(recorder.phase == .idle)
        #expect(recorder.errorMessage?.contains("didn’t reach the phone") == true)
    }

    @Test func savingAWatchSampleLearnsItsWindowAndSituationAndTurnsRecognitionOn() async {
        let source = VoiceTestSource()
        let model = VoiceSettingsModel(source: source)
        let me = Person(id: "me", name: "Roger", isCurrentUser: true)
        #expect(await model.saveWatchEnrollment(name: "", person: me, fromWallMs: 10, toWallMs: 20_010,
                                                sessionID: "s", kind: .noisy))
        #expect(source.watchWindows == [10...20_010])
        #expect(source.enrolledKinds == [.noisy])
        #expect(source.enabledValues == [true])
    }

    @Test func samplesAreLabelledByTheirSituationOrMicrophone() {
        func example(_ confirmation: String, _ segment: String) -> VoiceConfirmedExample {
            VoiceConfirmedExample(personId: "me", confirmationID: confirmation, sessionID: "s", segmentId: segment,
                startMediaMs: 0, endMediaMs: 4_000, sourceRevision: "r", recipeID: "x",
                recipeJSON: Data(), embeddingJSON: Data(), qualityJSON: Data())
        }
        let grouped = VoiceExampleDisplay.grouped([
            example("a", "watch-enrollment:1"), example("b", "enrollment:2"),
            example("c", "segment-from-a-conversation"), example("d", "watch-enrollment:3")],
            kinds: ["a": "outdoors"])
        let labels = Dictionary(uniqueKeysWithValues: grouped.map { ($0.id, $0.source) })
        #expect(labels == ["a": "Outdoors or on the move", "b": "Phone microphone",
                           "c": "From a conversation", "d": "Watch sample"])
        #expect(grouped.first { $0.id == "b" }?.microphone == .phone)
    }
}
