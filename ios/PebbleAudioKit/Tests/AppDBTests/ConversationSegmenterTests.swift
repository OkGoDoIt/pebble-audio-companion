import Foundation
import Testing

@testable import AppDB

// `ConversationSegmenter.cuts` — the exact search that divides a stretch of talk into units.
//
// The numbers in `SegmenterPolicy.default` are still being tuned, so nothing here depends on
// them by accident. A test that pins an exact answer passes `frozenSegmenterPolicy` (the numbers
// written out in `TestSupport.swift`). A test that states something the SHIPPED policy must
// keep — the guarantee that nothing is left as a three-hour "conversation", that an ordinary
// pause is not a boundary, that a plain change of mode with a pause is — runs against both, on
// scenarios with margins wide enough that any sane tuning gives the same answer.

/// A deterministic generator, so the property tests run the same cases every time.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678_9ABC_DEF1 }
    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let vocabularyA: [UInt32] = Array(1...16)
private let vocabularyB: [UInt32] = Array(101...116)

/// One block per minute of one KIND of talk: 58 seconds of turns, two seconds to the next.
private func talk(
    from startMs: Int64, minutes: Int, gapBeforeFirstMs: Int64 = 2_000, dialogue: Bool,
    dictation: Bool = false, foreign: Bool = false, vocabulary: [UInt32] = vocabularyA
) -> [SegmenterBlock] {
    (0..<minutes).map { index in
        let start = startMs + Int64(index) * 60_000
        return SegmenterBlock(
            wallStartMs: start, wallEndMs: start + 58_000,
            gapBeforeMs: index == 0 ? gapBeforeFirstMs : 2_000,
            lines: dialogue ? 6 : 1, words: dialogue ? 90 : 120,
            terms: (0..<12).map { vocabulary[(index * 5 + $0 * 3) % vocabulary.count] },
            isDialogue: dialogue, isForeign: foreign, isDictation: dictation,
            opensWithGreeting: false)
    }
}

private func opaque(from startMs: Int64, count: Int, minutesEach: Int64 = 15) -> [SegmenterBlock] {
    (0..<count).map { index in
        let start = startMs + Int64(index) * minutesEach * 60_000
        return SegmenterBlock(
            wallStartMs: start, wallEndMs: start + minutesEach * 60_000, gapBeforeMs: 0, lines: 0,
            words: 0, terms: [], isDialogue: false, isForeign: false, isDictation: false,
            opensWithGreeting: false, isOpaque: true)
    }
}

/// The length of each unit a set of cuts divides `blocks` into: first word to last word.
private func unitLengthsMs(_ blocks: [SegmenterBlock], cuts: [Int]) -> [Int64] {
    let edges = [0] + cuts + [blocks.count]
    return zip(edges, edges.dropFirst()).map { lower, upper in
        blocks[upper - 1].wallEndMs - blocks[lower].wallStartMs
    }
}

private let bothPolicies: [(name: String, policy: SegmenterPolicy)] = [
    ("frozen", frozenSegmenterPolicy), ("default", .default),
]

@Suite struct ConversationSegmenterTests {
    let t0 = testEpochMs

    // MARK: - the shape of the answer

