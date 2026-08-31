import AppDB
import CompanionRuntime
import Foundation
import Intelligence
import SearchKit
import SegmentStore
import Testing
import Transcription

// Deleting audio must be COMPLETE. A leftover transcript, annotation, AI output, follow-up,
// recap membership or index row keeps the content findable after the person asked for it to be
// gone — that is a privacy bug, not a tidiness one.

@Suite struct DeleteCascadeTests {

    private func seed(
        _ fixture: RuntimeFixture, segmentId: String, conversationId: String
    ) async throws {
        _ = try fixture.transcriptStore.save(
            segmentId,
            result: RoutedTranscription(
                text: "hello there", modeUsed: .localOnly, providerId: "fake", modelUsed: nil
            )
        )
        _ = try await fixture.annotations.save(
            ConversationAnnotation(
                conversationId: conversationId, title: "Title", summary: "Summary"
            )
        )
        _ = try await fixture.aiOutputs.save(
            request: AiRunRequest(
                requestId: "out-only-this",
                prompt: AiPromptTemplate(
                    id: "p", title: "Prompt", systemPrompt: "s", userPrompt: "u"
                ),
                transcripts: [TranscriptExcerpt(segmentId: segmentId, text: "hello there")]
            ),
            result: RoutedAiResult(
                text: "out", modeUsed: .localOnly, providerId: "fake",
                modelUsed: nil, inputTokens: nil, outputTokens: nil
            ),
            userConsentedToRemote: false
        )
        _ = try await fixture.aiOutputs.save(
            request: AiRunRequest(
                requestId: "out-shared",
                prompt: AiPromptTemplate(
                    id: "p", title: "Prompt", systemPrompt: "s", userPrompt: "u"
                ),
                transcripts: [
                    TranscriptExcerpt(segmentId: segmentId, text: "hello there"),
                    TranscriptExcerpt(segmentId: "some-other-segment", text: "elsewhere"),
                ]
            ),
            result: RoutedAiResult(
                text: "out", modeUsed: .localOnly, providerId: "fake",
                modelUsed: nil, inputTokens: nil, outputTokens: nil
            ),
            userConsentedToRemote: false
        )
        _ = try await fixture.followUps.add(
            text: "call back", conversationId: conversationId, segmentId: segmentId, nowMs: 0
        )
        _ = try await fixture.recapStore.save(
            DailyRecap(dateKey: "2026-08-30", text: "the day", segmentIds: [segmentId])
        )
        try fixture.index.upsert([
            IndexItem(
                id: conversationId, kind: .conversation, title: "Title",
                fullText: "hello there", contentCreationDateMs: 0
            ),
            IndexItem(
                id: RecapIndex.documentId(dateKey: "2026-08-30"), kind: .recap,
                title: "Recap", fullText: "the day", contentCreationDateMs: 0
            ),
        ])
    }

    @Test func segmentDeleteRemovesEverythingSourcedOnlyFromIt() async throws {
        let fixture = try RuntimeFixture()
        let segmentId = try await Fixture.writeSegment(into: fixture.store)
        let conversations = try await fixture.enrichment.regroup()
        let conversationId = try #require(conversations.first?.id)
        try await seed(fixture, segmentId: segmentId, conversationId: conversationId)

        let deleted = await fixture.cascade.deleteSegment(segmentId)

        #expect(deleted)
        // Audio + meta.
        #expect(await fixture.store.readMeta(segmentId) == nil)
        // Task + transcript.
        #expect(try fixture.queue.load(segmentId) == nil)
        #expect(fixture.transcriptStore.load(segmentId) == nil)
        // Annotation (the conversation lost its only member).
        #expect(try await fixture.annotations.load(conversationId) == nil)
        // AI outputs: the one sourced ONLY from this segment goes; the shared one survives,
        // because its remaining citations are still true.
        let outputIds = try await fixture.aiOutputs.list().map(\.outputId)
        #expect(!outputIds.contains("out-only-this"))
        #expect(outputIds.contains("out-shared"))
        // Follow-ups.
        #expect(try await fixture.followUps.list().isEmpty)
        // Recap membership + its `day-<key>` index entry.
        #expect(try await fixture.recapStore.list().isEmpty)
        #expect(fixture.index.removedIds.contains("day-2026-08-30"))
        #expect(fixture.index.removedIds.contains(conversationId))
        #expect(fixture.index.ids.isEmpty)
    }

    @Test func theOpenSegmentIsNeverDeleted() async throws {
        let fixture = try RuntimeFixture()
        _ = try await Fixture.writeSegment(into: fixture.store, close: false)
        let openId = try #require(await fixture.store.openSegmentId)

        let deleted = await fixture.cascade.deleteSegment(openId)

        #expect(!deleted)
        #expect(await fixture.store.readMeta(openId) != nil)
    }

    @Test func conversationDeleteCascadesOverEveryMember() async throws {
        let fixture = try RuntimeFixture()
        // Two segments 1 minute apart chain into one conversation (< 5 min rule).
        let first = try await Fixture.writeSegment(
            into: fixture.store, streamId: 1, startTimeMs: 1_756_512_000_000, receivedAtMs: 0
        )
        let second = try await Fixture.writeSegment(
            into: fixture.store, streamId: 2,
            startTimeMs: 1_756_512_000_000 + 60_000, receivedAtMs: 60_000
        )
        let conversations = try await fixture.enrichment.regroup()
        let conversationId = try #require(conversations.first?.id)
        #expect(conversations.count == 1)
        #expect(conversations[0].memberSegmentIds.count == 2)

        let deleted = await fixture.cascade.deleteConversation(conversationId)

        #expect(Set(deleted) == Set([first, second]))
        #expect(await fixture.store.listSegments().isEmpty)
    }

