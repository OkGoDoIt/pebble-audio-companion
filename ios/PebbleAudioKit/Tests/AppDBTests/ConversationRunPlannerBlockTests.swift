import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// How a run's turns become the segmenter's BLOCKS (`ConversationRunPlanner.blocks`), and where a
// cut in front of each would sit. The segmenter only ever sees blocks, so every signal it
// scores — the pause before a block, how many lines it has, whether more than one voice spoke,
// whether anybody was dictating — is decided here.

@Suite struct ConversationRunPlannerBlockTests {
    let t0 = testEpochMs

    private func turn(
        _ startS: Int64, _ endS: Int64, _ text: String = "harbour anchor rigging", speaker: String? = "A"
    ) -> SpeechSpan {
        SpeechSpan(startMs: startS * 1000, endMs: endS * 1000, text: text, speaker: speaker)
    }

    /// The blocks of a whole run.
    private func blocks(
        _ segments: [SegmentMeta], _ evidence: [SegmentSpeechEvidence],
        from lower: RunPosition? = nil, to upper: RunPosition? = nil, breaks: [RunPosition] = []
    ) -> [ConversationRunPlanner.PlacedBlock] {
        let map = evidenceMap(evidence)
        let members = ConversationRunPlanner.members(segments, evidence: map)
        let turns = ConversationRunPlanner.turns(members, evidence: map)
        return ConversationRunPlanner.blocks(
            from: lower ?? RunPosition(seg: 0, mediaMs: 0),
            to: upper ?? RunPosition(seg: segments.count, mediaMs: 0), breaks: breaks,
            members: members, turns: turns)
    }

    @Test func turnsAFewSecondsApartAreOneBlockUpToAMinute() {
        let segment = rotations(1, minutesEach: 10)
        // Gaps of 2 s, 5.9 s, then 6 s: the last one starts a new block.
        let close = blocks(
            segment,
            [settledEvidence("s0", turns: [turn(0, 8), turn(10, 18), turn(23, 30), turn(36, 40)])])
        #expect(close.count == 2)
        #expect(close[0].block.wallStartMs == t0 && close[0].block.wallEndMs == t0 + 30_000)
        #expect(close[1].block.wallStartMs == t0 + 36_000)
        #expect(close[1].block.gapBeforeMs == 6_000)

        // Continuous talk is broken every minute: a turn joins while the block it would make
        // is under sixty seconds long.
        let continuous = blocks(
            segment, [settledEvidence("s0", turns: (0..<30).map { turn($0 * 10, $0 * 10 + 8) })])
        #expect(continuous.count == 5)
        #expect(continuous.map { ($0.block.wallStartMs - t0) / 1000 } == [0, 60, 120, 180, 240])
        #expect(continuous.allSatisfy { $0.block.wallEndMs - $0.block.wallStartMs == 58_000 })
        #expect(continuous.dropFirst().allSatisfy { $0.block.gapBeforeMs == 2_000 })
        // The first block of a stretch has nothing before it.
        #expect(continuous[0].block.gapBeforeMs == 0)
    }

    @Test func aBlockCountsItsWordsItsTermsItsLinesAndItsVoices() {
        let segment = rotations(1, minutesEach: 10)
        let placed = blocks(
            segment,
            [
                settledEvidence(
                    "s0",
                    turns: [
                        turn(0, 4, "Hello the harbour was busy", speaker: "A"),
                        turn(5, 9, "anchor rigging", speaker: "B"),
                        turn(10, 12, "keel", speaker: "B"),  // the same voice, 1 s on: same line
                        turn(18, 20, "mast tide", speaker: "B"),  // the same voice after 6 s: a breath
                        turn(21, 25, "jib comma rudder", speaker: "A"),
                    ])
            ])
        // 12 → 18 s is a six-second gap: a new block.
        #expect(placed.count == 2)
        let first = placed[0].block
        #expect(first.words == 8)
        #expect(first.terms == ["harbour", "busy", "anchor", "rigging", "keel"].map(ConversationLexicon.fnv1a))
        #expect(first.lines == 2)
        #expect(first.isDialogue)
        #expect(!first.isDictation && !first.isForeign)
        #expect(first.opensWithGreeting)

        let second = placed[1].block
        #expect(second.words == 5)
        #expect(second.lines == 2)
        #expect(second.isDialogue)
        // Any turn dictating makes the block dictation …
        #expect(second.isDictation)
        // … but a greeting only counts at the opening of the block.
        #expect(!second.opensWithGreeting)
        #expect(!placed.contains { $0.block.isOpaque })
    }

