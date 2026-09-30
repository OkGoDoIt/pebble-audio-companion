import Foundation
import GRDB
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// The long-quiet rule (see `ConversationRunPlanner.quietCuts`), on its own: every case runs with
// `policy: .quietOnly`, so the segmenter is off and what is pinned is the rule that a long
// settled silence ends a conversation. Every case here is a shape that actually occurs in the
// captured library, and the deferral cases are the ones that decide whether the rule is safe: a
// boundary must never be decided from evidence that has not landed yet.
//
// PORTED 2026-09-30 from the suite of the same name that tested `groupWithCandidates`. What
// changed with conversations becoming pieces of segments:
//  - a quiet cut no longer snaps to the segment join nearest the middle of the silence. It lands
//    at the FIRST WORD AFTER the silence (less `ConversationRunPlanner.preRollMs`), which is a
//    position inside a segment — so the silence stays with the conversation it followed, and a
//    silence wholly inside one segment now splits it;
//  - the 8–15 minute candidate band, the semantic reviewer's verdicts and the flanking-flow
//    guard no longer exist as far as grouping is concerned. Their tests are gone; what is left
//    of them is "under the threshold nothing happens" and "the retired knobs change nothing".

private let hour = minutesMs(60)

@Suite struct ConversationBoundaryTests {
    let t0 = testEpochMs
    /// Where the cut before a turn that starts `minutes` into its segment sits.
    private func cut(beforeMinute minutes: Int64) -> Int64 {
        minutesMs(minutes) - ConversationRunPlanner.preRollMs
    }

    private func group(
        _ segments: [SegmentMeta],
        evidence: [String: SegmentSpeechEvidence] = [:],
        overrides: [String: BoundaryDecision] = [:],
        policy: BoundaryPolicy = .quietOnly,
        cutInputs: ConversationCutInputs = .none,
        open: String? = nil
    ) -> [GroupedConversation] {
        let conversations = ConversationGrouper.group(
            segments: segments, pauses: [], openSegmentId: open, fallbackTimeZoneID: "UTC",
            evidence: evidence, overrides: overrides, policy: policy, cutInputs: cutInputs)
        expectPiecesTile(conversations, segments: segments)
        return conversations
    }

    /// Talk, an hour in which nobody says anything, then talk again: four abutting 20-minute
    /// rotations, the last word of the first stretch 18 minutes into `s0` and the first word of
    /// the second 18 minutes into `s3`.
    private var talkQuietTalk: [String: SegmentSpeechEvidence] {
        evidenceMap([
            settledEvidence("s0", minutes: [(0, 18)]),
            settledEvidence("s1", minutes: []),
            settledEvidence("s2", minutes: []),
            settledEvidence("s3", minutes: [(18, 20)]),
        ])
    }

    // MARK: - the quiet rule itself

    @Test func continuousTalkAcrossRotationsIsOneConversation() {
        // No stretch of no-speech anywhere: the members abut and everyone keeps talking.
        let segments = rotations(3)
        let evidence = evidenceMap([
            settledEvidence("s0", minutes: [(0, 20)]), settledEvidence("s1", minutes: [(0, 20)]),
            settledEvidence("s2", minutes: [(0, 20)]),
        ])
        let result = group(segments, evidence: evidence)
        #expect(result.map(\.brief) == [["s0", "s1", "s2"]])
    }

