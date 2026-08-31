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
    private let annotations: AnnotationStore
    private let store: SegmentStore
    private let pauseJournal: PauseJournal?
    private let database: AppDatabase
    private let transcriptOf: @Sendable (String) -> SegmentTranscript?
    private let liveTextOf: @Sendable (String) -> String?
    private let donator: SpotlightDonator?
    private let clock: RuntimeClock
    private let log: RuntimeLog

    public init(
        worker: EnrichmentWorker,
        annotations: AnnotationStore,
        store: SegmentStore,
        database: AppDatabase,
        pauseJournal: PauseJournal? = nil,
        transcriptOf: @escaping @Sendable (String) -> SegmentTranscript?,
        liveTextOf: @escaping @Sendable (String) -> String? = { _ in nil },
        donator: SpotlightDonator? = nil,
        clock: RuntimeClock,
        log: RuntimeLog = .silent
    ) {
        self.worker = worker
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

    /// Rebuilds the conversation grouping and runs one enrichment pass over it.
    /// Returns the conversation ids whose annotation changed.
    public func enrichPass() async throws -> [String] {
        isEnriching = true
        defer { isEnriching = false }
        let conversations = try await regroup()
        guard !conversations.isEmpty else { return [] }
        let metasById = Dictionary(
            uniqueKeysWithValues: await store.listSegments().map { ($0.segmentId, $0) }
        )
        let inputs = conversations.map { conversation in
            EnrichmentConversation(
                conversationId: conversation.id,
                isOpen: conversation.isLive,
                members: conversation.memberSegmentIds.compactMap { metasById[$0] }
            )
        }
        return try await worker.enrich(
            inputs, transcriptOf: transcriptOf, liveTextOf: liveTextOf
        )
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
