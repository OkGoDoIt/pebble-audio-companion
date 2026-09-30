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
// record contains no speech AND the wearer was not still in full flow either side of it. Two
// thresholds, because the evidence says the middle is genuinely ambiguous, plus one guard —
// see `BoundaryPolicy`, which also records what a 150-boundary / 149-trap hand-labelled
// yardstick said about the rules that were tried and dropped (rolling word-rate lulls,
// artefact stripping, cutting on recorded link gaps).
//
// This file also owns the DISPLAYED extent of a conversation
// (`ConversationBoundaryDetector.displayExtent`), because the answer to "how long was it" comes
// from the same evidence as "where did it end": first word to last word, never a container
// edge. 41.4% of the library's displayed time was phantom before that.

/// One run of speech inside a member segment, in the transcript's own clock (milliseconds from
/// the start of that segment's stored audio) — exactly what `SegmentTranscript.segments`
/// carries, so building evidence is a `map`.
public struct SpeechSpan: Equatable, Sendable {
    public var startMs: Int64
    public var endMs: Int64
    /// Words in this run. Defaulted to 0 so every existing caller keeps compiling, and 0 is the
    /// safe value: the only rule that reads it (the flanking-flow guard in `BoundaryPolicy`)
    /// then measures nothing and never blocks a split, which is exactly the behaviour before
    /// word counts existed.
    public var wordCount: Int
    /// What the conversation segmenter reads from the turn's text (`ConversationLexicon`). Nil
    /// where a caller has timings only; the segmenter then works from the timings alone.
    public var features: TurnFeatures?

    public init(
        startMs: Int64, endMs: Int64, wordCount: Int = 0, features: TurnFeatures? = nil
    ) {
        self.startMs = startMs
        self.endMs = max(endMs, startMs)
        self.wordCount = wordCount
        self.features = features
    }

