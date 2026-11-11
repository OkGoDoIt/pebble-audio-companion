import AppDB
import Foundation
import Observation

@MainActor @Observable
final class VoiceSettingsModel {
    private(set) var display = VoiceSettingsDisplay()
    /// Recurring voices with no name yet, most-heard first.
    private(set) var unknownVoices: [UnknownVoiceDisplay] = []
    /// The voice to ask about next, with what was said in it.
    private(set) var leadReview: UnknownVoiceDisplay?
    /// "Is this you?": asked of the voice heard far more than any other, until there's an answer.
    private(set) var firstAsk: UnknownVoiceDisplay?
    private(set) var loaded = false
    private(set) var working = false
    private(set) var downloadProgress: Double?
    private(set) var errorMessage: String?
    private var refreshGeneration: UInt64 = 0
    private let injectedSource: (any VoiceRecognitionDataSource)?
    private var source: (any VoiceRecognitionDataSource)? { injectedSource ?? VoiceSources.current }

    init(source: (any VoiceRecognitionDataSource)? = nil) { injectedSource = source }

    /// Work in progress reports constantly on the charger. This rest keeps the screens from
    /// chasing it; what a person answers here refreshes them at once anyway.
    var restAfterRefresh: Duration = .seconds(5)
    /// Voice screens showing now. Refreshing for none of them is work nobody sees.
    private var screensShowing = 0
    private var appActive = true
    private var missedUpdate = false
    private var observing = false
    var isOnScreen: Bool { screensShowing > 0 && appActive }

    func screenAppeared() { screensShowing += 1; catchUp() }
    func screenDisappeared() { screensShowing = max(0, screensShowing - 1) }
    func appBecame(active: Bool) { appActive = active; catchUp() }

    /// Back on screen after updates went by unread: one refresh covers them all.
    private func catchUp() {
        guard isOnScreen, missedUpdate else { return }
        missedUpdate = false
        Task { await refresh() }
    }

    /// One loop per model, however many of its screens ask.
    func observe() async {
        guard !observing else { return }
        observing = true
        defer { observing = false }
        await refresh()
        guard let source else { return }
        for await _ in source.updates() {
            if Task.isCancelled { return }
            guard isOnScreen else { missedUpdate = true; continue }
            await refresh()
            try? await Task.sleep(for: restAfterRefresh)
        }
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard let source else { errorMessage = Copy.Voices.unavailable; return }
        do {
            let updated = try await source.snapshot()
            guard generation == refreshGeneration else { return }
            if display != updated { display = updated }
            let voices = updated.enabled ? await source.unknownVoices() : []
            guard generation == refreshGeneration else { return }
            if unknownVoices != voices { unknownVoices = voices }
            let lead = updated.enabled ? await fetchedDetail(of: toReview.first, had: leadReview, source: source) : nil
            let first = updated.enabled ? await fetchedDetail(of: firstAskCandidate(updated), had: firstAsk, source: source) : nil
            guard generation == refreshGeneration else { return }
            if leadReview != lead { leadReview = lead }
            if firstAsk != first { firstAsk = first }
            if errorMessage == Copy.Voices.loadFailed || errorMessage == Copy.Voices.unavailable { errorMessage = nil }
            loaded = true
        } catch {
            guard generation == refreshGeneration else { return }
            errorMessage = Copy.Voices.loadFailed
        }
    }

    /// A stray few seconds can wait: on the phone, 51 of 61 possible matches held under a minute,
    /// and the 5 largest held three-quarters of the speech.
    static let worthAskingMs: Int64 = 60_000
    /// Everything that might be someone, most heard first: their own screen lists these.
    var possibleMatches: [UnknownVoiceDisplay] { unknownVoices.filter { $0.suggestion != nil } }
    /// The ones worth asking about unprompted.
    var toReview: [UnknownVoiceDisplay] { possibleMatches.filter { $0.repaired || $0.speechMs >= Self.worthAskingMs } }
    /// Voices like nobody yet, heard enough to be worth a name.
    var toName: [UnknownVoiceDisplay] { unknownVoices.filter { $0.suggestion == nil && ($0.repaired || $0.speechMs >= Self.worthAskingMs) } }
    /// No voice to go by for the person wearing the watch, and no voice to ask them about either.
    var needsOwnVoice: Bool { !hasOwnVoice(display) && firstAsk == nil }

    private func hasOwnVoice(_ display: VoiceSettingsDisplay) -> Bool {
        display.people.contains { $0.person.isCurrentUser && (!$0.examples.isEmpty || $0.speechMs > 0) }
    }

    private func firstAskCandidate(_ display: VoiceSettingsDisplay) -> UnknownVoiceDisplay? {
        guard !hasOwnVoice(display), let top = toName.first, top.recordingCount >= 3,
              let speech = display.coverage?.speechMs, speech > 0, Double(top.speechMs) >= 0.25 * Double(speech) else { return nil }
        return top
    }

