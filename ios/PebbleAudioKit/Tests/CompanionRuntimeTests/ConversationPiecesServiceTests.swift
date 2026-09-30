import AppDB
import Foundation
import Intelligence
import SearchKit
import SegmentStore
import Testing
import Transcription

@testable import CompanionRuntime

// `EnrichmentService` end to end over conversations that are PIECES of a segment: the real
// store, the real grouper, a person's split in the middle of one recording. What each
// conversation is titled from, what makes it "no conversation", what search finds it by, and
// what happens to everything attached to it when the split is taken back.

@Suite("enrichment service — conversations are pieces of segments")
struct ConversationPiecesServiceTests {
    final class RecordingProvider: AiProvider, @unchecked Sendable {
        let id = "recording"
        private let lock = NSLock()
        private var _requests: [AiRunRequest] = []
        var requests: [AiRunRequest] { lock.withLock { _requests } }
        var runs: Int { lock.withLock { _requests.count } }

        func isAvailable() async -> Bool { true }
        func run(_ request: AiRunRequest) async throws -> AiProviderResult {
            let count = lock.withLock {
                _requests.append(request)
                return _requests.count
            }
            return AiProviderResult(
                text: "TITLE: Title \(count)\nSUMMARY: Summary \(count).\nTAGS: tag\(count)")
        }

        /// The words the latest request about one conversation carried.
        func text(for conversationId: String) -> String {
            requests.last { $0.requestId.hasPrefix("annotate-\(conversationId)-final-") }?
                .transcripts.map(\.text).joined(separator: "\n") ?? ""
        }
    }

    /// One minute of recording: the fence at 0:05, the match at 0:40.
    private static let turns: [Transcription.TranscriptSegment] = [
        Transcription.TranscriptSegment(
            text: "We should repaint the fence this weekend and I will buy the primer tomorrow.",
            startMs: 5_000, endMs: 9_000, speaker: "1"),
        Transcription.TranscriptSegment(
            text: "Did you see the match last night, the keeper saved two penalties.",
            startMs: 40_000, endMs: 45_000, speaker: "2"),
    ]

    private struct Harness {
        let fixture: RuntimeFixture
        let segmentId: String
        let provider: RecordingProvider
        let mask: AudioContentMask
        let index: TranscriptIndex
        let spotlight: RecordingSpotlight
        let enrichment: EnrichmentService
        let cuts: ConversationCutStore

        var first: String { "conv-\(segmentId)" }
        var second: String { "conv-\(segmentId)-m30000" }
        var cut: ConversationCut { ConversationCut(segmentId: segmentId, mediaMs: 30_000) }

        func found(_ query: String) throws -> [String] {
            try index.search(query, limit: 20).filter { $0.kind == .conversation }.map(\.id)
        }
    }

    /// A closed, transcribed minute of audio in a real store, and a service over it wired to a
    /// recording provider, the FTS index and a recording Spotlight.
    private func harness(withMask: Bool = true) async throws -> Harness {
        let fixture = try RuntimeFixture()
        let segmentId = try await Fixture.writeSegment(into: fixture.store, frames: 3_000)
        try await fixture.store.updateTranscriptionState(segmentId, .complete)
        let transcript = SegmentTranscript(
            segmentId: segmentId, text: Self.turns.map(\.text).joined(separator: " "),
            modeUsed: .localOnly, providerId: "fake", createdAtMs: 1, segments: Self.turns)
        let provider = RecordingProvider()
        let mask = AudioContentMask()
        let index = TranscriptIndex(database: fixture.database)
        let spotlight = RecordingSpotlight()
        let clock = fixture.clock
        let enrichment = EnrichmentService(
            worker: EnrichmentWorker(
                annotations: fixture.annotations,
                router: AiModeRouter(local: provider, remote: nil, mode: { .localOnly }),
                nowMs: { clock.nowMs }),
            followUps: FollowUpWorker(
                candidates: FollowUpCandidateStore(db: fixture.database),
                state: try FollowUpExtractionStore(db: fixture.database),
                router: nil, nowMs: { clock.nowMs }),
            curator: FollowUpCurator(
                candidates: FollowUpCandidateStore(db: fixture.database),
                followUps: fixture.followUps, router: nil, nowMs: { clock.nowMs }),
            annotations: fixture.annotations,
            store: fixture.store,
            database: fixture.database,
            pauseJournal: fixture.pauseJournal,
            transcriptOf: { _ in transcript },
            liveTextOf: { _ in nil },
            donator: SpotlightDonator(index: index, spotlight: spotlight),
            clock: clock,
            audioContentMask: withMask ? mask : nil,
            audioContentStore: AudioContentStore(db: fixture.database))
        return Harness(
            fixture: fixture, segmentId: segmentId, provider: provider, mask: mask, index: index,
            spotlight: spotlight, enrichment: enrichment,
            cuts: ConversationCutStore(db: fixture.database))
    }

