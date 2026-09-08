import Foundation
import SegmentStore
import WireProtocol

// Where a conversation ENDS (plan Part 3: "AI topic-splitting within one long chain is a
// post-v1 refinement"). This file is that refinement's structural half; the semantic half is
// `Intelligence/BoundaryReviewer.swift` and is strictly optional.
//
// WHY A SECOND LAYER AT ALL — measured, not assumed. Over Roger's real library (765 segment
// metas + 591 durable transcripts, 2026-06-12 → 2026-09-08) the v1 rules produce 210
// conversations with a median of 15 min but a p90 of 2 h 44 m and a longest of 17 h 31 m. The
// reason the 5-minute chain window never fires inside those monsters is that it looks at the
// wrong silence: of the 555 joins INSIDE those conversations, 370 abut to the second (a
// rotation hands straight over) and not one exceeds 5 minutes. The watch keeps counting through
// quiet, so the quiet is INSIDE the segments, not between them, and the only way to see it is
// the transcript.
//
// The three signals that were considered and rejected, so they are not tried again:
//  - `GapReason.silenceSuppressed` (VAD-skipped audio). Zero occurrences in the whole library:
//    the watch's gap records are spool overflow (5016), sequence skips (2690), transport reset
//    (101) and power save (4). There is no metadata-level "quiet" to read.
//  - Diarization speaker sets. Labels are assigned per SEGMENT by the provider, so "speaker 1"
//    in one 15-minute rotation is not "speaker 1" in the next; consecutive members of one
//    unbroken conversation routinely jump from {1,2,3} to {2,3,4,5,6}. A speaker-set change is
//    noise until identities are resolved across segments.
//  - A hard cap on conversation length. It would cut mid-sentence, and the cut point would be
//    an arbitrary 15-minute rotation boundary rather than anything the person experienced.
//
// What is left, and what this file implements: a conversation ends where a long stretch of the
// record contains no speech. Two thresholds, because the evidence says the middle is genuinely
// ambiguous (see `BoundaryPolicy`).

/// One run of speech inside a member segment, in the transcript's own clock (milliseconds from
/// the start of that segment's stored audio) — exactly what `SegmentTranscript.segments`
/// carries, so building evidence is a `map`.
public struct SpeechSpan: Equatable, Sendable {
    public var startMs: Int64
    public var endMs: Int64

    public init(startMs: Int64, endMs: Int64) {
        self.startMs = startMs
        self.endMs = max(endMs, startMs)
    }
}

/// What we know about speech in one member — and, critically, whether we know it YET.
///
/// `isSettled` is the whole defence against the trap the feature is most likely to fall into:
/// watch audio is spooled and backfills hours late, transcription lags behind capture by
/// minutes to days, and a segment that has simply not been transcribed yet looks exactly like a
/// segment in which nobody spoke. A boundary is only ever decided from settled members;
/// anything else DEFERS. Deferring is free because grouping is derived state — the next rebuild
/// after the transcript lands makes the same decision with better evidence.
public struct SegmentSpeechEvidence: Equatable, Sendable {
    public var segmentId: String
    /// True only when this member can no longer change our mind about where speech was.
    public var isSettled: Bool
    /// Speech runs in the member's own clock. Empty for a settled member in which nobody spoke.
    public var speech: [SpeechSpan]

    public init(segmentId: String, isSettled: Bool, speech: [SpeechSpan]) {
        self.segmentId = segmentId
        self.isSettled = isSettled
        self.speech = speech
    }

    /// The settling rule, in one place.
    ///
    /// `transcriptSpeech == nil` means "no durable transcript file for this segment". Note that
    /// `.complete` WITHOUT a transcript is deliberately unsettled: the meta claiming success
    /// while the file is missing is a bookkeeping bug, and inferring silence from a bug is how
    /// you permanently split a conversation that was never quiet.
    ///
    /// `.failed` and `.disabled` are unsettled on purpose too. Both are retried — `.disabled`
    /// explicitly becomes eligible again the moment a provider is usable — so treating either
    /// as "definitively abandoned" would turn a provider outage into a wave of wrong splits.
    /// The consequence is honest and intended: with transcription off, this layer does nothing
    /// and grouping is exactly what it was before.
    public static func of(
        _ meta: SegmentMeta, transcriptSpeech: [SpeechSpan]?
    ) -> SegmentSpeechEvidence {
        let closed = meta.closeReason != nil
        switch meta.transcriptionState {
        case .noSpeech:
            return SegmentSpeechEvidence(
                segmentId: meta.segmentId, isSettled: closed, speech: [])
        case .complete:
            guard let transcriptSpeech else {
                return SegmentSpeechEvidence(
                    segmentId: meta.segmentId, isSettled: false, speech: [])
            }
            return SegmentSpeechEvidence(
                segmentId: meta.segmentId, isSettled: closed, speech: transcriptSpeech)
        case .pending, .running, .uploading, .failed, .disabled:
            return SegmentSpeechEvidence(
                segmentId: meta.segmentId, isSettled: false, speech: transcriptSpeech ?? [])
        }
    }
}