    /// A turn with its text: the word count and the segmenter's features are derived here, so
    /// every place that builds evidence from a transcript agrees on both.
    public init(startMs: Int64, endMs: Int64, text: String, speaker: String?) {
        self.init(
            startMs: startMs, endMs: endMs,
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            features: ConversationLexicon.features(text: text, speaker: speaker))
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

    /// A cheap hash of where the speech is, for memoising a grouping on its evidence. Not
    /// stable across launches, and it does not need to be.
    var fingerprint: Int {
        var hasher = Hasher()
        hasher.combine(speech.count)
        for span in speech {
            hasher.combine(span.startMs)
            hasher.combine(span.endMs)
            hasher.combine(span.wordCount)
            hasher.combine(span.features?.terms.count ?? -1)
            hasher.combine(span.features?.speaker)
            hasher.combine(span.features?.isForeign)
            hasher.combine(span.features?.isDictation)
            hasher.combine(span.features?.opensWithGreeting)
        }
        return hasher.finalize()
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
    /// The talk itself changed here — who was speaking, how, or about what — with no long
    /// silence to mark it (`ConversationSegmenter`). Also what the retired semantic reviewer
    /// wrote, which meant the same thing.
    case topicChange
    /// The talk picked up again after a few quiet minutes, and what followed was a different
    /// conversation. Shorter than `quiet`, which is a silence long enough to end one by itself.
    case lull
    /// Nothing is known about this stretch yet except how long it is: its recordings are not
    /// transcribed. It is divided by length so that waiting audio is never one day-long block,
    /// and divided again, properly, when the transcripts arrive.
    case length
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
/// The numbers moved once, on 2026-09-08, against a **hand-labelled yardstick** rather than the
/// earlier hand-read sample: 150 boundaries (95 `certain`, 55 `unsure`) and 149 deliberate
/// NON-boundaries — the traps — read from 93.5% of the library's 74,125 utterances. Scoring is
/// a ±3-minute match on `certain`, with a predicted split landing on a trap counted as a false
/// split, because a splitter that fragments real conversations is worse than the status quo.
///
///  - **`quietSplitMs` 25 min → 15 min.** At 25 the rule found 62 of 95 certain boundaries and
///    hit 30 of 149 traps; at 15 it finds 67 and hits 34. Five real boundaries for five traps
///    is not obviously a win on count — it is a win on shape, because all five of the new
///    boundaries are "different people" / "place change" (a meeting ending, a new place, a
///    different room) while four of the five new traps are one long SOLO dictation session cut
///    into two solo dictation sessions, the class the labeller flagged as the softest call in
///    the file. It is also what breaks the 9-hour "conversation": 2026-08-15 becomes 1h21m of
///    solo dictation plus the genuine 7h38m long conversation, which is the labels' own answer.
///  - **8–15 min** stays a CANDIDATE band: with the semantic reviewer off it does not split.
///  - **< 8 min**: dominated by ordinary pauses. The label file is emphatic here — the 5–10
///    minute band runs about 7:1 AGAINST splitting (49 traps to 7 certain boundaries).
///
/// What was measured and **rejected**, so it is not tried again:
///  - **A rolling words-per-minute "lull" rule** (the obvious answer to sporadic hallucinated
///    one-liners keeping a stretch alive). At 10 wpm over 12 min it splits 8 certain boundaries
///    and 12 traps — worse than chance. Its own showcase case, 2026-08-20, carries ZERO certain
///    boundaries and SEVEN traps in the labels: the "sparse aftermath" it wants to cut off is
///    two speakers in one place with background noise. Tightened to 5 wpm over 15 min it stops losing, but
///    it is then a strictly worse restatement of a lower `quietSplitMs`, so it does not earn its
///    complexity.
///  - **Stripping looped ASR artefacts before measuring.** 7.9% of turns and 4.8% of words in
///    the library are repetition-loop artefacts, but removing them moves ZERO cuts at every
///    threshold swept: the loops sit inside stretches that are already speech. Worth doing for
///    honest word counts and titles; worthless for grouping.
///  - **Cutting on a recorded link gap ≥ 10 min.** Two extra cuts library-wide, no boundary
///    found, no trap hit — already covered by `.interrupted` on a loss-dominated quiet stretch.
public struct BoundaryPolicy: Hashable, Sendable {
    /// A settled no-speech stretch at least this long ends the conversation — unless the
    /// wearer was still in full flow on both sides of it (`flankFlowWordsPerMinute`).
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
    /// Refuse to cut an INTERIOR silence when the wearer was talking at this rate or above on
    /// BOTH sides of it. A break in the middle of a continuous occasion — coffee, a bathroom
    /// trip, a delayed flight — is bracketed by full conversation; the end of an occasion is
    /// not. Measured: this removes four traps and costs zero certain boundaries, and the four
    /// include the two the label file calls out by name (2026-07-01, three hours waiting in a
    /// waiting room with the same speaker either side of a 45-minute silence, and the longest
    /// silence in the whole library, where the same solo dictation resumes verbatim).
    ///
    /// A blocked stretch is not discarded: it becomes a CANDIDATE, so the semantic reviewer can
    /// still confirm it from what was actually said.
    ///
    /// Set to 0 to disable. It is also inert wherever `SpeechSpan.wordCount` is left at its
    /// default, so a caller that supplies no word counts gets the unguarded rule.
    public var flankFlowWordsPerMinute: Double
    /// How much of the record either side of the silence the guard reads.
    public var flankWindowMs: Int64
    /// How talk with no long silence in it is divided into conversations. Nil turns the
    /// segmenter off, which leaves only the structural rules and the long-quiet rule.
    public var segmenter: SegmenterPolicy?

    public init(
        quietSplitMs: Int64 = 15 * 60 * 1000,
        quietCandidateMs: Int64 = 8 * 60 * 1000,
        lossDominanceFraction: Double = 0.5,
        lossThresholdMultiplier: Double = 2,
        flankFlowWordsPerMinute: Double = 30,
        flankWindowMs: Int64 = 10 * 60 * 1000,
        segmenter: SegmenterPolicy? = .default
    ) {
        self.quietSplitMs = quietSplitMs
        self.quietCandidateMs = quietCandidateMs
        self.lossDominanceFraction = lossDominanceFraction
        self.lossThresholdMultiplier = lossThresholdMultiplier
        self.flankFlowWordsPerMinute = flankFlowWordsPerMinute
        self.flankWindowMs = flankWindowMs
        self.segmenter = segmenter
    }

    public static let `default` = BoundaryPolicy()

    /// v1 behaviour: structural rules only, no quiet layer at all. Used by callers that have no
    /// transcript evidence to give, and by the tests that pin the old rules.
    public static let structuralOnly = BoundaryPolicy(
        quietSplitMs: .max, quietCandidateMs: .max, segmenter: nil)

    /// The long-quiet rule without the segmenter: what shipped before conversations became
    /// topic-sized. Kept for the tests that pin that rule on its own.
    public static let quietOnly = BoundaryPolicy(segmenter: nil)
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
    /// The transcript's clock counts STORED AUDIO — `TranscriptionProcessor.segmentPcmSource`
    /// decodes the frame log and hands only that to the provider, so anything the log is
    /// missing is simply absent from what the provider heard. The member's span is wall time.
    /// The two are converted through the member's own gap records (`SegmentMediaClock`), which
    /// is the same conversion the transcript screen and the scrubber use; adding the raw
    /// provider offset to the member's start, as this used to, silently assumes the two clocks
    /// are the same one.
    ///
    /// THIS IS THE RULE THAT NOTICES QUIET, so getting it wrong here is not a cosmetic error —
    /// it deletes the evidence the rule exists to read. Watch-side silence suppression
    /// (PebbleOS a47acac74) had fired zero times in 88 days and now withholds 4.1%-13.8% of
    /// airtime; every suppressed millisecond is quiet that vanishes from the media clock.
    /// Measured over the real library with suppression synthesised at the firmware's own rates,
    /// reading media offsets as wall offsets loses 22% / 35% / 54% of the interior no-speech
    /// stretches over five minutes (light / balanced / aggressive) and 20% / 70% / 80% of those
    /// over twelve — i.e. exactly the long silences a conversation is supposed to end at.
    ///
    /// ONLY WHEN THE RECORDS SUPPORT IT (`SegmentMediaClock.isExact`). Where they do not — the
    /// gap list does not account for the difference between stored audio and elapsed wall time
    /// — the clock falls back to a proportional guess, and this is the one caller that must not
    /// act on a guess: a split is a structural decision a person then sees. Measured over the
    /// 2026-09-08 library, 23 of 765 segments are inexact and extreme with it (one claims
    /// 15 h 01 m of wall time around 14 m 45 s of audio across 79 records that add up to
    /// neither), and stretching their transcripts proportionally moved 7,285 turns by over a
    /// minute — up to 14 h 44 m — which put three more conversations over four hours and
    /// re-created exactly the phantom durations `displayExtent` exists to remove. Suppression
    /// does not produce that shape: the watch writes a gap record for every run it suppresses,
    /// so a silence-suppressed segment's records DO add up and this converts.
    static func speechSpansMs(_ meta: SegmentMeta, _ evidence: SegmentSpeechEvidence?)
        -> [(Int64, Int64)]
    {
        spokenRuns(meta, evidence).map { ($0.startMs, $0.endMs) }
    }

    /// The same runs, keeping the word count, for the rules that need to know how much was
    /// said and not merely that something was.
    static func spokenRuns(_ meta: SegmentMeta, _ evidence: SegmentSpeechEvidence?)
        -> [(startMs: Int64, endMs: Int64, wordCount: Int)]
    {
        guard let evidence, !evidence.speech.isEmpty else { return [] }
        let start = ConversationGrouper.segmentStartMs(meta)
        let span = max(ConversationGrouper.segmentEndMs(meta) - start, 0)
        let clock = SegmentMediaClock(meta)
        let toWall: (Int64) -> Int64 = clock.isExact ? { clock.wall(fromMedia: $0) } : { $0 }
        return evidence.speech.map { run in
            let a = min(max(toWall(run.startMs), 0), span)
            let b = min(max(toWall(run.endMs), a), span)
            return (start + a, start + b, run.wordCount)
        }
    }

    /// Words per minute over one wall-clock window. A run straddling the edge contributes in
    /// proportion to its overlap, so the answer does not jump when a turn happens to start one
    /// second before the window does.
    static func wordRate(
        from startMs: Int64, to endMs: Int64,
        runs: [(startMs: Int64, endMs: Int64, wordCount: Int)]
    ) -> Double {
        let minutes = Double(endMs - startMs) / 60_000
        guard minutes > 0 else { return 0 }
        var words = 0.0
        for run in runs where run.endMs > startMs && run.startMs < endMs {
            let length = run.endMs - run.startMs
            guard length > 0 else {
                // A zero-length run still said something; count it where it sits.
                words += Double(run.wordCount)
                continue
            }
            let overlap = min(run.endMs, endMs) - max(run.startMs, startMs)
            words += Double(run.wordCount) * Double(overlap) / Double(length)
        }
        return words / minutes
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

    /// The extent a conversation should DISPLAY: first word to last word, never a container
    /// edge — and where nothing was ever said, the audio actually received rather than the
    /// wall time the sample counter happened to run through.
    ///
    /// THE BUG THIS FIXES. 41.4% of the library's displayed time was phantom: 198 h 46 m of
    /// segment wall-span against 116 h 30 m of audio received. `transportReset` drops the BLE
    /// link, the watch's sample counter free-runs while it is down, and
    /// `lastSampleIndexExclusive − firstSampleIndex` then turns a dropped connection into hours
    /// of "conversation". The worst single segment displayed **16 h 29 m and holds 32 seconds of
    /// audio**; three of the ten longest "conversations" in the library contained 1 m 44 s to
    /// 2 m 34 s of speech each. Speech-anchoring the extent removes every one of them from the
    /// top of the list without moving a single boundary: measured over the 2026-09-08 backup it
    /// leaves precision, recall and false splits EXACTLY unchanged while the longest displayed
    /// conversation drops from 16 h 29 m to 8 h 59 m, p90 from 2 h 54 m to 2 h 05 m and the
    /// median from 26 m 38 s to 14 m 57 s.
    ///
    /// It deliberately does NOT cap `segmentEndMs` itself. That was measured too, and it is a
    /// trap: capping a member's PLACEMENT at the audio it holds turns interior loss into an
    /// inter-segment gap, the 5-minute chain window then fires on it, and the library picks up
    /// 7 to 12 extra false splits for one extra correct boundary. Placement is where the audio
    /// sits in wall time; extent is how much of it there is. They are not the same number.
    ///
    /// Trimming only ever eats SETTLED silence, from the outside in, and stops at the first
    /// member that could still change its mind — so a live conversation keeps its container end
    /// and a pending transcript never shortens anything. With no evidence at all this returns
    /// the container edges, which is exactly the v1 behaviour.
    static func displayExtent(
        members: [SegmentMeta], evidence: [String: SegmentSpeechEvidence]
    ) -> (startMs: Int64, endMs: Int64) {
        guard let first = members.first else { return (0, 0) }
        let containerStart = ConversationGrouper.segmentStartMs(first)
        let containerEnd = max(
            members.map(ConversationGrouper.segmentEndMs).max() ?? containerStart, containerStart)

        // Walk in from the front for the first word and in from the back for the last, skipping
        // members that are SETTLED AND SILENT (those contribute nothing) and stopping dead at
        // the first member that is not settled yet (we cannot claim it is empty, so it keeps
        // its whole placement). Both walks return nil only when every member is settled and
        // nobody spoke anywhere.
        // One `spokenRuns` per member, reused by both walks and the widening below. Each call
        // builds a `SegmentMediaClock` over the member's gap records, and silence suppression
        // multiplies those records by an order of magnitude, so asking three times per member
        // per regroup is real work for an answer that cannot differ.
        let runs = members.map { spokenRuns($0, evidence[$0.segmentId]) }
        var start: Int64?
        for (index, meta) in members.enumerated() {
            guard evidence[meta.segmentId]?.isSettled == true else {
                start = ConversationGrouper.segmentStartMs(meta)
                break
            }
            if let firstWord = runs[index].map(\.startMs).min() {
                start = firstWord
                break
            }
        }
        var end: Int64?
        for index in members.indices.reversed() {
            guard evidence[members[index].segmentId]?.isSettled == true else {
                end = ConversationGrouper.segmentEndMs(members[index])
                break
            }
            if let lastWord = runs[index].map(\.endMs).max() {
                end = lastWord
                break
            }
        }
        // Members OVERLAP in wall time — the watch's sample counter free-runs across a rotation
        // handover, and a spool backfill legitimately anchors earlier than the segment that
        // received it — so "the last member that spoke" is not always the member holding the
        // last word. The walks above take the first speaking member from each end and stop, so
        // a word in a member they stepped over could fall outside the extent, and the extent's
        // one hard rule is that it only ever eats SILENCE. Widening onto the real extremes
        // costs nothing (the runs are already computed) and cannot shorten anything.
        //
        // This became reachable when `spokenRuns` started placing runs at their true wall
        // position rather than at an offset from the member's start: before that every run sat
        // in the member's first `frameCount × 20 ms`, so the walks' answer was almost always
        // also the extreme. 67 words in the 2026-09-08 library fall outside it now.
        if let earliest = runs.compactMap({ $0.map(\.startMs).min() }).min() {
            start = min(start ?? earliest, earliest)
        }
        if let latest = runs.compactMap({ $0.map(\.endMs).max() }).max() {
            end = max(end ?? latest, latest)
        }
        guard start != nil || end != nil else {
            // Nothing was ever said and we now know it. The honest length is the audio we hold,
            // not the hours the counter ran through while the link was down. Never longer than
            // the container: a spool backfill can add audio, and the extent must not outrun the
            // wall time it is supposed to sit in.
            let audio = members.reduce(Int64(0)) { $0 + ConversationGrouper.segmentAudioMs($1) }
            return (containerStart, min(containerEnd, containerStart + audio))
        }
        let clampedStart = min(max(start ?? containerStart, containerStart), containerEnd)
        return (clampedStart, max(min(end ?? containerEnd, containerEnd), clampedStart))
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

        // Every word the run holds, once, for the flanking-flow guard. Cheap: it is the same
        // evidence `quietStretches` already walks.
        let runs: [(startMs: Int64, endMs: Int64, wordCount: Int)] =
            policy.flankFlowWordsPerMinute > 0
            ? members.flatMap { spokenRuns($0, evidence[$0.segmentId]) }
            : []

        /// True when the wearer was talking at conversational pace on BOTH sides of the
        /// silence — a break inside one occasion rather than the end of it.
        func isStillInFullFlow(_ stretch: QuietStretch) -> Bool {
            guard policy.flankFlowWordsPerMinute > 0, !runs.isEmpty else { return false }
            let window = policy.flankWindowMs
            let before = wordRate(
                from: stretch.startMs - window, to: stretch.startMs, runs: runs)
            let after = wordRate(from: stretch.endMs, to: stretch.endMs + window, runs: runs)
            return min(before, after) >= policy.flankFlowWordsPerMinute
        }

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
            // The guard applies to INTERIOR silences only. A leading or trailing stretch is not
            // a cut through anything — it peels silent members off the ends so the conversation
            // starts near its first word — and by construction one of its two flanks is empty.
            let guarded =
                !stretch.isLeading && !stretch.isTrailing && isStillInFullFlow(stretch)
            if duration >= splitAt, !guarded {
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
