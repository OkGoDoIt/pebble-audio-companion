import AppDB
import Foundation
import GRDB
import SegmentStore
import Testing
import Transcription

@testable import Intelligence

// Follow-up extraction over conversations that are PIECES of segments, and across the re-cut
// that made them so.
//
//  - A conversation reads the turns of its own pieces. Two conversations that share a segment
//    must not both be shown the same commitment, or it is proposed twice.
//  - Extraction bookkeeping is keyed by conversation id, and the re-cut gave nearly every
//    stretch of the library a new one. Without `follow_up_covered_segments` the worker would
//    read the whole library again and propose, under new ids, everything a person already has.

private final class RecordingProvider: AiProvider, @unchecked Sendable {
    let id = "recording"
    private let lock = NSLock()
    private var _requests: [AiRunRequest] = []
    private let response: String

    init(response: String) { self.response = response }

    var requests: [AiRunRequest] { lock.withLock { _requests } }
    var runCount: Int { lock.withLock { _requests.count } }

    func isAvailable() async -> Bool { true }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        lock.withLock { _requests.append(request) }
        return AiProviderResult(text: response, modelUsed: "recording-model")
    }

    /// What one conversation's (first, single-piece) extraction call was shown. Matched whole:
    /// `conv-seg-a` is a prefix of `conv-seg-a-m600000`.
    func body(for conversationId: String) -> String {
        requests.filter { $0.requestId == "followups-\(conversationId)-1" }
            .flatMap { $0.transcripts.map(\.text) }.joined(separator: "\n")
    }
}

private let recordedAtMs: Int64 = 1_788_193_700_000

private func segment(
    _ id: String, startMs: Int64 = recordedAtMs, open: Bool = false,
    state: TranscriptionState = .complete
) -> SegmentMeta {
    SegmentMeta(
        segmentId: id, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
        frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
        startTimeMs: UInt64(startMs), startMonotonicMs: 1, receivedAtMs: startMs,
        firstSampleIndex: 0, lastSampleIndexExclusive: 900 * 16_000, frameCount: 900 * 50,
        closeReason: open ? nil : .rotated, transcriptionState: state)
}

private func turn(_ text: String, at seconds: Int64, speaker: String = "1") -> TranscriptSegment {
    TranscriptSegment(
        text: text, startMs: seconds * 1_000, endMs: seconds * 1_000 + 4_000, speaker: speaker)
}

/// Filler so each half clears `FollowUpWorker.minChars` on its own.
private func padding(_ subject: String, from seconds: Int64) -> [TranscriptSegment] {
    (0..<5).map {
        turn("We went over the \(subject) again and what is left to do about it.",
            at: seconds + Int64($0) * 10)
    }
}

/// One segment, two conversations: the airport run in its first ten minutes, the checkout in
/// what follows.
private let turns: [TranscriptSegment] =
    padding("airport run", from: 10) + [turn("I got to take Theo at 7:00.", at: 80)]
    + padding("van", from: 610) + [turn("We have to return the van by 11:00.", at: 680)]

private func transcript(_ id: String) -> SegmentTranscript {
    SegmentTranscript(
        segmentId: id, text: turns.map(\.text).joined(separator: " "), modeUsed: .localOnly,
        providerId: "local", createdAtMs: 0, segments: turns)
}

private func piece(_ id: String, from: Int64? = nil, to: Int64? = nil) -> ConversationMember {
    ConversationMember(segmentId: id, startMediaMs: from, endMediaMs: to)
}

private let airport = EnrichmentConversation(
    conversationId: "conv-seg-a", isOpen: false, members: [segment("seg-a")],
    pieces: [piece("seg-a", to: 600_000)])
private let checkout = EnrichmentConversation(
    conversationId: "conv-seg-a-m600000", isOpen: false, members: [segment("seg-a")],
    pieces: [piece("seg-a", from: 600_000)])

/// Both commitments, whoever is asked — the model is not the thing under test.
private let bothItems = """
    {"items": [
      {"task": "Take Theo to the airport at 7:00", "quote": "I got to take Theo at 7:00.",
       "ifForgotten": "Theo misses his ride", "dueDate": "", "confidence": "high"},
      {"task": "Return the van to the depot by 11:00",
       "quote": "We have to return the van by 11:00.",
       "ifForgotten": "the van goes back late", "dueDate": "", "confidence": "medium"}
    ]}
    """

@Suite("follow-up extraction reads pieces, and does not re-read a re-cut library")
struct FollowUpConversationPiecesTests {
    private let clock = TestWallClock(ms: recordedAtMs + 3_600_000)
    private let db: AppDatabase
    private let candidates: FollowUpCandidateStore
    private let state: FollowUpExtractionStore

    init() throws {
        let db = try AppDatabase.inMemory()
        self.db = db
        candidates = FollowUpCandidateStore(db: db)
        state = try FollowUpExtractionStore(db: db)
    }