    @Test func oneVoiceIsNotADialogueAndTurnsWithNoLabelAreOneVoice() {
        let segment = rotations(1, minutesEach: 10)
        let solo = blocks(
            segment, [settledEvidence("s0", turns: [turn(0, 4), turn(5, 9), turn(10, 14)])])
        #expect(solo.count == 1)
        #expect(!solo[0].block.isDialogue)
        #expect(solo[0].block.lines == 1)

        let unlabelled = blocks(
            segment,
            [
                settledEvidence(
                    "s0", turns: [turn(0, 4, speaker: nil), turn(5, 9, speaker: nil)])
            ])
        #expect(!unlabelled[0].block.isDialogue)

        // Timings alone — no text, no features — still make blocks; they just carry no flags.
        let bare = blocks(
            segment,
            [
                settledEvidence(
                    "s0",
                    turns: [
                        SpeechSpan(startMs: 0, endMs: 4_000, wordCount: 3),
                        SpeechSpan(startMs: 5_000, endMs: 9_000, wordCount: 4),
                    ])
            ])
        #expect(bare.count == 1)
        #expect(bare[0].block.words == 7 && bare[0].block.terms.isEmpty)
        #expect(!bare[0].block.isDialogue && !bare[0].block.isDictation)
    }

    @Test func aBlockNeverRunsAcrossTwoRecordings() {
        // Talk straight through a rotation: the last turn of `s0` ends two seconds before the
        // first of `s1` starts, and they are still two blocks — a cut can sit on the join.
        let segments = rotations(2, minutesEach: 1)
        let placed = blocks(
            segments,
            [
                settledEvidence("s0", turns: [turn(40, 48), turn(50, 58)]),
                settledEvidence("s1", turns: [turn(0, 8), turn(10, 18)]),
            ])
        #expect(placed.count == 2)
        #expect(placed.map(\.position) == [RunPosition(seg: 0, mediaMs: 38_500), RunPosition(seg: 1, mediaMs: 0)])
        #expect(placed[1].block.gapBeforeMs == 2_000)
    }