    @Test func reprocessSegmentRequeuesUnderTheCurrentMode() async throws {
        let fixture = try RuntimeFixture()
        let segmentId = try await Fixture.writeSegment(into: fixture.store)
        try await fixture.transcription.enqueueClosedSegments()
        _ = try fixture.queue.markRunning(segmentId)
        _ = try fixture.queue.markFailed(segmentId, error: "nope", retryable: false)
        #expect(try fixture.queue.load(segmentId)?.state == .failed)

        await fixture.runtime.reprocessSegment(segmentId)

        #expect(try fixture.queue.load(segmentId)?.state == .pending)
        #expect(try fixture.queue.load(segmentId)?.attempts == 0)
        #expect(await fixture.store.readMeta(segmentId)?.transcriptionState == .pending)
    }

    @Test func reprocessIsANoOpForTheOpenSegment() async throws {
        let fixture = try RuntimeFixture()
        _ = try await Fixture.writeSegment(into: fixture.store, close: false)
        let openId = try #require(await fixture.store.openSegmentId)

        await fixture.runtime.reprocessSegment(openId)

        #expect(try fixture.queue.load(openId) == nil)
    }

    // MARK: - The 5 s undo window

    @Test func aStagedDeleteHidesTheConversationWithoutDestroyingAnything() async throws {
        let fixture = try RuntimeFixture()
        let segmentId = try await Fixture.writeSegment(into: fixture.store)
        let conversationId = try #require(try await fixture.enrichment.regroup().first?.id)

        let token = await fixture.runtime.deleteConversation(id: conversationId)

        #expect(token.conversationId == conversationId)
        #expect(await fixture.deferredDeletes.hiddenConversationIds == [conversationId])
        // Nothing is gone yet — a process death inside the window loses the delete, not the audio.
        #expect(await fixture.store.readMeta(segmentId) != nil)
    }

    @Test func undoRestoresTheConversationAndCommitDestroysIt() async throws {
        let fixture = try RuntimeFixture()
        let segmentId = try await Fixture.writeSegment(into: fixture.store)
        let conversationId = try #require(try await fixture.enrichment.regroup().first?.id)

        let undone = await fixture.runtime.deleteConversation(id: conversationId)
        #expect(await fixture.runtime.restoreDelete(undone))
        #expect(await fixture.deferredDeletes.hiddenConversationIds.isEmpty)
        #expect(await fixture.store.readMeta(segmentId) != nil)
        // A restored token cannot be committed afterwards.
        #expect(await fixture.runtime.commitDelete(undone).isEmpty)

        let committed = await fixture.runtime.deleteConversation(id: conversationId)
        let deleted = await fixture.runtime.commitDelete(committed)
        #expect(deleted == [segmentId])
        #expect(await fixture.store.readMeta(segmentId) == nil)
    }

    @Test func backgroundEntryCommitsAnythingStillStaged() async throws {
        let fixture = try RuntimeFixture()
        let segmentId = try await Fixture.writeSegment(into: fixture.store)
        let conversationId = try #require(try await fixture.enrichment.regroup().first?.id)
        _ = await fixture.runtime.deleteConversation(id: conversationId)

        await fixture.runtime.setForeground(false)

        #expect(await fixture.store.readMeta(segmentId) == nil)
        #expect(await fixture.deferredDeletes.hiddenConversationIds.isEmpty)
    }

    @Test func theLibraryHidesConversationsInsideTheUndoWindow() async throws {
        let fixture = try RuntimeFixture()
        _ = try await Fixture.writeSegment(into: fixture.store)
        let conversationId = try #require(try await fixture.enrichment.regroup().first?.id)
        #expect(try await fixture.runtime.library.library().count == 1)

        _ = await fixture.runtime.deleteConversation(id: conversationId)

        #expect(try await fixture.runtime.library.library().isEmpty)
    }

    /// "Delete All Recordings" has to include the one still being recorded. The cascade refuses
    /// an open segment by design, so a caller that merely looped over `listSegments()` left the
    /// in-progress recording behind and it reappeared in the Library the moment it closed —
    /// after a confirmed, destructive, irreversible action said everything was gone.
    @Test func deleteAllRecordingsIncludesTheOpenSegment() async throws {
        let fixture = try RuntimeFixture()
        let closed = try await Fixture.writeSegment(into: fixture.store)
        _ = try await Fixture.writeSegment(
            into: fixture.store, streamId: 0x5EED_0002,
            startTimeMs: 1_756_512_600_000, receivedAtMs: 1_756_512_600_000, close: false)
        let openId = try #require(await fixture.store.openSegmentId)
        _ = try fixture.transcriptStore.save(
            closed,
            result: RoutedTranscription(
                text: "hello there", modeUsed: .localOnly, providerId: "fake", modelUsed: nil
            )
        )

        let deleted = await fixture.runtime.deleteAllRecordings()

        #expect(deleted == 2)
        #expect(await fixture.store.readMeta(closed) == nil)
        #expect(await fixture.store.readMeta(openId) == nil)
        #expect(await fixture.store.listSegments().isEmpty)
        // And nothing derived survives it either — including the queue rows and transcript
        // files the bulk sweep exists to catch.
        #expect(fixture.transcriptStore.load(closed) == nil)
        #expect(try fixture.queue.all().isEmpty)
    }
}