    private func worker(
        _ provider: RecordingProvider,
        transcriptVersionOf: @escaping @Sendable (String) -> String? = { _ in nil }
    ) -> FollowUpWorker {
        let clock = self.clock
        return FollowUpWorker(
            candidates: candidates, state: state,
            router: AiModeRouter(local: provider, remote: nil, mode: { .localOnly }),
            nowMs: { clock.now }, timeZone: { TimeZone(identifier: "America/New_York")! },
            transcriptVersionOf: transcriptVersionOf)
    }

    private func cover(_ segmentIds: String...) throws {
        try db.writer.write { db in
            for id in segmentIds {
                try db.execute(
                    sql: "INSERT INTO follow_up_covered_segments (segmentId) VALUES (?)",
                    arguments: [id])
            }
        }
    }

    // MARK: Pieces

    @Test("two conversations sharing a segment are each read, and credited, for their own turns")
    func sharedSegmentIsNotSharedText() async throws {
        let provider = RecordingProvider(response: bothItems)
        let written = try await worker(provider).extract(
            [airport, checkout], transcriptOf: { transcript($0) })

        #expect(provider.runCount == 2)
        let airportBody = provider.body(for: "conv-seg-a")
        #expect(airportBody.contains("take Theo at 7:00") && !airportBody.contains("return the"))
        let checkoutBody = provider.body(for: "conv-seg-a-m600000")
        #expect(checkoutBody.contains("return the van by 11:00"))
        #expect(!checkoutBody.contains("take Theo"))

        // The model claimed both items both times. Each lands once, in the conversation whose
        // piece holds its words — the grounding check is what stops the other copy.
        #expect(written == 2)
        let first = try await candidates.list(conversationId: "conv-seg-a")
        #expect(first.map(\.task) == ["Take Theo to the airport at 7:00"])
        let second = try await candidates.list(conversationId: "conv-seg-a-m600000")
        #expect(second.map(\.task) == ["Return the van to the depot by 11:00"])
        // Offsets stay in the segment's own media clock.
        #expect(first.first?.segmentId == "seg-a" && first.first?.startMs == 80_000)
        #expect(second.first?.segmentId == "seg-a" && second.first?.startMs == 680_000)
    }

