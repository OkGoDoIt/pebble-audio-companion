import Foundation

/// A user-confirmed example. `confirmationID` links back to the durable correction/enrollment
/// event; never manufacture one from a prediction. Persistence and revocation belong to AppDB.
public struct ConfirmedSpeakerExample: Codable, Sendable {
    public let id: String
    public let personID: UUID
    public let confirmationID: String
    public let sessionID: String
    public let embedding: SpeakerEmbedding

    public init(id: String, personID: UUID, confirmationID: String, sessionID: String,
                embedding: SpeakerEmbedding) {
        self.id = id
        self.personID = personID
        self.confirmationID = confirmationID
        self.sessionID = sessionID
        self.embedding = embedding
    }
}

/// Thresholds must come from an explicitly named experiment/calibration. There is deliberately
/// no production default: cosine scores are not probabilities or measured watch accuracy.
public struct SpeakerMatchPolicy: Codable, Sendable {
    public let minimumSimilarity: Double
    public let minimumMargin: Double
    public let minimumExamples: Int
    public let calibrationID: String

    public init(minimumSimilarity: Double, minimumMargin: Double,
                minimumExamples: Int, calibrationID: String) {
        self.minimumSimilarity = minimumSimilarity
        self.minimumMargin = minimumMargin
        self.minimumExamples = minimumExamples
        self.calibrationID = calibrationID
    }

    func validate() throws {
        guard minimumSimilarity.isFinite, (-1...1).contains(minimumSimilarity),
              minimumMargin.isFinite, (0...2).contains(minimumMargin),
              (1...32).contains(minimumExamples), !calibrationID.isEmpty else {
            throw SpeakerRecognitionError.invalidPolicy
        }
    }
}

public enum SpeakerAbstention: String, Codable, Sendable {
    case noCompatibleExamples, insufficientEvidence, belowThreshold, ambiguous
}

public struct SpeakerMatch: Codable, Equatable, Sendable {
    public let personID: UUID?
    public let score: Double?
    public let margin: Double?
    public let abstention: SpeakerAbstention?
    public let calibrationID: String
}

public enum SpeakerMatcher {
    /// Small account-local roster, exact cosine search. Mean of the best two confirmed examples
    /// reduces dependence on one anomalous crop. Extra examples are bounded; callers should
    /// retain diverse sessions. Excluded identities implement explicit "not this person" evidence.
    public static func match(_ query: SpeakerEmbedding, examples: [ConfirmedSpeakerExample],
                             policy: SpeakerMatchPolicy, excluding: Set<UUID> = []) throws -> SpeakerMatch {
        try policy.validate()
        _ = try SpeakerEmbedding(recipe: query.recipe, values: query.values)
        var ids = Set<String>()
        for example in examples {
            guard !example.id.isEmpty, !example.confirmationID.isEmpty,
                  !example.sessionID.isEmpty, ids.insert(example.id).inserted else {
                throw SpeakerRecognitionError.invalidCorpus("Examples require unique IDs and confirmation provenance")
            }
        }
        let compatible = examples.filter { $0.embedding.recipe == query.recipe && !excluding.contains($0.personID) }
        func abstain(_ reason: SpeakerAbstention, score: Double? = nil, margin: Double? = nil) -> SpeakerMatch {
            SpeakerMatch(personID: nil, score: score, margin: margin,
                         abstention: reason, calibrationID: policy.calibrationID)
        }
        guard !compatible.isEmpty else { return abstain(.noCompatibleExamples) }
        let groups = Dictionary(grouping: compatible, by: \.personID)
        var candidates: [(personID: UUID, score: Double, count: Int)] = []
        for (personID, group) in groups {
            guard group.count <= 32 else {
                throw SpeakerRecognitionError.invalidCorpus("Keep at most 32 confirmed examples per person and recipe")
            }
            let scores = try group.map { try query.cosineSimilarity(to: $0.embedding) }.sorted(by: >)
            let best = scores.prefix(2)
            candidates.append((personID, best.reduce(0, +) / Double(best.count), group.count))
        }
        candidates.sort {
            $0.score == $1.score ? $0.personID.uuidString < $1.personID.uuidString : $0.score > $1.score
        }
        guard let winner = candidates.first else { return abstain(.insufficientEvidence) }
        let margin = candidates.count > 1 ? winner.score - candidates[1].score : nil
        // A likely person with too few examples must cause abstention, not disappear and let
        // the runner-up acquire their speech. Incomplete profiles still compete on margin.
        guard winner.count >= policy.minimumExamples else {
            return abstain(.insufficientEvidence, score: winner.score, margin: margin)
        }
        guard winner.score >= policy.minimumSimilarity else { return abstain(.belowThreshold, score: winner.score, margin: margin) }
        // Ties always abstain, even when an experiment deliberately sets a zero margin.
        if let margin, margin <= 0 || margin < policy.minimumMargin {
            return abstain(.ambiguous, score: winner.score, margin: margin)
        }
        return SpeakerMatch(personID: winner.personID, score: winner.score, margin: margin,
                            abstention: nil, calibrationID: policy.calibrationID)
    }
}
