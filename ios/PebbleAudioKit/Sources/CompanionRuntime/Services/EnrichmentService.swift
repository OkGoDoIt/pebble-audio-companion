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
    private let moments: MomentReviewWorker?
    private let annotations: AnnotationStore
    private let store: SegmentStore
    private let pauseJournal: PauseJournal?
    private let database: AppDatabase
    private let transcriptOf: @Sendable (String) -> SegmentTranscript?
    /// What the models read of ONE PIECE of a segment — the range a conversation owns of it
    /// (`ConversationMember`). Cut first, cleaned second: see the note in `init`.
    private let pieceTranscriptOf: @Sendable (ConversationMember) -> SegmentTranscript?
    /// The same piece with ONLY the looped artefacts collapsed — what search and Spotlight
    /// are given. Audio judged to hold no conversation (TV, lyrics) stays findable: a person may
    /// well search for a line they heard, and a label that can be wrong must not decide what
    /// can be found. See `AudioContentMask`.
    private let searchPieceTranscriptOf: @Sendable (ConversationMember) -> SegmentTranscript?
    /// Moves follow-ups, notes, tags, speaker names and typed titles to where they belong when
    /// a rebuild moves conversations (`ConversationReconciler`).
    private let reconciler: ConversationReconciler
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
        audioContentStore: AudioContentStore? = nil,
        moments: MomentReviewWorker? = nil
    ) {
        self.isForeground = isForeground
        self.worker = worker
        self.followUps = followUps
        self.curator = curator
        self.moments = moments
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
        // a song does not become a title or a follow-up. Search reads `searchPieceTranscriptOf`.
        //
        // A conversation owns a RANGE of each of its segments, so what the workers and the
        // donation read is a PIECE: the transcript cut to the range, THEN cleaned. The order is
        // not a detail. Both cleaners leave a note in `text` where they took turns out, and
        // `SegmentTranscript.piece` rebuilds a partial piece's text from its turns — cleaning
        // the whole segment and cutting afterwards would silently drop every note, and nearly
        // every piece is partial. (The loop rules look at the turns around each one, so a loop
        // that straddles a cut is judged in each half on its own; the cuts are placed between
        // turns of real talk, which is not where loops are.)
        self.searchPieceTranscriptOf = {
            transcriptOf($0.segmentId)?.piece($0).withLoopedArtefactsCollapsed()
        }
        self.pieceTranscriptOf = { member in
            guard
                let transcript = transcriptOf(member.segmentId)?.piece(member)
                    .withLoopedArtefactsCollapsed()
            else { return nil }
            guard let audioContentMask else { return transcript }
            return transcript.withStretchesWithheld(audioContentMask.aiRanges(member.segmentId))
        }
        // The whole-segment form, for the boundary reviewer's context.
        self.transcriptOf = { id in
            guard let transcript = transcriptOf(id)?.withLoopedArtefactsCollapsed() else { return nil }
            guard let audioContentMask else { return transcript }
            return transcript.withStretchesWithheld(audioContentMask.aiRanges(id))
        }
        self.reconciler = ConversationReconciler(db: database)
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
        // when a genuinely new candidate has appeared — and since conversations are cut by the
        // segmenter, none does: the rebuild hands back no candidates and this returns at once.
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
            + (try await worker.enrich(
                inputs, pieceTranscriptOf: pieceTranscriptOf, liveTextOf: liveTextOf))
    }

    /// Finished conversations with no conversation in them — the classified time of every PIECE
    /// is "no conversation" (all no-speech, or a stray remark) — are not the AI's to title. They
    /// get a plain stand-in annotation ("No conversation", with no AI tags) so every screen that
    /// shows a title says what they are, and they are left out of titling and follow-ups. A
    /// stand-in is withdrawn the moment the conversation turns out to hold talk (a correction, a
    /// new transcript, a cut that moved), which hands it back to the AI. A person's own tags —
    /// and a title they typed — are never touched.
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
                let standIn = await noConversationAnnotation(for: conversation, existing: current)
                // The key is part of the comparison for the reason it exists at all: a stand-in
                // inherited with an id says "no conversation" about audio it was never asked
                // about, and must be written again for the pieces it names now.
                if current?.title != standIn.title || current?.summary != standIn.summary
                    || current?.providerId != standIn.providerId || current?.tags.isEmpty == false
                    || !ConversationSourceKey.describes(
                        stored: current?.sourceKey, current: conversation.sourceKey)
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
            if let current, current.providerId == AudioContentPresentation.providerId {
                do {
                    try await annotations.delete(conversation.conversationId)
                    // The stand-in goes; a title the person typed over it does not. It is put
                    // back alone, with no key, so the pass below writes the rest around it.
                    if let title = current.title, current.titleEditedAtMs != nil {
                        try await annotations.save(
                            ConversationAnnotation(
                                conversationId: conversation.conversationId, title: title,
                                titleEditedAtMs: current.titleEditedAtMs))
                    }
                    changed.append(conversation.conversationId)
                } catch {
                    log.failure("no-conversation annotation withdraw", error)
                }
            }
            remaining.append(conversation)
        }
        return (remaining, changed)
    }

    /// Closed, with members, and no stretch classified as conversation overlapping any of its
    /// PIECES. A segment's verdict is not the conversation's: the conversation that owns a
    /// segment's quiet tail holds none, whatever was said at the segment's start — and the one
    /// that owns the talk is not excused by the quiet after it. An unclassified member keeps
    /// the conversation with the AI.
    private func holdsNoConversation(_ conversation: EnrichmentConversation) -> Bool {
        guard let audioContentMask, !conversation.isOpen, !conversation.members.isEmpty else {
            return false
        }
        return conversation.pieces.allSatisfy { audioContentMask.holdsConversation(in: $0) == false }
    }

    /// The stand-in, carrying which pieces it is about and — where the person has named the
    /// conversation — their title rather than "No conversation".
    private func noConversationAnnotation(
        for conversation: EnrichmentConversation, existing: ConversationAnnotation?
    ) async -> ConversationAnnotation {
        var spans: [SegmentAudioContentSpan] = []
        if let audioContentStore {
            for piece in conversation.pieces {
                // Only what was heard in the conversation's own range of the segment: the
                // summary must not say "music was playing" because it played after the cut.
                let start = piece.startMediaMs ?? 0
                let end = piece.endMediaMs ?? Int64.max
                spans += ((try? await audioContentStore.spans(segmentId: piece.segmentId)) ?? [])
                    .filter { piece.isWhole || ($0.mediaStartMs < end && $0.mediaEndMs > start) }
            }
        }
        let typed = existing?.titleEditedAtMs != nil ? existing?.title : nil
        return ConversationAnnotation(
            conversationId: conversation.conversationId,
            title: typed ?? AudioContentPresentation.noConversationTitle,
            summary: AudioContentPresentation.summary(for: spans),
            tags: [],
            providerId: AudioContentPresentation.providerId,
            updatedAtMs: clock.nowMs,
            isFinal: true,
            sourceKey: conversation.sourceKey,
            titleEditedAtMs: existing?.titleEditedAtMs)
    }

    /// The conversation grouping as the worker sees it: current grouping + member metas, each
    /// with the piece of it the conversation owns.
    private func enrichmentInputs() async -> [EnrichmentConversation] {
        let conversations = await grouping()
        guard !conversations.isEmpty else { return [] }
        let metasById = Dictionary(
            uniqueKeysWithValues: await store.listSegments().map { ($0.segmentId, $0) }
        )
        return conversations.map { conversation in
            // A piece whose segment is gone from the store (a delete racing the pass) is
            // dropped with it, so the two lists stay parallel.
            let parts = conversation.members.compactMap { piece in
                metasById[piece.segmentId].map { (meta: $0, piece: piece) }
            }
            return EnrichmentConversation(
                conversationId: conversation.id,
                // A conversation whose start or end can still move is treated like the live
                // one: it may get a working title, but the work that is done once per
                // conversation — the final title, follow-up extraction — waits until its
                // boundaries are held (`GroupedConversation.isProvisional`). Without this a
                // cut that moved would re-title and re-extract both neighbours each time.
                isOpen: conversation.isLive || conversation.isProvisional,
                members: parts.map(\.meta),
                pieces: parts.map(\.piece)
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

        let allInputs = await enrichmentInputs()
        if let moments,
           try await moments.run(conversations: allInputs, transcriptOf: searchPieceTranscriptOf) {
            changed = true
        }
        let inputs = allInputs.filter { !holdsNoConversation($0) }
        if !inputs.isEmpty {
            let proposed = try await followUps.extract(
                inputs, pieceTranscriptOf: pieceTranscriptOf)
            if proposed > 0 { changed = true }
        }

        let written = try await curator.curate()
        guard !written.isEmpty else { return changed }

        // Make them findable too. `donateFollowUp` had no production caller before this — the
        // search index knew about the `followup` kind and nothing ever wrote one.
        if let donator {
            for item in written {
                do {
                    try await donator.donateFollowUp(item)
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
    ///
    /// Batched: one FTS transaction and one system-index pass per `donationBatchSize`
    /// conversations, rather than a round trip each. A rebuild donates the whole library through
    /// here, so the batch is also what bounds how many transcripts are held in memory at once.
    ///
    /// A LIVE or still-provisional conversation goes to the app's own index (in-app search finds
    /// what is being said now) but not yet to the system index: Spotlight and Siri get it once it
    /// has closed and settled, which the final title pass donates, instead of a fresh partial
    /// copy at every provisional refresh.
    /// The system index's own change gate (`SpotlightIndexGate`) then makes a re-donation of
    /// anything that has not changed cost nothing.
    public func donate(conversationIds: [String]) async {
        guard let donator, !conversationIds.isEmpty else { return }
        let conversations = Dictionary(
            uniqueKeysWithValues: (await grouping()).map { ($0.id, $0) }
        )
        var batch: [SpotlightDonator.ConversationDonation] = []
        for id in conversationIds {
            guard let conversation = conversations[id] else { continue }
            do {
                guard let input = try await donation(for: conversation) else { continue }
                batch.append(input)
            } catch {
                log.failure("conversation donation", error)
            }
            if batch.count >= Self.donationBatchSize {
                await send(batch, to: donator)
                batch = []
            }
        }
        await send(batch, to: donator)
    }

    private func send(
        _ batch: [SpotlightDonator.ConversationDonation], to donator: SpotlightDonator
    ) async {
        guard !batch.isEmpty else { return }
        do { try await donator.donateConversations(batch) } catch {
            log.failure("conversation donation", error)
        }
    }

    /// What one conversation contributes to the index; nil when there is nothing to find it by.
    private func donation(for conversation: GroupedConversation) async throws
        -> SpotlightDonator.ConversationDonation?
    {
        let id = conversation.id
        let annotation = try await annotations.load(id)
        // A stand-in says the conversation holds none; there is nothing to find it by.
        if annotation?.providerId == AudioContentPresentation.providerId { return nil }
        // The words of the conversation's PIECES. Whole members would make the talk at the
        // other end of a shared segment findable under this conversation too — a search hit
        // that opens a conversation in which the words are never said.
        let transcript = conversation.members
            .compactMap { searchPieceTranscriptOf($0)?.text }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        // The tags the Library shows (the person's own edits included), falling back to the
        // annotation's before the tag table has caught up.
        let shownTags = ((try? await TagStore(db: database).tags(forConversation: id)) ?? [])
            .map(\.name)
        let named = ((try? await PeopleStore(db: database).assignments(forConversation: id)) ?? [])
            .map(\.personName)
        return SpotlightDonator.ConversationDonation(
            conversationId: id,
            title: annotation?.title,
            summary: annotation?.summary,
            tags: shownTags.isEmpty ? (annotation?.tags ?? []) : shownTags,
            people: Self.distinctNames(named),
            fullTranscript: transcript.isEmpty ? nil : transcript,
            startDateMs: conversation.startMs,
            endDateMs: conversation.endMs,
            // The conversation's own start, not the clock: a creation date of "now" made every
            // re-donation a different document to the change gate, and told Spotlight that a
            // week-old conversation was new. The foreground pass already donated it this way.
            createdAtMs: conversation.startMs,
            systemIndex: !(conversation.isLive || conversation.isProvisional),
            timeZoneID: conversation.timeZoneID
        )
    }

    /// Conversations per donation write; see `donate(conversationIds:)`.
    static let donationBatchSize = 25

    /// Speaker names, each once, in the order the conversation assigns them.
    static func distinctNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
        }
        return out
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
    ///
    /// `afterDelete` is for the delete cascade alone. A delete changes the pieces of the
    /// conversations beside the deleted one (the silenced range joins a neighbour) without
    /// changing a word of what they hold, and may pass through a grouping in which a neighbour
    /// briefly answers to another id. Neither is a re-cut: nothing is moved between
    /// conversations and no title is withdrawn; the cascade re-keys the neighbours itself.
    @discardableResult
    public func regroup(afterDelete: Bool = false) async throws -> [GroupedConversation] {
        try await regroupDetailed(settling: !afterDelete).conversations
    }

    private func regroupDetailed(settling: Bool = true) async throws
        -> ConversationGrouper.RebuiltGrouping
    {
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
            memo: groupingMemo,
            nowMs: clock.nowMs,
            db: database
        )
        cachedGrouping = rebuilt.conversations
        cachedBoundaryCandidates = rebuilt.candidates
        guard settling else { return rebuilt }
        await reconcile(after: rebuilt)
        if rebuilt.structureChanged { await withdrawStaleTitles(rebuilt.conversations) }
        return rebuilt
    }

    /// Takes back, at once, a finished title that was written about other audio.
    ///
    /// A conversation cut in two leaves its id — and so its title, summary and tags — on the
    /// first part. The worker writes a new one, but three conversations a pass, newest first,
    /// and not at all with AI off; until it gets there a ten-minute conversation would carry
    /// the title of the ten hours it was cut from, which is exactly the wrong thing this change
    /// exists to remove. An untitled conversation shows its time, which is true.
    ///
    /// Only FINISHED titles of conversations that are themselves finished: a live or still
    /// provisional conversation's working title is meant to lag behind its growing pieces, and
    /// the worker refreshes it on its own rule. A title the person typed always stays.
    private func withdrawStaleTitles(_ conversations: [GroupedConversation]) async {
        guard let stored = try? await annotations.all(), !stored.isEmpty else { return }
        var withdrawn: [String] = []
        for conversation in conversations where !conversation.isLive && !conversation.isProvisional {
            guard let existing = stored[conversation.id], existing.isFinal,
                existing.providerId != AudioContentPresentation.providerId,
                EnrichmentWorker.hasGeneratedContent(existing)
            else { continue }
            let key = ConversationSourceKey.key(of: conversation.members)
            guard !ConversationSourceKey.describes(stored: existing.sourceKey, current: key)
            else { continue }
            do {
                try await worker.withdraw(existing, sourceKey: key)
                withdrawn.append(conversation.id)
            } catch {
                log.failure("stale title withdrawal", error)
            }
        }
        // The search row still holds the old title and the old, longer transcript.
        if !withdrawn.isEmpty {
            log.write("withdrew \(withdrawn.count) titles written about other audio")
            await donate(conversationIds: withdrawn)
        }
    }

    /// Whether the once-per-launch whole-library reconciliation has run (`ConversationReconciler
    /// .sweep`). It catches up a rebuild whose own reconciliation never ran — the process died
    /// between the grouper's write and it — which nothing else can, because the grouping as it
    /// was is gone by then.
    private var sweptThisLaunch = false

    /// Re-attaches what a rebuild left behind: follow-ups to the conversation that owns their
    /// moment now, and the notes, tags, speaker names and typed title of a conversation whose id
    /// went away to the one that took its place. Then drops the search and Spotlight rows of
    /// the ids that were superseded — the index is keyed by conversation id too, and a hit for
    /// an id that no longer exists opens "conversation not found".
    ///
    /// Never fails the regroup: the grouping is already written, and everything this does is
    /// done again, from the database alone, by the next launch's sweep.
    private func reconcile(after rebuilt: ConversationGrouper.RebuiltGrouping) async {
        var superseded = Set<String>()
        do {
            if rebuilt.structureChanged, !rebuilt.previous.isEmpty {
                let outcome = try await reconciler.reconcile(
                    previous: rebuilt.previous, current: rebuilt.conversations)
                superseded.formUnion(outcome.superseded.keys)
                logReconciled(outcome, what: "reconciled")
            }
            if !sweptThisLaunch {
                let outcome = try await reconciler.sweep()
                sweptThisLaunch = true
                superseded.formUnion(outcome.superseded.keys)
                logReconciled(outcome, what: "launch sweep")
            }
        } catch {
            log.failure("conversation reconcile", error)
        }
        guard let donator else { return }
        for id in superseded {
            do { try await donator.remove(id: id, kind: .conversation) } catch {
                log.failure("superseded conversation index removal", error)
            }
        }
    }

    private func logReconciled(_ outcome: ConversationReconciler.Outcome, what: String) {
        guard !outcome.isEmpty else { return }
        log.write(
            "conversations \(what): \(outcome.superseded.count) superseded, "
                + "\(outcome.followUpsRepointed) follow-ups and "
                + "\(outcome.candidatesRepointed) candidates re-pointed, "
                + "\(outcome.notesMoved) notes, \(outcome.tagsMoved) tags, "
                + "\(outcome.speakerAssignmentsMoved) speaker names and "
                + "\(outcome.titlesMoved) typed titles moved")
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
    /// Each run's conversations, remembered between passes: regroup runs over the whole
    /// library every pass, and a run whose evidence has not moved must not be searched again.
    private let groupingMemo = GroupingMemo()
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
                        startMs: $0.startMs, endMs: $0.endMs, text: $0.text,
                        speaker: $0.speaker)
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

    /// Range-delete support: the words of a stretch of this segment were taken out of its
    /// transcript (`DeleteCascade`), and the evidence memoised above does not know. Its key is
    /// the segment's state, closedness and mask generation — none of which a redaction moves —
    /// so without this the next regroup would plan the run around turns that no longer exist,
    /// and the conversation that was just deleted would be grouped straight back.
    public func invalidateSpeechEvidence(segmentId: String) {
        evidenceCache[segmentId] = nil
    }

    private func grouping() async -> [GroupedConversation] {
        if let cachedGrouping { return cachedGrouping }
        return (try? await regroup()) ?? []
    }

    /// Invalidates the cached grouping (after a delete, retention sweep, or import).
    /// The conversations whose boundaries may still move, as the latest grouping saw them
    /// (`GroupedConversation.isProvisional` is a property of a grouping pass and is not stored).
    /// Read by the archive sync's payloads.
    ///
    /// With no grouping in memory — before the first regroup of a launch, after
    /// `invalidateGrouping`, and for the whole of a backgrounded session on battery, where
    /// regroup does not run — this used to answer "none", and a provisional conversation built
    /// then went to the server as settled; the outbox's flip check compares against what the
    /// grouping recorded, not what was sent, so nothing corrected it until the conversation
    /// really settled. The grouping that last marked each conversation for the sync recorded
    /// its flag in the outbox (`hint`, `p1` = provisional), and that survives a relaunch, so
    /// that is the answer then. Regrouping here instead would read every transcript on the
    /// first pass of a launch, from a sync pass that may be running in the background.
    public func provisionalConversationIds() async -> Set<String> {
        if let cachedGrouping {
            return Set(cachedGrouping.filter(\.isProvisional).map(\.id))
        }
        let marked = try? await database.reader.read { db -> [String] in
            guard try db.tableExists("sync_outbox") else { return [] }
            return try String.fetchAll(
                db,
                sql: "SELECT entityId FROM sync_outbox WHERE kind = 'conversation' AND hint = 'p1'"
            )
        }
        return Set(marked ?? [])
    }

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

    /// The pieces a conversation is made of: which range of each member segment it owns. A
    /// conversation rarely owns all of its first and last segments, so anything that acts on
    /// "the conversation's audio" or "its transcript" has to go through these, not the ids.
    public func pieces(ofConversation conversationId: String) async -> [ConversationMember] {
        (await grouping()).first { $0.id == conversationId }?.members ?? []
    }

    /// Every conversation that owns some part of a segment, with the part it owns.
    public func owners(ofSegment segmentId: String) async
        -> [(conversationId: String, piece: ConversationMember)]
    {
        (await grouping()).compactMap { conversation in
            conversation.member(segmentId).map { (conversation.id, $0) }
        }
    }
}
