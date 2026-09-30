import AppDB
import AudioCodec
import Foundation
import Intelligence
import SearchKit
import SegmentStore
import Transcription
import WireProtocol

/// Everything that must disappear with one segment or one conversation.
///
/// Deleting audio has to be complete or it is a privacy bug: a leftover transcript, annotation,
/// AI output, follow-up, recap membership or search-index row keeps the content findable after
/// the person asked for it to be gone.
///
/// And it has to be EXACT. A conversation is an ordered list of pieces, each a range of one
/// segment's stored audio (`ConversationMember`), and one segment routinely holds the end of
/// one conversation and the start of the next. Deleting a conversation therefore destroys its
/// own pieces — a whole segment where it owns one, a range of a segment where it shares one —
/// and nothing that belongs to the conversation beside it.
public actor DeleteCascade {
    private let store: SegmentStore
    private let transcription: TranscriptionService
    private let annotations: AnnotationStore
    private let aiOutputs: AiOutputStore
    private let followUps: FollowUpStore
    private let candidates: FollowUpCandidateStore
    private let recaps: RecapService
    private let enrichment: EnrichmentService
    private let index: (any TranscriptIndexing)?
    private let donator: SpotlightDonator?
    private let lossEvaluator: LossEventEvaluator?
    /// The user's manual split/join decisions, keyed by the segment that follows the join. Optional
    /// so every existing construction keeps compiling; the app's composition root passes the real
    /// one. See `forgetBoundaryOverride`.
    private let boundaryOverrides: BoundaryOverrideStore?
    /// The segment's audio-content spans, and any correction that was only about it.
    private let audioContent: AudioContentService?
    /// The stored-segment waveform cache, which a range delete has to be told about: it is
    /// keyed on a frame count that silencing does not change.
    private let live: LiveAudioService?
    private let log: RuntimeLog

    public init(
        store: SegmentStore,
        transcription: TranscriptionService,
        annotations: AnnotationStore,
        aiOutputs: AiOutputStore,
        followUps: FollowUpStore,
        candidates: FollowUpCandidateStore,
        recaps: RecapService,
        enrichment: EnrichmentService,
        index: (any TranscriptIndexing)? = nil,
        donator: SpotlightDonator? = nil,
        lossEvaluator: LossEventEvaluator? = nil,
        boundaryOverrides: BoundaryOverrideStore? = nil,
        audioContent: AudioContentService? = nil,
        live: LiveAudioService? = nil,
        log: RuntimeLog = .silent
    ) {
        self.store = store
        self.transcription = transcription
        self.annotations = annotations
        self.aiOutputs = aiOutputs
        self.followUps = followUps
        self.candidates = candidates
        self.recaps = recaps
        self.enrichment = enrichment
        self.index = index
        self.donator = donator
        self.lossEvaluator = lossEvaluator
        self.boundaryOverrides = boundaryOverrides
        self.audioContent = audioContent
        self.live = live
        self.log = log
    }

    /// Segment ⇒ audio + meta + task + transcript + annotation (when the conversation loses its
    /// last member) + AI outputs sourced ONLY from it + follow-ups sourced from it + recap
    /// membership + every index row, including `day-<key>`.
    ///
    /// No-op for the open segment: deleting audio out from under the receiver is never right.
    @discardableResult
    public func deleteSegment(_ segmentId: String) async -> Bool {
        if await store.openSegmentId == segmentId { return false }
        let conversationIds = await enrichment.conversationIds(containing: segmentId)
        guard await destroySegment(segmentId) else { return false }

        // Regroup, then drop annotations + index rows for conversations that no longer exist.
        let survivors = Set(await regrouped().map(\.id))
        for conversationId in conversationIds where !survivors.contains(conversationId) {
            await forgetConversationRecords(conversationId)
        }
        // A surviving conversation's index entry is now stale; the next enrichment pass
        // re-donates it, and until then the row is removed rather than left lying about content.
        for conversationId in conversationIds where survivors.contains(conversationId) {
            await removeFromIndex(id: conversationId, kind: .conversation)
        }
        return true
    }

    /// Conversation delete = cascade over every PIECE the conversation owns.
    ///
    ///  - A piece that is a whole segment: the per-segment cascade, as it always was.
    ///  - A piece that is part of a segment: `deleteRange`, which silences that stretch of the
    ///    audio and removes what was derived from it, and leaves the rest of the segment —
    ///    another conversation's — byte for byte as it was.
    ///  - A piece of the OPEN segment is skipped, as the open segment always has been.
    ///
    /// Everything keyed by the conversation itself goes too: annotation, tags, notes and AI
    /// outputs, speaker names, follow-up bookkeeping, its search-index row. Those go FIRST. If
    /// the process dies part-way, what is left is a conversation that has lost its title and
    /// can be deleted again; the other order leaves a title, a summary and notes about audio
    /// that no longer exists, under an id nothing on screen leads to.
    ///
    /// The regroup comes at the end, once. The pieces are read before anything is destroyed
    /// and acted on as read: regrouping between them would re-plan the run around a
    /// conversation that is half gone.
    ///
    /// Returns the segments that were deleted WHOLE. A segment the conversation only shared
    /// still exists and is not in the list.
    @discardableResult
    public func deleteConversation(_ conversationId: String) async -> [String] {
        let pieces = await enrichment.pieces(ofConversation: conversationId)
        let openSegmentId = await store.openSegmentId
        // Conversations that share a segment with this one: what search holds for them was
        // built from that segment's transcript and may quote what is about to go.
        var neighbours: [String] = []
        var whole: [ConversationMember] = []
        var partial: [ConversationMember] = []
        // The conversation that starts where one of this one's pieces ends, in the same
        // segment: the one whose identity the regroup below has to keep.
        var follower: (conversationId: String, after: ConversationMember)?
        for piece in pieces where piece.segmentId != openSegmentId {
            let owners = await enrichment.owners(ofSegment: piece.segmentId)
                .filter { $0.conversationId != conversationId }
            if piece.isWhole, owners.isEmpty {
                whole.append(piece)
                continue
            }
            partial.append(piece)
            for owner in owners where !neighbours.contains(owner.conversationId) {
                neighbours.append(owner.conversationId)
            }
            if let end = piece.endMediaMs,
                let next = owners.first(where: { $0.piece.startMediaMs == end })
            {
                follower = (next.conversationId, piece)
            }
        }

        await forgetConversationRecords(conversationId)

        var deleted: [String] = []
        var destroyed: [ConversationMember] = []
        for piece in whole where await destroySegment(piece.segmentId) {
            deleted.append(piece.segmentId)
            destroyed.append(piece)
        }
        for piece in partial {
            // Already gone (retention got there first): nothing of this piece is left.
            guard let meta = await store.readMeta(piece.segmentId) else { continue }
            let range = piece.mediaRange(mediaSpanMs: SegmentMediaClock(meta).mediaSpanMs)
            if await deleteRange(
                segmentId: piece.segmentId, mediaRangeMs: range, conversationId: conversationId)
            {
                destroyed.append(piece)
            }
        }

        // Nothing was destroyed (the conversation is all in the open segment, or is not one):
        // the grouping has not moved.
        guard !destroyed.isEmpty else { return deleted }

        // The regroup. It adopts ids from the stored grouping, so the deleted pieces leave
        // that first — see `ConversationCutStore.releaseStoredPlace` — and the speech evidence
        // the grouping remembers for the rewritten segments is dropped, which is what lets it
        // see that the words are gone.
        let cuts = ConversationCutStore(db: annotations.db)
        for piece in partial where destroyed.contains(piece) {
            await enrichment.invalidateSpeechEvidence(segmentId: piece.segmentId)
        }
        do { try await cuts.releaseStoredPlace(of: destroyed) } catch {
            log.failure("stored grouping cascade", error)
        }
        var conversations = await regrouped()

        // The conversation that follows in the shared segment must still be itself. When the
        // deleted one opened the run, the planner lets the follower begin earlier, over the
        // silence — at a position no stored piece of its own covers, so the rebuild issued it
        // a new id and left its title, notes and tags behind under the old one. It is the
        // conversation that now starts in the deleted range (or exactly where it ended); the
        // last such, because a long silence can also have become a quiet unit of its own in
        // front of it. It gets its id back, and the rebuild after that adopts it as usual.
        if let follower, destroyed.contains(follower.after),
            !conversations.contains(where: { $0.id == follower.conversationId })
        {
            let lower = follower.after.startMediaMs ?? 0
            let upper = follower.after.endMediaMs ?? lower
            func start(_ conversation: GroupedConversation) -> Int64? {
                guard let first = conversation.members.first,
                    first.segmentId == follower.after.segmentId
                else { return nil }
                let at = first.startMediaMs ?? 0
                return at >= lower && at <= upper ? at : nil
            }
            let candidate = conversations.filter { start($0) != nil }
                .max { (start($0) ?? 0) < (start($1) ?? 0) }
            if let candidate {
                do {
                    if try await cuts.renameStoredConversation(
                        from: candidate.id, to: follower.conversationId)
                    {
                        conversations = await regrouped()
                    }
                } catch {
                    log.failure("stored grouping rename", error)
                }
            }
        }

        let survivors = Set(conversations.map(\.id))
        // What search held for the neighbours quoted the shared segment; it is removed rather
        // than left lying about content, and put straight back from the transcript as it now
        // is. A neighbour is never stripped of its title or notes here, whatever the regroup
        // made of it — those are its own.
        for id in neighbours { await removeFromIndex(id: id, kind: .conversation) }
        await enrichment.donate(conversationIds: neighbours.filter(survivors.contains))
        return deleted
    }

    // MARK: - One segment

    /// Everything that hangs off one segment, without the regroup. False when the audio could
    /// not be deleted, in which case nothing else was touched.
    private func destroySegment(_ segmentId: String) async -> Bool {
        if await store.openSegmentId == segmentId { return false }
        // Read before the delete: the classification cascade needs the segment's wall span.
        let meta = await store.readMeta(segmentId)

        do { try await store.deleteSegment(segmentId) } catch {
            log.failure("segment delete", error)
            return false
        }
        do { try await transcription.deleteTranscriptionData(segmentId) } catch {
            log.failure("transcription delete", error)
        }
        // The copy of the audio staged for a background upload, and the job that would
        // otherwise save a transcript for a recording that no longer exists.
        await transcription.discardStagedUpload(segmentId, forgetJob: true)
        await lossEvaluator?.forget(segmentId: segmentId)
        await forgetBoundaryOverride(segmentId)
        do { try await ConversationCutStore(db: annotations.db).forget(segmentIds: [segmentId]) } catch {
            log.failure("conversation cut cascade", error)
        }
        if let meta { await audioContent?.forget(segment: meta) }
        await live?.audioRewritten(segmentId)

        // AI outputs whose source set was JUST this segment. An output that also cites surviving
        // segments stays: its remaining citations are still true.
        do {
            for output in try await aiOutputs.list()
            where output.segmentIds.contains(segmentId) && Set(output.segmentIds) == [segmentId] {
                try await aiOutputs.delete(outputId: output.outputId)
            }
        } catch {
            log.failure("ai output cascade", error)
        }

        // Follow-ups drawn from this segment, and the candidates behind them. A follow-up
        // outlives its recording only if nothing can find it — which is exactly what happened
        // when the extractor was free to name a segment that did not exist.
        await deleteFollowUps { $0.sourceSegmentId == segmentId }
        do { try await candidates.deleteForSegment(segmentId: segmentId) } catch {
            log.failure("follow-up cascade", error)
        }

        await deleteRecaps(sourcedFrom: segmentId)
        return true
    }

    // MARK: - Part of a segment

    /// A range of a CLOSED segment's stored audio ⇒ that audio, silenced in place + the turns
    /// and words that start in it + the follow-ups and candidates drawn from it + the cuts and
    /// decisions inside it + the recaps that quoted the segment, and every cache that would
    /// otherwise go on describing what was there.
    ///
    /// SILENCED, not removed. Every other thing that points into the segment — the neighbour's
    /// turn timings, its follow-up sources, the conversation cuts, playback positions — is an
    /// offset into the segment's media clock, and taking frames out would move all of them.
    /// Replacing each deleted frame with a frame of silence keeps the clock, the frame count,
    /// the extents and the gap records exactly as they were (`SegmentStore.silenceAudio`).
    ///
    /// The audio goes FIRST and everything else only after it has: if the process dies between
    /// the two, the words are still in the transcript, the conversation is still listed, and
    /// the person can delete it again — which repeats every step here harmlessly. The other
    /// order would leave audio nobody can find to delete.
    ///
    /// Not touched, deliberately: the segment's transcription task (the remaining turns are
    /// still right — see `TranscriptionService.redactTranscript`), its AI outputs (they are
    /// keyed by conversation and go with the conversation), and the decision about the
    /// segment's own start (`boundary_overrides`), which is about a join, not about this audio.
    ///
    /// Not done here either: forgetting the speech evidence the grouping remembers for the
    /// segment. That is what makes a regroup see the delete, and `deleteConversation` does it
    /// for all the pieces together, at the one moment it is safe to.
    ///
    /// `conversationId` is the conversation being deleted, used only to place a follow-up that
    /// carries no position inside its segment. False when the audio could not be silenced — an
    /// open segment, a codec there is no silence for, a failed write — in which case nothing
    /// else was touched.
    private func deleteRange(
        segmentId: String, mediaRangeMs: Range<Int64>, conversationId: String?
    ) async -> Bool {
        if await store.openSegmentId == segmentId { return false }
        guard let meta = await store.readMeta(segmentId), !meta.isOpen else { return false }
        // Clamped to the audio the segment holds NOW, never "to the end": an interrupted
        // segment can be reattached and grow, and what is recorded after the delete is not
        // part of what was deleted.
        let span = SegmentMediaClock(meta).mediaSpanMs
        let lower = min(max(mediaRangeMs.lowerBound, 0), span)
        let range = lower..<min(max(mediaRangeMs.upperBound, lower), span)
        // No stored audio there: nothing to destroy, and nothing left behind.
        guard !range.isEmpty else { return true }

        do {
            guard meta.codecIdRaw == CodecId.speexWideband.rawValue else {
                throw AudioCodecError.transcriptionFailed(
                    "no silence frame for codec \(meta.codecIdRaw)")
            }
            let silence = try SpeexSilence.frame(
                sampleRateHz: Int(meta.sampleRateHz), bitRateBps: Int(meta.bitRateBps))
            try await store.silenceAudio(segmentId, mediaRangeMs: range, silenceFrame: silence)
        } catch {
            log.failure("range delete", error)
            return false
        }

        do { try await transcription.redactTranscript(segmentId, mediaRangeMs: range) } catch {
            log.failure("transcript redaction", error)
        }
        await transcription.discardStagedUpload(segmentId, forgetJob: false)

        // Follow-ups and candidates drawn from the range. The neighbour's, drawn from the rest
        // of the same segment, stay.
        await deleteFollowUps { followUp in
            guard followUp.sourceSegmentId == segmentId else { return false }
            if let at = followUp.sourceStartMs { return range.contains(at) }
            return conversationId != nil && followUp.sourceConversationId == conversationId
        }
        do {
            try await candidates.deleteForRange(
                segmentId: segmentId, mediaRangeMs: range, conversationId: conversationId)
        } catch {
            log.failure("follow-up range cascade", error)
        }

        do {
            try await ConversationCutStore(db: annotations.db)
                .forget(segmentId: segmentId, mediaRangeMs: range)
        } catch {
            log.failure("conversation cut range cascade", error)
        }

        // Two caches that key on things a range delete does not move — the segment's state
        // and its frame count — and would otherwise go on describing the audio as it was.
        await audioContent?.audioRewritten(segment: meta, mediaRangeMs: range)
        await live?.audioRewritten(segmentId)

        // A day recap that quoted this segment may have quoted the range. It regenerates.
        await deleteRecaps(sourcedFrom: segmentId)
        return true
    }

    // MARK: - Shared steps

    /// Regroups and returns the conversations that exist afterwards.
    private func regrouped() async -> [GroupedConversation] {
        await enrichment.invalidateGrouping()
        return (try? await enrichment.regroup()) ?? []
    }

    /// Everything keyed by a conversation's id rather than by its audio: the annotation, the
    /// tags, the notes and AI outputs written for it, the names given to its speakers, the
    /// follow-up extraction bookkeeping, and its row in the search index.
    ///
    /// Notes and speaker names used to be left behind. A note is the most quotable thing the
    /// app makes from a conversation — a summary or an action list in full sentences — and it
    /// stayed in the table, and in search, after the conversation it was written from was gone.
    private func forgetConversationRecords(_ conversationId: String) async {
        do { try await annotations.delete(conversationId) } catch {
            log.failure("annotation cascade", error)
        }
        await forgetTags(conversationId)
        do {
            let notes = NotesStore(db: annotations.db)
            for note in try await notes.list(conversationId: conversationId) {
                try await notes.delete(id: note.id)
                await removeFromIndex(id: note.id, kind: .note)
            }
        } catch {
            log.failure("note cascade", error)
        }
        do {
            let people = PeopleStore(db: annotations.db)
            for assignment in try await people.assignments(forConversation: conversationId) {
                try await people.unassign(conversationId: conversationId, label: assignment.label)
            }
        } catch {
            log.failure("speaker cascade", error)
        }
        await enrichment.forgetFollowUpExtraction(conversationId: conversationId)
        await removeFromIndex(id: conversationId, kind: .conversation)
    }

    private func deleteFollowUps(where matches: (FollowUp) -> Bool) async {
        do {
            for followUp in try await followUps.list(scope: .all) where matches(followUp) {
                try await followUps.delete(id: followUp.id)
                await removeFromIndex(id: followUp.id, kind: .followUp)
            }
        } catch {
            log.failure("follow-up cascade", error)
        }
    }

    /// Recap membership: a day recap that quoted this segment is no longer true.
    private func deleteRecaps(sourcedFrom segmentId: String) async {
        for recap in await recaps.recapsSourced(from: segmentId) {
            do {
                try await recaps.delete(dateKey: recap.dateKey)
                await removeFromIndex(id: recaps.indexId(dateKey: recap.dateKey), kind: .recap)
            } catch {
                log.failure("recap cascade", error)
            }
        }
    }

    /// A manual "these are one conversation" / "these are two" decision is keyed by the segment
    /// that FOLLOWS the join. Delete that segment and the row is about a join that no longer
    /// exists, so it never applies again and nothing ever cleans it up — `forget(segmentIds:)`
    /// was written for exactly this call and had no caller.
    ///
    /// Harmless today, because segment ids are not reused. It is still a leak of a decision the
    /// person made about a recording they have since deleted, in the one table this cascade
    /// exists to keep honest.
    private func forgetBoundaryOverride(_ segmentId: String) async {
        guard let boundaryOverrides else { return }
        do { try await boundaryOverrides.forget(segmentIds: [segmentId]) } catch {
            log.failure("boundary override cascade", error)
        }
    }

    /// Tag pairs are keyed by conversation id with no foreign key to `conversations`, so a
    /// deleted conversation would otherwise keep counting toward every chip it carried — the
    /// Library would offer "budget 7" and show six rows.
    private func forgetTags(_ conversationId: String) async {
        do { try await TagStore(db: annotations.db).forgetConversation(conversationId) } catch {
            log.failure("tag cascade", error)
        }
    }

    private func removeFromIndex(id: String, kind: IndexKind) async {
        do {
            if let donator {
                try await donator.remove(id: id, kind: kind)
            } else {
                try index?.remove(id: id, kind: kind)
            }
        } catch {
            log.failure("index removal", error)
        }
    }
}