    @Test("two conversations cut from one segment are titled, and found, by their own words")
    func titlesAndSearchReadPieces() async throws {
        let h = try await harness()
        try await h.cuts.setOverride(at: h.cut, decision: .split)
        try await h.enrichment.regroupPass()

        #expect(
            await h.enrichment.pieces(ofConversation: h.first)
                == [ConversationMember(segmentId: h.segmentId, endMediaMs: 30_000)])
        #expect(
            await h.enrichment.pieces(ofConversation: h.second)
                == [ConversationMember(segmentId: h.segmentId, startMediaMs: 30_000)])

        let changed = try await h.enrichment.enrichPass()
        #expect(Set(changed) == [h.first, h.second])
        #expect(h.provider.runs == 2)
        #expect(h.provider.text(for: h.first).contains("repaint the fence"))
        #expect(!h.provider.text(for: h.first).contains("penalties"))
        #expect(h.provider.text(for: h.second).contains("penalties"))
        #expect(!h.provider.text(for: h.second).contains("fence"))
        // Each title records the pieces it was written from.
        #expect(
            try await h.fixture.annotations.load(h.second)?.sourceKey
                == "\(h.segmentId)@30000-")

        // Donation: a search for words said after the cut must not open the conversation
        // before it.
        await h.enrichment.donate(conversationIds: changed)
        #expect(try h.found("primer") == [h.first])
        #expect(try h.found("penalties") == [h.second])
    }

    @Test("a piece with no conversation in it is a stand-in; the talk beside it is not")
    func noConversationIsDecidedByPiece() async throws {
        let h = try await harness()
        try await h.cuts.setOverride(at: h.cut, decision: .split)
        try await h.enrichment.regroupPass()

        // Classified: conversation in the first twenty seconds, none after.
        h.mask.setConversationRanges(h.segmentId, [0..<20_000])
        let changed = try await h.enrichment.enrichPass()
        #expect(Set(changed) == [h.first, h.second])
        #expect(h.provider.runs == 1)
        #expect(try await h.fixture.annotations.load(h.first)?.title == "Title 1")
        let standIn = try #require(try await h.fixture.annotations.load(h.second))
        #expect(standIn.title == AudioContentPresentation.noConversationTitle)
        #expect(standIn.providerId == AudioContentPresentation.providerId)
        #expect(standIn.sourceKey == "\(h.segmentId)@30000-")
        // Settled: nothing more is written, nothing is asked.
        #expect(try await h.enrichment.enrichPass().isEmpty)
        #expect(h.provider.runs == 1)

        // The whole-segment answer would have said "holds conversation" for both, and "holds
        // none" for both once the talk is only in the second half.
        h.mask.setConversationRanges(h.segmentId, [38_000..<50_000])
        let flipped = try await h.enrichment.enrichPass()
        #expect(Set(flipped) == [h.first, h.second])
        #expect(
            try await h.fixture.annotations.load(h.first)?.title
                == AudioContentPresentation.noConversationTitle)
        #expect(try await h.fixture.annotations.load(h.second)?.title == "Title 2")
    }

    @Test("a name the person gave a no-conversation stretch is kept by the stand-in")
    func aTypedTitleSurvivesTheStandIn() async throws {
        let h = try await harness()
        try await h.enrichment.regroupPass()
        try await h.fixture.annotations.setUserTitle("Waiting room", conversationId: h.first)
        h.mask.setConversationRanges(h.segmentId, [])
        #expect(try await h.enrichment.enrichPass() == [h.first])
        let standIn = try #require(try await h.fixture.annotations.load(h.first))
        #expect(standIn.title == "Waiting room" && standIn.titleEditedAtMs != nil)
        #expect(standIn.providerId == AudioContentPresentation.providerId)
        #expect(try await h.enrichment.enrichPass().isEmpty)

        // It turns out to hold talk: the stand-in goes, the name stays, the model writes the
        // rest around it.
        h.mask.setConversationRanges(h.segmentId, [0..<60_000])
        #expect(try await h.enrichment.enrichPass().contains(h.first))
        let titled = try #require(try await h.fixture.annotations.load(h.first))
        #expect(titled.title == "Waiting room" && titled.summary == "Summary 1.")
        #expect(titled.providerId != AudioContentPresentation.providerId)
    }

    @Test("a regroup that moves conversations carries what was attached to them")
    func regroupReconciles() async throws {
        let h = try await harness(withMask: false)
        try await h.enrichment.regroupPass()
        // One conversation. A follow-up heard at 0:40, and a note, are attached to it.
        try await h.fixture.followUps.upsertExtracted(
            FollowUp(
                id: "fu-1", text: "Watch the replay", done: false,
                sourceConversationId: h.first, sourceSegmentId: h.segmentId, createdAtMs: 1,
                sourceStartMs: 40_000, sourceEndMs: 45_000))
        let notes = NotesStore(db: h.fixture.database)
        let tags = TagStore(db: h.fixture.database)
        let early = try await notes.create(
            conversationId: h.first, templateId: "summary", title: "Notes", body: "Body")

        // The person splits it at 0:30: the follow-up's moment is in the second part now.
        try await h.cuts.setOverride(at: h.cut, decision: .split)
        #expect(try await h.enrichment.regroupPass())
        #expect(try await h.fixture.followUps.load(id: "fu-1")?.sourceConversationId == h.second)
        #expect(try await notes.get(id: early.id)?.conversationId == h.first)

        // Both are titled and findable; the second gets a note, a tag and a name of its own.
        let changed = try await h.enrichment.enrichPass()
        await h.enrichment.donate(conversationIds: changed)
        #expect(try h.found("penalties") == [h.second])
        let late = try await notes.create(
            conversationId: h.second, templateId: "summary", title: "Match", body: "Body")
        try await tags.addTag(conversationId: h.second, name: "football", source: TagSource.user)

        // The split is taken back: the second conversation's id is gone.
        try await h.cuts.setOverride(at: h.cut, decision: nil)
        #expect(try await h.enrichment.regroupPass())
        #expect(await h.enrichment.pieces(ofConversation: h.second).isEmpty)
        #expect(try await h.fixture.followUps.load(id: "fu-1")?.sourceConversationId == h.first)
        #expect(try await notes.get(id: late.id)?.conversationId == h.first)
        #expect(try await notes.get(id: early.id)?.conversationId == h.first)
        #expect(try await tags.tags(forConversation: h.first).map(\.name).contains("football"))
        #expect(try await h.fixture.annotations.load(h.second) == nil)
        // Its search and Spotlight rows go with it, so a hit cannot open a missing conversation.
        #expect(try h.found("penalties").isEmpty)
        #expect(
            h.spotlight.removed.contains(
                SpotlightDonation.uniqueIdentifier(kind: .conversation, entityId: h.second)))

        // The survivor's title was written from half of what it now holds: it is written
        // again, and re-donated with the whole of it.
        let calls = h.provider.runs
        let retitled = try await h.enrichment.enrichPass()
        #expect(retitled == [h.first])
        #expect(h.provider.runs == calls + 1)
        #expect(h.provider.text(for: h.first).contains("penalties"))
        await h.enrichment.donate(conversationIds: retitled)
        #expect(try h.found("penalties") == [h.first])

        // Nothing moved on a regroup that changes nothing.
        #expect(try await h.enrichment.regroupPass() == false)
    }
}