/// Why a conversation starts where it does. Persisted with the conversation so the UI can say
/// it out loud — an automatic split the user cannot account for is worse than no split.
public enum ConversationStartReason: String, Sendable, Codable, CaseIterable {
    /// More than the chain window with no audio at all between two segments (the v1 rule).
    case gap
    /// The previous segment ended with an explicit Stop.
    case userStop
    /// A pause-journal interval falls between the segments.
    case pause
    /// A long settled stretch of the record with nothing said in it.
    case quiet
    /// Same, but the stretch was mostly MISSING audio rather than known-quiet. Never conflated
    /// with `quiet`: one is calm, the other is a hole in the record.
    case interrupted
    /// The semantic reviewer judged a candidate boundary to be a real change of subject/people.
    case topicChange
    /// The user split here by hand.
    case manual
}

/// The user's standing decision about one join, which always beats every automatic rule.
///
/// Keyed by the segment that FOLLOWS the join, because segment ids are the only stable thing
/// across a rebuild — conversation ids are derived and change when a split moves.
public enum BoundaryDecision: String, Sendable, Codable, CaseIterable {
    /// Start a new conversation at this segment.
    case split
    /// Keep this segment with the previous conversation, whatever the rules say. This is the
    /// answer to "a manual Stop is a strong signal but not an absolute one": rather than
    /// guessing when a stop-then-resume was really the same conversation, the app splits (which
    /// is what a Stop plainly means) and offers one tap to undo it.
    case join
}

/// Tunables. Conservative by default; every number below is justified by the same measured
/// library, and the two thresholds exist because the middle band is genuinely ambiguous.
///
/// Reading 93 boundary candidates by hand:
///  - **≥ 25 min of no speech**: every single one of the 29 stretches at or above 25 minutes is
///    a real boundary — a different room, different people, a flight, a night's sleep. This is
///    `quietSplitMs`, and it needs no AI.
///  - **8–25 min**: roughly half. "Right. / And the next part is…" six minutes later is one
///    conversation; "…time to put the kettle on" → "Okay, let me check the weather report"
///    six minutes later is two. Nothing structural separates them, so this band is only ever a
///    CANDIDATE: with the semantic reviewer off it does not split at all.
///  - **< 8 min**: dominated by ordinary pauses inside a conversation. Never a boundary.
public struct BoundaryPolicy: Equatable, Sendable {
    /// A settled no-speech stretch at least this long always ends the conversation.
    public var quietSplitMs: Int64
    /// A settled no-speech stretch at least this long is offered to the semantic reviewer.
    /// Below `quietSplitMs` nothing happens without a verdict.
    public var quietCandidateMs: Int64
    /// A stretch with more than this share of MISSING audio is treated as loss-dominated.
    public var lossDominanceFraction: Double
    /// Loss-dominated stretches need this multiple of the thresholds above. Missing audio is
    /// evidence of our ignorance, not evidence that nobody spoke — and a spool backfill can
    /// still shrink the hole later, which would un-split the conversation on the next rebuild
    /// and orphan whatever the user had tagged on the second half. Twice as much dead air
    /// before we act on it.
    public var lossThresholdMultiplier: Double

    public init(
        quietSplitMs: Int64 = 25 * 60 * 1000,
        quietCandidateMs: Int64 = 8 * 60 * 1000,
        lossDominanceFraction: Double = 0.5,
        lossThresholdMultiplier: Double = 2
    ) {
        self.quietSplitMs = quietSplitMs
        self.quietCandidateMs = quietCandidateMs
        self.lossDominanceFraction = lossDominanceFraction
        self.lossThresholdMultiplier = lossThresholdMultiplier
    }

