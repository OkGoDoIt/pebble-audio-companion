import Foundation
import GRDB
import SegmentStore
import WireProtocol

// The conversation model (plan Part 3, normative). Conversations are the UX unit; segments
// stay the storage/transport unit. Grouping is DERIVED state: rebuildable idempotently from
// the segment metas + the pause journal — same input ⇒ same conversation ids.

/// One grouped conversation, before/after persistence into the derived tables.
public struct GroupedConversation: Equatable, Sendable {
    /// Deterministic: `conv-<firstMemberSegmentId>` (stabilized against a previous grouping
    /// when retention removes the first member — see `group(segments:...)`).
    public var id: String
    public var startMs: Int64
    /// Wall-clock end of the last member so far. For a live conversation this is the
    /// last-flushed extent end; `isLive` (not a nil end) marks liveness so queries and
    /// coverage never have to special-case NULL.
    public var endMs: Int64
    /// IANA zone id — the first member's `recordedTimeZone`, falling back to the device's
    /// current zone (plan 6.4) when the member predates the field.
    public var timeZoneID: String
    /// True while the last member is the store's open segment.
    public var isLive: Bool
    /// Ordered member segment ids.
    public var memberSegmentIds: [String]
    /// Why this conversation starts where it does — nil for the very first one in a rebuild,
    /// where nothing preceded it. Persisted so the UI can account for an automatic split
    /// instead of leaving the user to guess.
    public var startReason: ConversationStartReason?

    public init(
        id: String, startMs: Int64, endMs: Int64, timeZoneID: String, isLive: Bool,
        memberSegmentIds: [String], startReason: ConversationStartReason? = nil
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.timeZoneID = timeZoneID
        self.isLive = isLive
        self.memberSegmentIds = memberSegmentIds
        self.startReason = startReason
    }
}

public enum ConversationGrouper {
    /// Segments with a start/end gap under this chain into one conversation (any stream id).
    public static let chainWindowMs: Int64 = 5 * 60 * 1000

    // --- segment wall-clock endpoints ---------------------------------------------------------

    /// `startTimeMs` anchors sample index 0 — but only when the watch's sample counter really
    /// started at 0 for this stream. It does not always: the counter free-runs on the watch
    /// across reattach, so a reattached stream's first segment can carry a first index worth
    /// hours. Anchoring that at `startTimeMs` places the segment HOURS INTO THE FUTURE (in
    /// Roger's library, 197 of 435 segments, by up to 14.8 h), which inflates durations, files
    /// conversations under the wrong day, and makes segments falsely abut the next one.
    ///
    /// The phone's own `receivedAtMs` is the ceiling: audio cannot have been recorded after the
    /// phone received it. A spooled backfill legitimately anchors EARLIER, and that still works.
    public static func segmentStartMs(_ meta: SegmentMeta) -> Int64 {
        guard let first = meta.firstSampleIndex else { return meta.receivedAtMs }
        return min(wallMs(ofSample: first, in: meta), meta.receivedAtMs)
    }

    /// End = start + the wall time the sample extents span (quiet included — the watch keeps
    /// counting through VAD-suppressed silence, so a mostly-quiet 15 min segment really is
    /// 15 min long). Bounded by `closedAtMs`: the segment cannot still be recording after the
    /// phone closed it, which is what kept a watch-side index jump from claiming 15 h.
    public static func segmentEndMs(_ meta: SegmentMeta) -> Int64 {
        let start = segmentStartMs(meta)
        guard let first = meta.firstSampleIndex, let last = meta.lastSampleIndexExclusive,
            last > first
        else {
            return max(meta.closedAtMs ?? start, start)
        }
        let spanMs = Int64((last - first) * 1000 / UInt64(meta.sampleRateHz > 0 ? meta.sampleRateHz : 16_000))
        return max(min(start + spanMs, meta.closedAtMs ?? Int64.max), start)
    }

    static func wallMs(ofSample sampleIndex: UInt64, in meta: SegmentMeta) -> Int64 {
        let rate = meta.sampleRateHz > 0 ? UInt64(meta.sampleRateHz) : 16_000
        return Int64(meta.startTimeMs) + Int64(sampleIndex * 1000 / rate)
    }

    // --- split predicates ---------------------------------------------------------------------

    /// An explicit on-watch/app Stop: closeReason "stopped" with StopReason.userDisabled.
    static func endsWithUserStop(_ meta: SegmentMeta) -> Bool {
        guard let close = meta.closeReason, close.kind == CloseReasonMeta.kindStopped,
            let raw = close.stopReasonRaw
        else { return false }
        return raw == Int(StopReason.userDisabled.rawValue)
    }

