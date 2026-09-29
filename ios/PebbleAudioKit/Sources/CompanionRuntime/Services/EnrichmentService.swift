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
    /// The second follow-up pass. Extraction proposes, this decides — see `FollowUpCurator`.
    private let curator: FollowUpCurator
    private let annotations: AnnotationStore
    private let store: SegmentStore
    private let pauseJournal: PauseJournal?
    private let database: AppDatabase
    private let transcriptOf: @Sendable (String) -> SegmentTranscript?
    /// Turn timings only, for the boundary layer's whole-library sweep. Defaults to reading the
    /// full transcript and throwing the words away; `FileTranscriptStore.loadSpeechTimings`
    /// avoids decoding them at all and is what the app supplies.
    private let speechTimingsOf: @Sendable (String) -> [Transcription.TranscriptSegment]?
    /// The open member's rolling live text. NOT defaulted: with the `{ _ in nil }` default nobody
    /// supplied, a LIVE conversation's open member always yielded nil, its combined length was 0,
    /// and it got no provisional title or summary until the segment closed — many minutes of an
    /// untitled "Recording now" row for exactly the conversation the person is having. The seam is
    /// synchronous while the previews live behind actors; `LivePreviewCache` is the mirror that
    /// bridges the two without blocking on an actor from a sync context.
    private let liveTextOf: @Sendable (String) -> String?
    private let donator: SpotlightDonator?
    /// The optional semantic boundary layer. Nil is a supported, tested configuration: the
    /// grouping is then purely structural.
    private let boundaryReviewer: BoundaryReviewer?
    private let clock: RuntimeClock
    private let log: RuntimeLog
    /// Whether the app is on screen, for the held-account probe's schedule (a person who just
    /// topped up is looking). `{ false }` keeps it on the hold's own backoff alone.
    private let isForeground: @Sendable () -> Bool

    public init(
        worker: EnrichmentWorker,
        followUps: FollowUpWorker,
        curator: FollowUpCurator,
        annotations: AnnotationStore,
        store: SegmentStore,
        database: AppDatabase,
        pauseJournal: PauseJournal? = nil,
        transcriptOf: @escaping @Sendable (String) -> SegmentTranscript?,
        liveTextOf: @escaping @Sendable (String) -> String?,
        donator: SpotlightDonator? = nil,
        boundaryReviewer: BoundaryReviewer? = nil,
        speechTimingsOf: (@Sendable (String) -> [Transcription.TranscriptSegment]?)? = nil,
        clock: RuntimeClock,
        log: RuntimeLog = .silent,
        isForeground: @escaping @Sendable () -> Bool = { false }
    ) {
        self.isForeground = isForeground
        self.worker = worker
        self.followUps = followUps
        self.curator = curator
        self.annotations = annotations
        self.store = store
        self.database = database
        self.pauseJournal = pauseJournal
        // ONE seam cleans every model input this service drives — titles, summaries and tags
        // (`EnrichmentWorker`), follow-ups (`FollowUpWorker`), boundary review
        // (`BoundaryReviewer`), and the transcript donated to search below — because all four
        // read their text through this closure. Cleaning at each call site instead would be
        // four edits and one of them would eventually be forgotten.
        //
        // It is a VIEW, not a rewrite: `withLoopedArtefactsCollapsed()` returns `self` when
        // there is nothing to collapse, and never touches the file the transcript screen reads.
        self.transcriptOf = { transcriptOf($0)?.withLoopedArtefactsCollapsed() }
        self.liveTextOf = liveTextOf
        self.donator = donator
        self.boundaryReviewer = boundaryReviewer
        self.speechTimingsOf = speechTimingsOf ?? { transcriptOf($0)?.segments }
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
        // A cloud AI account on hold is checked here, on its own schedule, before anything asks
        // whether the router is available — see `EnrichmentWorker.probeHeldAccountIfDue`. A
        // success lifts the hold, whose handler wakes every stage it parked.
        await worker.probeHeldAccountIfDue(foreground: isForeground())
        // The boundary review rides in the AI stage rather than the grouping one on purpose:
        // `regroupPass` is deliberately AI-free so the whole app's view of reality never waits
        // on a provider. Verdicts written here are read by the NEXT regroup, so a confirmed
        // boundary appears one pass later — which is also what keeps the AI from ever mutating
        // the grouping directly. It is cheap: verdicts are cached, so this makes a call only
        // when a genuinely new candidate has appeared.
        do {
            _ = try await boundaryReviewPass()
        } catch let error where error is CancellationError {
            throw error
        } catch {
            log.failure("boundary review", error)
        }
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
    /// Returns whether the grouping's STRUCTURE changed — membership, a member's state, or a
    /// conversation going live or closed. False means nothing the AI stages read has moved,
    /// which the pipeline uses to skip them. The live conversation's extent creeping forward
    /// while the watch records is deliberately not a change here: it is written, but it is not
    /// news to a title, a follow-up or a recap.
    @discardableResult
    public func regroupPass() async throws -> Bool {
        try await regroupDetailed().structureChanged
    }

    /// True while `followUpPass` is inside the worker.
    public private(set) var isExtractingFollowUps = false

    /// One follow-up pass: propose, decide, then file away what has gone quiet.
    ///
    /// Runs after `enrich` because both want the same durable, complete transcripts and the
    /// grouping that pass just rebuilt. Returns true when anything changed, so the pipeline
    /// treats the pass as having done work and comes back promptly for the rest of the backlog.
    ///
    /// The three steps are separate on purpose. Extraction is the expensive one and is capped
    /// per pass; curation is one call over whatever has accumulated; the age rule is arithmetic
    /// and runs even when there is no AI configured at all, because a person who turned remote
    /// processing off should still stop seeing a three-week-old proposal at the top of a list.
    @discardableResult
    public func followUpPass() async throws -> Bool {
        isExtractingFollowUps = true
        defer { isExtractingFollowUps = false }

        var changed = false
        if try await curator.archiveStale() > 0 { changed = true }

        let inputs = await enrichmentInputs()
        if !inputs.isEmpty {
            let proposed = try await followUps.extract(inputs, transcriptOf: transcriptOf)
            if proposed > 0 { changed = true }
        }

        let written = try await curator.curate()
        guard !written.isEmpty else { return changed }

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
    ///
    /// The rebuild is handed SPEECH EVIDENCE as well as the metas: which members are settled
    /// (closed, with a terminal transcript) and where speech actually was inside them. That is
    /// what lets a conversation end at a long stretch of nothing said — the 5-minute chain
    /// window cannot see it, because the watch counts through quiet and rotations abut. Members
    /// that are still transcribing simply defer the decision to a later pass; grouping is
    /// derived, so the answer improves as evidence lands instead of being guessed early.
    @discardableResult
    public func regroup() async throws -> [GroupedConversation] {
        try await regroupDetailed().conversations
    }

    private func regroupDetailed() async throws -> ConversationGrouper.RebuiltGrouping {
        let segments = await store.listSegments()
        let openId = await store.openSegmentId
        let pauses: [PauseInterval]
        if let pauseJournal {
            pauses = (try? await pauseJournal.all()) ?? []
        } else {
            pauses = []
        }
        let evidence = speechEvidence(for: segments)
        let rebuilt = try await ConversationGrouper.rebuildDetailed(
            segments: segments,
            pauses: pauses,
            openSegmentId: openId,
            evidence: evidence,
            db: database
        )
        cachedGrouping = rebuilt.conversations
        cachedBoundaryCandidates = rebuilt.candidates
        return rebuilt
    }

    /// One pass of the OPTIONAL semantic boundary review: asks the model about the joins the
    /// last regroup could not settle, and caches the verdicts. Returns the number written.
    ///
    /// Nothing depends on it. With no reviewer configured — no AI, local-only with no model,
    /// consent off — this returns 0 and the grouping is the structural one. The verdicts it
    /// does write are picked up by the NEXT `regroup`, which is the only place a split is ever
    /// made, so the AI never mutates the grouping directly.
    @discardableResult
    public func boundaryReviewPass() async throws -> Int {
        guard let boundaryReviewer, !cachedBoundaryCandidates.isEmpty else { return 0 }
        let read = transcriptOf
        return try await boundaryReviewer.review(candidates: cachedBoundaryCandidates) {
            BoundaryReviewer.context(for: $0, transcriptOf: read)
        }
    }

    private var cachedGrouping: [GroupedConversation]?
    /// Boundary candidates from the last regroup — the semantic layer's work list.
    private var cachedBoundaryCandidates: [BoundaryCandidate] = []

    /// Speech evidence, memoized on the only two things that can change it. Regroup runs on
    /// every pipeline pass over the WHOLE library, and without this it would re-read every
    /// transcript on disk each time — the megabytes-of-JSON shape that has already cost this app
    /// one stall. After the first sweep only a segment whose transcription state or closed-ness
    /// moved is read again, which is normally none of them.
    private var evidenceCache: [String: (state: TranscriptionState, closed: Bool, evidence: SegmentSpeechEvidence)] = [:]

    private func speechEvidence(for segments: [SegmentMeta]) -> [String: SegmentSpeechEvidence] {
        var out: [String: SegmentSpeechEvidence] = [:]
        out.reserveCapacity(segments.count)
        for meta in segments {
            let closed = meta.closeReason != nil
            if let cached = evidenceCache[meta.segmentId], cached.state == meta.transcriptionState,
                cached.closed == closed
            {
                out[meta.segmentId] = cached.evidence
                continue
            }
            // Only a `.complete` member has timings worth reading: `.noSpeech` settles with no
            // speech at all, and every other state is unsettled whatever the file says, so
            // reading it would be work done to reach the same answer.
            // The word count rides along because the boundary layer's flanking-flow guard needs
            // to know how MUCH was said either side of a silence, not merely that something
            // was: a break bracketed by full conversation is a pause inside one occasion.
            let timings: [SpeechSpan]? =
                meta.transcriptionState == .complete
                ? speechTimingsOf(meta.segmentId)?.map {
                    SpeechSpan(
                        startMs: $0.startMs, endMs: $0.endMs,
                        wordCount: $0.text.split(whereSeparator: \.isWhitespace).count)
                }
                : nil
            let evidence = SegmentSpeechEvidence.of(meta, transcriptSpeech: timings)
            evidenceCache[meta.segmentId] = (meta.transcriptionState, closed, evidence)
            out[meta.segmentId] = evidence
        }
        // Segments that no longer exist keep no cache entry.
        let alive = Set(segments.map(\.segmentId))
        evidenceCache = evidenceCache.filter { alive.contains($0.key) }
        return out
    }

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