    public static let `default` = BoundaryPolicy()

    /// v1 behaviour: structural rules only, no quiet layer at all. Used by callers that have no
    /// transcript evidence to give, and by the tests that pin the old rules.
    public static let structuralOnly = BoundaryPolicy(
        quietSplitMs: .max, quietCandidateMs: .max)
}

/// A join that looks like a boundary but is not certain enough to act on alone — the input to
/// the optional semantic layer. Carries no transcript text: `Intelligence` fills that in.
public struct BoundaryCandidate: Equatable, Sendable {
    /// The member that would START the new conversation — and the key every verdict is
    /// recorded under, because it is the stable identity of this join.
    public var newStartSegmentId: String
    /// The member that would END the previous conversation.
    public var previousEndSegmentId: String
    /// Wall clock of the join itself.
    public var atMs: Int64
    /// How long the record went without speech around this join.
    public var quietMs: Int64
    /// How much of that stretch was missing audio rather than known-quiet, 0…1.
    public var lossFraction: Double
    /// The member holding the last words spoken BEFORE the silence, and the first words spoken
    /// after it. Not the same as the two members either side of the join: a silence long enough
    /// to be a candidate usually swallows whole members, and those are exactly the ones with no
    /// text to read. This is what the semantic layer should quote from.
    public var lastSpokenSegmentId: String?
    public var nextSpokenSegmentId: String?

    public init(
        newStartSegmentId: String, previousEndSegmentId: String, atMs: Int64, quietMs: Int64,
        lossFraction: Double, lastSpokenSegmentId: String? = nil,
        nextSpokenSegmentId: String? = nil
    ) {
        self.newStartSegmentId = newStartSegmentId
        self.previousEndSegmentId = previousEndSegmentId
        self.atMs = atMs
        self.quietMs = quietMs
        self.lossFraction = lossFraction
        self.lastSpokenSegmentId = lastSpokenSegmentId
        self.nextSpokenSegmentId = nextSpokenSegmentId
    }
}

/// One cut inside a structurally-chained run of members.
struct BoundaryCut: Equatable {
    /// Index of the member that starts the new conversation.
    var index: Int
    var reason: ConversationStartReason
}

/// Pure, deterministic detection of quiet boundaries inside one chained run of segments.
/// No IO, no clock, no AI — the same members and evidence always yield the same cuts.
public enum ConversationBoundaryDetector {

    /// Wall-clock speech runs for one member, clamped into the member's own span.
    ///
    /// The transcript's clock counts stored audio, while the member's span is wall time, so the
    /// two drift by however much the member lost. Clamping bounds the error at one member's
    /// length (≤ ~20 min in practice) and, more importantly, keeps a drifted timestamp from
    /// inventing quiet outside the segment it came from. Every threshold here is far larger
    /// than that drift.
    static func speechSpansMs(_ meta: SegmentMeta, _ evidence: SegmentSpeechEvidence?)
        -> [(Int64, Int64)]
    {
        guard let evidence, !evidence.speech.isEmpty else { return [] }
        let start = ConversationGrouper.segmentStartMs(meta)
        let span = max(ConversationGrouper.segmentEndMs(meta) - start, 0)
        return evidence.speech.map { run in
            let a = min(max(run.startMs, 0), span)
            let b = min(max(run.endMs, a), span)
            return (start + a, start + b)
        }
    }

    /// Wall-clock stretches of MISSING audio inside one member. VAD-suppressed silence
    /// (`GapReason.silenceSuppressed`) is quiet, not loss, and is deliberately excluded — the
    /// product rule that loss is always explicit and quiet is never framed as loss.
    ///
    /// Anchored on `segmentStartMs` (not `startTimeMs + sampleIndex`) for the same reason the
    /// grouper is: the watch's sample counter free-runs across reattach, so the raw form places
    /// gaps hours into the future.
    static func lossSpansMs(_ meta: SegmentMeta) -> [(Int64, Int64)] {
        guard let first = meta.firstSampleIndex, !meta.gaps.isEmpty else { return [] }
        let rate = UInt64(meta.sampleRateHz > 0 ? meta.sampleRateHz : 16_000)
        let start = ConversationGrouper.segmentStartMs(meta)
        let end = ConversationGrouper.segmentEndMs(meta)
        let frameSamples = UInt64(max(meta.frameSamples, 1))
        return meta.gaps.compactMap { gap in
            if let raw = gap.reasonRaw, let reason = GapReason(rawValue: UInt8(clamping: raw)),
                reason.isSilence
            {
                return nil
            }
            guard gap.firstMissingSampleIndex >= first else { return nil }
            let offset = Int64((gap.firstMissingSampleIndex - first) * 1000 / rate)
            let length = Int64(UInt64(gap.missingFrameCount) * frameSamples * 1000 / rate)
            let a = min(max(start + offset, start), end)
            let b = min(max(a + length, a), end)
            return b > a ? (a, b) : nil
        }
    }