// MARK: - The 5 s undo window

/// A deferred conversation delete (plan Part 2: destructive actions get an undo, never a modal).
///
/// The runtime owns the COMMIT, not the timer: `deleteConversation(id:)` hides the conversation
/// and hands back a token; the app layer shows its snackbar and calls `commit` when the window
/// closes or `restore` when the person taps Undo. Nothing is destroyed until `commit` runs, so a
/// process death inside the window loses the delete, not the audio — the safe direction.
public struct PendingConversationDelete: Sendable, Equatable {
    public let conversationId: String
    public let requestedAtMs: Int64

    public init(conversationId: String, requestedAtMs: Int64) {
        self.conversationId = conversationId
        self.requestedAtMs = requestedAtMs
    }
}

/// Holds conversations hidden by a pending delete so the library can filter them out.
public actor DeferredDeleteBuffer {
    /// The approved undo window.
    public static let windowMs: Int64 = 5_000

    private let cascade: DeleteCascade
    private let clock: RuntimeClock
    private var pending: [String: PendingConversationDelete] = [:]

    public init(cascade: DeleteCascade, clock: RuntimeClock) {
        self.cascade = cascade
        self.clock = clock
    }

    /// Conversation ids the UI must hide right now.
    public var hiddenConversationIds: Set<String> { Set(pending.keys) }

    /// Stages a delete. Returns the token the app's snackbar carries.
    @discardableResult
    public func deleteConversation(id: String) -> PendingConversationDelete {
        let token = PendingConversationDelete(conversationId: id, requestedAtMs: clock.nowMs)
        pending[id] = token
        return token
    }

    /// Undo: the conversation reappears and nothing was destroyed.
    @discardableResult
    public func restore(_ token: PendingConversationDelete) -> Bool {
        pending.removeValue(forKey: token.conversationId) != nil
    }

    /// The window closed: destroy for real. Returns the deleted segment ids.
    @discardableResult
    public func commit(_ token: PendingConversationDelete) async -> [String] {
        guard pending.removeValue(forKey: token.conversationId) != nil else { return [] }
        return await cascade.deleteConversation(token.conversationId)
    }

    /// Commits everything still staged — called on background entry and on teardown so a delete
    /// is never left half-applied across a launch.
    public func commitAll() async {
        for token in pending.values {
            pending.removeValue(forKey: token.conversationId)
            _ = await cascade.deleteConversation(token.conversationId)
        }
    }
}
