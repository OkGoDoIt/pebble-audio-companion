import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// Where the conversations inside one run of segments start (`ConversationRunPlanner`), exercised
// the way the app reaches it: through `ConversationGrouper.group` / `groupDetailed`.
//
// Three layers, each of which only ever adds cuts — hard cuts at long settled silences, fixed
// cuts (the segmenter's settled decisions and the person's splits), and the segmenter over what
// is left — and one invariant over all of them: the pieces tile the library. Exact answers are
// pinned with `frozenPolicy` (the tests' own numbers) or with the segmenter off; the shipped
// `.default` is only ever held to things no tuning can change.

// MARK: - a day on the wall clock

enum TalkKind {
    /// Two voices, a turn every ten seconds.
    case dialogue
    /// One voice with spoken punctuation, a turn every twenty seconds.
    case dictation
}

struct Stretch {
    var from: Int64
    var to: Int64
    var kind: TalkKind
    var vocabulary: [String]

    static func dialogue(_ from: Int64, _ to: Int64, _ vocabulary: [String] = sailingWords)
        -> Stretch
    { Stretch(from: from, to: to, kind: .dialogue, vocabulary: vocabulary) }

    static func dictation(_ from: Int64, _ to: Int64, _ vocabulary: [String] = cookingWords)
        -> Stretch
    { Stretch(from: from, to: to, kind: .dictation, vocabulary: vocabulary) }
}

struct Day {
    var segments: [SegmentMeta]
    var evidence: [String: SegmentSpeechEvidence]
    /// The segment still being recorded into, when the day was built with `recording: true`.
    var open: String?

    static func + (a: Day, b: Day) -> Day {
        Day(
            segments: a.segments + b.segments,
            evidence: a.evidence.merging(b.evidence) { first, _ in first },
            open: b.open ?? a.open)
    }
}

/// `minutes` of recording as abutting `rotation`-minute segments (`s0`, `s1`, …), with `talk`
/// laid out in wall minutes from the start. Every segment is transcribed and settled unless its
/// index is in `unsettled`, in which case nothing is known about it.
///
/// `recording: true` appends one more rotation that is still OPEN — no close reason, no
/// transcript — and names it in `Day.open`: the run is being recorded into, which is what makes
/// it open-ended. Without it nothing is open and what is there is all there will be.
func day(
    minutes: Int64, rotation: Int64 = 15, prefix: String = "s", startTimeMs: Int64 = testEpochMs,
    stream: UInt32 = 7, talk: [Stretch] = [], unsettled: Set<Int> = [], recording: Bool = false
) -> Day {
    let heard = Int((minutes + rotation - 1) / rotation)
    let count = heard + (recording ? 1 : 0)
    var segments = rotations(
        count, minutesEach: UInt64(rotation), stream: stream, startTimeMs: startTimeMs,
        prefix: prefix)
    var evidence: [String: SegmentSpeechEvidence] = [:]
    var open: String?
    if recording {
        segments[heard].closeReason = nil
        open = segments[heard].segmentId
    }
    for index in 0..<count {
        let id = segments[index].segmentId
        guard !unsettled.contains(index), index < heard else {
            evidence[id] = unsettledEvidence(id)
            continue
        }
        segments[index].transcriptionState = .complete
        let segmentStart = Int64(index) * rotation
        var turns: [SpeechSpan] = []
        for stretch in talk {
            let low = max(stretch.from, segmentStart)
            let high = min(stretch.to, segmentStart + rotation)
            guard high > low else { continue }
            let fromMs = (low - segmentStart) * 60_000
            let toMs = (high - segmentStart) * 60_000
            switch stretch.kind {
            case .dialogue:
                turns += dialogueTurns(fromMs: fromMs, toMs: toMs, vocabulary: stretch.vocabulary)
            case .dictation:
                turns += dictationTurns(fromMs: fromMs, toMs: toMs, vocabulary: stretch.vocabulary)
            }
        }
        evidence[id] = settledEvidence(id, turns: turns.sorted { $0.startMs < $1.startMs })
    }
    return Day(segments: segments, evidence: evidence, open: open)
}

private let hardReasons: Set<ConversationStartReason> = [.quiet, .interrupted]
private let segmenterReasons: Set<ConversationStartReason> = [.topicChange, .lull, .length]

/// What must be true of ANY grouping, whatever went in and whatever the policy.
private func expectWellFormed(
    _ grouping: ConversationGrouper.Grouping, segments: [SegmentMeta], open: String?,
    policy: BoundaryPolicy, inputs: ConversationCutInputs = .none, _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let conversations = grouping.conversations
    // A held cut keeps the reason it was made for, whatever the policy of this pass.
    let heldReasons = Set(inputs.committed.values.flatMap(\.values))
    expectPiecesTile(conversations, segments: segments, label, sourceLocation: sourceLocation)
    for (index, conversation) in conversations.enumerated() {
        guard let first = conversation.members.first, let last = conversation.members.last else {
            continue
        }
        // Without a previous grouping, the id is the position the conversation starts at.
        let start = ConversationCut(segmentId: first.segmentId, mediaMs: first.startMediaMs ?? 0)
        #expect(
            conversation.id == start.conversationId, "\(label)", sourceLocation: sourceLocation)
        // Only the very first conversation starts for no reason.
        #expect(
            (conversation.startReason == nil) == (index == 0),
            "\(conversation.id): \(String(describing: conversation.startReason)). \(label)",
            sourceLocation: sourceLocation)
        // A conversation that starts inside a segment was cut there by a planner layer.
        if first.startMediaMs != nil, let reason = conversation.startReason {
            #expect(
                hardReasons.contains(reason) || segmenterReasons.contains(reason)
                    || reason == .manual,
                "\(conversation.id): \(reason). \(label)", sourceLocation: sourceLocation)
        }
        if let reason = conversation.startReason {
            if policy.quietSplitMs == .max {
                #expect(
                    !hardReasons.contains(reason), "\(conversation.id). \(label)",
                    sourceLocation: sourceLocation)
            }
            if policy.segmenter == nil, heldReasons.isEmpty {
                #expect(
                    !segmenterReasons.contains(reason),
                    "\(conversation.id): \(reason). \(label)", sourceLocation: sourceLocation)
            }
        }
        // Live is the piece that runs to the end of the open segment, and nothing else.
        #expect(
            conversation.isLive == (open != nil && last.segmentId == open && last.endMediaMs == nil),
            "\(conversation.id). \(label)", sourceLocation: sourceLocation)
        #expect(
            conversation.endMs >= conversation.startMs, "\(conversation.id). \(label)",
            sourceLocation: sourceLocation)
    }
    #expect(
        conversations.filter(\.isLive).count == (open == nil ? 0 : 1), "\(label)",
        sourceLocation: sourceLocation)

    // What is offered for committing: a segmenter cut, inside a segment, that starts one of the
    // conversations — and never one that is already held.
    let starts = Dictionary(
        conversations.compactMap { convo in
            convo.members.first.map {
                (ConversationCut(segmentId: $0.segmentId, mediaMs: $0.startMediaMs ?? 0), convo)
            }
        }, uniquingKeysWith: { first, _ in first })
    for (cut, reason) in grouping.cutsToCommit {
        #expect(
            inputs.committed[cut.segmentId]?[cut.mediaMs] == nil,
            "\(cut) is already held. \(label)", sourceLocation: sourceLocation)
        #expect(cut.mediaMs > 0, "\(cut). \(label)", sourceLocation: sourceLocation)
        #expect(
            reason == .topicChange || reason == .lull, "\(cut): \(reason). \(label)",
            sourceLocation: sourceLocation)
        #expect(
            starts[cut]?.startReason == reason, "\(cut). \(label)", sourceLocation: sourceLocation)
    }
}

@Suite struct ConversationRunPlannerTests {
    let t0 = testEpochMs
    let preRoll = ConversationRunPlanner.preRollMs
    let postRoll = ConversationRunPlanner.postRollMs

