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
    /// Wall clock of the first thing said, where settled evidence knows it, and the first
    /// member's placement otherwise (`ConversationBoundaryDetector.displayExtent`).
    public var startMs: Int64
    /// Wall clock of the last thing said — NOT the container edge, which on this hardware
    /// over-reports by 41% because the watch's sample counter free-runs through a dropped BLE
    /// link. For a live conversation, and for anything not yet settled, this is still the
    /// last-flushed extent end; `isLive` (not a nil end) marks liveness so queries and
    /// coverage never have to special-case NULL.
    public var endMs: Int64
    /// IANA zone id — the first member's `recordedTimeZone`, falling back to the device's
    /// current zone (plan 6.4) when the member predates the field.
    public var timeZoneID: String
    /// True while the last member is the store's open segment.
    public var isLive: Bool
    /// The ordered pieces this conversation is made of: a range of each member segment's stored
    /// audio. The first and last pieces are usually partial; everything between them is whole.
    public var members: [ConversationMember]
    /// Ordered member segment ids — the segments this conversation has a piece of.
    public var memberSegmentIds: [String] { members.map(\.segmentId) }
    /// Why this conversation starts where it does — nil for the very first one in a rebuild,
    /// where nothing preceded it. Persisted so the UI can account for an automatic split
    /// instead of leaving the user to guess.
    public var startReason: ConversationStartReason?
    /// True while where this conversation starts or ends could still move: one of its two
    /// boundaries is a segmenter decision too recent to have been written down
    /// (`ConversationRunPlanner.commitLagMs`), or it is the end of the run being recorded into.
    /// Work that should be done ONCE per conversation — a final title, follow-up extraction —
    /// waits for this to clear, exactly as it waits for a live conversation to close. Not
    /// persisted: it is a property of this grouping pass, and a grouping read back from the
    /// database reads as settled.
    public var isProvisional: Bool

    public init(
        id: String, startMs: Int64, endMs: Int64, timeZoneID: String, isLive: Bool,
        members: [ConversationMember], startReason: ConversationStartReason? = nil,
        isProvisional: Bool = false
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.timeZoneID = timeZoneID
        self.isLive = isLive
        self.members = members
        self.startReason = startReason
        self.isProvisional = isProvisional
    }

    /// A conversation made of whole segments.
    public init(
        id: String, startMs: Int64, endMs: Int64, timeZoneID: String, isLive: Bool,
        memberSegmentIds: [String], startReason: ConversationStartReason? = nil
    ) {
        self.init(
            id: id, startMs: startMs, endMs: endMs, timeZoneID: timeZoneID, isLive: isLive,
            members: memberSegmentIds.map { ConversationMember(segmentId: $0) },
            startReason: startReason)
    }

    /// The piece of `segmentId` this conversation owns, if it owns any.
    public func member(_ segmentId: String) -> ConversationMember? {
        members.first { $0.segmentId == segmentId }
    }

    /// Whether the conversation owns the moment `mediaMs` into `segmentId`.
    public func contains(segmentId: String, mediaMs: Int64) -> Bool {
        members.contains { $0.segmentId == segmentId && $0.contains(mediaMs: mediaMs) }
    }
}

public enum ConversationGrouper {
    /// Segments with a start/end gap under this chain into one conversation (any stream id).
    public static let chainWindowMs: Int64 = 5 * 60 * 1000

    // --- segment wall-clock endpoints ---------------------------------------------------------

    /// Where this segment starts on the wall clock.
    ///
    /// **The diagnosis this comment used to carry was wrong, and it is worth recording why.** It
    /// blamed the watch: "the counter free-runs across reattach", and every downstream fix was
    /// built on that. Measured against 774 real sidecars, the firmware's time base is *accurate* —
    /// it captures `start_time_ms` once at stream birth, resends it verbatim on RESUME, and
    /// advances the counter through pauses so it stays a wall clock. The 598 segments that kept
    /// the firmware's value land within **±32 s** of their own `receivedAtMs`, across streams up
    /// to 24 h long.
    ///
    /// The corruption was the app's: `SegmentStore` overwrote `startTimeMs` with `receivedAtMs`
    /// on every RESUME and every 15-minute rotation while `firstSampleIndex` kept counting from
    /// stream birth — adding the whole elapsed stream twice. 100% of the future-shifted segments
    /// were on that branch (91 of 169, up to +24.36 h); zero on the birth-clock branch.
    ///
    /// `SegmentMeta.startWallMs` now repairs that shape on decode, so this delegates to it and
    /// the `receivedAtMs` clamp is a safety net rather than the load-bearing fix it had become.
    public static func segmentStartMs(_ meta: SegmentMeta) -> Int64 {
        meta.startWallMs
    }