    @Test func aCutSitsAPreRollAheadOfTheBlocksFirstWordButNotInsideTheTurnBefore() {
        let segment = rotations(1, minutesEach: 10)
        let placed = blocks(
            segment,
            [settledEvidence("s0", turns: [turn(0, 8), turn(20, 28), turn(100, 101), turn(107, 110)])])
        #expect(
            placed.map(\.position.mediaMs) == [
                0, 20_000 - ConversationRunPlanner.preRollMs, 100_000 - ConversationRunPlanner.preRollMs,
                107_000 - ConversationRunPlanner.preRollMs,
            ])
        #expect(placed.map(\.firstTurn) == [0, 1, 2, 3])
        // Where each block's first WORD is, as opposed to where a cut before it would go.
        let map = evidenceMap([settledEvidence("s0", turns: [turn(0, 8), turn(20, 28)])])
        let members = ConversationRunPlanner.members(segment, evidence: map)
        let turns = ConversationRunPlanner.turns(members, evidence: map)
        let two = ConversationRunPlanner.blocks(
            from: RunPosition(seg: 0, mediaMs: 0), to: RunPosition(seg: 1, mediaMs: 0),
            members: members, turns: turns)
        #expect(
            ConversationRunPlanner.blockStart(two[1], in: turns)
                == RunPosition(seg: 0, mediaMs: 20_000))
    }

    @Test func anUnsettledRecordingIsOneOpaqueBlockAsLongAsItIs() {
        let segments = rotations(3, minutesEach: 15)
        let placed = blocks(
            segments,
            [
                settledEvidence("s0", turns: [turn(0, 8)]), unsettledEvidence("s1"),
                settledEvidence("s2", turns: [turn(30, 38)]),
            ])
        #expect(placed.map(\.block.isOpaque) == [false, true, false])
        let opaque = placed[1]
        #expect(opaque.position == RunPosition(seg: 1, mediaMs: 0))
        #expect(opaque.firstTurn == nil)
        #expect(opaque.block.wallStartMs == t0 + minutesMs(15))
        #expect(opaque.block.wallEndMs == t0 + minutesMs(30))
        #expect(opaque.block.lines == 0 && opaque.block.words == 0 && opaque.block.terms.isEmpty)
        // The talk after it is measured from the end of the unheard audio, not from the last
        // word before it: nothing is known about what was said in between.
        #expect(placed[2].block.gapBeforeMs == 30_000)

        // A settled recording in which nobody spoke makes no block at all.
        let silent = blocks(
            segments,
            [
                settledEvidence("s0", turns: [turn(0, 8)]), settledEvidence("s1", turns: []),
                settledEvidence("s2", turns: [turn(30, 38)]),
            ])
        #expect(silent.count == 2)
        #expect(silent[1].block.gapBeforeMs == minutesMs(30) + 30_000 - 8_000)
    }

    @Test func missingAudioInsideAPauseCountsHalf() {
        // Two turns eleven minutes apart, ten of those minutes a hole in the record. A hole is
        // not evidence that nobody spoke: the pause reads as six minutes, not eleven.
        var segment = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(30),
            gaps: [lossGap(atSample: minutesSamples(2), minutes: 10)])
        segment.frameCount -= 10 * 3_000
        #expect(SegmentMediaClock(segment).isExact)
        // On the media clock the second turn is one minute after the first.
        let turns = [turn(0, 60), turn(120, 180)]
        let lossy = blocks([segment], [settledEvidence("a", turns: turns)])
        #expect(lossy.count == 2)
        #expect(lossy[1].block.wallStartMs == t0 + minutesMs(12))
        #expect(lossy[1].block.gapBeforeMs == minutesMs(11) - minutesMs(5))

        // The same pause as watch-suppressed SILENCE is quiet, not loss, and counts in full.
        var quiet = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(30),
            gaps: [silenceGap(atSample: minutesSamples(2), minutes: 10)])
        quiet.frameCount -= 10 * 3_000
        let silent = blocks([quiet], [settledEvidence("a", turns: turns)])
        #expect(silent[1].block.gapBeforeMs == minutesMs(11))
    }

    @Test func aStretchStartsAndEndsWhereItIsToldTo() {
        let segments = rotations(2, minutesEach: 10)
        let evidence = [
            settledEvidence("s0", turns: [turn(0, 8), turn(100, 108), turn(300, 308)]),
            settledEvidence("s1", turns: [turn(0, 8), turn(200, 208)]),
        ]
        // From just before the second turn of `s0` to just before the second turn of `s1`.
        let placed = blocks(
            segments, evidence, from: RunPosition(seg: 0, mediaMs: 98_500),
            to: RunPosition(seg: 1, mediaMs: 198_500))
        #expect(
            placed.map(\.position) == [
                RunPosition(seg: 0, mediaMs: 98_500), RunPosition(seg: 0, mediaMs: 298_500),
                RunPosition(seg: 1, mediaMs: 0),
            ])
        // Nothing precedes the first block of a stretch.
        #expect(placed[0].block.gapBeforeMs == 0)
        #expect(placed[1].block.gapBeforeMs == 192_000)

        // An unsettled recording cut by the stretch is opaque only for the part inside it.
        let partly = blocks(
            segments, [evidence[0], unsettledEvidence("s1")],
            from: RunPosition(seg: 0, mediaMs: 298_500), to: RunPosition(seg: 1, mediaMs: 240_000))
        #expect(partly.map(\.block.isOpaque) == [false, true])
        #expect(partly[1].block.wallStartMs == t0 + minutesMs(10))
        #expect(partly[1].block.wallEndMs == t0 + minutesMs(14))
    }

    @Test func aBreakStartsABlockAtTheFirstTurnAtOrAfterIt() {
        let segment = rotations(1, minutesEach: 10)
        let evidence = [settledEvidence("s0", turns: (0..<12).map { turn($0 * 10, $0 * 10 + 8) })]
        let plain = blocks(segment, evidence)
        #expect(plain.map { ($0.block.wallStartMs - t0) / 1000 } == [0, 60])

        // A held cut a pre-roll ahead of the turn at 0:30 — in the middle of what was one block.
        let broken = blocks(segment, evidence, breaks: [RunPosition(seg: 0, mediaMs: 28_500)])
        #expect(broken.map { ($0.block.wallStartMs - t0) / 1000 } == [0, 30, 90])
        #expect(broken[1].position == RunPosition(seg: 0, mediaMs: 28_500))
        // A break exactly where a block already starts changes nothing.
        let natural = blocks(segment, evidence, breaks: [RunPosition(seg: 0, mediaMs: 58_500)])
        #expect(natural.map(\.block) == plain.map(\.block))
        #expect(natural.map(\.position) == plain.map(\.position))
        // Two breaks before the same turn are one break.
        let doubled = blocks(
            segment, evidence,
            breaks: [RunPosition(seg: 0, mediaMs: 21_000), RunPosition(seg: 0, mediaMs: 28_500)])
        #expect(doubled.map(\.block) == broken.map(\.block))
    }

    @Test func theTurnsOfARunAreOnBothClocksInRunOrder() {
        // The second recording lost its middle five minutes: media and wall part company.
        var lossy = makeSegment(
            id: "s1", stream: 7, startTimeMs: t0, firstSample: minutesSamples(10),
            durationSamples: minutesSamples(10),
            gaps: [lossGap(atSample: minutesSamples(12), minutes: 5)])
        lossy.frameCount -= 5 * 3_000
        let segments = [rotations(1, minutesEach: 10)[0], lossy, rotations(3, minutesEach: 10)[2]]
        let map = evidenceMap([
            settledEvidence("s0", turns: [turn(30, 40), turn(5, 9)]),  // out of order on disk
            settledEvidence("s1", turns: [turn(60, 70), turn(150, 160)]),
            unsettledEvidence("s2"),
        ])
        let members = ConversationRunPlanner.members(segments, evidence: map)
        #expect(members.map(\.isSettled) == [true, true, false])
        #expect(members.map(\.mediaSpanMs) == [minutesMs(10), minutesMs(5), minutesMs(10)])
        let turns = ConversationRunPlanner.turns(members, evidence: map)
        // Sorted within each member, members in run order, nothing from the unsettled one.
        #expect(turns.map(\.seg) == [0, 0, 1, 1])
        #expect(turns.map(\.mediaStartMs) == [5_000, 30_000, 60_000, 150_000])
        #expect(
            turns.map { $0.wallStartMs - t0 } == [
                5_000, 30_000, minutesMs(10) + 60_000,
                // 2:30 of stored audio is 7:30 of wall time: the five lost minutes came first.
                minutesMs(10) + minutesMs(5) + 150_000,
            ])
        #expect(turns.allSatisfy { $0.wallEndMs >= $0.wallStartMs && $0.mediaEndMs >= $0.mediaStartMs })
        #expect(turns[0].words == 3 && turns[0].features != nil)
    }
}
