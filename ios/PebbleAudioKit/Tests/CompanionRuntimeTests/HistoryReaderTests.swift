import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

@testable import CompanionRuntime

@Suite struct HistoryReaderTests {
    // B20: the queue's stored error is developer prose with the provider's response body in it —
    // sometimes the request URL, sometimes the key. History carries only the classified kind.
    @Test("a failed recording's reason is its classified kind, never the stored text")
    func reasonIsAKind() {
        let stored = "Soniox transcription error: Organization balance exhausted. Please either add funds manually or enable autopay. key=sk-live-abc123"
        let reason = HistoryReader.failureKind(stored)
        #expect(reason == TranscriptionFailureKind.classify(stored).rawValue)
        #expect(reason.map { TranscriptionFailureKind(rawValue: $0) != nil } == true)
        #expect(reason?.contains("sk-live") != true)
        #expect(HistoryReader.failureKind("something nobody can name") == nil)
        #expect(HistoryReader.failureKind(nil) == nil)
    }

    @Test("snippets never quote a turn said inside a no-conversation stretch")
    func previewsSkipNoConversation() {
        let turns = [
            HistorySpokenTurn(segmentId: "s", startMs: 100, endMs: 200, text: "We should call the landlord today."),
            HistorySpokenTurn(segmentId: "s", startMs: 1_100, endMs: 1_200, text: "Lyrics from the radio, over and over."),
            HistorySpokenTurn(segmentId: "s", startMs: 3_000, endMs: 3_100, text: "Back to the flat."),
        ]
        let content = [
            AudioContentSpan(startMs: 1_000, endMs: 2_000, kind: .noConversation, confidence: 0.9, decidedBy: "wordRate", version: 1),
            AudioContentSpan(startMs: 2_000, endMs: 4_000, kind: .conversation, confidence: 0.9, decidedBy: "wordRate", version: 1),
        ]
        let previews = HistoryReader.turnPreviews(turns, content: content)
        #expect(previews.map(\.startMs) == [100, 3_000])
    }

    @Test("a turn that is one word over and over is never a snippet")
    func degenerateTurns() {
        #expect(HistorySpokenTurn.isDegenerate(", the, the, the, the, the, the, the, the, the,"))
        #expect(HistorySpokenTurn.isDegenerate("yeah yeah yeah yeah yeah yeah"))
        #expect(HistorySpokenTurn.isDegenerate("the, the, the, the, the, uh, you kn"))
        #expect(HistorySpokenTurn.isDegenerate("저는안녕하세요. 저는안녕하세요. 저는안녕하세요. 저는안녕하세요. 저는안녕하세요."))
        #expect(HistorySpokenTurn.isDegenerate("in an apartment in Boston. I'll double I'll double I'll double I'll double I'll double"))
        #expect(HistorySpokenTurn.isDegenerate("안녕하세요. 저는안녕하세요. 저는안녕하세요. 저"))
        #expect(!HistorySpokenTurn.isDegenerate("Hôm nay trời đẹp nên chúng ta đi dạo công viên nhé."))
        #expect(!HistorySpokenTurn.isDegenerate("この件については明日また話しましょう"))
        #expect(!HistorySpokenTurn.isDegenerate("I think the thing is the thing we said"))
        #expect(!HistorySpokenTurn.isDegenerate("We should call the landlord today and ask about the deposit."))
        #expect(!HistorySpokenTurn.isDegenerate("Yeah, yeah, yeah."))
        #expect(!HistorySpokenTurn.isDegenerate("Yeah, sure, we can do that."))
        #expect(!HistorySpokenTurn.isDegenerate("I'm going to walk you through that checklist again."))
    }

    @Test("each conversation with speech is a card with its title, summary and tags")
    func conversationsAsCards() {
        // Conversations are topic-sized, so History reads them as its cards.
        #expect(ConversationUnits.isTopicSized)
        let rows = [
            ConversationListRow(
                id: "b", title: "Rent negotiation", summary: "Lower rent for a longer lease.", startMs: 5_000,
                endMs: 9_000, tags: ["apartment"]),
            ConversationListRow(id: "a", title: nil, summary: nil, startMs: 1_000, endMs: 4_000),
            ConversationListRow(id: "hidden", title: "Deleted", startMs: 9_000, endMs: 9_500),
            ConversationListRow(id: "empty", title: "No audio", startMs: 9_600, endMs: 9_600),
            // A long silence is a unit of its own with nothing said in it, and audio whose
            // transcripts have not arrived holds no speech yet: neither is a card — the builder
            // draws that time from coverage (quiet, no conversation, not transcribed yet).
            ConversationListRow(id: "silence", title: nil, startMs: 10_000, endMs: 40_000, hasSpeech: false),
            ConversationListRow(
                id: "waiting", title: nil, startMs: 40_000, endMs: 90_000, lifecycle: .capturedWaiting,
                hasSpeech: false),
        ]
        let chapters = HistoryReader.chapters(from: rows, hiding: ["hidden"])
        #expect(chapters == [
            HistoryChapterInput(id: "a", startMs: 1_000, endMs: 4_000, title: nil),
            HistoryChapterInput(
                id: "b", startMs: 5_000, endMs: 9_000, title: "Rent negotiation",
                summary: "Lower rent for a longer lease.", tags: ["apartment"], people: [], timesApproximate: false),
        ])
    }

    @Test("waiting time is stored audio, in proportion to the part of the recording inside the day")
    func waitingIsMedia() {
        var meta = SegmentMeta(
            segmentId: "s", streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1, frameSamples: 320,
            sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20, startTimeMs: 0, startMonotonicMs: 0,
            receivedAtMs: 0, transcriptionState: .pending)
        // 15 minutes on the wall, 1 minute of frames (the 2026-09-24 shape).
        meta.frameCount = 3_000
        let extent: Range<Int64> = 0..<900_000
        #expect(HistoryReader.mediaMs(meta, inside: 900_000, of: extent) == 60_000)
        #expect(HistoryReader.mediaMs(meta, inside: 450_000, of: extent) == 30_000)
        #expect(HistoryReader.mediaMs(meta, inside: 0, of: extent) == 0)
    }
}
