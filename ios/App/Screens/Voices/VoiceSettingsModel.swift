import AppDB
import Foundation
import Observation

@MainActor @Observable
final class VoiceSettingsModel {
    private(set) var display = VoiceSettingsDisplay()
    /// Recurring voices with no name yet, most-heard first.
    private(set) var unknownVoices: [UnknownVoiceDisplay] = []
    private(set) var loaded = false
    private(set) var working = false
    private(set) var downloadProgress: Double?
    private(set) var errorMessage: String?
    private var refreshGeneration: UInt64 = 0
    private let injectedSource: (any VoiceRecognitionDataSource)?
    private var source: (any VoiceRecognitionDataSource)? { injectedSource ?? VoiceSources.current }

    init(source: (any VoiceRecognitionDataSource)? = nil) { injectedSource = source }

    func observe() async {
        await refresh()
        guard let source else { return }
        for await _ in source.updates() {
            if Task.isCancelled { return }
            await refresh()
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
            if errorMessage == Copy.Voices.loadFailed || errorMessage == Copy.Voices.unavailable { errorMessage = nil }
            loaded = true
        } catch {
            guard generation == refreshGeneration else { return }
            errorMessage = Copy.Voices.loadFailed
        }
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