    /// The same voice keeps the words already read for it, as long as it hasn't changed.
    private func fetchedDetail(of voice: UnknownVoiceDisplay?, had: UnknownVoiceDisplay?,
                               source: any VoiceRecognitionDataSource) async -> UnknownVoiceDisplay? {
        guard let voice else { return nil }
        if let had, had.id == voice.id, had.recordingCount == voice.recordingCount, had.suggestion == voice.suggestion { return had }
        return await source.voiceDetail(id: voice.id) ?? voice
    }

    func detail(_ voice: UnknownVoiceDisplay) async -> UnknownVoiceDisplay? {
        await source?.voiceDetail(id: voice.id) ?? voice
    }

    func appearances(personId: String) async -> [VoiceAppearanceDisplay] {
        await source?.appearances(personId: personId) ?? []
    }

    /// "That's Dana", for the whole voice.
    func confirm(_ voice: UnknownVoiceDisplay, as suggestion: VoiceSuggestionDisplay) async {
        var count = 0
        let done = await perform { count = try await $0.nameUnknownVoice(id: voice.id, personId: suggestion.person.id, clips: nil) }
        guard done else { return }
        UndoCenter.shared.snackbar = WhoIsThisModel.namedNotice(suggestion.name, count: count, voiceId: voice.id,
                                                                personId: suggestion.person.id) { [weak self] in
            await self?.refresh()
        }
    }

    /// "Someone else": they aren't asked about as this person again.
    func someoneElse(_ voice: UnknownVoiceDisplay, instead suggestion: VoiceSuggestionDisplay) async -> Bool {
        await perform { try await $0.rejectSuggestion(id: voice.id, personId: suggestion.person.id) }
    }

    func notThisPerson(_ appearance: VoiceAppearanceDisplay, personId: String) async {
        _ = await perform { try await $0.notThisPerson(appearance, personId: personId) }
    }

    func enable(_ value: Bool) async -> Bool {
        await perform { source in
            if value { try await self.prepare(source) }
            try await source.setEnabled(value)
        }
    }

    func prepareForEnrollment() async -> Bool {
        await perform { source in try await self.prepare(source) }
    }

    func saveEnrollment(name: String, person: Person?, pcm: Data, sessionID: String,
                        kind: VoiceSampleKind? = .phone) async -> Bool {
        await perform { source in
            let target = try await self.target(source, name: name, person: person)
            _ = try await source.enrollPCM(personId: target.id, pcm16LE: pcm, sessionID: sessionID, kind: kind)
            try await source.setEnabled(true)
        }
    }

    /// A sample recorded through the watch between two instants on this phone's clock.
    func saveWatchEnrollment(name: String, person: Person?, fromWallMs: Int64, toWallMs: Int64,
                             sessionID: String, kind: VoiceSampleKind) async -> Bool {
        await perform { source in
            let target = try await self.target(source, name: name, person: person)
            _ = try await source.enrollWatch(personId: target.id, fromWallMs: fromWallMs, toWallMs: toWallMs,
                                             sessionID: sessionID, kind: kind)
            try await source.setEnabled(true)
        }
    }

    private func target(_ source: any VoiceRecognitionDataSource, name: String, person: Person?) async throws -> Person {
        if let person { return person }
        return try await source.currentUser(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func cancelEnrollment() async { await source?.cancelEnrollment() }

    func recognizeHistory(days: Int?) async {
        _ = await perform { try await $0.recognizeHistory(days: days) }
    }
    func cancel(_ run: VoiceRunDisplay) async {
        _ = await perform { try await $0.cancelRun(id: run.id) }
    }
    func undo(_ run: VoiceRunDisplay) async {
        _ = await perform { try await $0.undoRun(id: run.id) }
    }
    func stopAsking(about voice: UnknownVoiceDisplay) async {
        _ = await perform { try await $0.dismissUnknownVoice(id: voice.id) }
    }
    func clearAutomaticNames() async { _ = await perform { try await $0.clearAutomaticNames() } }
    func forget(_ person: VoicePersonDisplay) async {
        _ = await perform { try await $0.forgetVoice(personId: person.id) }
    }
    func remove(_ example: VoiceExampleDisplay) async {
        _ = await perform { try await $0.removeExamples(ids: example.exampleIDs.isEmpty ? [example.id] : example.exampleIDs) }
    }

    private func prepare(_ source: any VoiceRecognitionDataSource) async throws {
        downloadProgress = 0
        defer { downloadProgress = nil }
        try await source.prepareModels { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.working, self.downloadProgress != nil else { return }
                self.downloadProgress = min(max(progress, 0), 1)
            }
        }
    }

    private func perform(_ operation: @MainActor (any VoiceRecognitionDataSource) async throws -> Void) async -> Bool {
        guard !working, let source else { return false }
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            try await operation(source)
            await refresh()
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? Copy.Voices.actionFailed
            await refresh()
            return false
        }
    }
}