    /// A maximal run of the conversation's wall span in which nothing was said.
    struct QuietStretch: Equatable {
        var startMs: Int64
        var endMs: Int64
        /// No speech anywhere before it in this run.
        var isLeading: Bool
        /// No speech anywhere after it in this run.
        var isTrailing: Bool
        /// Members holding the words either side of the silence (nil at the run's edges).
        var lastSpokenSegmentId: String?
        var nextSpokenSegmentId: String?
        var durationMs: Int64 { endMs - startMs }
    }

    /// Maximal no-speech stretches over `[runStart, runEnd]`, including the leading stretch
    /// before the first word and the trailing stretch after the last.
    static func quietStretches(
        members: [SegmentMeta], evidence: [String: SegmentSpeechEvidence]
    ) -> [QuietStretch] {
        guard let first = members.first else { return [] }
        let runStart = ConversationGrouper.segmentStartMs(first)
        let runEnd = members.map(ConversationGrouper.segmentEndMs).max() ?? runStart
        var marks: [(start: Int64, end: Int64, segmentId: String)] = []
        for meta in members {
            marks.append(
                contentsOf: speechSpansMs(meta, evidence[meta.segmentId]).map {
                    (start: $0.0, end: $0.1, segmentId: meta.segmentId)
                })
        }
        marks.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        // A run in which nothing was ever said is left whole. Chopping silence into more
        // silence helps nobody, and it is the one case where every join looks equally like a
        // boundary.
        guard let firstMark = marks.first else { return [] }

        var stretches: [QuietStretch] = []
        if firstMark.start > runStart {
            stretches.append(
                QuietStretch(
                    startMs: runStart, endMs: firstMark.start, isLeading: true, isTrailing: false,
                    lastSpokenSegmentId: nil, nextSpokenSegmentId: firstMark.segmentId))
        }
        var previousEnd = firstMark.end
        var previousSegmentId = firstMark.segmentId
        for mark in marks.dropFirst() {
            if mark.start > previousEnd {
                stretches.append(
                    QuietStretch(
                        startMs: previousEnd, endMs: mark.start, isLeading: false,
                        isTrailing: false, lastSpokenSegmentId: previousSegmentId,
                        nextSpokenSegmentId: mark.segmentId))
            }
            if mark.end > previousEnd {
                previousEnd = mark.end
                previousSegmentId = mark.segmentId
            }
        }
        if runEnd > previousEnd {
            stretches.append(
                QuietStretch(
                    startMs: previousEnd, endMs: runEnd, isLeading: false, isTrailing: true,
                    lastSpokenSegmentId: previousSegmentId, nextSpokenSegmentId: nil))
        }
        return stretches
    }

