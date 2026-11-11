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
    var snapshotCount = 0
    var updateStream: AsyncStream<Void>?
    func snapshot() async throws -> VoiceSettingsDisplay {
        snapshotCount += 1
        if let snapshotOverride { return try await snapshotOverride() }
        return state
    }
    func updates() -> AsyncStream<Void> { updateStream ?? AsyncStream { $0.finish() } }
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
    var ignoredClips: [UnknownVoiceClip] = []
    var failIgnore = false
    func unknownVoices() async -> [UnknownVoiceDisplay] { unknown }
    var splitDraft: VoiceSplitDraft?
    var savedSplit: VoiceSplitDraft?
    var failSplit = false
    func prepareVoiceSplit(id: String) async throws -> VoiceSplitDraft {
        guard let splitDraft else { throw Failure.unavailable }; return splitDraft
    }
    func saveVoiceSplit(_ draft: VoiceSplitDraft) async throws -> VoiceSplitResult {
        if failSplit { throw Failure.unavailable }
        savedSplit = draft
        return VoiceSplitResult(undoToken: "undo", groupIDs: draft.groups.indices.map { "child-\($0)" })
    }
    func nameUnknownVoice(id: String, personId: String, clips: Set<String>?) async throws -> Int {
        namedUnknown.append((id, personId, clips))
        return clips?.count ?? unknown.first { $0.id == id }?.recordingCount ?? 0
    }
    func voiceDetail(id: String) async -> UnknownVoiceDisplay? { unknown.first { $0.id == id } }
    var rejected: [(String, String)] = []
    func rejectSuggestion(id: String, personId: String) async throws { rejected.append((id, personId)) }
    var undone: [(String, String)] = []
    func undoNaming(id: String, personId: String) async throws { undone.append((id, personId)) }
    func appearances(personId: String) async -> [VoiceAppearanceDisplay] { [] }
    func notThisPerson(_ appearance: VoiceAppearanceDisplay, personId: String) async throws {}
    func dismissUnknownVoice(id: String) async throws {
        if failIgnore { throw Failure.unavailable }
        dismissedUnknown.append(id)
    }
    func ignoreUnknownClip(_ clip: UnknownVoiceClip) async throws {
        if failIgnore { throw Failure.unavailable }
        ignoredClips.append(clip)
    }
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
    /// People & voices asks one question at a time: voices that might be someone go to review,
    /// the rest wait in "Voices to name", and answering brings up the next.
    @Test func voicesThatMightBeSomeoneComeFirstOneAtATime() async {
        let source = VoiceTestSource()
        source.state.enabled = true
        let dana = Person(id: "dana", name: "Dana")
        func voice(_ id: String, suggested: Person?) -> UnknownVoiceDisplay {
            UnknownVoiceDisplay(id: id, recordingCount: 4, detail: "", clips: [], speechMs: 60_000,
                                suggestion: suggested.map { VoiceSuggestionDisplay(person: $0, colorIndex: 1, score: 0.5) })
        }
        source.unknown = [voice("a", suggested: nil), voice("b", suggested: dana), voice("c", suggested: dana)]
        let model = VoiceSettingsModel(source: source)
        await model.refresh()
        #expect(model.toReview.map(\.id) == ["b", "c"])
        #expect(model.toName.map(\.id) == ["a"])
        #expect(model.leadReview?.id == "b")

        let lead = try! #require(model.leadReview)
        await model.confirm(lead, as: try! #require(lead.suggestion))
        #expect(source.namedUnknown.map(\.0) == ["b"])
        source.unknown.removeAll { $0.id == "b" }
        await model.refresh()
        #expect(model.leadReview?.id == "c")
    }

    /// A stray few seconds waits on the person's own screen rather than asking unprompted.
    @Test func aFewSecondsOfAVoiceIsNotWorthAskingAbout() async {
        let source = VoiceTestSource()
        source.state.enabled = true
        let dana = Person(id: "dana", name: "Dana")
        source.unknown = [
            UnknownVoiceDisplay(id: "brief-maybe", recordingCount: 1, detail: "", clips: [], speechMs: 20_000,
                                suggestion: VoiceSuggestionDisplay(person: dana, colorIndex: 1, score: 0.5)),
            UnknownVoiceDisplay(id: "brief", recordingCount: 2, detail: "", clips: [], speechMs: 20_000),
        ]
        let model = VoiceSettingsModel(source: source)
        await model.refresh()
        #expect(model.toReview.isEmpty && model.toName.isEmpty && model.leadReview == nil)
        #expect(model.possibleMatches.map(\.id) == ["brief-maybe"], "Still there for them to look through")
    }

    /// "Is this you?" comes up only for someone with no voice of their own, about a voice heard
    /// far more than any other.
    @Test func theFirstQuestionIsAboutTheVoiceHeardMost() async {
        let source = VoiceTestSource()
        source.state.enabled = true
        source.state.coverage = VoiceCoverageDisplay(speechMs: 100 * 60_000, namedMs: 0, shares: [])
        source.unknown = [UnknownVoiceDisplay(id: "most", recordingCount: 12, detail: "", clips: [], speechMs: 60 * 60_000)]
        let model = VoiceSettingsModel(source: source)
        await model.refresh()
        #expect(model.firstAsk?.id == "most")
        #expect(!model.needsOwnVoice)

        source.state.people = [VoicePersonDisplay(person: Person(id: "me", name: "Alex", isCurrentUser: true), examples: [],
                                                  speechMs: 10 * 60_000)]
        await model.refresh()
        #expect(model.firstAsk == nil, "They have a voice already")

        source.state.people = []
        source.unknown = [UnknownVoiceDisplay(id: "little", recordingCount: 12, detail: "", clips: [], speechMs: 60_000)]
        await model.refresh()
        #expect(model.firstAsk == nil, "Too little of everything said to guess it's them")
        #expect(model.needsOwnVoice)
    }

    /// One person keeps one colour, nobody shares while a colour is free, and adding someone
    /// doesn't repaint the rest.
    @Test func everyoneKeepsTheirOwnColor() {
        let you = Person(id: "you", name: "Alex", isCurrentUser: true)
        let people = (0..<6).map { Person(id: "person-\($0)", name: "P\($0)") }
        let colors = PersonPalette.indices(of: [you] + people)
        #expect(colors["you"] == PersonPalette.youIndex)
        #expect(Set(people.compactMap { colors[$0.id] }).count == 6)
        #expect(!people.contains { colors[$0.id] == PersonPalette.youIndex })
        #expect(PersonPalette.indices(of: [you] + people) == colors, "Stable")
    }

    /// Off screen, the voice screens read nothing however much work reports in; back on
    /// screen, one refresh catches up.
    @Test func nothingIsReadWhileTheScreensAreAway() async {
        let source = VoiceTestSource()
        let (updates, report) = AsyncStream<Void>.makeStream()
        source.updateStream = updates
        let model = VoiceSettingsModel(source: source)
        model.restAfterRefresh = .zero
        model.screenAppeared()
        let observing = Task { await model.observe() }
        func settle(until done: () -> Bool) async {
            for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
        }
        await settle { source.snapshotCount == 1 }
        report.yield()
        await settle { source.snapshotCount == 2 }
        #expect(source.snapshotCount == 2, "On screen, an update is read")

        model.screenDisappeared()
        for _ in 0..<5 { report.yield() }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(source.snapshotCount == 2, "Away, nothing is read")

        model.screenAppeared()
        await settle { source.snapshotCount == 3 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(source.snapshotCount == 3, "Back, one read covers what went by")
        observing.cancel()
        report.finish()
    }

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
