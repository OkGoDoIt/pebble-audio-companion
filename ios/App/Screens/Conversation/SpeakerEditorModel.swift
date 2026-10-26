import AppDB
import Foundation
import Observation

enum SpeakerEditorError: LocalizedError {
    case timingUnavailable, voiceUnavailable
    var errorDescription: String? {
        switch self {
        case .timingUnavailable: Copy.Speaker.timingUnavailable
        case .voiceUnavailable: Copy.Voices.unavailable
        }
    }
}

/// A manual name is saved first. Acoustic enrollment requires the separate, explicit choice.
@MainActor @Observable
final class SpeakerEditorModel {
    private(set) var people: [Person] = []
    private(set) var assigned: Person?
    private(set) var isSaving = false
    private(set) var loaded = false
    private(set) var errorMessage: String?
    private(set) var voiceAvailable = false
    private(set) var nameWasSaved = false
    /// One line about learning the voice after a save, for the screen to show once.
    var learnNotice: String?
    private let injectedSource: (any PeopleDataSource)?
    private var source: any PeopleDataSource { injectedSource ?? AskLibraryDataSources.current.people }
    // Retain a newly created identity if saving its passage fails; Retry must not create a twin.
    private var pendingPerson: Person?

    private let injectedVoice: (any VoiceRecognitionDataSource)?
    private var voiceSource: (any VoiceRecognitionDataSource)? { injectedVoice ?? VoiceSources.current }

    init(source: (any PeopleDataSource)? = nil, voice: (any VoiceRecognitionDataSource)? = nil) {
        injectedSource = source
        injectedVoice = voice
    }

    func load(conversationId: String, turns: [TranscriptTurn]) async {
        guard !isSaving else { return }
        do {
            let people = try await source.people()
            // Several paragraphs may each have someone different; only one shows a current pick.
            let assigned = turns.count == 1
                ? try await source.assignedPerson(conversationId: conversationId, turn: turns[0]) : nil
            self.people = people
            self.assigned = assigned
            loaded = true
            if let voice = voiceSource, let state = try? await voice.snapshot() {
                voiceAvailable = state.enabled && state.modelsReady
            }
            errorMessage = nil
        } catch {
            errorMessage = Copy.Speaker.loadFailed
        }
    }

    func choose(_ person: Person?, for turns: [TranscriptTurn], rememberVoice: Bool = false) async -> Bool {
        await save(turns: turns) {
            for turn in turns { try await self.source.assignPassage(turn, personId: person?.id, makeCurrentUser: false) }
            self.nameWasSaved = true
            if rememberVoice, let person { try await self.remember(person.id, turns: turns) }
        }
    }

    func createAndChoose(name: String, for turns: [TranscriptTurn], rememberVoice: Bool = false) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return await save(turns: turns) {
            let person: Person
            if let pending = self.pendingPerson, pending.name == name { person = pending }
            else {
                person = try await self.source.createPerson(name: name)
                self.pendingPerson = person
            }
            for turn in turns { try await self.source.assignPassage(turn, personId: person.id, makeCurrentUser: false) }
            self.nameWasSaved = true
            if rememberVoice { try await self.remember(person.id, turns: turns) }
            self.pendingPerson = nil
        }
    }

    func chooseMe(for turns: [TranscriptTurn], name: String, rememberVoice: Bool = false) async -> Bool {
        await save(turns: turns) {
            let person = try await self.source.assignCurrentUserPassage(turns[0], displayName: name)
            for turn in turns.dropFirst() {
                try await self.source.assignPassage(turn, personId: person.id, makeCurrentUser: false)
            }
            self.nameWasSaved = true
            if rememberVoice { try await self.remember(person.id, turns: turns) }
        }
    }

    /// Every manual name teaches the voice when recognition is on. The longest passages make
    /// the best samples and a handful is plenty for one change. Learning never undoes or blocks
    /// the name: a passage that can't be learned from is skipped, and one line says so.
    private func remember(_ id: String, turns: [TranscriptTurn]) async throws {
        guard let voice = voiceSource else { return }
        let length: (TranscriptTurn) -> Int64 = { ($0.sourceEndMs ?? 0) - ($0.sourceStartMs ?? 0) }
        let eligible = turns.filter { $0.canIdentifyPassage && length($0) >= 2_000 }.sorted { length($0) > length($1) }
        guard !eligible.isEmpty else { return }
        var learned = 0
        var otherVoice = 0.0
        for turn in eligible.prefix(5) {
            guard let outcome = try? await voice.enrollPassage(personId: id, turn: turn) else { continue }
            learned += outcome.examplesAdded
            otherVoice += outcome.otherVoiceSeconds
        }
        if learned > 0 {
            let earliest = eligible.compactMap(\.startedAt).min().map { Int64($0.timeIntervalSince1970 * 1_000) }
            await voice.recognizeAfterLearning(personId: id, since: earliest)
        }
        if learned == 0 {
            learnNotice = "Saved. The audio was too unclear to learn this voice from."
        } else if otherVoice >= 2 {
            learnNotice = "Saved. Part of it sounded like someone else, so only the rest was learned."
        }
    }

    func rename(_ person: Person, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await save { try await self.source.renamePerson(id: person.id, to: trimmed) }
    }

    func delete(_ person: Person) async -> Bool {
        await save { try await self.source.deletePerson(id: person.id) }
    }

    func makeMe(_ person: Person) async -> Bool {
        await save { try await self.source.setCurrentUser(personId: person.id) }
    }

    private func save(turns: [TranscriptTurn] = [], operation: () async throws -> Void) async -> Bool {
        guard !isSaving, loaded else { return false }
        if !turns.allSatisfy(\.canIdentifyPassage) {
            errorMessage = Copy.Speaker.timingUnavailable
            return false
        }
        isSaving = true
        nameWasSaved = false
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await operation()
            return true
        } catch {
            if nameWasSaved {
                let reason = (error as? LocalizedError)?.errorDescription
                errorMessage = reason.map { "The name was saved. " + $0 } ?? Copy.Voices.manualSavedSampleFailed
            } else { errorMessage = Copy.Speaker.saveFailed }
            return false
        }
    }
}
