import AppDB
import Foundation
import Intelligence
import SearchKit
import SegmentStore
import Transcription

/// Conversation-granular enrichment (plan Part 3: the pipeline is retargeted from segments to
/// conversations) plus search/Spotlight donation of whatever it changed.
///
/// The grouping itself is derived state: every pass rebuilds `conversations` /
/// `conversation_segments` from the segment metas + the pause journal, which is also what makes a
/// user pause end a conversation.
public actor EnrichmentService {
    private let worker: EnrichmentWorker
    /// Follow-up extraction shares this service's grouping, transcripts and donator rather than
    /// standing up a second copy of all three. NOT optional and NOT defaulted: the reason
    /// `FollowUps.swift` sat dead was a subsystem nothing was obliged to construct, and a
    /// required parameter is the only version of this the compiler enforces.
    private let followUps: FollowUpWorker
    private let annotations: AnnotationStore
    private let store: SegmentStore
    private let pauseJournal: PauseJournal?
    private let database: AppDatabase
    private let transcriptOf: @Sendable (String) -> SegmentTranscript?
    /// The open member's rolling live text. NOT defaulted: with the `{ _ in nil }` default nobody
    /// supplied, a LIVE conversation's open member always yielded nil, its combined length was 0,
    /// and it got no provisional title or summary until the segment closed — many minutes of an
    /// untitled "Recording now" row for exactly the conversation the person is having. The seam is
    /// synchronous while the previews live behind actors; `LivePreviewCache` is the mirror that
    /// bridges the two without blocking on an actor from a sync context.
    private let liveTextOf: @Sendable (String) -> String?
    private let donator: SpotlightDonator?
    private let clock: RuntimeClock
    private let log: RuntimeLog

    public init(
        worker: EnrichmentWorker,
        followUps: FollowUpWorker,
        annotations: AnnotationStore,
        store: SegmentStore,
        database: AppDatabase,
        pauseJournal: PauseJournal? = nil,
        transcriptOf: @escaping @Sendable (String) -> SegmentTranscript?,
        liveTextOf: @escaping @Sendable (String) -> String?,
        donator: SpotlightDonator? = nil,
        clock: RuntimeClock,
        log: RuntimeLog = .silent
    ) {
        self.worker = worker
        self.followUps = followUps
        self.annotations = annotations
        self.store = store
        self.database = database
        self.pauseJournal = pauseJournal
        self.transcriptOf = transcriptOf
        self.liveTextOf = liveTextOf
        self.donator = donator
        self.clock = clock
        self.log = log
    }

    /// True while `enrichPass` is inside the worker. Diagnostics and the conversation state
    /// card read it so background AI work is visible instead of silent.
    public private(set) var isEnriching = false

    /// Conversations that are fully transcribed but still carry no AI title or summary — the
    /// backlog the enrichment pass will work through. Counted straight off the derived tables
    /// so it stays true after a migration that deliberately imported no AI content.
    public func awaitingEnrichmentCount() async -> Int {
        let queries = ConversationQueries(db: database)
        let sections = (try? await queries.library()) ?? []
        return sections.flatMap(\.rows).filter { $0.awaitingAnnotation }.count
    }

    /// Runs one enrichment pass over the CURRENT grouping.
    /// Returns the conversation ids whose annotation changed.
    ///
    /// It deliberately does NOT regroup: grouping is cheap, local, AI-free work and belongs to
    /// its own pipeline stage (`regroupPass`). This used to call `regroup()` first, which meant
    /// the whole app's view of reality — Library, Today's conversation list, the live row, the
    /// Recording-now screen, all of which read the grouped tables — was blocked behind however
    /// long the AI backlog took. A migrated library with 145 unenriched conversations therefore
    /// froze the world at whatever moment the backfill started, while recording carried on.
    public func enrichPass() async throws -> [String] {
        isEnriching = true
        defer { isEnriching = false }
        let inputs = await enrichmentInputs()
        guard !inputs.isEmpty else { return [] }
        return try await worker.enrich(
            inputs, transcriptOf: transcriptOf, liveTextOf: liveTextOf
        )
    }

    /// The conversation grouping as the worker sees it: current grouping + member metas.
    private func enrichmentInputs() async -> [EnrichmentConversation] {
        let conversations = await grouping()
        guard !conversations.isEmpty else { return [] }
        let metasById = Dictionary(
            uniqueKeysWithValues: await store.listSegments().map { ($0.segmentId, $0) }
        )
        return conversations.map { conversation in
            EnrichmentConversation(
                conversationId: conversation.id,
                isOpen: conversation.isLive,
                members: conversation.memberSegmentIds.compactMap { metasById[$0] }
            )
        }
    }

    /// The grouping stage: rebuild `conversations` / `conversation_segments` from the segment
    /// metas and the pause journal. Every pass, unconditionally, independent of the AI layer —
    /// this is what makes a segment visible as soon as it closes.
    public func regroupPass() async throws {
        _ = try await regroup()
    }

    /// True while `followUpPass` is inside the worker.
    public private(set) var isExtractingFollowUps = false

    /// Extracts follow-ups from finished conversations (plan Part 4.5). Runs after `enrich`
    /// because it wants the same durable, complete transcripts the final annotation pass wants,
    /// and reuses the grouping that pass just rebuilt rather than regrouping again.
    ///
    /// Returns true when it wrote at least one new follow-up, so the pipeline treats the pass as
    /// having done work and comes back promptly for the rest of the backlog.
    @discardableResult
    public func followUpPass() async throws -> Bool {
        isExtractingFollowUps = true
        defer { isExtractingFollowUps = false }
        let inputs = await enrichmentInputs()
        guard !inputs.isEmpty else { return false }
        let written = try await followUps.extract(inputs, transcriptOf: transcriptOf)
        guard !written.isEmpty else { return false }
        // Make them findable too. `donateFollowUp` had no production caller before this — the
        // search index knew about the `followup` kind and nothing ever wrote one.
        if let donator {
            for item in written {
                do {
                    try await donator.donateFollowUp(
                        id: item.id,
                        text: item.text,
                        sourceConversationId: item.sourceConversationId,
                        createdAtMs: item.createdAtMs
                    )
                } catch {
                    log.failure("follow-up donation", error)
                }
            }
        }
        return true
    }

    /// Delete-cascade support: a conversation that no longer exists keeps no extraction
    /// bookkeeping. (Its follow-up ROWS are removed by the per-segment cascade, which is what
    /// their `sourceSegmentId` is for.)
    public func forgetFollowUpExtraction(conversationId: String) async {
        await followUps.forgetExtraction(conversationId: conversationId)
    }

    /// Donates the changed conversations into the persistent index + Spotlight. Separate from
    /// `enrichPass` so the pipeline's ORDER is observable (enrich, then donate).
    public func donate(conversationIds: [String]) async {
        guard let donator, !conversationIds.isEmpty else { return }
        let conversations = Dictionary(
            uniqueKeysWithValues: (await grouping()).map { ($0.id, $0) }
        )
        for id in conversationIds {
            guard let conversation = conversations[id] else { continue }
            do {
                let annotation = try await annotations.load(id)
                let transcript = conversation.memberSegmentIds
                    .compactMap { transcriptOf($0)?.text }
                    .joined(separator: "\n")
                try await donator.donateConversation(
                    conversationId: id,
                    title: annotation?.title,
                    summary: annotation?.summary,
                    tags: annotation?.tags ?? [],
                    fullTranscript: transcript.isEmpty ? nil : transcript,
                    startDateMs: conversation.startMs,
                    createdAtMs: clock.nowMs
                )
            } catch {
                log.failure("conversation donation", error)
            }
        }
    }

    /// Rebuilds `conversations` / `conversation_segments` from durable state, and caches the
    /// result so cascade lookups need no second query.
    @discardableResult
    public func regroup() async throws -> [GroupedConversation] {
        let segments = await store.listSegments()
        let openId = await store.openSegmentId
        let pauses: [PauseInterval]
        if let pauseJournal {
            pauses = (try? await pauseJournal.all()) ?? []
        } else {
            pauses = []
        }
        let grouped = try await ConversationGrouper.rebuild(
            segments: segments,
            pauses: pauses,
            openSegmentId: openId,
            db: database
        )
        cachedGrouping = grouped
        return grouped
    }

    private var cachedGrouping: [GroupedConversation]?

    private func grouping() async -> [GroupedConversation] {
        if let cachedGrouping { return cachedGrouping }
        return (try? await regroup()) ?? []
    }

    /// Invalidates the cached grouping (after a delete, retention sweep, or import).
    public func invalidateGrouping() {
        cachedGrouping = nil
    }

    /// The conversation ids a segment belongs to (delete-cascade support).
    public func conversationIds(containing segmentId: String) async -> [String] {
        (await grouping()).filter { $0.memberSegmentIds.contains(segmentId) }.map(\.id)
    }

    public func members(ofConversation conversationId: String) async -> [String] {
        (await grouping()).first { $0.id == conversationId }?.memberSegmentIds ?? []
    }
}
