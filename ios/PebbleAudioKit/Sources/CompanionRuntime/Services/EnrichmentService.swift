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
    /// The same transcript with ONLY the looped artefacts collapsed — what search and Spotlight
    /// are given. Audio judged to hold no conversation (TV, lyrics) stays findable: a person may
    /// well search for a line they heard, and a label that can be wrong must not decide what
    /// can be found. See `AudioContentMask`.
    private let searchTranscriptOf: @Sendable (String) -> SegmentTranscript?
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
    private let audioContentMask: AudioContentMask?
    private let audioContentStore: AudioContentStore?

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
        isForeground: @escaping @Sendable () -> Bool = { false },
        audioContentMask: AudioContentMask? = nil,
        audioContentStore: AudioContentStore? = nil
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
        //
        // The audio-content mask is the second half of the same seam: stretches judged to hold
        // no conversation (TV dialogue, lyrics, or a person's own "this was not a
        // conversation") are left out of what the MODELS read, with a note in their place, so
        // a song does not become a title or a follow-up. Search reads `searchTranscriptOf`.
        self.searchTranscriptOf = { transcriptOf($0)?.withLoopedArtefactsCollapsed() }
        self.transcriptOf = { id in
            guard let transcript = transcriptOf(id)?.withLoopedArtefactsCollapsed() else { return nil }
            guard let audioContentMask else { return transcript }
            return transcript.withStretchesWithheld(audioContentMask.aiRanges(id))
        }
        self.liveTextOf = liveTextOf
        self.donator = donator
        self.boundaryReviewer = boundaryReviewer
        let timings = speechTimingsOf ?? { transcriptOf($0)?.segments }
        // Turns inside a stretch judged to hold no conversation are not speech evidence: lyrics
        // and transcriber loops used to keep a conversation open straight through them.
        self.speechTimingsOf = { id in
            guard let turns = timings(id) else { return nil }
            guard let audioContentMask else { return turns }
            let ranges = audioContentMask.speechRanges(id)
            guard !ranges.isEmpty else { return turns }
            return turns.filter { turn in
                let middle = turn.startMs + max(turn.endMs - turn.startMs, 0) / 2
                return !ranges.contains { $0.contains(middle) }
            }
        }
        self.audioContentMask = audioContentMask
        self.audioContentStore = audioContentStore
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
        let (inputs, settled) = await settleNoConversation(await enrichmentInputs())
        guard !inputs.isEmpty else { return settled }
        return settled
            + (try await worker.enrich(inputs, transcriptOf: transcriptOf, liveTextOf: liveTextOf))
    }

    /// Finished conversations with no conversation in them — every member's classified time is
    /// "no conversation" (all no-speech, or a stray remark) — are not the AI's to title. They get
    /// a plain stand-in annotation ("No conversation", with no AI tags) so every screen that
    /// shows a title says what they are, and they are left out of titling and follow-ups. A
    /// stand-in is withdrawn the moment the conversation turns out to hold talk (a correction, a
    /// new transcript), which hands it back to the AI. A person's own tags are never touched.
    ///
    /// Returns the conversations still to enrich, and the ids whose annotation this changed.
    private func settleNoConversation(
        _ inputs: [EnrichmentConversation]
    ) async -> (remaining: [EnrichmentConversation], changed: [String]) {
        guard audioContentMask != nil else { return (inputs, []) }
        let existing = (try? await annotations.all()) ?? [:]
        var remaining: [EnrichmentConversation] = []
        var changed: [String] = []
        for conversation in inputs {
            let current = existing[conversation.conversationId]
            if holdsNoConversation(conversation) {
                let standIn = await noConversationAnnotation(for: conversation)
                if current?.title != standIn.title || current?.summary != standIn.summary
                    || current?.providerId != standIn.providerId || current?.tags.isEmpty == false
                {
                    do {
                        _ = try await annotations.save(standIn)
                        changed.append(conversation.conversationId)
                    } catch {
                        log.failure("no-conversation annotation", error)
                    }
                }
                continue
            }
            if current?.providerId == AudioContentPresentation.providerId {
                do {
                    try await annotations.delete(conversation.conversationId)
                    changed.append(conversation.conversationId)
                } catch {
                    log.failure("no-conversation annotation withdraw", error)
                }
            }
            remaining.append(conversation)
        }
        return (remaining, changed)
    }

    /// Closed, with members, and every member classified as holding no conversation.
    private func holdsNoConversation(_ conversation: EnrichmentConversation) -> Bool {
        guard let audioContentMask, !conversation.isOpen, !conversation.members.isEmpty else {
            return false
        }
        return conversation.members.allSatisfy {
            audioContentMask.holdsConversation($0.segmentId) == false
        }
    }

    private func noConversationAnnotation(
        for conversation: EnrichmentConversation
    ) async -> ConversationAnnotation {
        var spans: [SegmentAudioContentSpan] = []
        if let audioContentStore {
            for member in conversation.members {
                spans += (try? await audioContentStore.spans(segmentId: member.segmentId)) ?? []
            }
        }
        return ConversationAnnotation(
            conversationId: conversation.conversationId,
            title: AudioContentPresentation.noConversationTitle,
            summary: AudioContentPresentation.summary(for: spans),
            tags: [],
            providerId: AudioContentPresentation.providerId,
            updatedAtMs: clock.nowMs,
            isFinal: true)
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

        let inputs = await enrichmentInputs().filter { !holdsNoConversation($0) }
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

    /// Every AI job's retry budget and backoff start over: titles, follow-up extraction and
    /// curation, and the boundary review. Called when the AI configuration changes — a key, a
    /// mode, the remote provider or model — and when a held cloud account takes work again,
    /// because each of those can make a failed job succeed and none of them should wait out a
    /// six-hour backoff to be noticed.
    public func resetAiRetryBudgets() async {
        await worker.resetRetryBudgets()
        await followUps.resetRetryBudgets()
        await curator.resetRetryBudgets()
        await boundaryReviewer?.resetRetryBudgets()
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
                // A stand-in says the conversation holds none; there is nothing to find it by.
                if annotation?.providerId == AudioContentPresentation.providerId { continue }
                let transcript = conversation.memberSegmentIds
                    .compactMap { searchTranscriptOf($0)?.text }
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
    private var evidenceCache: [String: (state: TranscriptionState, closed: Bool, mask: Int, evidence: SegmentSpeechEvidence)] = [:]

    private func speechEvidence(for segments: [SegmentMeta]) -> [String: SegmentSpeechEvidence] {
        var out: [String: SegmentSpeechEvidence] = [:]
        out.reserveCapacity(segments.count)
        for meta in segments {
            let closed = meta.closeReason != nil
            // The third key: a new audio-content verdict about this segment changes which of
            // its turns count as speech.
            let maskGeneration = audioContentMask?.speechGeneration(meta.segmentId) ?? 0
            if let cached = evidenceCache[meta.segmentId], cached.state == meta.transcriptionState,
                cached.closed == closed, cached.mask == maskGeneration
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
            evidenceCache[meta.segmentId] = (meta.transcriptionState, closed, maskGeneration, evidence)
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
