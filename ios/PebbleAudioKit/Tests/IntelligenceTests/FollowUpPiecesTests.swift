import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

@testable import Intelligence

// A conversation longer than one extraction call used to be cut to its LAST 120,000 characters
// and then settled as read — the first hours of a long conversation were never looked at for
// follow-ups by anything, ever. It is read in pieces now, and settles only when all of them have
// been read.

private final class PieceProvider: AiProvider, AiInputWindowReporting, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var _bodies: [String] = []
    private var failOn: Int?
    private let window: Int?

    init(_ id: String, failOnCall: Int? = nil, contextTokens: Int? = nil) {
        self.id = id
        self.failOn = failOnCall
        self.window = contextTokens
    }

    var bodies: [String] { lock.withLock { _bodies } }
    func stopFailing() { lock.withLock { failOn = nil } }

    func isAvailable() async -> Bool { true }
    func inputChars() async -> Int? { nil }
    func contextTokens() async -> Int? { window }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        let body = request.transcripts.first?.text ?? ""
        let fail: Bool = lock.withLock {
            _bodies.append(body)
            return failOn == _bodies.count
        }
        if fail { throw AiError.providerFailed("OpenAI responses request failed (503): busy") }
        // One item per piece, quoting the piece's own marker sentence when it has one.
        let quote =
            ["I will send Dana the lease by Friday.", "I have to book the vet for Rex."]
            .first { body.contains($0) }
        guard let quote else { return AiProviderResult(text: #"{"items":[]}"#, modelUsed: id) }
        return AiProviderResult(
            text: """
                {"items":[{"task":"\(quote.hasPrefix("I will") ? "Send Dana the lease" : "Book the vet for Rex")",
                "quote":"\(quote)","ifForgotten":"it does not happen","dueDate":"",
                "confidence":"high"}]}
                """,
            modelUsed: id)
    }
}

private func part(_ id: String, at ms: Int64, text: String) -> FollowUpSourcePart {
    FollowUpSourcePart(segmentId: id, startedAtMs: ms, text: text)
}

private func filler(_ count: Int, _ tag: String) -> String {
    (0..<count).map { "\(tag) talked about the plan number \($0)." }.joined(separator: " ")
}

@Suite("Follow-ups — a long conversation is read in pieces, every one of them")
struct FollowUpPiecesTests {
    private let zone = TimeZone(identifier: "UTC")!
    private let start: Int64 = 1_788_193_700_000

