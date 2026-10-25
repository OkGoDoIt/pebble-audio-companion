import Foundation
import Testing
@testable import SpeakerRecognition

@Suite struct SpeakerMatchingTests {
    let me = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let recipe = SpeakerEmbeddingRecipe(modelID: "test", modelRevision: "1", weightsSHA256: "test",
        runtimeID: "test", preprocessingID: "test", dimensions: 2)
    let policy = SpeakerMatchPolicy(minimumSimilarity: 0.8, minimumMargin: 0.1,
        minimumExamples: 1, calibrationID: "synthetic-unit-test-only")

    func vector(_ values: [Float]) throws -> SpeakerEmbedding { try SpeakerEmbedding(recipe: recipe, values: values) }
    func example(_ id: String, _ person: UUID, _ values: [Float]) throws -> ConfirmedSpeakerExample {
        ConfirmedSpeakerExample(id: id, personID: person, confirmationID: "human-\(id)",
            sessionID: "enrollment", embedding: try vector(values))
    }

    @Test func unknownAndAmbiguousSpeechAbstainAndExclusionCannotForceAMatch() throws {
        let profiles = try [example("me", me, [1, 0]), example("other", other, [0, 1])]
        let known = try SpeakerMatcher.match(vector([1, 0]), examples: profiles, policy: policy)
        #expect(known.personID == me)
        #expect(try SpeakerMatcher.match(vector([-1, -1]), examples: profiles, policy: policy).abstention == .belowThreshold)
        #expect(try SpeakerMatcher.match(vector([1, 0]), examples: profiles, policy: policy, excluding: [me]).personID == nil)
        let tied = try [example("me", me, [1, 0]), example("other", other, [1, 0])]
        #expect(try SpeakerMatcher.match(vector([1, 0]), examples: tied, policy: policy).abstention == .ambiguous)
    }

    @Test func incompleteLikelyProfileStillCompetes() throws {
        let profiles = try [example("me", me, [1, 0]), example("other1", other, [0.9, 0.1]), example("other2", other, [0.9, 0.1])]
        let policy = SpeakerMatchPolicy(minimumSimilarity: 0.5, minimumMargin: 0,
            minimumExamples: 2, calibrationID: "synthetic-test")
        #expect(try SpeakerMatcher.match(vector([1, 0]), examples: profiles, policy: policy).abstention == .insufficientEvidence)
    }

    @Test func noCompatibleExamplesAndMissingConfirmationCannotProduceNames() throws {
        #expect(try SpeakerMatcher.match(vector([1, 0]), examples: [], policy: policy).abstention == .noCompatibleExamples)
        let bad = ConfirmedSpeakerExample(id: "a", personID: me, confirmationID: "", sessionID: "one", embedding: try vector([1, 0]))
        #expect(throws: SpeakerRecognitionError.self) { try SpeakerMatcher.match(vector([1, 0]), examples: [bad], policy: policy) }
        let invalidPolicy = SpeakerMatchPolicy(minimumSimilarity: .nan, minimumMargin: 0,
            minimumExamples: 1, calibrationID: "bad")
        #expect(throws: SpeakerRecognitionError.invalidPolicy) { try SpeakerMatcher.match(vector([1, 0]), examples: [], policy: invalidPolicy) }
    }

    @Test func evaluatorCountsFalseSelfUnknownRejectionCoverageAndConditions() throws {
        let enrollment = try [example("me", me, [1, 0]), example("other", other, [0, 1])]
        let probes = try [
            probe("right", truth: me, values: [1, 0]),
            probe("wrong-self", truth: other, values: [1, 0]),
            probe("unknown", truth: nil, values: [-1, -1]),
            probe("missed", truth: me, values: [-1, -1]),
        ]
        let report = try SpeakerEvaluator.evaluate(SpeakerEvaluationCorpus(enrollment: enrollment,
            probes: probes, selfPersonID: me), policy: policy)
        #expect(report.counts.total == 4)
        #expect(report.counts.correctlyNamed == 1)
        #expect(report.counts.incorrectlyNamed == 1)
        #expect(report.counts.falseSelf == 1)
        #expect(report.counts.unknownRejected == 1)
        #expect(report.counts.knownAbstained == 1)
        #expect(report.counts.coverage == 0.5)
        #expect(report.conditions["synthetic"] == report.counts)
    }

    @Test func evaluatorRejectsLeakageAndUnreviewedLabels() throws {
        let enrollment = try [example("me", me, [1, 0])]
        for (session, confirmation) in [("enrollment", "reviewed"), ("held-out", "")] {
            let probe = SpeakerEvaluationProbe(id: "probe", sessionID: session, personID: me,
                labelConfirmationID: confirmation, condition: "synthetic", embedding: try vector([1, 0]))
            #expect(throws: SpeakerRecognitionError.self) {
                try SpeakerEvaluator.evaluate(SpeakerEvaluationCorpus(enrollment: enrollment, probes: [probe], selfPersonID: me), policy: policy)
            }
        }
    }

    func probe(_ id: String, truth: UUID?, values: [Float]) throws -> SpeakerEvaluationProbe {
        SpeakerEvaluationProbe(id: id, sessionID: "held-out", personID: truth,
            labelConfirmationID: "human-\(id)", condition: "synthetic", embedding: try vector(values))
    }
}