    @Test("a piece is dated from its first turn, not from its segment's start")
    func aPieceStartsWhereItsTalkDoes() async throws {
        let provider = RecordingProvider(response: bothItems)
        _ = try await worker(provider).extract([checkout], transcriptOf: { transcript($0) })
        let row = try #require(
            try await candidates.list(conversationId: "conv-seg-a-m600000").first)
        // 10:10 into the segment — the first turn at or after the cut.
        #expect(row.recordedAtMs == recordedAtMs + 610_000)
    }

    @Test("a cut that moves is a different question, though no file changed")
    func aRangeOnlyChangeIsReadAgain() async throws {
        let provider = RecordingProvider(response: #"{"items":[]}"#)
        let worker = worker(provider, transcriptVersionOf: { _ in "v1" })
        func conversation(to end: Int64?) -> EnrichmentConversation {
            EnrichmentConversation(
                conversationId: "conv-seg-a", isOpen: false, members: [segment("seg-a")],
                pieces: [piece("seg-a", to: end)])
        }
        _ = try await worker.extract([conversation(to: 600_000)], transcriptOf: { transcript($0) })
        _ = try await worker.extract([conversation(to: 600_000)], transcriptOf: { transcript($0) })
        #expect(provider.runCount == 1)

        // The conversation now runs to the end of the segment: it holds the checkout too.
        _ = try await worker.extract([conversation(to: nil)], transcriptOf: { transcript($0) })
        #expect(provider.runCount == 2)
        #expect(provider.requests.last?.transcripts.first?.text.contains("return the van") == true)
    }

    // MARK: Covered segments

    @Test("a conversation made only of segments read before the re-cut is settled without a call")
    func coveredConversationsAreNotReRead() async throws {
        try cover("seg-a", "seg-b")
        let provider = RecordingProvider(response: bothItems)
        let worker = worker(provider)
        let recut = [
            airport, checkout,
            EnrichmentConversation(
                conversationId: "conv-seg-b", isOpen: false, members: [segment("seg-b")]),
        ]
        let loads = Loads()

        let written = try await worker.extract(
            recut,
            transcriptOf: {
                loads.increment()
                return transcript($0)
            })
        #expect(written == 0)
        #expect(provider.runCount == 0)
        // Not even a transcript is opened for them.
        #expect(loads.value == 0)
        for conversation in recut {
            let row = try #require(try await state.load(conversation.conversationId))
            #expect(row.settled && row.itemCount == 0)
        }
        #expect(try await candidates.pendingCount() == 0)

        // And it stays that way, without a write a pass.
        let before = try await state.load("conv-seg-a")
        clock.advance(byMs: 60_000)
        _ = try await worker.extract(recut, transcriptOf: { transcript($0) })
        #expect(try await state.load("conv-seg-a") == before)
        #expect(provider.runCount == 0)
    }

    @Test("audio recorded since is still read — alone, or in a conversation with covered audio")
    func newAudioIsStillExtracted() async throws {
        try cover("seg-a")
        let provider = RecordingProvider(response: bothItems)
        let worker = worker(provider)
        let fresh = EnrichmentConversation(
            conversationId: "conv-seg-new", isOpen: false, members: [segment("seg-new")],
            pieces: [piece("seg-new", to: 600_000)])
        // Starts in covered audio and runs on into a segment recorded after the upgrade.
        let straddling = EnrichmentConversation(
            conversationId: "conv-seg-a-m600000", isOpen: false,
            members: [segment("seg-a"), segment("seg-next", startMs: recordedAtMs + 900_000)],
            pieces: [piece("seg-a", from: 600_000), piece("seg-next", to: 600_000)])

        _ = try await worker.extract(
            [airport, fresh, straddling], transcriptOf: { transcript($0) })
        #expect(provider.runCount == 2)
        #expect(provider.body(for: "conv-seg-a").isEmpty)
        #expect(!provider.body(for: "conv-seg-new").isEmpty)
        #expect(!provider.body(for: "conv-seg-a-m600000").isEmpty)
        #expect(try await candidates.list(conversationId: "conv-seg-new").count == 1)
    }

    @Test("a conversation that is still open is left to the ordinary gate")
    func anOpenConversationIsNotSettledByCoverage() async throws {
        try cover("seg-a")
        let live = EnrichmentConversation(
            conversationId: "conv-seg-a", isOpen: true, members: [segment("seg-a")])
        #expect(!FollowUpWorker.isCovered(live, by: ["seg-a"]))
        let provider = RecordingProvider(response: bothItems)
        _ = try await worker(provider).extract([live], transcriptOf: { transcript($0) })
        #expect(provider.runCount == 0)
        #expect(try await state.load("conv-seg-a") == nil)
    }

    // MARK: The migration that fills the table

    @Test("the upgrade writes down every segment of a conversation whose extraction had settled")
    func migrationCoversSettledSegments() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("covered-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        // A database as the previous release left it: whole-segment conversations, extraction
        // bookkeeping under their ids, and none of what `annotation-source-key-v1` adds. Built
        // by opening a current one and taking the migration back out, so every earlier
        // migration's schema is the real one.
        let old = try AppDatabase.open(at: url)
        _ = try FollowUpExtractionStore(db: old)
        try await old.writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM grdb_migrations WHERE identifier = 'annotation-source-key-v1';
                    DROP TABLE follow_up_covered_segments;
                    ALTER TABLE annotations DROP COLUMN sourceKey;
                    ALTER TABLE annotations DROP COLUMN titleEditedAtMs;
                    """)
            for (id, state) in [("conv-seg-1", "closed"), ("conv-seg-3", "closed"),
                ("conv-seg-4", "live")]
            {
                try db.execute(
                    sql: """
                        INSERT INTO conversations (id, startMs, endMs, timezone, state)
                        VALUES (?, 0, 1, 'UTC', ?)
                        """,
                    arguments: [id, state])
            }
            for (conversation, segment, ordinal) in [
                ("conv-seg-1", "seg-1", 0), ("conv-seg-1", "seg-2", 1),
                ("conv-seg-3", "seg-3", 0), ("conv-seg-4", "seg-4", 0),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO conversation_segments (conversationId, segmentId, ordinal)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [conversation, segment, ordinal])
            }
            try db.execute(
                sql: """
                    INSERT INTO follow_up_extractions (conversationId, settled, itemCount)
                    VALUES ('conv-seg-1', 1, 2), ('conv-seg-3', 0, 0), ('conv-gone', 1, 1);
                    INSERT INTO annotations (conversationId, title, isFinal)
                    VALUES ('conv-seg-1', 'A long day', 1);
                    """)
        }
        try old.writer.close()

        let upgraded = try AppDatabase.open(at: url)
        let store = try FollowUpExtractionStore(db: upgraded)
        // Both segments of the settled conversation; not the one that failed, not the one that
        // was never looked at.
        #expect(try await store.coveredSegments() == ["seg-1", "seg-2"])
        // The title that was there is kept, and reads as written from nothing: due once.
        let annotation = try #require(
            try await AnnotationStore(db: upgraded).load("conv-seg-1"))
        #expect(annotation.title == "A long day" && annotation.isFinal)
        #expect(annotation.sourceKey == nil && annotation.titleEditedAtMs == nil)
    }

    @Test("a database that has never extracted anything upgrades with nothing covered")
    func migrationWithoutAnExtractionTable() async throws {
        // `follow_up_extractions` is created by its store, not by a migration.
        let fresh = try AppDatabase.inMemory()
        let covered = try await fresh.reader.read { db in
            try String.fetchAll(db, sql: "SELECT segmentId FROM follow_up_covered_segments")
        }
        #expect(covered.isEmpty)
    }
}

private final class Loads: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}