    /// End = start + the wall time the sample extents span (quiet included — the watch keeps
    /// counting through VAD-suppressed silence, so a mostly-quiet 15 min segment really is
    /// 15 min long). Bounded by `closedAtMs`: the segment cannot still be recording after the
    /// phone closed it, which is what kept a watch-side index jump from claiming 15 h.
    ///
    /// This is deliberately NOT capped at `segmentAudioMs`, even though the two differ by 82 h
    /// across Roger's library. This value is a PLACEMENT: it says where the member's audio sits
    /// in wall time, and everything downstream — the chain window, gap spans, the transcript
    /// screen's clock — depends on that. Capping it was measured on the real library and made
    /// things worse: interior loss then reads as a gap BETWEEN segments, the 5-minute chain
    /// window fires on it, and the grouping picks up 7–12 extra false splits (against the
    /// hand-labelled non-boundaries) to gain one correct boundary. The phantom duration is a
    /// DISPLAY bug and is fixed where it belongs, in
    /// `ConversationBoundaryDetector.displayExtent`.
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

    /// The audio this member actually holds: `frameCount × frameDurationMs`. NOT the same as
    /// its wall span, and the difference is the whole phantom-duration bug — across the library
    /// the two differ by 82 h 15 m (41.4%), because the watch's sample counter keeps running
    /// while the BLE link is down. Used for the DISPLAYED extent of a conversation nobody spoke
    /// in (see `ConversationBoundaryDetector.displayExtent`); never for placement.
    public static func segmentAudioMs(_ meta: SegmentMeta) -> Int64 {
        let frames = max(meta.frameCount, 0)
        let perFrame = Int64(meta.frameDurationMs > 0 ? meta.frameDurationMs : 20)
        return frames * perFrame
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
    /// `overrides` are the user's own decisions about a segment's START and beat everything
    /// else, in both directions; `cutInputs` are the decisions about positions inside segments
    /// (the segmenter's settled cuts, and the person's splits and joins there).
    ///
    /// Inside a run — and the rules above leave whole days as one run — conversations start
    /// where `ConversationRunPlanner` says, which is no longer tied to segment joins. "A single
    /// segment is never split" therefore only holds with `policy.segmenter` off.
    public static func group(
        segments: [SegmentMeta],
        pauses: [PauseInterval],
        openSegmentId: String?,
        fallbackTimeZoneID: String = TimeZone.current.identifier,
        previous: [GroupedConversation]? = nil,
        evidence: [String: SegmentSpeechEvidence] = [:],
        overrides: [String: BoundaryDecision] = [:],
        policy: BoundaryPolicy = .default,
        cutInputs: ConversationCutInputs = .none,
        memo: GroupingMemo? = nil,
        nowMs: Int64 = .max
    ) -> [GroupedConversation] {
        groupDetailed(
            segments: segments, pauses: pauses, openSegmentId: openSegmentId,
            fallbackTimeZoneID: fallbackTimeZoneID, previous: previous, evidence: evidence,
            overrides: overrides, policy: policy, cutInputs: cutInputs, memo: memo,
            nowMs: nowMs
        ).conversations
    }

    /// One grouping: the conversations, and the segmenter cuts in it that are now old enough
    /// to be written down and held (`ConversationRunPlanner.commitLagMs`).
    public struct Grouping: Equatable, Sendable {
        public var conversations: [GroupedConversation]
        public var cutsToCommit: [ConversationCut: ConversationStartReason]
    }

    /// `group`, plus what should be committed.
    ///
    /// The structural rules decide which segments form one unbroken RUN; inside a run,
    /// `ConversationRunPlanner` decides where conversations start, at positions between turns
    /// rather than at segment joins. That second half is what replaced "a conversation is a set
    /// of whole segments": a cut driven by a change in the talk no longer has to be snapped to
    /// the nearest 15-minute rotation, which is what used to make cutting inside continuous
    /// speech impossible to do honestly.
    public static func groupDetailed(
        segments: [SegmentMeta],
        pauses: [PauseInterval],
        openSegmentId: String?,
        fallbackTimeZoneID: String = TimeZone.current.identifier,
        previous: [GroupedConversation]? = nil,
        evidence: [String: SegmentSpeechEvidence] = [:],
        overrides: [String: BoundaryDecision] = [:],
        policy: BoundaryPolicy = .default,
        cutInputs: ConversationCutInputs = .none,
        memo: GroupingMemo? = nil,
        nowMs: Int64 = .max
    ) -> Grouping {
        let ordered = segments.sorted { a, b in
            if a.receivedAtMs != b.receivedAtMs { return a.receivedAtMs < b.receivedAtMs }
            return a.segmentId < b.segmentId
        }
        let joined = Set(overrides.filter { $0.value == .join }.keys)

        // The structural runs, and why each starts.
        var runs: [(members: [SegmentMeta], reason: ConversationStartReason?)] = []
        var members: [SegmentMeta] = []
        var runReason: ConversationStartReason?
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
                    runs.append((members, runReason))
                    members = []
                    runReason = structural
                }
            }
            members.append(meta)
        }
        if !members.isEmpty { runs.append((members, runReason)) }

        var result: [GroupedConversation] = []
        var cutsToCommit: [ConversationCut: ConversationStartReason] = [:]
        for (index, run) in runs.enumerated() {
            // A run can still grow only while it is being recorded into: it is the last one and
            // holds the open segment. With nothing open, what is there is all there will be —
            // and treating a finished library's last conversation as still undecided would
            // leave it without its final title until the next time the watch is worn.
            //
            // "Nothing open" is not quite "over", though: every time the link to the watch
            // drops and comes back, one recording closes and the next opens a moment later IN
            // THE SAME RUN (anything inside the chain window continues it). A regroup that
            // lands in that gap must not declare the tail finished, title it and write its
            // cuts down, only to have it grow a few seconds later. So a run whose last
            // recording ended less than a chain window ago is still open-ended. `nowMs` is
            // `.max` for callers with no clock, for whom the library is simply what it is.
            let holdsOpenSegment =
                openSegmentId != nil && run.members.contains { $0.segmentId == openSegmentId }
            let endedAtMs = run.members.last.map { max(segmentEndMs($0), $0.closedAtMs ?? 0) }
            // (A clock that reads EARLIER than the recording's end is not a clock to reason
            // from — a test's, or a badly placed segment's — and says nothing about recency.)
            let mayStillChain =
                nowMs != .max
                && (endedAtMs.map { nowMs >= $0 && nowMs - $0 < chainWindowMs } ?? false)
            let isOpenEnded = index == runs.count - 1 && (holdsOpenSegment || mayStillChain)
            let planned = plannedRun(
                run.members, reason: run.reason, evidence: evidence, policy: policy,
                cutInputs: cutInputs, joinedSegments: joined, isOpenEnded: isOpenEnded,
                openSegmentId: openSegmentId, fallbackTimeZoneID: fallbackTimeZoneID, memo: memo)
            result.append(contentsOf: planned.conversations)
            cutsToCommit.merge(planned.cutsToCommit) { _, latest in latest }
        }

        guard let previous, !previous.isEmpty else {
            return Grouping(conversations: result, cutsToCommit: cutsToCommit)
        }
        return Grouping(
            conversations: adoptStableIds(result, previous: previous), cutsToCommit: cutsToCommit)
    }

    /// One run's conversations. Memoised on everything the answer depends on, because regroup
    /// runs over the whole library on every pipeline pass and a day that has not changed must
    /// cost a hash, not a search.
    static func plannedRun(
        _ metas: [SegmentMeta], reason: ConversationStartReason?,
        evidence: [String: SegmentSpeechEvidence], policy: BoundaryPolicy,
        cutInputs: ConversationCutInputs, joinedSegments: Set<String>, isOpenEnded: Bool,
        openSegmentId: String?, fallbackTimeZoneID: String, memo: GroupingMemo?
    ) -> Grouping {
        var key: Int?
        if let memo {
            var hasher = Hasher()
            hasher.combine(reason)
            hasher.combine(policy)
            hasher.combine(isOpenEnded)
            hasher.combine(fallbackTimeZoneID)
            for meta in metas {
                let id = meta.segmentId
                hasher.combine(id)
                hasher.combine(meta.startWallMs)
                hasher.combine(segmentEndMs(meta))
                hasher.combine(meta.frameCount)
                hasher.combine(meta.gaps.count)
                hasher.combine(meta.transcriptionState)
                hasher.combine(meta.recordedTimeZone)
                hasher.combine(id == openSegmentId)
                hasher.combine(joinedSegments.contains(id))
                if let item = evidence[id] {
                    hasher.combine(item.isSettled)
                    hasher.combine(item.fingerprint)
                } else {
                    hasher.combine(0)
                }
                if let committed = cutInputs.committed[id] {
                    for media in committed.keys.sorted() {
                        hasher.combine(media)
                        hasher.combine(committed[media])
                    }
                }
                hasher.combine(1)
                for media in (cutInputs.splits[id] ?? []).sorted() { hasher.combine(media) }
                hasher.combine(2)
                for media in (cutInputs.joins[id] ?? []).sorted() { hasher.combine(media) }
            }
            // Few, and a span can reach into a run from outside it: hash them all.
            for span in cutInputs.joinSpans {
                hasher.combine(span.from)
                hasher.combine(span.to)
            }
            let value = hasher.finalize()
            if let hit = memo.lookup(value) { return hit }
            key = value
        }

        let plan = ConversationRunPlanner.plan(
            metas: metas, evidence: evidence, policy: policy, inputs: cutInputs,
            joinedSegments: joinedSegments, isOpenEnded: isOpenEnded)
        let members = ConversationRunPlanner.members(metas, evidence: evidence)
        let runEnd = RunPosition(seg: metas.count, mediaMs: 0)
        let edges = [RunPosition(seg: 0, mediaMs: 0)] + plan.cuts.map(\.position) + [runEnd]
        var conversations: [GroupedConversation] = []
        var cutsToCommit: [ConversationCut: ConversationStartReason] = [:]

        for unit in 0..<(edges.count - 1) {
            let lower = edges[unit]
            let upper = edges[unit + 1]
            var pieces: [PlacedPiece] = []
            for seg in lower.seg..<min(upper.seg + 1, metas.count) {
                let start = seg == lower.seg ? lower.mediaMs : 0
                let end: Int64? = seg == upper.seg ? upper.mediaMs : nil
                if let end, end <= start { continue }
                pieces.append(
                    PlacedPiece(
                        seg: seg, member: members[seg],
                        piece: ConversationMember(
                            segmentId: metas[seg].segmentId, startMediaMs: start,
                            endMediaMs: end)))
            }
            guard let first = pieces.first, let last = pieces.last else { continue }
            let turns = plan.turns[turnRange(from: lower, to: upper, in: plan.turns)]
            let extent = unitExtent(pieces: pieces, turns: turns)
            let start = ConversationCut(
                segmentId: first.piece.segmentId, mediaMs: first.piece.startMediaMs ?? 0)
            // A boundary is fixed unless it is a segmenter decision still inside the lag.
            func isFixed(_ cut: PlannedCut) -> Bool { cut.kind != .segmenter || cut.shouldCommit }
            let startFixed = unit == 0 || isFixed(plan.cuts[unit - 1])
            let endFixed = unit < plan.cuts.count ? isFixed(plan.cuts[unit]) : !isOpenEnded
            conversations.append(
                GroupedConversation(
                    id: start.conversationId,
                    startMs: extent.startMs,
                    endMs: extent.endMs,
                    timeZoneID: first.member.meta.recordedTimeZone ?? fallbackTimeZoneID,
                    isLive: openSegmentId != nil && last.piece.segmentId == openSegmentId
                        && last.piece.endMediaMs == nil,
                    members: pieces.map(\.piece),
                    startReason: unit == 0 ? reason : plan.cuts[unit - 1].reason,
                    isProvisional: !(startFixed && endFixed)
                ))
            if unit > 0, plan.cuts[unit - 1].shouldCommit {
                cutsToCommit[start] = plan.cuts[unit - 1].reason
            }
        }
        let grouping = Grouping(conversations: conversations, cutsToCommit: cutsToCommit)
        if let memo, let key { memo.store(key, grouping) }
        return grouping
    }

    /// The turns of a run that start inside `[lower, upper)`.
    static func turnRange(from lower: RunPosition, to upper: RunPosition, in turns: [RunTurn])
        -> Range<Int>
    {
        let low = turns.partitioningIndex {
            RunPosition(seg: $0.seg, mediaMs: $0.mediaStartMs) >= lower
        }
        let high = turns.partitioningIndex {
            RunPosition(seg: $0.seg, mediaMs: $0.mediaStartMs) >= upper
        }
        return low..<max(high, low)
    }

    /// One piece of a conversation with the run member it is cut from.
    struct PlacedPiece {
        /// The member's index in its run — what `RunTurn.seg` refers to.
        var seg: Int
        var member: ConversationRunPlanner.Member
        var piece: ConversationMember

        var wallStartMs: Int64 {
            piece.startMediaMs.map { member.wallStart(ofPieceAt: $0) } ?? member.startWallMs
        }
        /// To the end of the member — which, for a member nobody has heard yet, is the end of
        /// the audio it holds rather than of a wall span its records cannot account for.
        var wallEndMs: Int64 {
            piece.endMediaMs.map { member.wallEnd(ofPieceTo: $0) }
                ?? (member.isSettled ? member.endWallMs : member.heardEndWallMs)
        }
    }

    /// The extent a conversation DISPLAYS: first word to last word — the same rule as
    /// `ConversationBoundaryDetector.displayExtent`, over pieces instead of whole members.
    ///
    /// Trimming only ever eats SETTLED silence, from the outside in, and stops at the first
    /// piece that could still change its mind, so a live conversation keeps its container end
    /// and a pending transcript never shortens anything. Where nothing was ever said and we
    /// know it, the honest length is the audio the pieces hold.
    static func unitExtent(pieces: [PlacedPiece], turns: ArraySlice<RunTurn>)
        -> (startMs: Int64, endMs: Int64)
    {
        guard let first = pieces.first else { return (0, 0) }
        let containerStart = first.wallStartMs
        let containerEnd = max(pieces.map(\.wallEndMs).max() ?? containerStart, containerStart)

        var spoken: [Int: (first: Int64, last: Int64)] = [:]
        for turn in turns {
            if let entry = spoken[turn.seg] {
                spoken[turn.seg] = (
                    min(entry.first, turn.wallStartMs), max(entry.last, turn.wallEndMs)
                )
            } else {
                spoken[turn.seg] = (turn.wallStartMs, turn.wallEndMs)
            }
        }
        var start: Int64?
        for piece in pieces {
            guard piece.member.isSettled else {
                start = piece.wallStartMs
                break
            }
            if let words = spoken[piece.seg] {
                start = words.first
                break
            }
        }
        var end: Int64?
        for piece in pieces.reversed() {
            guard piece.member.isSettled else {
                end = piece.wallEndMs
                break
            }
            if let words = spoken[piece.seg] {
                end = words.last
                break
            }
        }
        // Members overlap in wall time, so the first speaking piece from each end is not always
        // the one holding the extreme word; widening onto the real extremes cannot shorten
        // anything.
        if let earliest = spoken.values.map(\.first).min() {
            start = min(start ?? earliest, earliest)
        }
        if let latest = spoken.values.map(\.last).max() { end = max(end ?? latest, latest) }
        guard start != nil || end != nil else {
            let audio = pieces.reduce(Int64(0)) { total, item in
                let range = item.piece.mediaRange(mediaSpanMs: item.member.mediaSpanMs)
                return total + (range.upperBound - range.lowerBound)
            }
            return (containerStart, min(containerEnd, containerStart + audio))
        }
        let clampedStart = min(max(start ?? containerStart, containerStart), containerEnd)
        return (clampedStart, max(min(end ?? containerEnd, containerEnd), clampedStart))
    }

    /// Deterministic id adoption: in order, each fresh conversation takes the id of the previous
    /// conversation that contained the moment it now starts at — unless another fresh one
    /// already claimed it, so a split keeps the old id on its first half only. This is what
    /// keeps an id stable when retention removes a conversation's first member, and what keeps
    /// the first part of a conversation that has just been divided under the id it had.
    static func adoptStableIds(
        _ fresh: [GroupedConversation], previous: [GroupedConversation]
    ) -> [GroupedConversation] {
        var bySegment: [String: [(member: ConversationMember, id: String)]] = [:]
        for convo in previous {
            for member in convo.members {
                bySegment[member.segmentId, default: []].append((member, convo.id))
            }
        }
        var used = Set<String>()
        // Ids that fresh conversations hold by right (their own start) are never handed to
        // another one, whatever order they come in.
        let own = Set(fresh.map(\.id))
        return fresh.map { convo in
            var convo = convo
            if let first = convo.members.first,
                let inherited = bySegment[first.segmentId]?.first(where: {
                    $0.member.contains(mediaMs: first.startMediaMs ?? 0)
                })?.id,
                !used.contains(inherited), inherited == convo.id || !own.contains(inherited)
            {
                convo.id = inherited
            }
            used.insert(convo.id)
            return convo
        }
    }

    // --- persistence --------------------------------------------------------------------------

    /// Persists the grouping — and writes NOTHING when it already matches what is stored.
    ///
    /// Returns what, if anything, was written. This used to delete and re-insert every row on
    /// every call, which on a phone meant the whole grouping was rewritten every 5 s, identical
    /// or not. Every `ValueObservation` on these tables — the Library, Today, the Settings
    /// storage line, the widget snapshot — fired on each rewrite and refetched, so a pipeline
    /// pass that found nothing to do still cost the app a full refresh of every screen's data,
    /// 12 times a minute, for as long as the phone sat on a charger. A rebuild that changes
    /// nothing must write nothing (the 2026-09-09 rule, one layer down).
    ///
    /// The two halves of the answer are kept apart because they mean different things to the
    /// stages behind the regroup. `wrote` is the DB's view: rows differed and were replaced.
    /// `structureChanged` is the AI layer's view: a conversation appeared, gained or lost a
    /// piece, a piece's range or transcription state moved, or a conversation went live or
    /// closed. The live conversation's extent (`endMs`) advances on every pass while the watch
    /// is recording, so `wrote` is true almost always; nothing the AI stages read has changed
    /// when that is the only difference.
    ///
    /// `segmentStates` mirrors each member's own `SegmentMeta.transcriptionState` into the
    /// derived table so the lifecycle aggregation can trust a durable transcript over a
    /// missing queue row (see the `v2` migration). `silentPieces` are the pieces of a
    /// transcribed segment in which nobody spoke: they are written as `NoSpeech`, because that
    /// is what the PIECE is, whatever the rest of its segment holds.
    public struct ApplyOutcome: Equatable, Sendable {
        public var wrote: Bool
        public var structureChanged: Bool
    }

    @discardableResult
    public static func apply(
        _ conversations: [GroupedConversation],
        segmentStates: [String: TranscriptionState] = [:],
        silentPieces: Set<ConversationMember> = [],
        in db: Database
    ) throws -> ApplyOutcome {
        func state(_ member: ConversationMember) -> String? {
            guard let state = segmentStates[member.segmentId] else { return nil }
            if state == .complete, silentPieces.contains(member) {
                return TranscriptionState.noSpeech.rawValue
            }
            return state.rawValue
        }
        let stored = try storedImage(db)
        let next = image(of: conversations, state: state)
        // The archive sync's marks, in this transaction: what changed, what went away, and
        // whose provisional flag flipped (which no stored row records). Before the early
        // return, because a flag can flip on a pass that writes nothing else.
        try ArchiveOutboxGrouping.note(
            stored: stored, next: next, conversations: conversations, in: db)
        if stored == next { return ApplyOutcome(wrote: false, structureChanged: false) }
        let structureChanged = structure(of: stored) != structure(of: next)
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
            for (ordinal, member) in convo.members.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO conversation_segments
                            (conversationId, segmentId, ordinal, transcriptionState,
                             startMediaMs, endMediaMs)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        convo.id, member.segmentId, ordinal, state(member),
                        member.startMediaMs, member.endMediaMs,
                    ]
                )
            }
        }
        return ApplyOutcome(wrote: true, structureChanged: structureChanged)
    }

    /// Exactly the columns `apply` writes, in the order it writes them, so equality means
    /// "the write would be a no-op" and nothing else.
    private typealias StoredImage = [[String?]]

    /// The image with the extent columns (startMs, endMs) blanked — what is left is the
    /// membership, the ranges and the states, which is what `structureChanged` compares.
    private static func structure(of image: StoredImage) -> StoredImage {
        image.map { row in
            guard row.first == "c" else { return row }
            var r = row
            r[2] = nil
            r[3] = nil
            return r
        }
    }

    private static func image(
        of conversations: [GroupedConversation], state: (ConversationMember) -> String?
    ) -> StoredImage {
        var out: StoredImage = []
        for convo in conversations.sorted(by: {
            $0.startMs == $1.startMs ? $0.id < $1.id : $0.startMs < $1.startMs
        }) {
            out.append([
                "c", convo.id, String(convo.startMs), String(convo.endMs), convo.timeZoneID,
                convo.isLive ? "live" : "closed", convo.startReason?.rawValue,
            ])
            for (ordinal, member) in convo.members.enumerated() {
                out.append([
                    "s", convo.id, member.segmentId, String(ordinal), state(member),
                    member.startMediaMs.map { String($0) }, member.endMediaMs.map { String($0) },
                ])
            }
        }
        return out
    }

    private static func storedImage(_ db: Database) throws -> StoredImage {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, startMs, endMs, timezone, state, startReason FROM conversations
                ORDER BY startMs, id
                """)
        let memberRows = try Row.fetchAll(
            db,
            sql: """
                SELECT conversationId, segmentId, ordinal, transcriptionState,
                    startMediaMs, endMediaMs
                FROM conversation_segments ORDER BY conversationId, ordinal
                """)
        var members: [String: [[String?]]] = [:]
        for row in memberRows {
            let conversationId: String = row["conversationId"]
            members[conversationId, default: []].append([
                "s", conversationId, row["segmentId"], String(row["ordinal"] as Int),
                row["transcriptionState"],
                (row["startMediaMs"] as Int64?).map { String($0) },
                (row["endMediaMs"] as Int64?).map { String($0) },
            ])
        }
        var out: StoredImage = []
        for row in rows {
            let id: String = row["id"]
            let startMs: Int64 = row["startMs"]
            let endMs: Int64? = row["endMs"]
            out.append([
                "c", id, String(startMs), String(endMs ?? startMs), row["timezone"],
                row["state"], row["startReason"],
            ])
            out.append(contentsOf: members[id] ?? [])
        }
        return out
    }

    /// Group + persist in one write. Reads the previous grouping from the DB first so ids stay
    /// stable across retention deletions of first members, and reads the user's boundary
    /// overrides so a hand-made split or merge survives every rebuild.
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

    /// One rebuild's output.
    public struct RebuiltGrouping: Equatable, Sendable {
        public var conversations: [GroupedConversation]
        /// Always empty. The joins the retired semantic reviewer used to be asked about no
        /// longer exist as a category: the segmenter decides inside talk, from the talk.
        public var candidates: [BoundaryCandidate]
        /// Whether the persisted grouping differs from before this rebuild — false means the
        /// inputs the grouping is derived from (segments, their states, pauses, the open
        /// segment, overrides and cuts) produced exactly what was already stored, and nothing
        /// was written.
        public var changed: Bool
        /// Whether the membership, a piece's range or state, or a live/closed state changed —
        /// as opposed to only the live conversation's extent creeping forward. See
        /// `ApplyOutcome`.
        public var structureChanged: Bool
        /// The grouping as it was before this rebuild, for whoever has to move records from a
        /// conversation that no longer exists to the one that now holds its start
        /// (`ConversationReconciler`). Empty when nothing structural changed.
        public var previous: [GroupedConversation]

        public init(
            conversations: [GroupedConversation], candidates: [BoundaryCandidate] = [],
            changed: Bool = true, structureChanged: Bool = true,
            previous: [GroupedConversation] = []
        ) {
            self.conversations = conversations
            self.candidates = candidates
            self.changed = changed
            self.structureChanged = structureChanged
            self.previous = previous
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
        memo: GroupingMemo? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        db: AppDatabase
    ) async throws -> RebuiltGrouping {
        try await db.writer.write { d in
            let previous = try fetchAll(d)
            var overrides = try BoundaryOverrideStore.fetchAll(d)
            let cutInputs = try ConversationCutStore.fetchInputs(d, into: &overrides)
            let grouping = groupDetailed(
                segments: segments, pauses: pauses, openSegmentId: openSegmentId,
                fallbackTimeZoneID: fallbackTimeZoneID, previous: previous, evidence: evidence,
                overrides: overrides, policy: policy, cutInputs: cutInputs, memo: memo,
                nowMs: nowMs)
            try ConversationCutStore.commit(grouping.cutsToCommit, atMs: nowMs, in: d)

            // A piece of a transcribed segment that holds none of its turns is a silent piece.
            var silent = Set<ConversationMember>()
            for conversation in grouping.conversations {
                for member in conversation.members where !member.isWhole {
                    guard let speech = evidence[member.segmentId],
                        speech.isSettled
                    else { continue }
                    if !speech.speech.contains(where: { member.contains(mediaMs: $0.startMs) }) {
                        silent.insert(member)
                    }
                }
            }
            let outcome = try apply(
                grouping.conversations,
                segmentStates: Dictionary(
                    segments.map { ($0.segmentId, $0.transcriptionState) },
                    uniquingKeysWith: { _, latest in latest }
                ),
                silentPieces: silent,
                in: d
            )
            return RebuiltGrouping(
                conversations: grouping.conversations, changed: outcome.wrote,
                structureChanged: outcome.structureChanged,
                previous: outcome.structureChanged ? previous : [])
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
                SELECT conversationId, segmentId, startMediaMs, endMediaMs
                FROM conversation_segments ORDER BY conversationId, ordinal
                """
        )
        var members: [String: [ConversationMember]] = [:]
        for row in memberRows {
            members[row["conversationId"], default: []].append(
                ConversationMember(
                    segmentId: row["segmentId"], startMediaMs: row["startMediaMs"],
                    endMediaMs: row["endMediaMs"]))
        }
        return rows.map { row in
            GroupedConversation(
                id: row["id"],
                startMs: row["startMs"],
                endMs: row["endMs"] ?? row["startMs"],
                timeZoneID: row["timezone"],
                isLive: (row["state"] as String) == "live",
                members: members[row["id"]] ?? [],
                startReason: (row["startReason"] as String?).flatMap(
                    ConversationStartReason.init(rawValue:))
            )
        }
    }
}

/// Remembers each run's conversations between regroups, keyed on a hash of everything the
/// answer depends on. One per `EnrichmentService`; safe to share across tasks.
public final class GroupingMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int: ConversationGrouper.Grouping] = [:]
    /// Runs seen since the last sweep: entries not seen in a whole regroup are dropped.
    private var seen = Set<Int>()

    public init() {}

    func lookup(_ key: Int) -> ConversationGrouper.Grouping? {
        lock.lock()
        defer { lock.unlock() }
        seen.insert(key)
        return entries[key]
    }

    func store(_ key: Int, _ value: ConversationGrouper.Grouping) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = value
        seen.insert(key)
        if entries.count > 4_096 {
            entries = entries.filter { seen.contains($0.key) }
            seen.removeAll()
        }
    }

    /// Searches actually run (not answered from memory) — for the tests that pin "an unchanged
    /// library costs nothing".
    public var storedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
