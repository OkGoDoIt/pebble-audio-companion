import Foundation
import Testing
import AppDB

@testable import Intelligence

// Port of `core/ai/src/jvmTest/.../FileAiOutputStoreTest.kt` against the DB-backed store
// (plan 6.5 moves persistent AI outputs into the `notes` table), plus pins for the pieces the
// DB move adds: editedAtMs stamping and coexistence with Notes-flow rows.

@Suite struct AiOutputsTests {
    private func makeStore(clock: TestWallClock = TestWallClock(ms: 1_000)) throws
        -> (AiOutputStore, AppDatabase)
    {
        let db = try AppDatabase.inMemory()
        return (AiOutputStore(db: db, nowMs: { clock.now }), db)
    }

    @Test func savesLoadsListsAndDeletesOutput() async throws {
        let (store, _) = try makeStore()
        let request = AiRunRequest(
            requestId: "run-1",
            prompt: AiPromptTemplate(
                id: "actions", title: "Action Items",
                systemPrompt: "Extract action items.", userPrompt: "Use transcripts."),
            transcripts: [
                TranscriptExcerpt(segmentId: "seg-1", text: "call Sam"),
                TranscriptExcerpt(segmentId: "seg-1", text: "email Lee"),
                TranscriptExcerpt(segmentId: "seg-2", text: "book room"),
            ])
        let result = RoutedAiResult(
            text: "1. Call Sam\n2. Email Lee", modeUsed: .remoteOnly, providerId: "remote",
            modelUsed: "model-a", inputTokens: 12, outputTokens: 8)

        let saved = try await store.save(
            request: request, result: result, userConsentedToRemote: true)

        #expect(saved.outputId == "run-1")
        #expect(saved.segmentIds == ["seg-1", "seg-2"])
        #expect(saved.createdAtMs == 1_000)
        #expect(saved.modeUsed == .remoteOnly)
        #expect(saved.userConsentedToRemote == true)
        #expect(try await store.load(outputId: "run-1") == saved)
        #expect(try await store.list() == [saved])

        try await store.delete(outputId: "run-1")
        #expect(try await store.load(outputId: "run-1") == nil)
    }

    @Test func deleteAllRemovesOutputs() async throws {
        let (store, _) = try makeStore()
        let prompt = AiPromptTemplate(
            id: "summary", title: "Summary",
            systemPrompt: "Summarize.", userPrompt: "Use transcripts.")
        let result = RoutedAiResult(
            text: "summary", modeUsed: .localOnly, providerId: "local",
            modelUsed: nil, inputTokens: nil, outputTokens: nil)
        try await store.save(
            request: AiRunRequest(
                requestId: "run-1", prompt: prompt,
                transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "one")]),
            result: result, userConsentedToRemote: false)
        try await store.save(
            request: AiRunRequest(
                requestId: "run-2", prompt: prompt,
                transcripts: [TranscriptExcerpt(segmentId: "seg-2", text: "two")]),
            result: result, userConsentedToRemote: false)

        try await store.deleteAll()

        #expect(try await store.list() == [])
    }

    @Test func updateTextStampsEditedAtAndListStaysCreationOrdered() async throws {
        let clock = TestWallClock(ms: 1_000)
        let (store, _) = try makeStore(clock: clock)
        let prompt = AiPromptTemplate(
            id: "summary", title: "Summary", systemPrompt: "s", userPrompt: "u")
        let result = RoutedAiResult(
            text: "first", modeUsed: .localOnly, providerId: "local",
            modelUsed: nil, inputTokens: nil, outputTokens: nil)
        let first = try await store.save(
            request: AiRunRequest(
                requestId: "run-1", prompt: prompt,
                transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "one")]),
            result: result, userConsentedToRemote: false)
        clock.now = 2_000
        let second = try await store.save(
            request: AiRunRequest(
                requestId: "run-2", prompt: prompt,
                transcripts: [TranscriptExcerpt(segmentId: "seg-2", text: "two")]),
            result: result, userConsentedToRemote: false)

        clock.now = 3_000
        let updated = try await store.updateText(outputId: "run-1", text: "edited")
        #expect(updated?.text == "edited")
        #expect(updated?.editedAtMs == 3_000)
        #expect(updated?.createdAtMs == 1_000)
        #expect(try await store.load(outputId: "run-1") == updated)
        #expect(try await store.updateText(outputId: "missing", text: "x") == nil)

        // Oldest first by creation, and the edit does not reorder.
        #expect(try await store.list().map(\.outputId) == [first.outputId, second.outputId])
    }

    /// The store shares the `notes` table with the Notes flow; rows it did not write are
    /// invisible to it and survive `deleteAll()`.
    @Test func notesFlowRowsAreInvisibleAndSurviveDeleteAll() async throws {
        let (store, db) = try makeStore()
        let notes = NotesStore(db: db)
        try await notes.create(
            conversationId: "conv-1", templateId: "summary", title: "My note", body: "Kept.")
        try await store.save(
            request: AiRunRequest(
                requestId: "run-1",
                prompt: AiPromptTemplate(
                    id: "summary", title: "Summary", systemPrompt: "s", userPrompt: "u"),
                transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "one")]),
            result: RoutedAiResult(
                text: "summary", modeUsed: .localOnly, providerId: "local",
                modelUsed: nil, inputTokens: nil, outputTokens: nil),
            userConsentedToRemote: false)

        #expect(try await store.list().map(\.outputId) == ["run-1"])

        try await store.deleteAll()
        #expect(try await store.list() == [])
        let remaining = try await notes.list(conversationId: "conv-1")
        #expect(remaining.map(\.title) == ["My note"])
    }
}