    /// True when a pause-journal interval overlaps the no-audio window BETWEEN two segments.
    /// Overlap (not strict containment) tolerates the small clock jitter between the pause ack
    /// and the segment close it causes. A pause wholly inside one segment's span never matches
    /// (the rule applies between segments, never within one).
    static func pauseFalls(
        between prevEndMs: Int64, and nextStartMs: Int64, pauses: [PauseInterval]
    ) -> Bool {
        guard nextStartMs > prevEndMs else { return false }
        return pauses.contains { pause in
            let end = pause.endMs ?? Int64.max
            return pause.startMs < nextStartMs && end > prevEndMs
        }
    }

    // --- grouping -----------------------------------------------------------------------------

    /// Pure grouping. Rules (plan Part 3):
    /// - next start < 5 min after previous end chains (any stream id); same `streamId` also
    ///   chains a rotation whose extents ABUT or overlap, which is what the stream-id clause
    ///   was for. The clause used to be unbounded, and a Pebble stream id survives a long
    ///   silent disconnect: in Roger's library 34 of the 52 genuine breaks ≥ 5 min — gaps of
    ///   up to 10.5 HOURS — were glued back together by it, collapsing 438 segments into 17
    ///   conversations spanning up to 53 h. A reattach after a real break is a new conversation;
    /// - VAD quiet never splits (quiet lives inside segments — nothing to do here);
    /// - PRECEDENCE: an explicit user Stop on the previous segment, or a pause-journal entry
    ///   between the segments, ALWAYS splits — even same-stream within 5 min;
    /// - a single segment is never split, however long.
    ///
    /// `previous` (optional) keeps ids stable when retention deletes a conversation's first
    /// member: a fresh group adopts the id of the previous conversation that contained its
    /// first member, so annotations/tags keyed by conversation id survive the rebuild.
    ///
    /// The rules above are the STRUCTURAL layer, and on real data they never fire inside a
    /// running capture: of the 555 joins inside Roger's 210 conversations, 370 abut to the
    /// second and none exceeds 5 minutes, because the watch counts through quiet and the quiet
    /// therefore lives inside the segments. `evidence` adds the layer that can see it — a
    /// settled stretch of the record with nothing said in it, per `BoundaryPolicy`. Supplying
    /// no evidence, or `policy: .structuralOnly`, is exactly the v1 behaviour.
    ///
    /// `overrides` are the user's own decisions and beat everything else, in both directions.
    /// `semanticSplits` are segment ids the optional AI reviewer has ruled start a new
    /// conversation; it can only act on joins this function already offered it as candidates.
    public static func group(
        segments: [SegmentMeta],
        pauses: [PauseInterval],
        openSegmentId: String?,
        fallbackTimeZoneID: String = TimeZone.current.identifier,
        previous: [GroupedConversation]? = nil,
        evidence: [String: SegmentSpeechEvidence] = [:],
        overrides: [String: BoundaryDecision] = [:],
        policy: BoundaryPolicy = .default,
        semanticSplits: Set<String> = []
    ) -> [GroupedConversation] {
        groupWithCandidates(
            segments: segments, pauses: pauses, openSegmentId: openSegmentId,
            fallbackTimeZoneID: fallbackTimeZoneID, previous: previous, evidence: evidence,
            overrides: overrides, policy: policy, semanticSplits: semanticSplits
        ).conversations
    }

