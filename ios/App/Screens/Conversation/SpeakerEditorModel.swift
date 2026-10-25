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
    private let injectedSource: (any PeopleDataSource)?
    private var source: any PeopleDataSource { injectedSource ?? AskLibraryDataSources.current.people }
    // Retain a newly created identity if saving its passage fails; Retry must not create a twin.
    private var pendingPerson: Person?

    init(source: (any PeopleDataSource)? = nil) { injectedSource = source }

    func load(conversationId: String, turn: TranscriptTurn) async {
        guard !isSaving else { return }
        do {
            let people = try await source.people()
            let assigned = try await source.assignedPerson(conversationId: conversationId, turn: turn)
            self.people = people
            self.assigned = assigned
            loaded = true
            if let voice = VoiceSources.current, let state = try? await voice.snapshot() {
                voiceAvailable = state.enabled && state.modelsReady
            }
            errorMessage = nil
        } catch {
            errorMessage = Copy.Speaker.loadFailed
        }
    }

    func choose(_ person: Person?, for turn: TranscriptTurn, rememberVoice: Bool = false) async -> Bool {
        await save(turn: turn) {
            try await self.source.assignPassage(turn, personId: person?.id, makeCurrentUser: false)
            self.nameWasSaved = true
            if rememberVoice, let person { try await self.remember(person.id, turn: turn) }
        }
    }

    func createAndChoose(name: String, for turn: TranscriptTurn, rememberVoice: Bool = false) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return await save(turn: turn) {
            let person: Person
            if let pending = self.pendingPerson, pending.name == name { person = pending }
            else {
                person = try await self.source.createPerson(name: name)
                self.pendingPerson = person
            }
            try await self.source.assignPassage(turn, personId: person.id, makeCurrentUser: false)
            self.nameWasSaved = true
            if rememberVoice { try await self.remember(person.id, turn: turn) }
            self.pendingPerson = nil
        }
    }

    func chooseMe(for turn: TranscriptTurn, name: String, rememberVoice: Bool = false) async -> Bool {
        await save(turn: turn) {
            let person = try await self.source.assignCurrentUserPassage(turn, displayName: name)
            self.nameWasSaved = true
            if rememberVoice { try await self.remember(person.id, turn: turn) }
        }
    }

    private func remember(_ id: String, turn: TranscriptTurn) async throws {
        guard let voice = VoiceSources.current else { throw SpeakerEditorError.voiceUnavailable }
        _ = try await voice.enrollPassage(personId: id, turn: turn)
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

    private func save(turn: TranscriptTurn? = nil, operation: () async throws -> Void) async -> Bool {
        guard !isSaving, loaded else { return false }
        if let turn, !turn.canIdentifyPassage {
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