    /// The cuts and the deferred candidates for one structurally-chained run.
    ///
    /// `semanticSplits` are segment ids the reviewer has already ruled start a new
    /// conversation; `blocked` are segment ids the user has pinned to the previous conversation.
    static func boundaries(
        members: [SegmentMeta],
        evidence: [String: SegmentSpeechEvidence],
        policy: BoundaryPolicy,
        semanticSplits: Set<String> = [],
        blocked: Set<String> = []
    ) -> (cuts: [BoundaryCut], candidates: [BoundaryCandidate]) {
        guard members.count > 1 else { return ([], []) }
        // Wall time of every join, by the index of the member that follows it.
        let joins: [(index: Int, atMs: Int64)] = (1..<members.count).map {
            ($0, ConversationGrouper.segmentStartMs(members[$0]))
        }

        var cutsByIndex: [Int: ConversationStartReason] = [:]
        var candidates: [BoundaryCandidate] = []

        for stretch in quietStretches(members: members, evidence: evidence) {
            let overlapping = members.filter {
                ConversationGrouper.segmentEndMs($0) > stretch.startMs
                    && ConversationGrouper.segmentStartMs($0) < stretch.endMs
            }
            // DEFERRAL, not a decision: one member still transcribing (or still open) and we
            // cannot yet tell silence from a queue.
            guard overlapping.allSatisfy({ evidence[$0.segmentId]?.isSettled == true }) else {
                continue
            }

            let lostMs = overlapping.reduce(Int64(0)) { total, meta in
                total
                    + lossSpansMs(meta).reduce(Int64(0)) { inner, span in
                        inner + max(0, min(span.1, stretch.endMs) - max(span.0, stretch.startMs))
                    }
            }
            let duration = stretch.durationMs
            guard duration > 0 else { continue }
            let lossFraction = Double(lostMs) / Double(duration)
            let scale = lossFraction > policy.lossDominanceFraction
                ? policy.lossThresholdMultiplier : 1
            let splitAt = scaled(policy.quietSplitMs, by: scale)
            let candidateAt = scaled(policy.quietCandidateMs, by: scale)
            guard duration >= candidateAt else { continue }

            // A conversation is a set of WHOLE segments, so a cut can only land on a join. A
            // stretch entirely inside one member (the watch was quiet for an hour in the middle
            // of a rotation) produces no cut at all.
            //
            // The bounds are INCLUSIVE, and that is not a detail: rotations hand straight over,
            // so a member whose first word is at offset 0 puts the join exactly on the edge of
            // the stretch. Strict bounds threw those away — the commonest shape in the library.
            let inside = joins.filter { $0.atMs >= stretch.startMs && $0.atMs <= stretch.endMs }
            guard !inside.isEmpty else { continue }
            let chosen: (index: Int, atMs: Int64)
            if stretch.isLeading {
                // Peel the silent members off the front so the conversation starts near its
                // first word rather than hours earlier.
                chosen = inside[inside.count - 1]
            } else if stretch.isTrailing {
                chosen = inside[0]
            } else {
                let midpoint = stretch.startMs + duration / 2
                chosen = inside.min {
                    let left = abs($0.atMs - midpoint)
                    let right = abs($1.atMs - midpoint)
                    return left == right ? $0.index < $1.index : left < right
                }!
            }
            let startingSegment = members[chosen.index].segmentId
            guard !blocked.contains(startingSegment) else { continue }

            let lossDominated = lossFraction > policy.lossDominanceFraction
            if duration >= splitAt {
                let reason: ConversationStartReason = lossDominated ? .interrupted : .quiet
                cutsByIndex[chosen.index] = strongest(cutsByIndex[chosen.index], reason)
            } else if semanticSplits.contains(startingSegment) {
                cutsByIndex[chosen.index] = strongest(cutsByIndex[chosen.index], .topicChange)
            } else {
                candidates.append(
                    BoundaryCandidate(
                        newStartSegmentId: startingSegment,
                        previousEndSegmentId: members[chosen.index - 1].segmentId,
                        atMs: chosen.atMs,
                        quietMs: duration,
                        lossFraction: lossFraction,
                        lastSpokenSegmentId: stretch.lastSpokenSegmentId,
                        nextSpokenSegmentId: stretch.nextSpokenSegmentId
                    )
                )
            }
        }

        let cuts = cutsByIndex.keys.sorted().map {
            BoundaryCut(index: $0, reason: cutsByIndex[$0]!)
        }
        return (cuts, candidates.sorted { $0.atMs < $1.atMs })
    }

    private static func scaled(_ value: Int64, by factor: Double) -> Int64 {
        guard factor != 1, value != .max else { return value }
        let scaled = Double(value) * factor
        return scaled >= Double(Int64.max) ? .max : Int64(scaled)
    }

    /// A join that two stretches both point at keeps the more specific reason; the order is
    /// fixed so the result stays deterministic.
    private static func strongest(
        _ existing: ConversationStartReason?, _ candidate: ConversationStartReason
    ) -> ConversationStartReason {
        guard let existing else { return candidate }
        let rank: [ConversationStartReason: Int] = [
            .quiet: 0, .interrupted: 1, .topicChange: 2,
        ]
        return (rank[candidate] ?? 0) > (rank[existing] ?? 0) ? candidate : existing
    }
}