    @Test func aConversationThatFitsIsOnePieceExactlyAsBefore() {
        let parts = [part("seg-1", at: start, text: "Short talk.")]
        let pieces = FollowUpTranscriptRenderer.renderChunks(
            parts: parts, title: "Lunch", summary: nil,
            recordedAt: Date(timeIntervalSince1970: Double(start) / 1000), timeZone: zone,
            maxChars: 10_000)
        #expect(
            pieces
                == [
                    FollowUpTranscriptRenderer.render(
                        parts: parts, title: "Lunch", summary: nil,
                        recordedAt: Date(timeIntervalSince1970: Double(start) / 1000),
                        timeZone: zone, maxChars: 10_000)
                ])
    }

    @Test func aLongConversationIsCutIntoPiecesThatEachFitAndTogetherHoldEverything() {
        let parts = (0..<6).map { index in
            part("seg-\(index)", at: start + Int64(index) * 900_000, text: filler(400, "S\(index)"))
        }
        let pieces = FollowUpTranscriptRenderer.renderChunks(
            parts: parts, title: "Long day", summary: "A long one.",
            recordedAt: Date(timeIntervalSince1970: Double(start) / 1000), timeZone: zone,
            maxChars: 30_000)
        #expect(pieces.count > 1)
        for (index, piece) in pieces.enumerated() {
            #expect(piece.count <= 30_000)
            #expect(piece.hasPrefix("Recorded: "))
            #expect(piece.contains("Conversation: Long day"))
            #expect(piece.contains("Part \(index + 1) of \(pieces.count) of this conversation"))
        }
        // Every sentence of every recording is in exactly one piece, in order.
        let joined = pieces.joined(separator: "\n")
        for index in 0..<6 {
            #expect(joined.contains("S\(index) talked about the plan number 0."))
            #expect(joined.contains("S\(index) talked about the plan number 399."))
        }
        #expect(
            joined.range(of: "S0 talked about the plan number 0.")!.lowerBound
                < joined.range(of: "S5 talked about the plan number 399.")!.lowerBound)
    }

    @Test func aSingleRecordingLongerThanAPieceIsSplitToo() {
        let parts = [part("seg-1", at: start, text: filler(3_000, "Solo"))]
        let pieces = FollowUpTranscriptRenderer.renderChunks(
            parts: parts, title: nil, summary: nil,
            recordedAt: Date(timeIntervalSince1970: Double(start) / 1000), timeZone: zone,
            maxChars: 20_000)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= 20_000 })
        #expect(pieces.joined().contains("Solo talked about the plan number 2999."))
    }

    // MARK: The worker

    private func worker(_ provider: PieceProvider, mode: AiProcessingMode = .localOnly) throws
        -> (FollowUpWorker, FollowUpExtractionStore, FollowUpCandidateStore, TestWallClock)
    {
        let db = try AppDatabase.inMemory()
        let candidates = FollowUpCandidateStore(db: db)
        let state = try FollowUpExtractionStore(db: db)
        let clock = TestWallClock(ms: start + 3_600_000)
        let router =
            mode == .localOnly
            ? AiModeRouter(local: provider, remote: nil, mode: { mode })
            : AiModeRouter(local: nil, remote: provider, mode: { mode })
        let worker = FollowUpWorker(
            candidates: candidates, state: state, router: router, nowMs: { clock.now },
            timeZone: { TimeZone(identifier: "UTC")! })
        return (worker, state, candidates, clock)
    }

    private func meta(_ id: String, at ms: Int64) -> SegmentMeta {
        SegmentMeta(
            segmentId: id, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
            startTimeMs: UInt64(ms), startMonotonicMs: 1, receivedAtMs: ms,
            closeReason: .rotated, transcriptionState: .complete)
    }

    /// A four-hour conversation: the commitment in the FIRST hour, which the old cut dropped.
    private var longConversation: (EnrichmentConversation, [String: String]) {
        let texts: [String: String] = [
            "seg-1": filler(2_000, "Early") + " I will send Dana the lease by Friday. "
                + filler(500, "Early"),
            "seg-2": filler(3_000, "Middle"),
            "seg-3": filler(3_000, "Late") + " I have to book the vet for Rex.",
        ]
        let conversation = EnrichmentConversation(
            conversationId: "conv-long", isOpen: false,
            members: [
                meta("seg-1", at: start), meta("seg-2", at: start + 3_600_000),
                meta("seg-3", at: start + 7_200_000),
            ])
        return (conversation, texts)
    }

    @Test func everyPieceIsReadAndTheFirstHoursCommitmentIsFound() async throws {
        let provider = PieceProvider("cloud")
        let (worker, state, candidates, _) = try worker(provider)
        let (conversation, texts) = longConversation
        #expect(texts.values.map(\.count).reduce(0, +) > FollowUpWorker.maxTranscriptChars)

        _ = try await worker.extract(
            [conversation],
            transcriptOf: { id in
                texts[id].map {
                    SegmentTranscript(
                        segmentId: id, text: $0, modeUsed: .localOnly, providerId: "t",
                        createdAtMs: 0)
                }
            })

        #expect(provider.bodies.count > 1)
        #expect(provider.bodies.allSatisfy { $0.count <= FollowUpWorker.maxTranscriptChars })
        let tasks = try await candidates.list(conversationId: "conv-long").map(\.task)
        #expect(tasks.contains("Send Dana the lease"), "the first hour was read")
        #expect(tasks.contains("Book the vet for Rex"))
        #expect(try await state.load("conv-long")?.settled == true)
    }

    /// A piece that fails leaves the conversation UNSETTLED — the pieces before it are not a
    /// reading of the whole — and the retry duplicates nothing.
    @Test func aConversationSettlesOnlyWhenEveryPieceWasRead() async throws {
        let provider = PieceProvider("cloud", failOnCall: 2)
        let (worker, state, candidates, clock) = try worker(provider)
        let (conversation, texts) = longConversation
        let transcriptOf: (String) -> SegmentTranscript? = { id in
            texts[id].map {
                SegmentTranscript(
                    segmentId: id, text: $0, modeUsed: .localOnly, providerId: "t", createdAtMs: 0)
            }
        }

        _ = try await worker.extract([conversation], transcriptOf: transcriptOf)
        #expect(try await state.load("conv-long")?.settled == false)

        provider.stopFailing()
        clock.advance(byMs: AiRetryPolicy.maxRetryMs)
        _ = try await worker.extract([conversation], transcriptOf: transcriptOf)
        #expect(try await state.load("conv-long")?.settled == true)
        let tasks = try await candidates.list(conversationId: "conv-long").map(\.task)
        #expect(tasks.filter { $0 == "Send Dana the lease" }.count == 1)
    }

    /// Apple Private Cloud Compute reports a 32K-token window; a piece sized for OpenAI would be
    /// cut by it. Pieces are sized for the provider that runs first.
    @Test func piecesAreSizedForTheRemoteWindowWhenItReportsOne() async throws {
        let provider = PieceProvider("apple-pcc", contextTokens: 32_768)
        let (worker, _, _, _) = try worker(provider, mode: .remoteOnly)
        let (conversation, texts) = longConversation
        _ = try await worker.extract(
            [conversation],
            transcriptOf: { id in
                texts[id].map {
                    SegmentTranscript(
                        segmentId: id, text: $0, modeUsed: .localOnly, providerId: "t",
                        createdAtMs: 0)
                }
            })
        let window = AskBudget.forContext(tokens: 32_768).transcriptChars
        #expect(provider.bodies.count > 2)
        #expect(provider.bodies.allSatisfy { $0.count <= window })
    }
}
