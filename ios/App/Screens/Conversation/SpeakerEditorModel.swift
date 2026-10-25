import AppDB
import Foundation
import Observation

enum SpeakerEditorError: LocalizedError {
    case timingUnavailable
    var errorDescription: String? { Copy.Speaker.timingUnavailable }
}

/// Manual decisions only. Naming a passage never starts recording or enrolls a voice.
@MainActor @Observable
final class SpeakerEditorModel {
    private(set) var people: [Person] = []
    private(set) var assigned: Person?
    private(set) var isSaving = false
    private(set) var loaded = false
    private(set) var errorMessage: String?
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
            errorMessage = nil
        } catch {
            errorMessage = Copy.Speaker.loadFailed
        }
    }

    func choose(_ person: Person?, for turn: TranscriptTurn, makeCurrentUser: Bool = false) async -> Bool {
        await save(turn: turn) {
            try await self.source.assignPassage(turn, personId: person?.id, makeCurrentUser: makeCurrentUser)
        }
    }

    func createAndChoose(name: String, for turn: TranscriptTurn) async -> Bool {
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
            self.pendingPerson = nil
        }
    }

    func chooseMe(for turn: TranscriptTurn) async -> Bool {
        await save(turn: turn) {
            // Re-read: another open screen may have changed the explicit association.
            let all = try await self.source.people()
            let person: Person
            if let me = all.first(where: \.isCurrentUser) { person = me }
            else if let pending = self.pendingPerson, pending.name == Copy.Speaker.you { person = pending }
            else {
                person = try await self.source.createPerson(name: Copy.Speaker.you)
                self.pendingPerson = person
            }
            try await self.source.assignPassage(turn, personId: person.id, makeCurrentUser: true)
            self.pendingPerson = nil
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

    private func save(turn: TranscriptTurn? = nil, operation: () async throws -> Void) async -> Bool {
        guard !isSaving, loaded else { return false }
        if let turn, !turn.canIdentifyPassage {
            errorMessage = Copy.Speaker.timingUnavailable
            return false
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await operation()
            return true
        } catch {
            errorMessage = Copy.Speaker.saveFailed
            return false
        }
    }
}