    private func grouping(
        _ day: Day, policy: BoundaryPolicy, open: String? = nil, pauses: [PauseInterval] = [],
        overrides: [String: BoundaryDecision] = [:], cutInputs: ConversationCutInputs = .none,
        previous: [GroupedConversation]? = nil, memo: GroupingMemo? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> ConversationGrouper.Grouping {
        let grouping = ConversationGrouper.groupDetailed(
            segments: day.segments, pauses: pauses, openSegmentId: open ?? day.open,
            fallbackTimeZoneID: "UTC", previous: previous, evidence: day.evidence,
            overrides: overrides, policy: policy, cutInputs: cutInputs, memo: memo)
        expectPiecesTile(grouping.conversations, segments: day.segments, sourceLocation: sourceLocation)
        return grouping
    }

    private func group(
        _ day: Day, policy: BoundaryPolicy, open: String? = nil,
        overrides: [String: BoundaryDecision] = [:], cutInputs: ConversationCutInputs = .none,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> [GroupedConversation] {
        grouping(
            day, policy: policy, open: open, overrides: overrides, cutInputs: cutInputs,
            sourceLocation: sourceLocation
        ).conversations
    }

    /// Thirty minutes of two people talking about sailing, a four-minute pause, then one voice
    /// dictating about cooking until `minutes`. The margins are wide on purpose: any sane tuning
    /// cuts this once, where the dictation starts — four minutes into `s2`.
    private func twoModes(minutes: Int64, unsettled: Set<Int> = []) -> Day {
        day(
            minutes: minutes, talk: [.dialogue(0, 30), .dictation(34, minutes)],
            unsettled: unsettled)
    }
    private var modeChange: ConversationCut {
        ConversationCut(segmentId: "s2", mediaMs: minutesMs(4) - preRoll)
    }

    // MARK: - the pieces tile

    @Test func thePiecesTileTheRunForEveryShapeOfInput() {
        var open = twoModes(minutes: 90)
        open.segments[5].closeReason = nil
        open.evidence["s5"] = unsettledEvidence("s5")
        var stopped = twoModes(minutes: 60)
        stopped.segments[3].closeReason = userStopClose

        let shapes: [(name: String, day: Day, open: String?, overrides: [String: BoundaryDecision], inputs: ConversationCutInputs)] = [
            ("nothing at all", Day(segments: [], evidence: [:], open: nil), nil, [:], .none),
            ("one short segment, no evidence", day(minutes: 5, rotation: 5, unsettled: [0]), nil, [:], .none),
            ("ten untranscribed hours", day(minutes: 600, unsettled: Set(0..<40)), nil, [:], .none),
            ("two silent hours", day(minutes: 120), nil, [:], .none),
            ("two modes", twoModes(minutes: 90), nil, [:], .none),
            ("two modes, still recording", open, "s5", [:], .none),
            ("two modes, stopped", stopped, nil, [:], .none),
            ("two modes, the middle not transcribed", twoModes(minutes: 90, unsettled: [2, 3]), nil, [:], .none),
            (
                "talk, a long silence, talk",
                day(minutes: 120, talk: [.dialogue(0, 20), .dialogue(80, 120)]), nil, [:], .none
            ),
            (
                "silence first, silence last",
                day(minutes: 120, talk: [.dialogue(50, 70)]), nil, [:], .none
            ),
            (
                "three hours of one kind of talk",
                day(minutes: 180, talk: [.dialogue(0, 180)]), nil, [:], .none
            ),
            (
                "splits, joins and settled cuts",
                twoModes(minutes: 90), nil, ["s4": .join, "s1": .split],
                ConversationCutInputs(
                    committed: ["s0": [300_000: .topicChange], "s3": [1: .lull, 899_999: .lull]],
                    splits: ["s5": [450_000], "s0": [300_000]],
                    joins: ["s2": [238_500], "s3": [10_000]])
            ),
            (
                "decisions about places that do not exist",
                twoModes(minutes: 60), nil, ["nope": .split],
                ConversationCutInputs(
                    committed: ["s0": [0: .lull, 900_000: .lull, 5_000_000: .lull], "gone": [5: .lull]],
                    splits: ["s1": [0, 900_000, -5], "gone": [1]], joins: ["gone": [1]])
            ),
            (
                "two runs and a third",
                twoModes(minutes: 60)
                    + day(
                        minutes: 45, prefix: "t", startTimeMs: t0 + minutesMs(200), stream: 8,
                        talk: [.dialogue(3, 40)])
                    + day(minutes: 30, prefix: "u", startTimeMs: t0 + minutesMs(900), stream: 9, unsettled: [0, 1]),
                nil, [:], .none
            ),
        ]
        for shape in shapes {
            for (policyName, policy) in [
                ("structuralOnly", BoundaryPolicy.structuralOnly), ("quietOnly", .quietOnly),
                ("default", .default), ("frozen", frozenPolicy),
            ] {
                let label = "\(shape.name), \(policyName)"
                let result = ConversationGrouper.groupDetailed(
                    segments: shape.day.segments, pauses: [], openSegmentId: shape.open,
                    fallbackTimeZoneID: "UTC", evidence: shape.day.evidence,
                    overrides: shape.overrides, policy: policy, cutInputs: shape.inputs)
                expectWellFormed(
                    result, segments: shape.day.segments, open: shape.open, policy: policy,
                    inputs: shape.inputs, label)
                // Deterministic, and independent of the order the segments are handed over in.
                let again = ConversationGrouper.groupDetailed(
                    segments: shape.day.segments.reversed(), pauses: [],
                    openSegmentId: shape.open, fallbackTimeZoneID: "UTC",
                    evidence: shape.day.evidence, overrides: shape.overrides, policy: policy,
                    cutInputs: shape.inputs)
                #expect(again == result, "\(label)")
            }
        }
    }

    /// The same invariants over days nobody designed: random runs of random segments — talking,
    /// silent, untranscribed, open — with random decisions laid over them.
    @Test func thePiecesTileRandomDays() {
        var generator = SeededGenerator(seed: 9_301)
        var seen = Set<ConversationStartReason>()
        var offered = 0
        for scenario in 0..<40 {
            var whole = Day(segments: [], evidence: [:], open: nil)
            var clock = t0
            let runs = Int.random(in: 1...3, using: &generator)
            var inputs = ConversationCutInputs()
            var overrides: [String: BoundaryDecision] = [:]
            for run in 0..<runs {
                let rotation = Int64([5, 10, 15, 20].randomElement(using: &generator)!)
                let count = Int.random(in: 1...8, using: &generator)
                let minutes = rotation * Int64(count)
                var talk: [Stretch] = []
                var minute: Int64 = 0
                while minute < minutes {
                    let length = Int64.random(in: 1...40, using: &generator)
                    let end = min(minute + length, minutes)
                    switch Int.random(in: 0..<4, using: &generator) {
                    case 0: talk.append(.dialogue(minute, end, sailingWords))
                    case 1: talk.append(.dictation(minute, end, cookingWords))
                    case 2: talk.append(.dialogue(minute, end, cookingWords))
                    default: break  // silence
                    }
                    minute = end
                }
                let unsettled = Set((0..<count).filter { _ in Int.random(in: 0..<5, using: &generator) == 0 })
                var part = day(
                    minutes: minutes, rotation: rotation, prefix: "r\(run)s", startTimeMs: clock,
                    stream: UInt32(run + 1), talk: talk, unsettled: unsettled)
                if Int.random(in: 0..<4, using: &generator) == 0 {
                    part.segments[count - 1].closeReason = userStopClose
                }
                for segment in part.segments {
                    let span = rotation * 60_000
                    switch Int.random(in: 0..<12, using: &generator) {
                    case 0: inputs.splits[segment.segmentId] = [Int64.random(in: 1..<span, using: &generator)]
                    case 1: inputs.joins[segment.segmentId] = [Int64.random(in: 0..<span, using: &generator)]
                    case 2:
                        inputs.committed[segment.segmentId] = [
                            Int64.random(in: 1..<span, using: &generator): .topicChange
                        ]
                    case 3: overrides[segment.segmentId] = Bool.random(using: &generator) ? .split : .join
                    default: break
                    }
                }
                whole = whole + part
                clock += minutes * 60_000 + Int64.random(in: 1...120, using: &generator) * 60_000
            }
            var open: String?
            if Bool.random(using: &generator), let last = whole.segments.indices.last {
                whole.segments[last].closeReason = nil
                whole.evidence[whole.segments[last].segmentId] = unsettledEvidence(
                    whole.segments[last].segmentId)
                open = whole.segments[last].segmentId
            }
            for (policyName, policy) in [
                ("structuralOnly", BoundaryPolicy.structuralOnly), ("quietOnly", .quietOnly),
                ("default", .default), ("frozen", frozenPolicy),
            ] {
                let label = "random day \(scenario), \(policyName)"
                let result = ConversationGrouper.groupDetailed(
                    segments: whole.segments, pauses: [], openSegmentId: open,
                    fallbackTimeZoneID: "UTC", evidence: whole.evidence, overrides: overrides,
                    policy: policy, cutInputs: inputs)
                seen.formUnion(result.conversations.compactMap(\.startReason))
                offered += result.cutsToCommit.count
                expectWellFormed(
                    result, segments: whole.segments, open: open, policy: policy,
                    inputs: inputs, label)
                let again = ConversationGrouper.groupDetailed(
                    segments: whole.segments, pauses: [], openSegmentId: open,
                    fallbackTimeZoneID: "UTC", evidence: whole.evidence, overrides: overrides,
                    policy: policy, cutInputs: inputs)
                #expect(again == result, "\(label)")

                // THE ROUND TRIP: what this pass offers for committing, held as committed in the
                // next, gives the same conversations — and is not offered again.
                var held = inputs
                for (cut, reason) in result.cutsToCommit {
                    held.committed[cut.segmentId, default: [:]][cut.mediaMs] = reason
                }
                let second = ConversationGrouper.groupDetailed(
                    segments: whole.segments, pauses: [], openSegmentId: open,
                    fallbackTimeZoneID: "UTC", evidence: whole.evidence, overrides: overrides,
                    policy: policy, cutInputs: held)
                #expect(second.conversations.map(\.id) == result.conversations.map(\.id), "\(label)")
                #expect(
                    second.conversations.map(\.members) == result.conversations.map(\.members),
                    "\(label)")
                #expect(
                    second.conversations.map(\.startReason)
                        == result.conversations.map(\.startReason), "\(label)")
                #expect(
                    Set(second.cutsToCommit.keys).isDisjoint(with: result.cutsToCommit.keys),
                    "\(label)")
            }
        }
        // The generator really does reach every layer: structural starts, long silences, the
        // person's splits, the segmenter's cuts of each kind, and cuts old enough to commit.
        #expect(seen == Set(ConversationStartReason.allCases).subtracting([.pause, .interrupted]))
        #expect(offered > 20)
    }

    // MARK: - hard cuts: where a long settled silence puts them

    @Test func anInteriorSilenceCutsAtTheFirstWordAfterIt() {
        // Twenty minutes of talk, an hour of nothing, forty minutes of talk. The new
        // conversation starts a pre-roll ahead of its first word, five minutes into `s5`
        // (75–90 min): the silence, and the silent head of `s5`, stay with the one before.
        let quiet = day(minutes: 120, talk: [.dialogue(0, 20), .dialogue(80, 120)])
        let at = minutesMs(5) - preRoll
        for policy in [BoundaryPolicy.quietOnly, frozenPolicy] {
            let result = group(quiet, policy: policy)
            #expect(
                result.map(\.brief)
                    == [["s0", "s1", "s2", "s3", "s4", "s5[..\(at))"], ["s5[\(at)..)", "s6", "s7"]])
            #expect(result.map(\.id) == ["conv-s0", "conv-s5-m\(at)"])
            #expect(result.map(\.startReason) == [nil, .quiet])
            #expect(result[0].startMs == t0)
            #expect(result[0].endMs == t0 + minutesMs(20) - 2_000)  // the last turn ends at 19:58
            #expect(result[1].startMs == t0 + minutesMs(80))
        }
    }

    @Test func theCutNeverReachesBackIntoThePreviousTurnOrBeforeItsSegment() {
        // First word less than a pre-roll into its segment: the cut is the segment's own start,
        // and the conversation keeps the id it always had.
        let edge = makeSegment(id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(30))
        let next = makeSegment(
            id: "b", stream: 1, startTimeMs: t0, firstSample: minutesSamples(30),
            durationSamples: minutesSamples(30))
        let evidence = evidenceMap([
            settledEvidence("a", turns: [SpeechSpan(startMs: 0, endMs: minutesMs(5))]),
            settledEvidence(
                "b", turns: [SpeechSpan(startMs: 700, endMs: minutesMs(30))]),
        ])
        let result = ConversationGrouper.group(
            segments: [edge, next], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, policy: .quietOnly)
        #expect(result.map(\.brief) == [["a"], ["b"]])
        #expect(result.map(\.id) == ["conv-a", "conv-b"])
        #expect(result[1].startReason == .quiet)

        // Two people talking at once across the silence's far edge cannot happen — but a cut
        // computed for a turn that OVERLAPS the one before it must not land inside that one, or
        // after the turn it introduces.
        let turns = [
            RunTurn(seg: 0, mediaStartMs: 0, mediaEndMs: 10_000, wallStartMs: 0, wallEndMs: 10_000, words: 1),
            RunTurn(seg: 0, mediaStartMs: 10_400, mediaEndMs: 12_000, wallStartMs: 10_400, wallEndMs: 12_000, words: 1),
            RunTurn(seg: 0, mediaStartMs: 11_000, mediaEndMs: 15_000, wallStartMs: 11_000, wallEndMs: 15_000, words: 1),
            RunTurn(seg: 0, mediaStartMs: 60_000, mediaEndMs: 61_000, wallStartMs: 60_000, wallEndMs: 61_000, words: 1),
            RunTurn(seg: 1, mediaStartMs: 900, mediaEndMs: 2_000, wallStartMs: 900_900, wallEndMs: 902_000, words: 1),
        ]
        // 400 ms after the previous turn ended: the cut sits at that end, not 1.5 s back.
        #expect(
            ConversationRunPlanner.position(beforeTurn: 1, in: turns)
                == RunPosition(seg: 0, mediaMs: 10_000))
        // The previous turn is still going: the cut is the turn's own start.
        #expect(
            ConversationRunPlanner.position(beforeTurn: 2, in: turns)
                == RunPosition(seg: 0, mediaMs: 11_000))
        // Room to spare: a full pre-roll.
        #expect(
            ConversationRunPlanner.position(beforeTurn: 3, in: turns)
                == RunPosition(seg: 0, mediaMs: 60_000 - preRoll))
        // The first turn of a segment does not look back into the segment before.
        #expect(
            ConversationRunPlanner.position(beforeTurn: 4, in: turns)
                == RunPosition(seg: 1, mediaMs: 0))
        #expect(
            ConversationRunPlanner.position(beforeTurn: 0, in: turns)
                == RunPosition(seg: 0, mediaMs: 0))
    }

    @Test func aLeadingSilenceIsItsOwnConversationAndTheTalkStartsAtItsFirstWord() {
        // Fifty minutes of nothing, then talk from 50 to 70 (five minutes into `s3`), then
        // fifty minutes of nothing to the end of the run.
        let quiet = day(minutes: 120, talk: [.dialogue(50, 70)])
        let first = minutesMs(5) - preRoll
        // The last turn of the talk ends at 69:58 — 9:58 into `s4` — and the tail starts a
        // post-roll after it.
        let tail = minutesMs(10) - 2_000 + postRoll
        for policy in [BoundaryPolicy.quietOnly, frozenPolicy] {
            let result = group(quiet, policy: policy)
            #expect(
                result.map(\.brief) == [
                    ["s0", "s1", "s2", "s3[..\(first))"],
                    ["s3[\(first)..)", "s4[..\(tail))"],
                    ["s4[\(tail)..)", "s5", "s6", "s7"],
                ])
            #expect(result.map(\.startReason) == [nil, .quiet, .quiet])
            #expect(result.map(\.id) == ["conv-s0", "conv-s3-m\(first)", "conv-s4-m\(tail)"])
            // The talk shows first word to last word; the silences show the audio they hold.
            #expect(result[1].startMs == t0 + minutesMs(50))
            #expect(result[1].endMs == t0 + minutesMs(70) - 2_000)
            #expect(result[0].startMs == t0)
            #expect(result[0].endMs == t0 + minutesMs(45) + first)
            #expect(result[2].startMs == t0 + minutesMs(60) + tail)
            #expect(result[2].endMs == t0 + minutesMs(120))
        }
    }

    @Test func aTrailingSilenceStartsAtTheNextSegmentWhenTheLastWordEndsItsOwn() {
        // The last word ends inside the final post-roll of `s1`, so there is no room for the
        // tail to start there: it starts with `s2`.
        let segments = rotations(4, minutesEach: 15)
        let evidence = evidenceMap([
            settledEvidence("s0", turns: [SpeechSpan(startMs: 0, endMs: minutesMs(15))]),
            settledEvidence(
                "s1", turns: [SpeechSpan(startMs: 0, endMs: minutesMs(15) - postRoll)]),
            settledEvidence("s2", turns: []), settledEvidence("s3", turns: []),
        ])
        let result = ConversationGrouper.group(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, policy: .quietOnly)
        #expect(result.map(\.brief) == [["s0", "s1"], ["s2", "s3"]])
        #expect(result[1].startReason == .quiet)
    }

    @Test func theSilenceIsMeasuredOnTheWallClockAndTheCutIsAMediaPosition() {
        // A 40-minute segment from which the watch withheld 20 minutes of silence (wall 5–25):
        // it holds 20 minutes of audio. The transcript, timed on that audio, has talk for three
        // minutes and again from minute 7 — four minutes of "silence" on the media clock,
        // twenty-four on the wall. It is the wall that decides there was a silence, and the
        // cut is written in the clock the pieces are stored in.
        var segment = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(40),
            gaps: [silenceGap(atSample: minutesSamples(5), minutes: 20)])
        segment.frameCount -= 20 * 3_000
        #expect(SegmentMediaClock(segment).isExact)
        let evidence = [
            "a": settledEvidence(
                "a",
                turns: [
                    SpeechSpan(startMs: 0, endMs: minutesMs(3)),
                    SpeechSpan(startMs: minutesMs(7), endMs: minutesMs(20)),
                ])
        ]
        let result = ConversationGrouper.group(
            segments: [segment], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, policy: .quietOnly)
        let at = minutesMs(7) - preRoll
        #expect(result.map(\.brief) == [["a[..\(at))"], ["a[\(at)..)"]])
        #expect(result[1].startReason == .quiet)
        #expect(result[0].endMs == t0 + minutesMs(3))
        #expect(result[1].startMs == t0 + minutesMs(27))
        #expect(result[1].endMs == t0 + minutesMs(40))
        expectPiecesTile(result, segments: [segment])
    }

    // MARK: - deferral

    @Test func aHardCutWaitsWhileAnyMemberOverlappingTheSilenceIsUnsettled() {
        // Talk, an hour with nothing said, talk — `s2` (30–45) sits in the middle of the hour.
        let talk: [Stretch] = [.dialogue(0, 20), .dialogue(80, 120)]
        let landed = group(day(minutes: 120, talk: talk), policy: .quietOnly)
        #expect(landed.count == 2)
        #expect(landed[1].startReason == .quiet)

        // Any one member inside the silence still waiting for its transcript: no quiet cut.
        for waiting in 1...5 {
            let deferred = group(
                day(minutes: 120, talk: talk, unsettled: [waiting]), policy: .quietOnly)
            #expect(deferred.map(\.memberSegmentIds) == [(0..<8).map { "s\($0)" }], "s\(waiting)")
            // And with the segmenter on, whatever else it decides, nothing is called quiet.
            for policy in [BoundaryPolicy.default, frozenPolicy] {
                let result = group(day(minutes: 120, talk: talk, unsettled: [waiting]), policy: policy)
                #expect(
                    !result.contains { $0.startReason == .quiet || $0.startReason == .interrupted },
                    "s\(waiting)")
            }
        }
        // A member that does not overlap the silence may be unsettled without deferring it.
        let elsewhere = group(day(minutes: 120, talk: talk, unsettled: [7]), policy: .quietOnly)
        #expect(elsewhere.count == 2)
        #expect(elsewhere[1].startReason == .quiet)
    }

    // MARK: - audio nobody has heard yet

    @Test func tenUntranscribedHoursAreDividedByLengthAndNothingIsHeld() {
        let waiting = day(minutes: 600, unsettled: Set(0..<40))
        // The tests' own numbers give exactly hours.
        let exact = grouping(waiting, policy: frozenPolicy)
        #expect(
            exact.conversations.map(\.id)
                == stride(from: 0, to: 40, by: 4).map { "conv-s\($0)" })
        for (name, policy) in [("default", BoundaryPolicy.default), ("frozen", frozenPolicy)] {
            let result = grouping(waiting, policy: policy)
            #expect(result.conversations.count > 2, "\(name)")
            #expect(result.conversations.dropFirst().allSatisfy { $0.startReason == .length }, "\(name)")
            #expect(result.conversations.first?.startReason == nil, "\(name)")
            // Unheard audio is only ever divided at a join between two recordings.
            #expect(result.conversations.allSatisfy { $0.members.allSatisfy(\.isWhole) }, "\(name)")
            #expect(
                result.conversations.allSatisfy { $0.endMs - $0.startMs <= 3 * 60 * 60_000 },
                "\(name)")
            // Nothing decided from ignorance is written down, and all of it may still move.
            #expect(result.cutsToCommit.isEmpty, "\(name)")
            #expect(result.conversations.allSatisfy { $0.isProvisional }, "\(name)")
        }
        // With the segmenter off, it is what it always was: one run, one conversation.
        #expect(group(waiting, policy: .quietOnly).count == 1)
    }

    @Test func aDayDividedByLengthIsDividedProperlyWhenTheTranscriptsArrive() {
        // The same ninety minutes, first unheard and then heard.
        let heard = twoModes(minutes: 90)
        let unheard = twoModes(minutes: 90, unsettled: Set(0..<6))
        let before = group(unheard, policy: frozenPolicy)
        #expect(before.allSatisfy { $0.startReason == nil || $0.startReason == .length })
        let after = group(heard, policy: frozenPolicy)
        #expect(after.map(\.id) == ["conv-s0", modeChange.conversationId])
        #expect(after[1].startReason == .lull)
    }

    // MARK: - ids, reasons and liveness

    @Test func aChangeOfModeIsCutWhereItHappensWithAnIdAndAReasonOfItsOwn() {
        for (name, policy) in [("default", BoundaryPolicy.default), ("frozen", frozenPolicy)] {
            let result = group(twoModes(minutes: 64), policy: policy)
            let at = modeChange.mediaMs
            #expect(
                result.map(\.brief) == [["s0", "s1", "s2[..\(at))"], ["s2[\(at)..)", "s3", "s4"]],
                "\(name)")
            #expect(result.map(\.id) == ["conv-s0", "conv-s2-m\(at)"], "\(name)")
            // Four minutes of nothing before it: the talk picked up again after a lull.
            #expect(result.map(\.startReason) == [nil, .lull], "\(name)")
        }
        // With no pause at all the same change is a change of topic.
        let abrupt = day(minutes: 60, talk: [.dialogue(0, 30), .dictation(30, 60)])
        let result = group(abrupt, policy: frozenPolicy)
        #expect(result.map(\.brief) == [["s0", "s1"], ["s2", "s3"]])
        #expect(result.map(\.startReason) == [nil, .topicChange])
    }

    @Test func onlyThePieceThatEndsAtTheOpenSegmentIsLive() {
        // Ten untranscribed hours still recording: several conversations, the last one live.
        var waiting = day(minutes: 600, unsettled: Set(0..<40))
        waiting.segments[39].closeReason = nil
        let byLength = group(waiting, policy: frozenPolicy, open: "s39")
        #expect(byLength.count == 10)
        #expect(byLength.map(\.isLive) == Array(repeating: false, count: 9) + [true])

        // The open segment itself divided by the person: its first piece has an end, so it is
        // closed; the piece that runs on is the live one.
        var recording = day(minutes: 30, unsettled: [1])
        recording.segments[1].closeReason = nil
        let split = group(
            recording, policy: .quietOnly, open: "s1",
            cutInputs: ConversationCutInputs(splits: ["s1": [300_000]]))
        #expect(split.map(\.brief) == [["s0", "s1[..300000)"], ["s1[300000..)"]])
        #expect(split.map(\.isLive) == [false, true])
        #expect(split[1].startReason == .manual)

        // Not the open segment, not live — whatever is passed.
        #expect(group(recording, policy: .quietOnly, open: nil).filter { $0.isLive }.isEmpty)
        #expect(group(recording, policy: .quietOnly, open: "elsewhere").filter { $0.isLive }.isEmpty)
    }

    // MARK: - fixed cuts: the segmenter's settled decisions

    @Test func aCommittedCutIsHonouredWithItsReasonAndNeverReportedAgain() {
        // Continuous talk nothing would cut, and a cut held from an earlier pass.
        let talk = day(minutes: 45, talk: [.dialogue(0, 45)])
        let held = ConversationCutInputs(committed: ["s1": [300_000: .topicChange]])
        for policy in [BoundaryPolicy.structuralOnly, .quietOnly, frozenPolicy] {
            #expect(group(talk, policy: policy).count == 1)
            let result = grouping(talk, policy: policy, cutInputs: held)
            #expect(
                result.conversations.map(\.brief) == [["s0", "s1[..300000)"], ["s1[300000..)", "s2"]])
            #expect(result.conversations.map(\.id) == ["conv-s0", "conv-s1-m300000"])
            #expect(result.conversations[1].startReason == .topicChange)
            #expect(result.cutsToCommit.isEmpty)
        }
        // A held cut at the segment's own start, or past its end, is not a position inside it.
        let nowhere = ConversationCutInputs(
            committed: ["s1": [0: .lull, 900_000: .lull, 9_000_000: .lull]])
        #expect(group(talk, policy: .quietOnly, cutInputs: nowhere).count == 1)
    }

    /// In the run being recorded into, a cut is written down only when 45 minutes of settled
    /// talk lie after it (and both conversations it separates have been heard in full). Until
    /// then it is re-decided each time more of the day arrives.
    @Test func aSegmenterCutIsOfferedForCommittingOnlyOnceFortyFiveMinutesOfSettledTalkFollowIt() {
        // Two people, then dictation from minute 34, then two people again from minute 64 — and
        // the watch still recording. Two cuts; the question is when the FIRST is old enough.
        let second = ConversationCut(segmentId: "s4", mediaMs: minutesMs(4) - preRoll)
        func recordingDay(talkUntil end: Int64) -> Day {
            day(
                minutes: ((end + 14) / 15) * 15,
                talk: [.dialogue(0, 30), .dictation(34, 60), .dialogue(64, end)], recording: true)
        }
        // 41 minutes of settled talk after it: not yet.
        let recent = grouping(recordingDay(talkUntil: 75), policy: frozenPolicy)
        #expect(
            recent.conversations.map(\.id)
                == ["conv-s0", modeChange.conversationId, second.conversationId])
        #expect(recent.conversations.map(\.startReason) == [nil, .lull, .lull])
        #expect(recent.cutsToCommit.isEmpty)

        // 56 minutes after it: now — and only it. The second cut is 26 minutes old, and the
        // conversation after it runs into the recording that has not been heard.
        let settled = grouping(recordingDay(talkUntil: 90), policy: frozenPolicy)
        #expect(
            settled.conversations.map(\.id)
                == ["conv-s0", modeChange.conversationId, second.conversationId])
        #expect(settled.cutsToCommit == [modeChange: .lull])

        // Either side of the line. The lag is measured from the first word of the new
        // conversation to the last word of the settled talk after it.
        #expect(ConversationRunPlanner.commitLagMs == 45 * 60_000)
        #expect(grouping(recordingDay(talkUntil: 78), policy: frozenPolicy).cutsToCommit.isEmpty)
        #expect(
            grouping(recordingDay(talkUntil: 80), policy: frozenPolicy).cutsToCommit
                == [modeChange: .lull])
    }

    @Test func inARunThatIsNotBeingRecordedIntoACutIsCommittedAtOnce() {
        // The same recent cut, 41 minutes old — but nothing is open: what is there is all
        // there will be.
        #expect(grouping(twoModes(minutes: 75), policy: frozenPolicy).cutsToCommit == [modeChange: .lull])

        // Something is open, but in a LATER run: this one has ended for good.
        let later = day(
            minutes: 15, prefix: "t", startTimeMs: t0 + minutesMs(300), stream: 9, recording: true)
        let followed = grouping(twoModes(minutes: 75) + later, policy: frozenPolicy)
        #expect(followed.conversations.map(\.id) == ["conv-s0", modeChange.conversationId, "conv-t0"])
        #expect(followed.cutsToCommit == [modeChange: .lull])

        // Still recording, but a long settled silence has closed the STRETCH the cut is in.
        let quietAfter = day(
            minutes: 180, talk: [.dialogue(0, 30), .dictation(34, 60), .dialogue(140, 180)],
            recording: true)
        let result = grouping(quietAfter, policy: frozenPolicy)
        #expect(result.conversations.map(\.startReason) == [nil, .lull, .quiet])
        #expect(result.cutsToCommit == [modeChange: .lull])

        // An explicit Stop is not what decides it either way: with the Stop and nothing open,
        // committed; the same talk still being recorded into, not.
        var stopped = twoModes(minutes: 75)
        stopped.segments[4].closeReason = userStopClose
        #expect(grouping(stopped, policy: frozenPolicy).cutsToCommit == [modeChange: .lull])
        let recording = day(
            minutes: 75, talk: [.dialogue(0, 30), .dictation(34, 75)], recording: true)
        #expect(grouping(recording, policy: frozenPolicy).cutsToCommit.isEmpty)
    }

    @Test func aCutBesideUnheardAudioIsNotCommitted() {
        // An hour of settled dictation follows the cut — and then a recording with no
        // transcript yet, in the same conversation. Both conversations a cut separates must be
        // fully heard before it is written down.
        let pending = grouping(twoModes(minutes: 105, unsettled: [6]), policy: frozenPolicy)
        #expect(pending.conversations.first?.brief == ["s0", "s1", "s2[..\(modeChange.mediaMs))"])
        #expect(pending.cutsToCommit.isEmpty)
        // …even in a run that has ended.
        var stopped = twoModes(minutes: 105, unsettled: [6])
        stopped.segments[6].closeReason = userStopClose
        #expect(grouping(stopped, policy: frozenPolicy).cutsToCommit.isEmpty)
        // Once it is heard, it is.
        #expect(
            grouping(twoModes(minutes: 105), policy: frozenPolicy).cutsToCommit[modeChange] == .lull)
    }

    @Test func whatOnePassOffersTheNextPassHoldsAndTheConversationsAreTheSame() {
        // Group, feed `cutsToCommit` back as committed, group again: identical ids and members.
        for (name, policy) in [("default", BoundaryPolicy.default), ("frozen", frozenPolicy)] {
            let long = day(
                minutes: 300,
                talk: [
                    .dialogue(0, 30), .dictation(34, 95), .dialogue(95, 140, cookingWords),
                    .dictation(143, 200, sailingWords), .dialogue(206, 300),
                ])
            let first = grouping(long, policy: policy)
            #expect(!first.cutsToCommit.isEmpty, "\(name)")
            var held = ConversationCutInputs()
            for (cut, reason) in first.cutsToCommit {
                held.committed[cut.segmentId, default: [:]][cut.mediaMs] = reason
            }
            let second = grouping(long, policy: policy, cutInputs: held)
            #expect(second.conversations.map(\.id) == first.conversations.map(\.id), "\(name)")
            #expect(
                second.conversations.map(\.members) == first.conversations.map(\.members), "\(name)")
            #expect(
                second.conversations.map(\.startReason) == first.conversations.map(\.startReason),
                "\(name)")
            #expect(second.conversations == first.conversations, "\(name)")
            #expect(second.cutsToCommit.isEmpty, "\(name)")

            // And the day growing does not move what is held: another hour of talk arrives.
            let grown = day(
                minutes: 360,
                talk: [
                    .dialogue(0, 30), .dictation(34, 95), .dialogue(95, 140, cookingWords),
                    .dictation(143, 200, sailingWords), .dialogue(206, 300), .dictation(303, 360),
                ])
            let third = grouping(grown, policy: policy, cutInputs: held)
            for cut in first.cutsToCommit.keys {
                #expect(third.conversations.contains { $0.id == cut.conversationId }, "\(name): \(cut)")
            }
        }
    }

    // MARK: - fixed cuts: the person's own

    @Test func aSplitInsideASegmentForcesACutWhateverThePolicy() {
        let talk = day(minutes: 45, talk: [.dialogue(0, 45)])
        let split = ConversationCutInputs(splits: ["s1": [400_000]])
        for policy in [BoundaryPolicy.structuralOnly, .quietOnly, .default, frozenPolicy] {
            let result = grouping(talk, policy: policy, cutInputs: split)
            #expect(
                result.conversations.contains { $0.id == "conv-s1-m400000" && $0.startReason == .manual })
            #expect(result.cutsToCommit[ConversationCut(segmentId: "s1", mediaMs: 400_000)] == nil)
        }
        let exact = group(talk, policy: .quietOnly, cutInputs: split)
        #expect(exact.map(\.brief) == [["s0", "s1[..400000)"], ["s1[400000..)", "s2"]])

        // It holds on audio nobody has heard yet, too.
        let unheard = group(
            day(minutes: 45, unsettled: [0, 1, 2]), policy: .quietOnly, cutInputs: split)
        #expect(unheard.map(\.brief) == [["s0", "s1[..400000)"], ["s1[400000..)", "s2"]])

        // A split at the very start of a segment, or outside it, is not a position inside it
        // (the segment's own start is `boundary_overrides`' business).
        let outside = ConversationCutInputs(splits: ["s1": [0, 900_000, 5_000_000]])
        #expect(group(talk, policy: .quietOnly, cutInputs: outside).count == 1)
    }

    /// A join recorded at a POINT (a row without a span — see the span tests below for what the
    /// app writes now): it removes a held cut there and keeps automatic cuts two minutes away.
    @Test func aPointJoinRemovesACommittedCutAndKeepsAutomaticCutsTwoMinutesAway() {
        #expect(ConversationRunPlanner.joinReachMs == 120_000)
        let talk = day(minutes: 45, talk: [.dialogue(0, 45)])
        // Three held cuts in `s1`: at the join itself, 100 seconds after it, 130 seconds after.
        let committed: [String: [Int64: ConversationStartReason]] = [
            "s1": [300_000: .topicChange, 400_000: .topicChange, 430_000: .topicChange]
        ]
        let free = group(
            talk, policy: .quietOnly, cutInputs: ConversationCutInputs(committed: committed))
        #expect(free.map(\.id) == ["conv-s0", "conv-s1-m300000", "conv-s1-m400000", "conv-s1-m430000"])

        let joined = group(
            talk, policy: .quietOnly,
            cutInputs: ConversationCutInputs(committed: committed, joins: ["s1": [300_000]]))
        #expect(joined.map(\.id) == ["conv-s0", "conv-s1-m430000"])

        // The reach is two minutes either side, inclusive.
        let edges = group(
            talk, policy: .quietOnly,
            cutInputs: ConversationCutInputs(
                committed: ["s1": [180_000: .lull, 179_999: .lull, 420_000: .lull, 420_001: .lull]],
                joins: ["s1": [300_000]]))
        #expect(edges.map(\.id) == ["conv-s0", "conv-s1-m179999", "conv-s1-m420001"])
    }

    @Test func aPointJoinsReachIsWallTimeSoItCoversTheEndOfTheRecordingBefore() {
        // A join thirty seconds into `s1`. The talk just before it is in `s0`: a held cut a
        // minute before the end of `s0` is 90 seconds away on the wall and is removed; one
        // 130 seconds away is not.
        let talk = day(minutes: 45, talk: [.dialogue(0, 45)])
        let committed: [String: [Int64: ConversationStartReason]] = [
            "s0": [840_000: .topicChange, 800_000: .topicChange],
            "s1": [60_000: .topicChange, 200_000: .topicChange],
        ]
        let joined = group(
            talk, policy: .quietOnly,
            cutInputs: ConversationCutInputs(committed: committed, joins: ["s1": [30_000]]))
        #expect(joined.map(\.id) == ["conv-s0", "conv-s0-m800000", "conv-s1-m200000"])

        // The same for a join recorded against the segment's own start (`boundary_overrides`).
        let atStart = group(
            talk, policy: .quietOnly, overrides: ["s1": .join],
            cutInputs: ConversationCutInputs(
                committed: [
                    "s0": [840_000: .topicChange, 770_000: .topicChange],
                    "s1": [60_000: .topicChange, 130_000: .topicChange],
                ]))
        #expect(atStart.map(\.id) == ["conv-s0", "conv-s0-m770000", "conv-s1-m130000"])
    }

    @Test func aPointJoinAlsoRemovesAQuietCutAndASplitAtTheSamePlaceBeatsTheJoin() {
        let quiet = day(minutes: 120, talk: [.dialogue(0, 20), .dialogue(80, 120)])
        let at = minutesMs(5) - preRoll
        #expect(group(quiet, policy: .quietOnly).map(\.id) == ["conv-s0", "conv-s5-m\(at)"])
        // "These are one conversation", said at the cut or near it.
        for offset: Int64 in [0, 60_000, -60_000, 120_000] {
            #expect(
                group(
                    quiet, policy: .quietOnly,
                    cutInputs: ConversationCutInputs(joins: ["s5": [at + offset]])
                ).count == 1, "\(offset)")
        }
        // Said somewhere else, it is about somewhere else.
        #expect(
            group(
                quiet, policy: .quietOnly,
                cutInputs: ConversationCutInputs(joins: ["s5": [at + 200_000], "s3": [at]])
            ).count == 2)

        // A split is the newer, more specific decision about that exact place: it stands.
        let both = group(
            quiet, policy: .quietOnly,
            cutInputs: ConversationCutInputs(splits: ["s5": [at]], joins: ["s5": [at]]))
        #expect(both.map(\.id) == ["conv-s0", "conv-s5-m\(at)"])
        #expect(both[1].startReason == .manual)
    }

    // MARK: - fixed cuts: a join protects the span it joined

    /// What the app writes for "these two are one conversation": the span from the start of the
    /// earlier one to the start of whatever follows the later one. Nothing automatic cuts
    /// strictly inside it — not the cut that was there, not a long silence, not the segmenter
    /// deciding the now longer conversation would be better divided a little further on.
    private func span(_ from: ConversationCut, _ to: ConversationCut?) -> ConversationCutInputs {
        ConversationCutInputs(joinSpans: [.init(from: from, to: to)])
    }
    private var runStart: ConversationCut { ConversationCut(segmentId: "s0", mediaMs: 0) }

    /// "These are one conversation", said where a long silence had split one. The quiet cut goes
    /// — and nothing else puts a cut back a little further on because the silence the person
    /// has just joined across makes the conversation long.
    ///
    /// (This failed while a join was a point with a two-minute reach: the silent span counts
    /// toward the length of the unit that holds it, so the search cut again at the first block
    /// outside the reach, and across three hours on BOTH sides of the silence. Reported
    /// 2026-09-30; a join made in the app now records its span.)
    @Test(arguments: [30, 60, 90, 180] as [Int64])
    func aJoinAcrossALongSilenceLeavesOneConversation(silence: Int64) {
        // Twenty minutes of talk, the silence, forty minutes of the same talk. The talk resumes
        // five minutes into its segment.
        let resumes = 20 + silence
        let quiet = day(
            minutes: resumes + 40, talk: [.dialogue(0, 20), .dialogue(resumes, resumes + 40)])
        let segment = "s\(resumes / 15)"
        let at = minutesMs(5) - preRoll
        #expect(group(quiet, policy: .quietOnly).map(\.id) == ["conv-s0", "conv-\(segment)-m\(at)"])
        for (name, policy) in [
            ("quietOnly", BoundaryPolicy.quietOnly), ("default", .default), ("frozen", frozenPolicy),
        ] {
            let result = group(quiet, policy: policy, cutInputs: span(runStart, nil))
            #expect(
                result.map(\.id) == ["conv-s0"],
                "\(name), \(silence) min: \(result.map(\.id)) \(result.map(\.startReason))")
        }
    }

    /// "These are one conversation", said at a cut the segmenter made where the talk changed.
    /// The two conversations become one — the person's answer beats the evidence, however
    /// strong the evidence is. It does not move the cut along.
    ///
    /// (This failed while a join was a point: the evidence for the cut — two voices giving way
    /// to one dictating — was still there just outside the join's reach, and the search put the
    /// cut back in the last minute of the dialogue. Reported 2026-09-30.)
    @Test func aJoinAtASegmenterCutLeavesOneConversationNotTheCutMovedAlong() {
        let talk = twoModes(minutes: 90)
        for (name, policy) in [("default", BoundaryPolicy.default), ("frozen", frozenPolicy)] {
            #expect(
                group(talk, policy: policy).map(\.id) == ["conv-s0", modeChange.conversationId],
                "\(name)")
            let result = group(talk, policy: policy, cutInputs: span(runStart, nil))
            #expect(
                result.map(\.id) == ["conv-s0"],
                "\(name): \(result.map(\.id)) \(result.map(\.startReason))")
            // The same with the cut already held: it is inside the span, and stays removed.
            var held = span(runStart, nil)
            held.committed = ["s2": [modeChange.mediaMs: .lull]]
            #expect(
                group(talk, policy: policy, cutInputs: held).map(\.id) == ["conv-s0"], "\(name), held")
        }
        // A point join at the same place — a row from before spans — promises less: no cut
        // within two minutes of it, and the search is free to cut further off.
        let point = group(
            talk, policy: frozenPolicy,
            cutInputs: ConversationCutInputs(joins: ["s2": [modeChange.mediaMs]]))
        #expect(!point.contains { $0.id == modeChange.conversationId })
    }

    @Test func aSpanBlocksOnlyWhatIsStrictlyInsideIt() {
        // Three hours: two people (0–30), dictation (34–90), two people about something else
        // (94–150), dictation again (154–180). Three cuts.
        let talk = day(
            minutes: 180,
            talk: [
                .dialogue(0, 30), .dictation(34, 90), .dialogue(94, 150, cookingWords),
                .dictation(154, 180, sailingWords),
            ])
        let second = ConversationCut(segmentId: "s6", mediaMs: minutesMs(4) - preRoll)
        let third = ConversationCut(segmentId: "s10", mediaMs: minutesMs(4) - preRoll)
        let free = group(talk, policy: frozenPolicy)
        #expect(
            free.map(\.id)
                == ["conv-s0", modeChange.conversationId, second.conversationId, third.conversationId])

        // Join the second into the first: the span runs from the first's start to the third's.
        let joined = group(talk, policy: frozenPolicy, cutInputs: span(runStart, second))
        // The cut exactly at `to` is not inside the span: the third conversation still starts
        // where it did, with the id it had, and so does the fourth.
        #expect(joined.map(\.id) == ["conv-s0", second.conversationId, third.conversationId])
        #expect(joined[1].startReason == .lull)

        // Join the third into the second: the cut exactly at `from` stays too.
        let middle = group(talk, policy: frozenPolicy, cutInputs: span(modeChange, third))
        #expect(middle.map(\.id) == ["conv-s0", modeChange.conversationId, third.conversationId])

        // Held cuts are blocked inside a span and honoured at its edges.
        var held = span(modeChange, third)
        held.committed = [
            "s2": [modeChange.mediaMs: .lull], "s6": [second.mediaMs: .lull],
            "s10": [third.mediaMs: .lull], "s4": [300_000: .topicChange],
        ]
        let withHeld = group(talk, policy: .quietOnly, cutInputs: held)
        #expect(withHeld.map(\.id) == ["conv-s0", modeChange.conversationId, third.conversationId])

        // The person's own split inside a span still wins: it is the newer decision.
        var split = span(runStart, nil)
        split.splits = ["s5": [450_000]]
        let withSplit = group(talk, policy: frozenPolicy, cutInputs: split)
        #expect(withSplit.map(\.id) == ["conv-s0", "conv-s5-m450000"])
        #expect(withSplit[1].startReason == .manual)
    }

    @Test func aSpanBlocksALongSilenceInsideItAndNothingOutsideIt() {
        // Talk, an hour of nothing, talk, an hour of nothing, talk.
        let quiet = day(
            minutes: 240, talk: [.dialogue(0, 20), .dialogue(80, 110), .dialogue(170, 240)])
        let first = ConversationCut(segmentId: "s5", mediaMs: minutesMs(5) - preRoll)
        let second = ConversationCut(segmentId: "s11", mediaMs: minutesMs(5) - preRoll)
        #expect(
            group(quiet, policy: .quietOnly).map(\.id)
                == ["conv-s0", first.conversationId, second.conversationId])
        // The first two joined: the first silence no longer cuts, the second still does.
        for policy in [BoundaryPolicy.quietOnly, frozenPolicy] {
            let joined = group(quiet, policy: policy, cutInputs: span(runStart, second))
            #expect(joined.map(\.id) == ["conv-s0", second.conversationId])
            #expect(joined[1].startReason == .quiet)
        }
    }

    @Test func aSpanWhoseStartIsGoneProtectsFromTheRunsStartAndOneAboutAnotherRunIsIgnored() {
        let gone = ConversationCut(segmentId: "deleted-by-retention", mediaMs: 0)
        // Three conversations; the first two were joined, and then retention deleted the
        // segment the earlier one started in. What is left of the pair is still one
        // conversation, up to where the span ends — and the third still starts there.
        let three = day(
            minutes: 150, talk: [.dialogue(0, 30), .dictation(34, 90), .dialogue(94, 150)])
        let third = ConversationCut(segmentId: "s6", mediaMs: minutesMs(4) - preRoll)
        #expect(
            group(three, policy: frozenPolicy).map(\.id)
                == ["conv-s0", modeChange.conversationId, third.conversationId])
        let trimmed = group(three, policy: frozenPolicy, cutInputs: span(gone, third))
        #expect(trimmed.map(\.id) == ["conv-s0", third.conversationId])

        let talk = twoModes(minutes: 90)
        // Neither end is in this run: it is about another run, and changes nothing here. (A span
        // with no end and a start that is gone is the same: there is nothing left to place it.)
        let elsewhere = ConversationCut(segmentId: "also-not-here", mediaMs: 5)
        #expect(
            group(talk, policy: frozenPolicy, cutInputs: span(gone, elsewhere))
                == group(talk, policy: frozenPolicy))
        #expect(
            group(talk, policy: frozenPolicy, cutInputs: span(gone, nil))
                == group(talk, policy: frozenPolicy))

        // A span in one run does not reach into the next.
        let later = day(
            minutes: 90, prefix: "t", startTimeMs: t0 + minutesMs(400), stream: 9,
            talk: [.dialogue(0, 30), .dictation(34, 90)])
        let both = group(talk + later, policy: frozenPolicy, cutInputs: span(runStart, nil))
        #expect(both.map(\.id) == ["conv-s0", "conv-t0", "conv-t2-m\(modeChange.mediaMs)"])
    }

    @Test func aJoinAtASegmentsOwnStartKeepsCutsOutOfItsFirstTwoMinutes() {
        let talk = day(minutes: 45, talk: [.dialogue(0, 45)])
        let committed = ConversationCutInputs(
            committed: ["s1": [60_000: .topicChange, 200_000: .topicChange]])
        #expect(group(talk, policy: .quietOnly, cutInputs: committed).count == 3)
        let joined = group(talk, policy: .quietOnly, overrides: ["s1": .join], cutInputs: committed)
        #expect(joined.map(\.id) == ["conv-s0", "conv-s1-m200000"])
    }

    // MARK: - units with nothing in them

    @Test func aHeldCutWithNoTurnsAfterItBeforeTheNextCutDisappears() {
        // One 30-minute recording: talk for five minutes, nothing for seven, talk to the end.
        let segment = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(30))
        let evidence = ["a": settledEvidence("a", minutes: [(0, 5), (12, 30)])]
        func group(_ inputs: ConversationCutInputs) -> [GroupedConversation] {
            let result = ConversationGrouper.group(
                segments: [segment], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
                evidence: evidence, policy: .quietOnly, cutInputs: inputs)
            expectPiecesTile(result, segments: [segment])
            return result
        }
        // Two held cuts inside the seven quiet minutes. The first would start a conversation
        // with nothing in it; it is dropped, and its range joins the conversation before it.
        let held = group(
            ConversationCutInputs(committed: ["a": [400_000: .topicChange, 600_000: .lull]]))
        #expect(held.map(\.brief) == [["a[..600000)"], ["a[600000..)"]])
        #expect(held[1].startReason == .lull)

        // The person's own split is no different: a conversation of nothing is not one.
        let split = group(ConversationCutInputs(splits: ["a": [400_000, 600_000]]))
        #expect(split.map(\.brief) == [["a[..600000)"], ["a[600000..)"]])

        // A cut before the first word: the empty unit is the one BEFORE it, so it goes too.
        let early = makeSegment(
            id: "b", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(30))
        let lateTalk = ["b": settledEvidence("b", minutes: [(10, 30)])]
        let leading = ConversationGrouper.group(
            segments: [early], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: lateTalk, policy: .quietOnly,
            cutInputs: ConversationCutInputs(committed: ["b": [300_000: .topicChange]]))
        #expect(leading.map(\.brief) == [["b"]])
    }

    @Test func hardCutsStayEvenWhenTheUnitTheyStartIsSilent() {
        // Four minutes of talk and then nothing: the silent tail is exactly what the hard cut
        // is for. A held cut inside that tail starts nothing, and goes.
        let segment = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(60))
        let evidence = ["a": settledEvidence("a", minutes: [(0, 4)])]
        let tail = minutesMs(4) + postRoll
        let result = ConversationGrouper.group(
            segments: [segment], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, policy: .quietOnly,
            cutInputs: ConversationCutInputs(committed: ["a": [1_000_000: .topicChange]]))
        #expect(result.map(\.brief) == [["a[..\(tail))"], ["a[\(tail)..)"]])
        #expect(result[1].startReason == .quiet)

        // And the silence before the first word of a run stays its own unit.
        let late = ["a": settledEvidence("a", minutes: [(20, 60)])]
        let leading = ConversationGrouper.group(
            segments: [segment], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: late, policy: .quietOnly)
        let first = minutesMs(20) - preRoll
        #expect(leading.map(\.brief) == [["a[..\(first))"], ["a[\(first)..)"]])
    }

    // MARK: - the structural rules on their own

    @Test func structuralOnlyReproducesWholeSegmentConversationsExactly() {
        // Every shape the other layers would cut: silences, a change of mode, hours of talk,
        // unheard audio. With `.structuralOnly` none of it matters — a conversation is a run of
        // whole segments, exactly as it is with no evidence at all.
        let days: [Day] = [
            twoModes(minutes: 90),
            day(minutes: 120, talk: [.dialogue(0, 20), .dialogue(80, 120)]),
            day(minutes: 120, talk: [.dialogue(50, 70)]),
            day(minutes: 600, unsettled: Set(0..<40)),
            day(minutes: 180, talk: [.dialogue(0, 180)]),
            twoModes(minutes: 60)
                + day(minutes: 45, prefix: "t", startTimeMs: t0 + minutesMs(200), stream: 8, talk: [.dialogue(3, 40)]),
        ]
        for (index, day) in days.enumerated() {
            let withEvidence = grouping(day, policy: .structuralOnly)
            let without = ConversationGrouper.groupDetailed(
                segments: day.segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
                policy: .structuralOnly)
            #expect(withEvidence.conversations.allSatisfy { $0.members.allSatisfy(\.isWhole) }, "day \(index)")
            #expect(
                withEvidence.conversations.map(\.members) == without.conversations.map(\.members),
                "day \(index)")
            #expect(
                withEvidence.conversations.map(\.id) == without.conversations.map(\.id),
                "day \(index)")
            #expect(
                withEvidence.conversations.map(\.id)
                    == withEvidence.conversations.map { "conv-\($0.memberSegmentIds[0])" },
                "day \(index)")
            #expect(withEvidence.cutsToCommit.isEmpty, "day \(index)")
        }
        let two = group(days[5], policy: .structuralOnly)
        #expect(two.map(\.brief) == [["s0", "s1", "s2", "s3"], ["t0", "t1", "t2"]])
        #expect(two.map(\.startReason) == [nil, .gap])
    }

    // MARK: - provisional

    @Test func theTailOfTheRunBeingRecordedIntoIsProvisional() {
        // Whatever the policy, the last conversation of the run that holds the open segment has
        // an end that is not decided yet.
        for policy in [BoundaryPolicy.structuralOnly, .quietOnly, frozenPolicy] {
            let result = group(
                day(minutes: 45, talk: [.dialogue(0, 45)], recording: true), policy: policy)
            #expect(result.map(\.isProvisional) == [true])
            #expect(result.map(\.isLive) == [true])
        }
        // With nothing open, what is there is all there will be: a finished library's last
        // conversation is not left waiting for the watch to be worn again.
        for policy in [BoundaryPolicy.structuralOnly, .quietOnly, frozenPolicy] {
            let result = group(day(minutes: 45, talk: [.dialogue(0, 45)]), policy: policy)
            #expect(result.map(\.isProvisional) == [false])
        }
        // An earlier run is over; only the one being recorded into is open-ended.
        let two =
            day(minutes: 45, talk: [.dialogue(0, 45)])
            + day(
                minutes: 15, prefix: "t", startTimeMs: t0 + minutesMs(300), stream: 9,
                talk: [.dialogue(0, 15)], recording: true)
        #expect(group(two, policy: frozenPolicy).map(\.isProvisional) == [false, true])
        // The open segment has to be IN the last run: an id that is not there opens nothing.
        let stale = grouping(
            day(minutes: 45, talk: [.dialogue(0, 45)]), policy: frozenPolicy, open: "not-here")
        #expect(stale.conversations.map(\.isProvisional) == [false])
    }

    @Test func provisionalClearsOnceBothBoundariesAreHeld() {
        // Still recording. Two people, dictation from 34, two people from 64: two cuts.
        func recordingDay(talkUntil end: Int64) -> Day {
            day(
                minutes: ((end + 14) / 15) * 15,
                talk: [.dialogue(0, 30), .dictation(34, 60), .dialogue(64, end)], recording: true)
        }
        // The first cut has 41 minutes of settled talk after it: nothing either side of either
        // cut is final.
        #expect(
            group(recordingDay(talkUntil: 75), policy: frozenPolicy).map(\.isProvisional)
                == [true, true, true])
        // 56 minutes after the first cut: the conversation BEFORE it has both its boundaries.
        // The one after it still ends at a cut that is 26 minutes old.
        #expect(
            group(recordingDay(talkUntil: 90), policy: frozenPolicy).map(\.isProvisional)
                == [false, true, true])

        // Four conversations: the second clears when the cut that ends it is 45 minutes old too.
        let four = day(
            minutes: 165,
            talk: [.dialogue(0, 30), .dictation(34, 90), .dialogue(94, 150), .dictation(154, 165)],
            recording: true)
        let result = group(four, policy: frozenPolicy)
        #expect(result.map(\.startReason) == [nil, .lull, .lull, .lull])
        #expect(result.map(\.isProvisional) == [false, false, true, true])

        // A held cut is a fixed boundary from the start.
        let held = group(
            recordingDay(talkUntil: 75), policy: frozenPolicy,
            cutInputs: ConversationCutInputs(committed: ["s2": [modeChange.mediaMs: .lull]]))
        #expect(held.map(\.isProvisional) == [false, true, true])
        // So is a long silence, and so is the person's own split.
        let quiet = group(
            day(minutes: 120, talk: [.dialogue(0, 20), .dialogue(80, 120)], recording: true),
            policy: frozenPolicy)
        #expect(quiet.map(\.startReason) == [nil, .quiet])
        #expect(quiet.map(\.isProvisional) == [false, true])
        let split = group(
            day(minutes: 45, talk: [.dialogue(0, 45)], recording: true), policy: frozenPolicy,
            cutInputs: ConversationCutInputs(splits: ["s1": [400_000]]))
        #expect(split.map(\.isProvisional) == [false, true])
    }

    @Test func nothingHeardIsProvisionalOnceNothingIsOpen() {
        // The same recent cut that kept three conversations provisional while recording.
        let talk: [Stretch] = [.dialogue(0, 30), .dictation(34, 60), .dialogue(64, 75)]
        #expect(
            group(day(minutes: 75, talk: talk), policy: frozenPolicy).map(\.isProvisional)
                == [false, false, false])
        for policy in [BoundaryPolicy.structuralOnly, .quietOnly] {
            #expect(group(day(minutes: 75, talk: talk), policy: policy).map(\.isProvisional) == [false])
        }
        // A run closed by a later one is final even while that later one is being recorded.
        let later = day(
            minutes: 15, prefix: "t", startTimeMs: t0 + minutesMs(300), stream: 9,
            talk: [.dialogue(0, 15)], recording: true)
        #expect(
            group(day(minutes: 75, talk: talk) + later, policy: frozenPolicy).map(\.isProvisional)
                == [false, false, false, true])
        // A Stop the person has joined across has not ended anything: the run that now holds
        // the open segment is one run, and its tail is provisional.
        var stopped = day(minutes: 75, talk: [.dialogue(0, 75)])
        stopped.segments[4].closeReason = userStopClose
        let more = day(
            minutes: 15, prefix: "t", startTimeMs: t0 + minutesMs(76), stream: 9,
            talk: [.dialogue(0, 15)], recording: true)
        #expect(group(stopped + more, policy: .quietOnly).map(\.isProvisional) == [false, true])
        let joined = group(stopped + more, policy: .quietOnly, overrides: ["t0": .join])
        #expect(joined.map(\.brief) == [["s0", "s1", "s2", "s3", "s4", "t0", "t1"]])
        #expect(joined.map(\.isProvisional) == [true])
    }

    @Test func unheardAudioDividedByLengthStaysProvisionalEvenInAClosedRun() {
        // The run is over, but its recordings are not transcribed: every `.length` boundary
        // will be re-decided when they are, so nothing on either side of one is final.
        var waiting = day(minutes: 600, unsettled: Set(0..<40))
        waiting.segments[39].closeReason = userStopClose
        let result = group(waiting, policy: frozenPolicy)
        #expect(result.count == 10)
        #expect(result.allSatisfy { $0.isProvisional })
    }

    // MARK: - the memo

    @Test func aSecondIdenticalCallAddsNoEntriesAndReturnsEqualResults() {
        let library =
            twoModes(minutes: 90)
            + day(minutes: 45, prefix: "t", startTimeMs: t0 + minutesMs(300), stream: 8, talk: [.dialogue(3, 40)])
            + day(minutes: 30, prefix: "u", startTimeMs: t0 + minutesMs(900), stream: 9, talk: [.dictation(0, 30)])
        for policy in [BoundaryPolicy.quietOnly, frozenPolicy] {
            let memo = GroupingMemo()
            let unmemoised = grouping(library, policy: policy)
            let first = grouping(library, policy: policy, memo: memo)
            // One search per run, and the memo changes no answer.
            #expect(memo.storedCount == 3)
            #expect(first == unmemoised)
            let second = grouping(library, policy: policy, memo: memo)
            #expect(memo.storedCount == 3)
            #expect(second == first)
        }
    }

    @Test func aChangedTranscriptInvalidatesOnlyItsRun() {
        let first = twoModes(minutes: 90)
        let second = day(
            minutes: 45, prefix: "t", startTimeMs: t0 + minutesMs(300), stream: 8, talk: [.dialogue(3, 40)])
        let third = day(
            minutes: 30, prefix: "u", startTimeMs: t0 + minutesMs(900), stream: 9, talk: [.dictation(0, 30)])
        let memo = GroupingMemo()
        let before = grouping(first + second + third, policy: frozenPolicy, memo: memo)
        #expect(memo.storedCount == 3)

        // The middle run is re-transcribed: its talk now starts at minute 6.
        let retranscribed = day(
            minutes: 45, prefix: "t", startTimeMs: t0 + minutesMs(300), stream: 8, talk: [.dialogue(6, 40)])
        let after = grouping(first + retranscribed + third, policy: frozenPolicy, memo: memo)
        #expect(memo.storedCount == 4, "one new search: the run that changed")
        #expect(after == grouping(first + retranscribed + third, policy: frozenPolicy))
        #expect(after != before)
        // The runs that did not change are answered exactly as before.
        let unchanged: (ConversationGrouper.Grouping) -> [GroupedConversation] = {
            $0.conversations.filter { !$0.id.hasPrefix("conv-t") }
        }
        #expect(unchanged(after) == unchanged(before))
    }

    @Test func theMemoIsKeyedOnEverythingElseTheAnswerDependsOn() {
        let library = twoModes(minutes: 90)
        let memo = GroupingMemo()
        _ = grouping(library, policy: frozenPolicy, memo: memo)
        #expect(memo.storedCount == 1)

        // A different policy.
        _ = grouping(library, policy: .quietOnly, memo: memo)
        #expect(memo.storedCount == 2)
        // A held cut.
        let held = grouping(
            library, policy: frozenPolicy,
            cutInputs: ConversationCutInputs(committed: ["s0": [300_000: .topicChange]]), memo: memo)
        #expect(memo.storedCount == 3)
        #expect(held.conversations.contains { $0.id == "conv-s0-m300000" })
        // A split, a point join, and a join with its span.
        _ = grouping(
            library, policy: frozenPolicy,
            cutInputs: ConversationCutInputs(splits: ["s0": [300_000]]), memo: memo)
        #expect(memo.storedCount == 4)
        _ = grouping(
            library, policy: frozenPolicy,
            cutInputs: ConversationCutInputs(joins: ["s2": [238_500]]), memo: memo)
        #expect(memo.storedCount == 5)
        let spanned = grouping(
            library, policy: frozenPolicy, cutInputs: span(runStart, nil), memo: memo)
        #expect(memo.storedCount == 6)
        #expect(spanned.conversations.count == 1)
        // A join at a segment's own start.
        _ = grouping(library, policy: frozenPolicy, overrides: ["s3": .join], memo: memo)
        #expect(memo.storedCount == 7)
        // The open segment: the run is now being recorded into.
        let recording = grouping(library, policy: frozenPolicy, open: "s5", memo: memo)
        #expect(memo.storedCount == 8)
        #expect(recording.conversations.last?.isProvisional == true)
        // A member settling.
        var unsettled = library
        unsettled.evidence["s5"] = unsettledEvidence("s5")
        _ = grouping(unsettled, policy: frozenPolicy, memo: memo)
        #expect(memo.storedCount == 9)
        // A later run appears: one more search for it, and none for the run that did not change.
        let later = day(
            minutes: 15, prefix: "t", startTimeMs: t0 + minutesMs(300), stream: 9, unsettled: [0])
        _ = grouping(library + later, policy: frozenPolicy, memo: memo)
        #expect(memo.storedCount == 10)

        // And every one of those is answered from memory the second time.
        _ = grouping(library, policy: frozenPolicy, memo: memo)
        _ = grouping(library, policy: .quietOnly, memo: memo)
        _ = grouping(library, policy: frozenPolicy, cutInputs: span(runStart, nil), memo: memo)
        _ = grouping(library + later, policy: frozenPolicy, memo: memo)
        #expect(memo.storedCount == 10)
    }

    /// The memo answers from memory only when NOTHING the answer depends on has changed. Who
    /// spoke and how (dialogue, dictation, another language) is most of what the segmenter
    /// reads, so a transcript whose turns keep their timings and word counts but change their
    /// speakers or their text is a changed transcript.
    ///
    /// KNOWN ISSUE (reported 2026-09-30): `SegmentSpeechEvidence.fingerprint` hashes each turn's
    /// start, end, word count and NUMBER of terms — not its speaker or its flags — so such a
    /// change is answered from the stale entry until the app restarts. Hard to reach today
    /// (a re-transcription moves the timings), which is why it is recorded rather than failing.
    @Test func aTranscriptThatChangesOnlyInWhoSpokeAndHowIsAChangedTranscript() {
        // Half an hour of two people talking, then — with no pause at all — half an hour of one
        // voice dictating. The only thing that marks the change is who is speaking and how.
        let original = day(minutes: 60, talk: [.dialogue(0, 30), .dictation(30, 60)])
        // The same turns at the same times with the same number of words and content words:
        // but the two voices of the first half hour are now one, and nobody is dictating.
        var relabelled = original
        for (id, item) in original.evidence {
            relabelled.evidence[id] = SegmentSpeechEvidence(
                segmentId: id, isSettled: item.isSettled,
                speech: item.speech.map { span in
                    var features = span.features
                    features?.speaker = 1
                    features?.isDictation = false
                    return SpeechSpan(
                        startMs: span.startMs, endMs: span.endMs, wordCount: span.wordCount,
                        features: features)
                })
        }
        #expect(relabelled.evidence != original.evidence)
        let fresh = grouping(relabelled, policy: frozenPolicy)
        #expect(grouping(original, policy: frozenPolicy).conversations.count == 2)
        #expect(fresh.conversations.count == 1, "the change matters to the answer")

        let memo = GroupingMemo()
        _ = grouping(original, policy: frozenPolicy, memo: memo)
        withKnownIssue("the evidence fingerprint does not cover speakers or flags") {
            #expect(grouping(relabelled, policy: frozenPolicy, memo: memo) == fresh)
            #expect(memo.storedCount == 2)
        }
    }
}