    @Test func aLongSettledStretchWithNoSpeechEndsTheConversation() {
        // The v1 rules see four abutting rotations and one conversation; this is the case the
        // rule exists for. The new conversation starts at its first word — a position inside
        // `s3` — and the hour of silence stays with the conversation it followed.
        let result = group(rotations(4), evidence: talkQuietTalk)
        let at = cut(beforeMinute: 18)
        #expect(
            result.map(\.brief) == [["s0", "s1", "s2", "s3[..\(at))"], ["s3[\(at)..)"]])
        #expect(result.map(\.startReason) == [nil, .quiet])
        #expect(result.map(\.id) == ["conv-s0", "conv-s3-m\(at)"])
        // Each shows first word to last word: the silence is in neither.
        #expect(result[0].startMs == t0)
        #expect(result[0].endMs == t0 + minutesMs(18))
        #expect(result[1].startMs == t0 + minutesMs(78))
        #expect(result[1].endMs == t0 + minutesMs(80))
    }

    @Test func quietUnderTheThresholdDoesNotSplit() {
        // 12 minutes of nothing. Against the hand-labelled NON-boundaries, silences under the
        // 15-minute bar are traps far more often than they are boundaries (the 5–10 minute band
        // alone ran about 7:1 against splitting), so the long-quiet rule leaves them alone. This
        // used to be the "candidate band" offered to the semantic reviewer; that layer is gone,
        // and inside talk the decision now belongs to the segmenter, which is off here.
        let twelve = group(
            rotations(3, minutesEach: 6),
            evidence: evidenceMap([
                settledEvidence("s0", minutes: [(0, 3)]), settledEvidence("s1", minutes: []),
                settledEvidence("s2", minutes: [(3, 6)]),
            ]))
        #expect(twelve.map(\.brief) == [["s0", "s1", "s2"]])

        // Three minutes: an ordinary pause.
        let three = group(
            rotations(3, minutesEach: 3),
            evidence: evidenceMap([
                settledEvidence("s0", minutes: [(0, 3)]), settledEvidence("s1", minutes: []),
                settledEvidence("s2", minutes: [(0, 3)]),
            ]))
        #expect(three.map(\.brief) == [["s0", "s1", "s2"]])

        // One second under the bar, and exactly on it.
        func run(quietSeconds: Int64) -> Int {
            let segment = makeSegment(
                id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(40))
            let evidence = SegmentSpeechEvidence(
                segmentId: "a", isSettled: true,
                speech: [
                    SpeechSpan(startMs: 0, endMs: 60_000),
                    SpeechSpan(
                        startMs: 60_000 + quietSeconds * 1000, endMs: minutesMs(40)),
                ])
            return group([segment], evidence: ["a": evidence]).count
        }
        #expect(run(quietSeconds: 15 * 60 - 1) == 1)
        #expect(run(quietSeconds: 15 * 60) == 2)
    }

    @Test func theRetiredCandidateBandAndFlankingFlowGuardChangeNothing() {
        // Twenty minutes of silence with the wearer talking hard on both sides of it (600 words
        // in the ten minutes before and after). The flanking-flow guard used to WITHHOLD this
        // split and hand it to the reviewer; the guard no longer reads anything, so the policy's
        // leftover knobs must make no difference to the grouping.
        let segments = rotations(4, minutesEach: 10)
        let evidence = evidenceMap([
            settledEvidence("s0", minutes: [(0, 10)], words: 600),
            settledEvidence("s1", minutes: []),
            settledEvidence("s2", minutes: []),
            settledEvidence("s3", minutes: [(0, 10)], words: 600),
        ])
        let shipped = group(segments, evidence: evidence)
        #expect(shipped.map(\.brief) == [["s0", "s1", "s2"], ["s3"]])
        #expect(shipped[1].startReason == .quiet)

        var knobs = BoundaryPolicy.quietOnly
        knobs.flankFlowWordsPerMinute = 0
        knobs.flankWindowMs = 1
        knobs.quietCandidateMs = 1
        #expect(group(segments, evidence: evidence, policy: knobs) == shipped)
    }

    // MARK: - delay is not silence

    @Test func aMemberStillTranscribingDefersTheBoundaryRatherThanSplitting() {
        // THE trap: watch audio backfills hours late and transcription lags behind capture, so
        // "no transcript yet" and "nobody spoke" look identical. Deferring costs nothing —
        // grouping is derived, and the next rebuild decides with the evidence in hand.
        let segments = rotations(4)
        var evidence = talkQuietTalk
        evidence["s2"] = unsettledEvidence("s2")
        #expect(group(segments, evidence: evidence).map(\.brief) == [["s0", "s1", "s2", "s3"]])

        // A member with no evidence entry at all is just as unknown.
        evidence["s2"] = nil
        #expect(group(segments, evidence: evidence).count == 1)

        // Same segments, same rules, once the transcript lands and says nobody spoke.
        #expect(group(segments, evidence: talkQuietTalk).count == 2)
    }

    @Test func settlingRuleTreatsRetryableAndMissingTranscriptsAsUnknown() {
        var meta = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10))

        meta.transcriptionState = .noSpeech
        #expect(SegmentSpeechEvidence.of(meta, transcriptSpeech: nil).isSettled)

        meta.transcriptionState = .complete
        #expect(SegmentSpeechEvidence.of(meta, transcriptSpeech: []).isSettled)
        // Complete but the transcript file is gone: a bookkeeping bug, not proof of silence.
        #expect(!SegmentSpeechEvidence.of(meta, transcriptSpeech: nil).isSettled)

        // Both of these are retried — `.disabled` becomes eligible again the moment a provider
        // is usable — so neither may stand in for "nobody spoke".
        for state in [TranscriptionState.failed, .disabled, .pending, .running, .uploading] {
            meta.transcriptionState = state
            #expect(!SegmentSpeechEvidence.of(meta, transcriptSpeech: []).isSettled)
        }

        // Still open: never settled, whatever the state says.
        var open = makeSegment(
            id: "b", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10),
            close: nil)
        open.transcriptionState = .noSpeech
        #expect(!SegmentSpeechEvidence.of(open, transcriptSpeech: nil).isSettled)
    }

    @Test func aLateBackfillSegmentRegroupsRatherThanLeavingAWrongSplit() {
        // The spool hands over a segment that belongs in the middle of the quiet stretch, and
        // it turns out to be full of speech. Because grouping is recomputed rather than
        // patched, the split simply stops existing.
        let segments = rotations(4)
        #expect(group(segments, evidence: talkQuietTalk).count == 2)

        // The backfill fills the silence outright: new evidence dissolves an old split, so the
        // evidence has to actually be new.
        let backfilled = evidenceMap([
            settledEvidence("s0", minutes: [(0, 18)]), settledEvidence("s1", minutes: [(0, 20)]),
            settledEvidence("s2", minutes: [(0, 20)]), settledEvidence("s3", minutes: [(0, 20)]),
        ])
        #expect(group(segments, evidence: backfilled).map(\.brief) == [["s0", "s1", "s2", "s3"]])
    }

    @Test func theOpenSegmentNeverSettlesSoALiveConversationIsNotSplitAtItsTail() {
        var segments = rotations(3)
        segments[2].closeReason = nil
        let evidence = evidenceMap([
            settledEvidence("s0", minutes: [(0, 18)]),
            settledEvidence("s1", minutes: []),
            unsettledEvidence("s2"),
        ])
        let result = group(segments, evidence: evidence, open: "s2")
        #expect(result.map(\.brief) == [["s0", "s1", "s2"]])
        #expect(result[0].isLive)
    }

    // MARK: - loss is not quiet

    @Test func aStretchThatIsMostlyMissingAudioNeedsTwiceAsMuchDeadAir() {
        // 26 minutes with nothing said, 20 of them a hole in the record. Missing audio is
        // evidence of our ignorance, not that nobody spoke — and a spool backfill can still
        // fill it, which would un-split the conversation later and orphan whatever the user
        // had tagged on the second half.
        var segments = rotations(6, minutesEach: 5)
        for index in 1...4 {
            segments[index].gaps = [
                lossGap(atSample: minutesSamples(UInt64(index) * 5), minutes: 5)
            ]
        }
        let evidence = evidenceMap([
            settledEvidence("s0", minutes: [(0, 2)]), settledEvidence("s1", minutes: []),
            settledEvidence("s2", minutes: []), settledEvidence("s3", minutes: []),
            settledEvidence("s4", minutes: []), settledEvidence("s5", minutes: [(3, 5)]),
        ])
        // Over the 15-minute quiet bar, under the 30-minute loss-dominated one.
        #expect(group(segments, evidence: evidence).count == 1)

        var relaxed = BoundaryPolicy.quietOnly
        relaxed.lossThresholdMultiplier = 1
        let split = group(segments, evidence: evidence, policy: relaxed)
        let at = cut(beforeMinute: 3)
        #expect(
            split.map(\.brief)
                == [["s0", "s1", "s2", "s3", "s4", "s5[..\(at))"], ["s5[\(at)..)"]])
        // …and it is called what it is. Quiet and a hole in the record are never conflated.
        #expect(split[1].startReason == .interrupted)

        // Twice the bar of mostly-missing air does split, without relaxing anything: the same
        // shape with a ten-minute hole in each of the four silent members (42 minutes unspoken,
        // 40 of them lost).
        var longer = rotations(6, minutesEach: 10)
        for index in 1...4 {
            longer[index].gaps = [
                lossGap(atSample: minutesSamples(UInt64(index) * 10), minutes: 10)
            ]
        }
        let longerEvidence = evidenceMap([
            settledEvidence("s0", minutes: [(0, 9)]), settledEvidence("s1", minutes: []),
            settledEvidence("s2", minutes: []), settledEvidence("s3", minutes: []),
            settledEvidence("s4", minutes: []), settledEvidence("s5", minutes: [(1, 10)]),
        ])
        let interrupted = group(longer, evidence: longerEvidence)
        #expect(interrupted.count == 2)
        #expect(interrupted.last?.startReason == .interrupted)
    }

    @Test func vadSuppressedSilenceCountsAsQuietNotAsLoss() {
        // A `silenceSuppressed` gap is audio the watch knowingly skipped. It must not push the
        // stretch into the loss-dominated band and double the threshold.
        var withSilenceGaps = rotations(4)
        withSilenceGaps[1].gaps = [silenceGap(atSample: minutesSamples(20), minutes: 19)]
        withSilenceGaps[2].gaps = [silenceGap(atSample: minutesSamples(40), minutes: 19)]
        let result = group(withSilenceGaps, evidence: talkQuietTalk)
        #expect(result.count == 2)
        #expect(result[1].startReason == .quiet)
    }

    // MARK: - inside one segment

    @Test func quietEntirelyInsideOneMemberNowSplitsItAtTheFirstWordAfter() {
        // This was `quietEntirelyInsideOneMemberNeverSplits`: a conversation was a set of whole
        // segments, so there was nowhere to cut. There is now — the first word after the
        // silence — and both conversations are pieces of the same segment.
        let segments = [
            makeSegment(
                id: "s0", stream: 7, startTimeMs: t0, durationSamples: minutesSamples(90))
        ]
        let evidence = evidenceMap([settledEvidence("s0", minutes: [(0, 2), (85, 90)])])
        let result = group(segments, evidence: evidence)
        let at = cut(beforeMinute: 85)
        #expect(result.map(\.brief) == [["s0[..\(at))"], ["s0[\(at)..)"]])
        #expect(result.map(\.id) == ["conv-s0", "conv-s0-m\(at)"])
        #expect(result.map(\.startReason) == [nil, .quiet])
        #expect(result[0].endMs == t0 + minutesMs(2))
        #expect(result[1].startMs == t0 + minutesMs(85))

        // With the quiet rule off there is still nowhere to cut.
        #expect(
            group(segments, evidence: evidence, policy: .structuralOnly).map(\.brief) == [["s0"]])
    }

    @Test func aRecordingWithNoSpeechAtAllIsLeftWhole() {
        // Chopping silence into more silence helps nobody. With nothing said anywhere there is
        // no first word to start a conversation at — and nothing for the segmenter to read
        // either, so this holds with everything switched on.
        let segments = rotations(6)
        let evidence = evidenceMap((0..<6).map { settledEvidence("s\($0)", minutes: []) })
        #expect(group(segments, evidence: evidence).map(\.brief) == [(0..<6).map { "s\($0)" }])
        #expect(group(segments, evidence: evidence, policy: .default).count == 1)
        #expect(group(segments, evidence: evidence, policy: frozenPolicy).count == 1)
    }

    @Test func withNoEvidenceAtAllTheQuietRuleDoesNothing() {
        // Transcription off, or a library that has not been transcribed yet: the quiet rule
        // contributes nothing and the v1 rules stand alone. (With the segmenter ON, a long
        // untranscribed run is divided by length — `ConversationRunPlannerTests` pins that.)
        let segments = rotations(6)
        let structural = group(segments, policy: .structuralOnly)
        #expect(structural.map(\.brief) == [(0..<6).map { "s\($0)" }])
        #expect(group(segments) == structural)
    }

    // MARK: - trimming dead air off the ends

    @Test func silenceBeforeTheFirstWordIsPeeledOffTheFront() {
        // The 17 h 31 m row in Roger's library: a 16-hour silent segment handed straight over
        // to an hour of real conversation. The cut belongs next to the speech.
        let segments = rotations(4)
        let evidence = evidenceMap([
            settledEvidence("s0", minutes: []), settledEvidence("s1", minutes: []),
            settledEvidence("s2", minutes: []), settledEvidence("s3", minutes: [(0, 20)]),
        ])
        let result = group(segments, evidence: evidence)
        #expect(result.map(\.brief) == [["s0", "s1", "s2"], ["s3"]])
        #expect(result.map(\.id) == ["conv-s0", "conv-s3"])
        #expect(result[1].startReason == .quiet)

        // The first word need not sit on a join: five minutes into `s3`, the conversation
        // starts there and the silent head of `s3` stays with the silence.
        let late = evidenceMap([
            settledEvidence("s0", minutes: []), settledEvidence("s1", minutes: []),
            settledEvidence("s2", minutes: []), settledEvidence("s3", minutes: [(5, 20)]),
        ])
        let at = cut(beforeMinute: 5)
        #expect(
            group(segments, evidence: late).map(\.brief)
                == [["s0", "s1", "s2", "s3[..\(at))"], ["s3[\(at)..)"]])
    }

    @Test func silenceAfterTheLastWordIsPeeledOffTheBack() {
        let segments = rotations(4)
        let evidence = evidenceMap([
            settledEvidence("s0", minutes: [(0, 20)]), settledEvidence("s1", minutes: []),
            settledEvidence("s2", minutes: []), settledEvidence("s3", minutes: []),
        ])
        let result = group(segments, evidence: evidence)
        #expect(result.map(\.brief) == [["s0"], ["s1", "s2", "s3"]])
        #expect(result[1].startReason == .quiet)

        // The last word need not sit on a join either: the silent tail starts
        // `postRollMs` after it, inside `s0`.
        let early = evidenceMap([
            settledEvidence("s0", minutes: [(0, 4)]), settledEvidence("s1", minutes: []),
            settledEvidence("s2", minutes: []), settledEvidence("s3", minutes: []),
        ])
        let at = minutesMs(4) + ConversationRunPlanner.postRollMs
        let tail = group(segments, evidence: early)
        #expect(tail.map(\.brief) == [["s0[..\(at))"], ["s0[\(at)..)", "s1", "s2", "s3"]])
        #expect(tail[0].endMs == t0 + minutesMs(4))
    }

    // MARK: - the user always wins

    @Test func joinOverrideUndoesAUserStopSplit() {
        // "A manual stop is a strong signal, but not an absolute one." Rather than guessing
        // when a stop-then-resume was really one conversation, the app splits — which is what
        // Stop plainly means — and one tap puts it back, durably.
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10),
            close: userStopClose)
        let b = makeSegment(
            id: "b", stream: 2, startTimeMs: t0 + minutesMs(11),
            durationSamples: minutesSamples(4))
        #expect(group([a, b]).count == 2)
        #expect(group([a, b])[1].startReason == .userStop)

        let rejoined = group([a, b], overrides: ["b": .join])
        #expect(rejoined.map(\.brief) == [["a", "b"]])
    }

    @Test func joinOverrideAlsoDefeatsALongGapAndAnAutomaticQuietSplit() {
        // The override is the user's own answer, so it beats every rule in both directions.
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10))
        let b = makeSegment(
            id: "b", stream: 2, startTimeMs: t0 + hour, durationSamples: minutesSamples(4))
        #expect(group([a, b]).count == 2)
        #expect(group([a, b], overrides: ["b": .join]).count == 1)

        // A quiet split that lands on a segment's own start is a decision about that segment's
        // start, and the override there defeats it.
        let segments = rotations(4)
        let leading = evidenceMap([
            settledEvidence("s0", minutes: []), settledEvidence("s1", minutes: []),
            settledEvidence("s2", minutes: []), settledEvidence("s3", minutes: [(0, 20)]),
        ])
        #expect(group(segments, evidence: leading).count == 2)
        #expect(group(segments, evidence: leading, overrides: ["s3": .join]).count == 1)

        // One that lands inside a segment is defeated by a join at that position.
        let at = cut(beforeMinute: 18)
        #expect(group(segments, evidence: talkQuietTalk).count == 2)
        #expect(
            group(
                segments, evidence: talkQuietTalk,
                cutInputs: ConversationCutInputs(joins: ["s3": [at]])
            ).map(\.brief) == [["s0", "s1", "s2", "s3"]])
    }

    /// A join the person made BEFORE conversations became pieces. The quiet split it undid
    /// landed on a segment join (the one nearest the middle of the silence), so the decision is
    /// stored against that segment — `boundary_overrides(s2, join)`. The same silence now cuts
    /// at the first word after it, 18 minutes into `s3`, and the stored decision has to keep
    /// meaning what the person meant: these are one conversation. (It did not, until 25f14fe:
    /// a silence that contains a joined segment's start is not cut at all.)
    @Test func aJoinMadeAtTheOldJoinStillDefeatsTheQuietSplitItWasMadeAgainst() {
        let segments = rotations(4)
        #expect(group(segments, evidence: talkQuietTalk).count == 2)
        // The old rule could have put the split on either join inside the silence.
        for joined in ["s1", "s2"] {
            #expect(
                group(segments, evidence: talkQuietTalk, overrides: [joined: .join]).map(\.brief)
                    == [["s0", "s1", "s2", "s3"]], "\(joined)")
        }
        // A join about a segment whose start is NOT in the silence is about something else: the
        // talk of `s0` runs to minute 18, so `s0`'s own start is well clear of it.
        #expect(group(segments, evidence: talkQuietTalk, overrides: ["s0": .join]).count == 2)

        // The same for the silent tail of a run, and for the silence before its first word.
        let trailing = evidenceMap([
            settledEvidence("s0", minutes: [(0, 20)]), settledEvidence("s1", minutes: []),
            settledEvidence("s2", minutes: []), settledEvidence("s3", minutes: []),
        ])
        #expect(group(segments, evidence: trailing).count == 2)
        #expect(group(segments, evidence: trailing, overrides: ["s2": .join]).count == 1)
    }

    @Test func splitOverrideCutsWhereNothingElseWould() {
        let segments = rotations(3)
        let evidence = evidenceMap([
            settledEvidence("s0", minutes: [(0, 20)]), settledEvidence("s1", minutes: [(0, 20)]),
            settledEvidence("s2", minutes: [(0, 20)]),
        ])
        let result = group(segments, evidence: evidence, overrides: ["s1": .split])
        #expect(result.map(\.brief) == [["s0"], ["s1", "s2"]])
        #expect(result[1].startReason == .manual)
    }

    // MARK: - determinism

    @Test func theSameInputGivesTheSameGrouping() {
        let segments = rotations(4)
        for policy in [BoundaryPolicy.structuralOnly, .quietOnly, .default, frozenPolicy] {
            let first = group(segments, evidence: talkQuietTalk, policy: policy)
            let second = group(segments, evidence: talkQuietTalk, policy: policy)
            #expect(first == second)
            // The order the segments are handed over in is not part of the input.
            #expect(group(segments.reversed(), evidence: talkQuietTalk, policy: policy) == first)
        }
    }

    // MARK: - persistence and id stability

    @Test func startReasonRoundTripsThroughTheDatabase() async throws {
        let db = try AppDatabase.inMemory()
        let segments = rotations(4)
        let first = try await ConversationGrouper.rebuild(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: talkQuietTalk, policy: .quietOnly, db: db)
        #expect(first.map(\.startReason) == [nil, .quiet])

        // What is stored is what was returned, less `isProvisional`: that is a property of the
        // pass (the last conversation of a run that can still grow), not of the conversation.
        let persisted = try await db.reader.read { try ConversationGrouper.fetchAll($0) }
        #expect(persisted == first.map(\.asStored))

        // Same input twice ⇒ same ids, same reasons, same rows.
        let second = try await ConversationGrouper.rebuild(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: talkQuietTalk, policy: .quietOnly, db: db)
        #expect(second == first)
    }

    @Test func aNewSplitLeavesTheFirstHalfWithTheOriginalId() async throws {
        // Annotations, tags and follow-ups are keyed by conversation id. When a split appears
        // later (the transcript finally landed), the first half must keep what the user has
        // attached to it; only the new second half starts empty.
        let db = try AppDatabase.inMemory()
        let segments = rotations(4)
        var unsettled = talkQuietTalk
        unsettled["s1"] = unsettledEvidence("s1")
        unsettled["s2"] = unsettledEvidence("s2")
        let before = try await ConversationGrouper.rebuild(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: unsettled, policy: .quietOnly, db: db)
        #expect(before.map(\.id) == ["conv-s0"])

        let after = try await ConversationGrouper.rebuild(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: talkQuietTalk, policy: .quietOnly, db: db)
        #expect(after.map(\.id) == ["conv-s0", "conv-s3-m\(cut(beforeMinute: 18))"])
    }

    @Test func overridesArePersistentAndReadByTheRebuild() async throws {
        let db = try AppDatabase.inMemory()
        let store = BoundaryOverrideStore(db: db)
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10),
            close: userStopClose)
        let b = makeSegment(
            id: "b", stream: 2, startTimeMs: t0 + minutesMs(11),
            durationSamples: minutesSamples(4))
        func rebuild() async throws -> [GroupedConversation] {
            try await ConversationGrouper.rebuild(
                segments: [a, b], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
                policy: .quietOnly, db: db)
        }

        #expect(try await rebuild().count == 2)

        try await store.set(segmentId: "b", decision: .join, atMs: t0)
        #expect(try await store.decision(forSegment: "b") == .join)
        #expect(try await rebuild().map(\.brief) == [["a", "b"]])

        // Clearing it hands the join back to the rules — every manual decision is undoable.
        try await store.set(segmentId: "b", decision: nil)
        #expect(try await rebuild().count == 2)

        // Retention removed the segment: the decision goes with it.
        try await store.set(segmentId: "b", decision: .join)
        try await store.forget(segmentIds: ["b"])
        #expect(try await store.all().isEmpty)
    }

    @Test func theRebuildOffersNothingToTheRetiredReviewer() async throws {
        // Twelve minutes of quiet used to come back as a candidate for the semantic reviewer.
        // There is no such category any more: `candidates` is always empty, and a verdict left
        // in `boundary_reviews` by an earlier build splits nothing.
        let db = try AppDatabase.inMemory()
        let segments = rotations(3, minutesEach: 6)
        let evidence = evidenceMap([
            settledEvidence("s0", minutes: [(0, 3)]), settledEvidence("s1", minutes: []),
            settledEvidence("s2", minutes: [(3, 6)]),
        ])
        try await BoundaryReviewStore(db: db).save([
            BoundaryReview(
                segmentId: "s1", isBoundary: true, quietMs: minutesMs(12),
                reason: "different people", createdAtMs: t0)
        ])
        let rebuilt = try await ConversationGrouper.rebuildDetailed(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, policy: .quietOnly, db: db)
        #expect(rebuilt.candidates.isEmpty)
        #expect(rebuilt.conversations.map(\.brief) == [["s0", "s1", "s2"]])
    }
}