    @Test func thereIsNoCutInOneBlockOrNone() {
        for (_, policy) in bothPolicies {
            #expect(ConversationSegmenter.cuts(blocks: [], policy: policy).isEmpty)
            #expect(
                ConversationSegmenter.cuts(
                    blocks: talk(from: t0, minutes: 1, dialogue: true), policy: policy
                ).isEmpty)
            #expect(
                ConversationSegmenter.cuts(blocks: opaque(from: t0, count: 1), policy: policy)
                    .isEmpty)
        }
    }

    /// Random stretches — every mix of pauses, modes, vocabularies, unheard audio and "no cut
    /// here" marks — and what must hold for all of them: the cuts are strictly ascending, none
    /// is block 0 or past the end, none is where the person said no, the same blocks give the
    /// same cuts, and FORCING ANY SUBSET OF THE ANSWER RETURNS EXACTLY THE ANSWER. That last one
    /// is what lets a settled cut be held without disturbing the cuts around it.
    @Test func cutsAreAscendingNeverZeroNeverBlockedDeterministicAndStableUnderForcing() {
        var generator = SeededGenerator(seed: 20_260_930)
        var sawACut = false
        for scenario in 0..<60 {
            let count = Int.random(in: 2...140, using: &generator)
            var blocks: [SegmenterBlock] = []
            var clock = t0
            var mode = 0
            for _ in 0..<count {
                if Int.random(in: 0..<12, using: &generator) == 0 {
                    mode = Int.random(in: 0..<4, using: &generator)
                }
                let pause: Int64 =
                    Int.random(in: 0..<10, using: &generator) == 0
                    ? Int64.random(in: 30_000...900_000, using: &generator)
                    : Int64.random(in: 0...5_000, using: &generator)
                clock += pause
                let length = Int64.random(in: 5_000...60_000, using: &generator)
                if mode == 3 {
                    blocks.append(
                        SegmenterBlock(
                            wallStartMs: clock, wallEndMs: clock + length * 15, gapBeforeMs: 0,
                            lines: 0, words: 0, terms: [], isDialogue: false, isForeign: false,
                            isDictation: false, opensWithGreeting: false, isOpaque: true))
                    clock += length * 15
                } else {
                    let vocabulary = mode == 0 ? vocabularyA : vocabularyB
                    blocks.append(
                        SegmenterBlock(
                            wallStartMs: clock, wallEndMs: clock + length, gapBeforeMs: pause,
                            lines: Int.random(in: 1...8, using: &generator),
                            words: Int.random(in: 1...150, using: &generator),
                            terms: (0..<Int.random(in: 0...15, using: &generator)).map { _ in
                                vocabulary.randomElement(using: &generator)!
                            },
                            isDialogue: mode == 0, isForeign: mode == 2, isDictation: mode == 1,
                            opensWithGreeting: Int.random(in: 0..<20, using: &generator) == 0))
                    clock += length
                }
            }
            let blocked = Set(
                (1..<count).filter { _ in Int.random(in: 0..<6, using: &generator) == 0 })
            for (name, policy) in bothPolicies {
                let cuts = ConversationSegmenter.cuts(
                    blocks: blocks, blocked: blocked, policy: policy)
                let label = "scenario \(scenario), \(name) policy: \(cuts)"
                #expect(zip(cuts, cuts.dropFirst()).allSatisfy { $0 < $1 }, "\(label)")
                #expect(cuts.allSatisfy { $0 > 0 && $0 < count }, "\(label)")
                #expect(blocked.isDisjoint(with: cuts), "\(label)")
                #expect(
                    ConversationSegmenter.cuts(blocks: blocks, blocked: blocked, policy: policy)
                        == cuts, "\(label)")
                sawACut = sawACut || !cuts.isEmpty

                // Holding all of the answer, or any part of it, changes none of it.
                #expect(
                    ConversationSegmenter.cuts(
                        blocks: blocks, forced: Set(cuts), blocked: blocked, policy: policy)
                        == cuts, "all forced. \(label)")
                for _ in 0..<3 where !cuts.isEmpty {
                    let subset = Set(cuts.filter { _ in Bool.random(using: &generator) })
                    #expect(
                        ConversationSegmenter.cuts(
                            blocks: blocks, forced: subset, blocked: blocked, policy: policy)
                            == cuts, "forced \(subset.sorted()). \(label)")
                }
                // Forcing somewhere else: that place is cut, and the shape of the answer holds.
                let elsewhere = Int.random(in: 1..<count, using: &generator)
                let forcedCuts = ConversationSegmenter.cuts(
                    blocks: blocks, forced: [elsewhere], blocked: blocked, policy: policy)
                #expect(forcedCuts.contains(elsewhere), "forced \(elsewhere). \(label)")
                #expect(
                    zip(forcedCuts, forcedCuts.dropFirst()).allSatisfy { $0 < $1 },
                    "forced \(elsewhere). \(label)")
                #expect(
                    blocked.subtracting([elsewhere]).isDisjoint(with: forcedCuts),
                    "forced \(elsewhere). \(label)")
            }
        }
        #expect(sawACut, "sixty random days and not one cut: the generator is not exercising the search")
    }

    // MARK: - where it cuts, and where it does not

    /// Thirty minutes of two people talking about one thing, a four-minute pause, then thirty
    /// minutes of one voice dictating about something else. One cut, exactly where the talk
    /// changed — not a block early, not a block late, and nothing inside either half.
    @Test func aClearChangeOfModeWithAPauseIsCutWhereItHappens() {
        let before = talk(from: t0, minutes: 30, dialogue: true, vocabulary: vocabularyA)
        let after = talk(
            from: t0 + 34 * 60_000, minutes: 30, gapBeforeFirstMs: 4 * 60_000 + 2_000,
            dialogue: false, dictation: true, vocabulary: vocabularyB)
        for (name, policy) in bothPolicies {
            #expect(
                ConversationSegmenter.cuts(blocks: before + after, policy: policy) == [30],
                "\(name) policy")
        }
    }

    /// Ten minutes of the same talk with one ordinary forty-second pause in the middle:
    /// somebody thinking, not somebody leaving.
    @Test func tenMinutesOfTalkWithOneOrdinaryPauseIsNotCut() {
        let blocks =
            talk(from: t0, minutes: 5, dialogue: true)
            + talk(
                from: t0 + 5 * 60_000 + 40_000, minutes: 5, gapBeforeFirstMs: 42_000,
                dialogue: true)
        for (name, policy) in bothPolicies {
            #expect(
                ConversationSegmenter.cuts(blocks: blocks, policy: policy).isEmpty,
                "\(name) policy")
        }
    }

    @Test func twentyMinutesOfOneKindOfTalkIsOneUnit() {
        for (name, policy) in bothPolicies {
            for dialogue in [true, false] {
                #expect(
                    ConversationSegmenter.cuts(
                        blocks: talk(from: t0, minutes: 20, dialogue: dialogue), policy: policy
                    ).isEmpty, "\(name) policy, dialogue \(dialogue)")
            }
        }
    }

    /// THE GUARANTEE. Three hours of talk with no pause and no visible change anywhere — the
    /// case the old rules left as one three-hour "conversation" — is still divided, and no unit
    /// it is divided into runs past ninety minutes. Eight hours of it, the same.
    @Test(arguments: [180, 480])
    func homogeneousPauseFreeTalkIsStillDividedIntoConversationSizedUnits(minutes: Int) {
        for (name, policy) in bothPolicies {
            for dialogue in [true, false] {
                let blocks = talk(from: t0, minutes: minutes, dialogue: dialogue)
                let cuts = ConversationSegmenter.cuts(blocks: blocks, policy: policy)
                let lengths = unitLengthsMs(blocks, cuts: cuts)
                let label = "\(name) policy, dialogue \(dialogue), \(minutes) min: \(cuts)"
                #expect(!cuts.isEmpty, "\(label)")
                #expect((lengths.max() ?? .max) <= 90 * 60_000, "\(label)")
                // Divided, not shredded: the units are conversation-sized at the other end too.
                #expect((lengths.min() ?? 0) >= 10 * 60_000, "\(label)")
            }
        }
    }

    @Test func noUnitIsEverLongerThanMaxUnitMsEvenWhenLengthCostsNothing() {
        // With the quadratic price switched off there is no reason left to cut homogeneous
        // talk — except the hard limit, which still applies.
        var policy = frozenSegmenterPolicy
        policy.longWeight = 0
        policy.maxUnitMs = 60 * 60_000
        let blocks = talk(from: t0, minutes: 200, dialogue: true)
        let cuts = ConversationSegmenter.cuts(blocks: blocks, policy: policy)
        #expect(!cuts.isEmpty)
        #expect(unitLengthsMs(blocks, cuts: cuts).allSatisfy { $0 <= policy.maxUnitMs })
    }

    // MARK: - the person's "no cut here"

    @Test func aBlockedPositionIsNeverCutHoweverStrongTheEvidence() {
        let before = talk(from: t0, minutes: 30, dialogue: true, vocabulary: vocabularyA)
        let after = talk(
            from: t0 + 34 * 60_000, minutes: 30, gapBeforeFirstMs: 4 * 60_000 + 2_000,
            dialogue: false, dictation: true, vocabulary: vocabularyB)
        let blocks = before + after
        for (name, policy) in bothPolicies {
            let free = ConversationSegmenter.cuts(blocks: blocks, policy: policy)
            #expect(free == [30], "\(name) policy")
            let blocked = ConversationSegmenter.cuts(blocks: blocks, blocked: [30], policy: policy)
            #expect(!blocked.contains(30), "\(name) policy: \(blocked)")
            // Blocking a position where nothing was going to be cut changes nothing.
            #expect(
                ConversationSegmenter.cuts(blocks: blocks, blocked: [7, 45], policy: policy)
                    == free, "\(name) policy")
            // With every position blocked there is nothing left to choose.
            #expect(
                ConversationSegmenter.cuts(
                    blocks: blocks, blocked: Set(1..<blocks.count), policy: policy
                ).isEmpty, "\(name) policy")
        }
    }

    @Test func blockingEveryPositionOverridesEvenTheGuarantee() {
        // "These are one conversation" is the person's answer; three hours of it stays whole.
        let blocks = talk(from: t0, minutes: 180, dialogue: true)
        #expect(
            ConversationSegmenter.cuts(
                blocks: blocks, blocked: Set(1..<blocks.count), policy: frozenSegmenterPolicy
            ).isEmpty)
    }

    // MARK: - decisions already made

    @Test func aForcedPositionIsAlwaysCutAndNothingElseMoves() {
        // Twenty minutes of one kind of talk is one unit — unless a unit must start inside it.
        let plain = talk(from: t0, minutes: 20, dialogue: true)
        let policy = frozenSegmenterPolicy
        #expect(ConversationSegmenter.cuts(blocks: plain, policy: policy).isEmpty)
        #expect(ConversationSegmenter.cuts(blocks: plain, forced: [7], policy: policy) == [7])
        #expect(
            ConversationSegmenter.cuts(blocks: plain, forced: [3, 7, 12], policy: policy)
                == [3, 7, 12])

        // A forced cut beside a real one: both, and the real one exactly where it was.
        let before = talk(from: t0, minutes: 30, dialogue: true, vocabulary: vocabularyA)
        let after = talk(
            from: t0 + 34 * 60_000, minutes: 30, gapBeforeFirstMs: 4 * 60_000 + 2_000,
            dialogue: false, dictation: true, vocabulary: vocabularyB)
        for (name, policy) in bothPolicies {
            #expect(
                ConversationSegmenter.cuts(blocks: before + after, forced: [10], policy: policy)
                    == [10, 30], "\(name) policy")
            #expect(
                ConversationSegmenter.cuts(blocks: before + after, forced: [30], policy: policy)
                    == [30], "\(name) policy")
        }
    }

    @Test func forcedBeatsBlockedAndIndexesOutsideTheBlocksAreIgnored() {
        let plain = talk(from: t0, minutes: 20, dialogue: true)
        let policy = frozenSegmenterPolicy
        // A held decision and a "no cut here" at the same block: the decision stands.
        #expect(
            ConversationSegmenter.cuts(blocks: plain, forced: [7], blocked: [7], policy: policy)
                == [7])
        #expect(
            ConversationSegmenter.cuts(
                blocks: plain, forced: [7], blocked: Set(1..<20), policy: policy) == [7])
        // Block 0 starts a unit anyway, and there is no block 20 or 99.
        #expect(
            ConversationSegmenter.cuts(blocks: plain, forced: [0, 20, 99], policy: policy)
                .isEmpty)
    }

    @Test func noUnitRunsAcrossAForcedPosition() {
        // Three hours of homogeneous talk with the middle forced: the search still divides each
        // half on its own, and block 90 starts a unit.
        let blocks = talk(from: t0, minutes: 180, dialogue: true)
        for (name, policy) in bothPolicies {
            let cuts = ConversationSegmenter.cuts(blocks: blocks, forced: [90], policy: policy)
            #expect(cuts.contains(90), "\(name) policy: \(cuts)")
            #expect(
                (unitLengthsMs(blocks, cuts: cuts).max() ?? .max) <= 90 * 60_000,
                "\(name) policy: \(cuts)")
        }
    }

    // MARK: - the vocabulary model, which the shipped policy leaves off

    @Test func withTheVocabularyModelOnAChangeOfSubjectAloneIsCut() {
        // An hour of the same two voices at the same pace, no pause anywhere — but the first
        // half is about one thing and the second about another. With words unread that is one
        // kind of talk; with the vocabulary model on it is two, cut where the words change.
        let blocks =
            talk(from: t0, minutes: 30, dialogue: true, vocabulary: vocabularyA)
            + talk(from: t0 + 30 * 60_000, minutes: 30, dialogue: true, vocabulary: vocabularyB)
        var policy = frozenSegmenterPolicy
        #expect(ConversationSegmenter.cuts(blocks: blocks, policy: policy).isEmpty)
        policy.wordWeight = 0.25
        #expect(ConversationSegmenter.cuts(blocks: blocks, policy: policy) == [30])
    }

    /// The guarantee is the quadratic price of a long unit, and it has to hold whatever else the
    /// policy scores — including with the vocabulary model turned on, which is "what a finer
    /// setting would turn on".
    ///
    /// KNOWN ISSUE (reported 2026-09-30): the vocabulary term is a marginal likelihood, which
    /// grows FASTER than linearly with the length of a unit whose blocks resemble each other, so
    /// on homogeneous talk it outbids the length price. With `wordWeight` 0.25 (the value
    /// committed at eb28c62) three hours of talk over a small repeated vocabulary is not divided
    /// at all, and eight hours is divided once — at the 4-hour hard limit. The shipped policy
    /// has the weight at 0, so nothing ships with this; it bites whoever turns it back on.
    @Test(arguments: [180, 480])
    func theGuaranteeSurvivesTurningTheVocabularyModelOn(minutes: Int) {
        let blocks = talk(from: t0, minutes: minutes, dialogue: true)
        var policy = frozenSegmenterPolicy
        policy.wordWeight = 0.25
        withKnownIssue("the vocabulary term grows superlinearly and outbids the length price") {
            let cuts = ConversationSegmenter.cuts(blocks: blocks, policy: policy)
            #expect(
                (unitLengthsMs(blocks, cuts: cuts).max() ?? .max) <= 90 * 60_000,
                "\(minutes) min: \(cuts)")
        }
    }

    /// The rhythm model pulls the same way, but mildly: with it on, homogeneous talk is still
    /// divided, into units a little longer than without it (96 minutes where the length price
    /// alone gives 60).
    @Test(arguments: [180, 480])
    func withTheRhythmModelOnHomogeneousTalkIsStillDivided(minutes: Int) {
        let blocks = talk(from: t0, minutes: minutes, dialogue: true)
        var policy = frozenSegmenterPolicy
        policy.rhythmWeight = 0.5
        let cuts = ConversationSegmenter.cuts(blocks: blocks, policy: policy)
        #expect(!cuts.isEmpty)
        #expect(
            (unitLengthsMs(blocks, cuts: cuts).max() ?? .max) <= 120 * 60_000,
            "\(minutes) min: \(cuts)")
    }

    // MARK: - audio nobody has heard yet

    /// Ten hours of recordings with no transcripts: forty 15-minute blocks about which nothing
    /// is known but their length. They are divided by length alone — evenly, into hours.
    @Test func aRunOfOpaqueBlocksIsCutByLengthOnly() {
        let blocks = opaque(from: t0, count: 40)
        #expect(
            ConversationSegmenter.cuts(blocks: blocks, policy: frozenSegmenterPolicy)
                == [4, 8, 12, 16, 20, 24, 28, 32, 36])

        // Whatever an opaque block happens to carry is not read: only its length is.
        var decorated = blocks
        for index in decorated.indices {
            decorated[index].terms = index < 20 ? vocabularyA : vocabularyB
            decorated[index].isDialogue = index < 20
            decorated[index].isDictation = index >= 20
            decorated[index].isForeign = index % 3 == 0
            decorated[index].opensWithGreeting = index == 20
            decorated[index].gapBeforeMs = index == 20 ? 10 * 60_000 : 0
            decorated[index].lines = 5
            decorated[index].words = 100
        }
        for (name, policy) in bothPolicies {
            let plain = ConversationSegmenter.cuts(blocks: blocks, policy: policy)
            #expect(
                ConversationSegmenter.cuts(blocks: decorated, policy: policy) == plain,
                "\(name) policy")
            // The shipped policy, whatever its numbers: several units, none past three hours.
            let lengths = unitLengthsMs(blocks, cuts: plain)
            #expect(lengths.count > 2, "\(name) policy: \(plain)")
            #expect((lengths.max() ?? .max) <= 3 * 60 * 60_000, "\(name) policy: \(plain)")
        }
    }

    @Test func aShortRunOfOpaqueBlocksIsLeftWhole() {
        // Forty-five minutes waiting for its transcript is not worth dividing.
        for (name, policy) in bothPolicies {
            #expect(
                ConversationSegmenter.cuts(blocks: opaque(from: t0, count: 3), policy: policy)
                    .isEmpty, "\(name) policy")
        }
    }

    @Test func thereIsNoEvidenceForACutBesideAnOpaqueBlock() {
        // Heard talk, then unheard audio, then heard talk: the joins with the unheard block
        // score nothing, whatever pause or change of mode sits there.
        let blocks =
            talk(from: t0, minutes: 5, dialogue: true)
            + opaque(from: t0 + 5 * 60_000, count: 1)
            + talk(
                from: t0 + 20 * 60_000, minutes: 5, gapBeforeFirstMs: 10 * 60_000,
                dialogue: false, dictation: true, vocabulary: vocabularyB)
        let scores = ConversationSegmenter.boundaryScores(
            blocks: blocks, policy: frozenSegmenterPolicy)
        #expect(scores[5] == 0)
        #expect(scores[6] == 0)
    }

    // MARK: - the pieces of the score

    @Test func aUnitPaysAFixedPriceMoreForBeingASliverAndQuadraticallyForRunningLong() {
        let policy = frozenSegmenterPolicy
        func cost(minutes: Double) -> Double {
            ConversationSegmenter.durationCost(ms: Int64(minutes * 60_000), policy: policy)
        }
        #expect(cost(minutes: 20) == 8)
        #expect(cost(minutes: 3) == 8)
        #expect(cost(minutes: 40) == 8)
        #expect(abs(cost(minutes: 2) - 9.5) < 1e-9)
        #expect(abs(cost(minutes: 0) - 12.5) < 1e-9)
        #expect(abs(cost(minutes: 60) - 9.6) < 1e-9)
        #expect(abs(cost(minutes: 180) - 86.4) < 1e-9)
        // Past `longFromMinutes` the price only ever rises, and faster the longer it runs —
        // which is what makes one three-hour unit dearer than three one-hour ones.
        #expect(cost(minutes: 180) > 3 * cost(minutes: 60))
        let steps = stride(from: 40.0, through: 240.0, by: 10).map(cost)
        let rises = zip(steps, steps.dropFirst()).map { $1 - $0 }
        #expect(rises.allSatisfy { $0 > 0 })
        #expect(zip(rises, rises.dropFirst()).allSatisfy { $1 > $0 })
    }

    @Test func aUnitThatIsAllOneModeScoresHigherThanAMixture() {
        let pure = ConversationSegmenter.flagLikelihood(0, 20)
        #expect(pure == ConversationSegmenter.flagLikelihood(20, 20))
        #expect(pure > ConversationSegmenter.flagLikelihood(10, 20))
        #expect(
            ConversationSegmenter.flagLikelihood(1, 20) > ConversationSegmenter.flagLikelihood(10, 20))
        #expect(ConversationSegmenter.flagLikelihood(0, 0) == 0)
        // Two pure units beat the same blocks as one mixed unit — the reason a change of mode
        // is cut at all.
        #expect(
            ConversationSegmenter.flagLikelihood(10, 10) + ConversationSegmenter.flagLikelihood(0, 10)
                > ConversationSegmenter.flagLikelihood(10, 20))
    }

    @Test func aSteadyRhythmScoresHigherThanTheSamePausesWithALongSilenceAmongThem() {
        func likelihood(_ gapsSeconds: [Double]) -> Double {
            let logs = gapsSeconds.map { log($0 + 1) }
            return ConversationSegmenter.rhythmLikelihood(
                logs.count, logs.reduce(0, +), logs.reduce(0) { $0 + $1 * $1 })
        }
        let steady = Array(repeating: 2.0, count: 20)
        var interrupted = steady
        interrupted[10] = 600
        #expect(likelihood(steady) > likelihood(interrupted))
        #expect(ConversationSegmenter.rhythmLikelihood(0, 0, 0) == 0)
    }

    @Test func theEvidenceForACutGrowsWithThePauseAndAGreetingAddsItsWeight() {
        let policy = frozenSegmenterPolicy
        func score(pauseMs: Int64, greeting: Bool = false) -> Double {
            var blocks =
                talk(from: t0, minutes: 5, dialogue: true)
                + talk(
                    from: t0 + 5 * 60_000 + pauseMs, minutes: 5, gapBeforeFirstMs: pauseMs,
                    dialogue: true)
            blocks[5].opensWithGreeting = greeting
            let scores = ConversationSegmenter.boundaryScores(blocks: blocks, policy: policy)
            #expect(scores[0] == 0, "index 0 is unused")
            return scores[5]
        }
        let pauses: [Int64] = [2_000, 10_000, 40_000, 120_000, 299_000, 300_000, 900_000]
        let scores = pauses.map { score(pauseMs: $0) }
        #expect(zip(scores, scores.dropFirst()).allSatisfy { $1 > $0 }, "\(scores)")
        // Five minutes is the step: the pause weight is continuous, the bonus is not.
        #expect(scores[5] - scores[4] > policy.pause5MinWeight)
        #expect(
            abs(score(pauseMs: 40_000, greeting: true) - score(pauseMs: 40_000) - policy.greetingWeight)
                < 1e-9)
    }

    @Test func aChangeOfModeIsEvidenceEvenWithNoPause() {
        let policy = frozenSegmenterPolicy
        let same =
            talk(from: t0, minutes: 5, dialogue: true)
            + talk(from: t0 + 5 * 60_000, minutes: 5, dialogue: true)
        let changed =
            talk(from: t0, minutes: 5, dialogue: true)
            + talk(from: t0 + 5 * 60_000, minutes: 5, dialogue: false, dictation: true)
        let foreign =
            talk(from: t0, minutes: 5, dialogue: true)
            + talk(from: t0 + 5 * 60_000, minutes: 5, dialogue: true, foreign: true)
        let base = ConversationSegmenter.boundaryScores(blocks: same, policy: policy)[5]
        #expect(ConversationSegmenter.boundaryScores(blocks: changed, policy: policy)[5] > base)
        #expect(ConversationSegmenter.boundaryScores(blocks: foreign, policy: policy)[5] > base)
        // The evidence sits AT the change, not a few blocks either side of it.
        let scores = ConversationSegmenter.boundaryScores(blocks: changed, policy: policy)
        #expect(scores[5] == scores.max())
    }
}