    /// `group`, plus the joins that looked like boundaries but were not certain enough to act
    /// on alone. The candidates are the ONLY input the semantic layer ever gets: it can veto or
    /// confirm a structurally-plausible boundary, never invent one in continuous speech.
    ///
    /// That restriction is not timidity, it is the shape of the data: a conversation is a set of
    /// whole segments, and segment joins are 15-minute rotation artefacts. A cut driven purely
    /// by a change of subject would have to be snapped to the nearest rotation, landing up to
    /// 15 minutes — and usually mid-sentence — away from the change it claims to mark. Inside a
    /// quiet stretch the exact position does not matter, which is why quiet is the only signal
    /// safe to cut on.
    public static func groupWithCandidates(
        segments: [SegmentMeta],
        pauses: [PauseInterval],
        openSegmentId: String?,
        fallbackTimeZoneID: String = TimeZone.current.identifier,
        previous: [GroupedConversation]? = nil,
        evidence: [String: SegmentSpeechEvidence] = [:],
        overrides: [String: BoundaryDecision] = [:],
        policy: BoundaryPolicy = .default,
        semanticSplits: Set<String> = []
    ) -> (conversations: [GroupedConversation], candidates: [BoundaryCandidate]) {
        let ordered = segments.sorted { a, b in
            if a.receivedAtMs != b.receivedAtMs { return a.receivedAtMs < b.receivedAtMs }
            return a.segmentId < b.segmentId
        }
        let joined = Set(overrides.filter { $0.value == .join }.keys)

        var result: [GroupedConversation] = []
        var candidates: [BoundaryCandidate] = []
        var members: [SegmentMeta] = []
        /// Why the run currently being accumulated started.
        var runReason: ConversationStartReason?

        func emit(_ slice: ArraySlice<SegmentMeta>, reason: ConversationStartReason?) {
            guard let first = slice.first, let last = slice.last else { return }
            result.append(
                GroupedConversation(
                    id: "conv-\(first.segmentId)",
                    startMs: segmentStartMs(first),
                    endMs: slice.map(segmentEndMs).max() ?? segmentEndMs(last),
                    timeZoneID: first.recordedTimeZone ?? fallbackTimeZoneID,
                    isLive: openSegmentId != nil && last.segmentId == openSegmentId,
                    memberSegmentIds: slice.map(\.segmentId),
                    startReason: reason
                )
            )
        }

        func flush() {
            defer { members = [] }
            guard !members.isEmpty else { return }
            let found = ConversationBoundaryDetector.boundaries(
                members: members, evidence: evidence, policy: policy,
                semanticSplits: semanticSplits, blocked: joined)
            candidates.append(contentsOf: found.candidates)
            var start = 0
            var reason = runReason
            for cut in found.cuts where cut.index > start {
                emit(members[start..<cut.index], reason: reason)
                start = cut.index
                reason = cut.reason
            }
            emit(members[start...], reason: reason)
        }

        for meta in ordered {
            if let prev = members.last {
                let prevEnd = segmentEndMs(prev)
                let nextStart = segmentStartMs(meta)
                let chains =
                    nextStart - prevEnd < chainWindowMs
                    || (prev.streamId == meta.streamId && nextStart <= prevEnd)
                var structural: ConversationStartReason?
                if endsWithUserStop(prev) {
                    structural = .userStop
                } else if pauseFalls(between: prevEnd, and: nextStart, pauses: pauses) {
                    structural = .pause
                } else if !chains {
                    structural = .gap
                }
                // The user's decision wins both ways. `join` is how a Stop stops being
                // absolute: the app still splits (a Stop plainly means "end this"), and one tap
                // puts it back — durably, because the override is authoritative and the rebuild
                // reads it every time.
                switch overrides[meta.segmentId] {
                case .split: structural = .manual
                case .join: structural = nil
                case nil: break
                }
                if let structural {
                    flush()
                    runReason = structural
                }
            }
            members.append(meta)
        }
        flush()

        guard let previous, !previous.isEmpty else { return (result, candidates) }
        return (adoptStableIds(result, previous: previous), candidates)
    }

    /// Deterministic id adoption: in order, each fresh group takes the id of the previous
    /// conversation that contained its first member (unless another fresh group already
    /// claimed it — a split keeps the old id on its first half only).
    static func adoptStableIds(
        _ fresh: [GroupedConversation], previous: [GroupedConversation]
    ) -> [GroupedConversation] {
        var byMember: [String: String] = [:]
        for convo in previous {
            for member in convo.memberSegmentIds where byMember[member] == nil {
                byMember[member] = convo.id
            }
        }
        var used = Set<String>()
        return fresh.map { convo in
            var convo = convo
            if let firstMember = convo.memberSegmentIds.first,
                let inherited = byMember[firstMember], !used.contains(inherited) {
                convo.id = inherited
            }
            used.insert(convo.id)
            return convo
        }
    }

    // --- persistence --------------------------------------------------------------------------

