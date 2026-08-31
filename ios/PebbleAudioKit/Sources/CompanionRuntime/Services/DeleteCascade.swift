import AppDB
import Foundation
import Intelligence
import SearchKit
import SegmentStore
import Transcription

/// Everything that must disappear with one segment or one conversation.
///
/// Deleting audio has to be complete or it is a privacy bug: a leftover transcript, annotation,
/// AI output, follow-up, recap membership or search-index row keeps the content findable after
/// the person asked for it to be gone.
public actor DeleteCascade {
    private let store: SegmentStore
    private let transcription: TranscriptionService
    private let annotations: AnnotationStore
    private let aiOutputs: AiOutputStore
    private let followUps: FollowUpStore
    private let recaps: RecapService
    private let enrichment: EnrichmentService
    private let index: (any TranscriptIndexing)?
    private let donator: SpotlightDonator?
    private let lossEvaluator: LossEventEvaluator?
    private let log: RuntimeLog

    public init(
        store: SegmentStore,
        transcription: TranscriptionService,
        annotations: AnnotationStore,
        aiOutputs: AiOutputStore,
        followUps: FollowUpStore,
        recaps: RecapService,
        enrichment: EnrichmentService,
        index: (any TranscriptIndexing)? = nil,
        donator: SpotlightDonator? = nil,
        lossEvaluator: LossEventEvaluator? = nil,
        log: RuntimeLog = .silent
    ) {
        self.store = store
        self.transcription = transcription
        self.annotations = annotations
        self.aiOutputs = aiOutputs
        self.followUps = followUps
        self.recaps = recaps
        self.enrichment = enrichment
        self.index = index
        self.donator = donator
        self.lossEvaluator = lossEvaluator
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

        do { try await store.deleteSegment(segmentId) } catch {
            log.failure("segment delete", error)
            return false
        }
        do { try await transcription.deleteTranscriptionData(segmentId) } catch {
            log.failure("transcription delete", error)
        }
        await lossEvaluator?.forget(segmentId: segmentId)

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

        // Follow-ups extracted from this segment.
        do {
            for followUp in try await followUps.list() where followUp.sourceSegmentId == segmentId {
                try await followUps.delete(id: followUp.id)
                await removeFromIndex(id: followUp.id, kind: .followUp)
            }
        } catch {
            log.failure("follow-up cascade", error)
        }

        // Recap membership: a day recap that quoted this segment is no longer true.
        for recap in await recaps.recapsSourced(from: segmentId) {
            do {
                try await recaps.delete(dateKey: recap.dateKey)
                await removeFromIndex(id: recaps.indexId(dateKey: recap.dateKey), kind: .recap)
            } catch {
                log.failure("recap cascade", error)
            }
        }

        // Regroup, then drop annotations + index rows for conversations that no longer exist.
        await enrichment.invalidateGrouping()
        let survivors = Set(((try? await enrichment.regroup()) ?? []).map(\.id))
        for conversationId in conversationIds where !survivors.contains(conversationId) {
            do { try await annotations.delete(conversationId) } catch {
                log.failure("annotation cascade", error)
            }
            await removeFromIndex(id: conversationId, kind: .conversation)
        }
        // A surviving conversation's index entry is now stale; the next enrichment pass
        // re-donates it, and until then the row is removed rather than left lying about content.
        for conversationId in conversationIds where survivors.contains(conversationId) {
            await removeFromIndex(id: conversationId, kind: .conversation)
        }
        return true
    }

    /// Conversation delete = cascade over every member segment.
    @discardableResult
    public func deleteConversation(_ conversationId: String) async -> [String] {
        let members = await enrichment.members(ofConversation: conversationId)
        var deleted: [String] = []
        for segmentId in members {
            if await deleteSegment(segmentId) { deleted.append(segmentId) }
        }
        do { try await annotations.delete(conversationId) } catch {
            log.failure("annotation delete", error)
        }
        await removeFromIndex(id: conversationId, kind: .conversation)
        return deleted
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