    /// Idempotently replaces the derived `conversations`/`conversation_segments` tables in one
    /// transaction. Annotations/tags/follow-ups reference conversation ids by value and the
    /// ids are deterministic, so a rebuild leaves them attached.
    ///
    /// `segmentStates` mirrors each member's own `SegmentMeta.transcriptionState` into the
    /// derived table so the lifecycle aggregation can trust a durable transcript over a
    /// missing queue row (see the `v2` migration).
    public static func apply(
        _ conversations: [GroupedConversation],
        segmentStates: [String: TranscriptionState] = [:],
        in db: Database
    ) throws {
        try db.execute(sql: "DELETE FROM conversation_segments")
        try db.execute(sql: "DELETE FROM conversations")
        for convo in conversations {
            try db.execute(
                sql: """
                    INSERT INTO conversations (id, startMs, endMs, timezone, state, startReason)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    convo.id, convo.startMs, convo.endMs, convo.timeZoneID,
                    convo.isLive ? "live" : "closed", convo.startReason?.rawValue,
                ]
            )
            for (ordinal, segmentId) in convo.memberSegmentIds.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO conversation_segments
                            (conversationId, segmentId, ordinal, transcriptionState)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        convo.id, segmentId, ordinal, segmentStates[segmentId]?.rawValue,
                    ]
                )
            }
        }
    }

    /// Group + persist in one write. Reads the previous grouping from the DB first so ids stay
    /// stable across retention deletions of first members, and reads the user's boundary
    /// overrides so a hand-made split or merge survives every rebuild.
    ///
    @discardableResult
    public static func rebuild(
        segments: [SegmentMeta],
        pauses: [PauseInterval],
        openSegmentId: String?,
        fallbackTimeZoneID: String = TimeZone.current.identifier,
        evidence: [String: SegmentSpeechEvidence] = [:],
        policy: BoundaryPolicy = .default,
        db: AppDatabase
    ) async throws -> [GroupedConversation] {
        try await rebuildDetailed(
            segments: segments, pauses: pauses, openSegmentId: openSegmentId,
            fallbackTimeZoneID: fallbackTimeZoneID, evidence: evidence, policy: policy, db: db
        ).conversations
    }

    /// One rebuild's output: the grouping that was persisted, plus the joins that looked like
    /// boundaries but were left alone because the quiet was in the ambiguous band. The
    /// candidates are the semantic layer's whole work list; ignoring them is a supported way
    /// to run, and is what happens when no AI is configured.
    public struct RebuiltGrouping: Equatable, Sendable {
        public var conversations: [GroupedConversation]
        public var candidates: [BoundaryCandidate]

        public init(conversations: [GroupedConversation], candidates: [BoundaryCandidate]) {
            self.conversations = conversations
            self.candidates = candidates
        }
    }

    @discardableResult
    public static func rebuildDetailed(
        segments: [SegmentMeta],
        pauses: [PauseInterval],
        openSegmentId: String?,
        fallbackTimeZoneID: String = TimeZone.current.identifier,
        evidence: [String: SegmentSpeechEvidence] = [:],
        policy: BoundaryPolicy = .default,
        db: AppDatabase
    ) async throws -> RebuiltGrouping {
        try await db.writer.write { d in
            let previous = try fetchAll(d)
            let overrides = try BoundaryOverrideStore.fetchAll(d)
            let reviews = try BoundaryReviewStore.fetchAll(d)
            // A first pass with no semantic verdicts tells us which joins are candidates; the
            // cached verdicts that match those candidates then feed a second, final pass. Both
            // passes are pure, so this costs arithmetic and keeps the "same input ⇒ same ids"
            // guarantee intact.
            let probe = groupWithCandidates(
                segments: segments, pauses: pauses, openSegmentId: openSegmentId,
                fallbackTimeZoneID: fallbackTimeZoneID, previous: previous, evidence: evidence,
                overrides: overrides, policy: policy
            )
            var semanticSplits: Set<String> = []
            for candidate in probe.candidates {
                guard let review = reviews[candidate.newStartSegmentId], review.isBoundary else {
                    continue
                }
                if abs(review.quietMs - candidate.quietMs)
                    <= BoundaryReviewStore.quietDriftToleranceMs
                {
                    semanticSplits.insert(candidate.newStartSegmentId)
                }
            }
            let final = semanticSplits.isEmpty
                ? probe
                : groupWithCandidates(
                    segments: segments, pauses: pauses, openSegmentId: openSegmentId,
                    fallbackTimeZoneID: fallbackTimeZoneID, previous: previous,
                    evidence: evidence, overrides: overrides, policy: policy,
                    semanticSplits: semanticSplits)
            try apply(
                final.conversations,
                segmentStates: Dictionary(
                    segments.map { ($0.segmentId, $0.transcriptionState) },
                    uniquingKeysWith: { _, latest in latest }
                ),
                in: d
            )
            return RebuiltGrouping(
                conversations: final.conversations, candidates: probe.candidates)
        }
    }

    /// Reads the persisted grouping back (ordered by startMs, members by ordinal).
    public static func fetchAll(_ db: Database) throws -> [GroupedConversation] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, startMs, endMs, timezone, state, startReason FROM conversations
                ORDER BY startMs, id
                """
        )
        let memberRows = try Row.fetchAll(
            db,
            sql: """
                SELECT conversationId, segmentId FROM conversation_segments
                ORDER BY conversationId, ordinal
                """
        )
        var members: [String: [String]] = [:]
        for row in memberRows {
            members[row["conversationId"], default: []].append(row["segmentId"])
        }
        return rows.map { row in
            GroupedConversation(
                id: row["id"],
                startMs: row["startMs"],
                endMs: row["endMs"] ?? row["startMs"],
                timeZoneID: row["timezone"],
                isLive: (row["state"] as String) == "live",
                memberSegmentIds: members[row["id"]] ?? [],
                startReason: (row["startReason"] as String?).flatMap(
                    ConversationStartReason.init(rawValue:))
            )
        }
    }
}
