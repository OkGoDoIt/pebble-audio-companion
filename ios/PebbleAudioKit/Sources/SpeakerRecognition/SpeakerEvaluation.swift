import Foundation

/// Explicit human labels, including reviewed unknown people. Nil personID means unknown to the
/// enrolled roster, never "we haven't labeled this yet". No labels are inferred from filenames.
public struct SpeakerEvaluationProbe: Codable, Sendable {
    public let id: String
    public let sessionID: String
    public let personID: UUID?
    public let labelConfirmationID: String
    public let condition: String
    public let embedding: SpeakerEmbedding

    public init(id: String, sessionID: String, personID: UUID?, labelConfirmationID: String,
                condition: String, embedding: SpeakerEmbedding) {
        self.id = id
        self.sessionID = sessionID
        self.personID = personID
        self.labelConfirmationID = labelConfirmationID
        self.condition = condition
        self.embedding = embedding
    }
}

public struct SpeakerEvaluationCorpus: Codable, Sendable {
    public let enrollment: [ConfirmedSpeakerExample]
    public let probes: [SpeakerEvaluationProbe]
    public let selfPersonID: UUID?
    public init(enrollment: [ConfirmedSpeakerExample], probes: [SpeakerEvaluationProbe], selfPersonID: UUID?) {
        self.enrollment = enrollment
        self.probes = probes
        self.selfPersonID = selfPersonID
    }
}

public struct SpeakerEvaluationCounts: Codable, Equatable, Sendable {
    public var total = 0
    public var known = 0
    public var unknown = 0
    public var correctlyNamed = 0
    public var incorrectlyNamed = 0
    public var knownAbstained = 0
    public var unknownRejected = 0
    public var falseSelf = 0
    public var named = 0
    public var coverage: Double { total == 0 ? 0 : Double(named) / Double(total) }

    mutating func record(truth: UUID?, result: UUID?, selfID: UUID?) {
        total += 1
        if truth != nil { known += 1 } else { unknown += 1 }
        if result != nil { named += 1 }
        if let result {
            if result == truth { correctlyNamed += 1 } else { incorrectlyNamed += 1 }
            if result == selfID, truth != selfID { falseSelf += 1 }
        } else if truth == nil { unknownRejected += 1 } else { knownAbstained += 1 }
    }
}

public struct SpeakerEvaluationReport: Codable, Sendable {
    public let recipe: SpeakerEmbeddingRecipe
    public let policy: SpeakerMatchPolicy
    public let counts: SpeakerEvaluationCounts
    public let conditions: [String: SpeakerEvaluationCounts]
    public let decisions: [String: SpeakerMatch]
}

public enum SpeakerEvaluator {
    /// Refuses same-session leakage and mixed recipes. Use separate tuning and held-out corpus
    /// files; this helper does not choose thresholds or claim a representative population.
    public static func evaluate(_ corpus: SpeakerEvaluationCorpus, policy: SpeakerMatchPolicy) throws -> SpeakerEvaluationReport {
        try policy.validate()
        guard let first = corpus.enrollment.first, !corpus.probes.isEmpty else {
            throw SpeakerRecognitionError.invalidCorpus("Provide confirmed enrollment and held-out probes")
        }
        let enrollmentSessions = Set(corpus.enrollment.map(\.sessionID))
        let enrolledPeople = Set(corpus.enrollment.map(\.personID))
        if let selfID = corpus.selfPersonID, !enrolledPeople.contains(selfID) {
            throw SpeakerRecognitionError.invalidCorpus("Self identity must be in the enrolled roster")
        }
        guard corpus.enrollment.allSatisfy({ $0.embedding.recipe == first.embedding.recipe }),
              corpus.probes.allSatisfy({ $0.embedding.recipe == first.embedding.recipe }) else {
            throw SpeakerRecognitionError.incompatibleRecipe
        }
        var ids = Set(corpus.enrollment.map(\.id))
        var counts = SpeakerEvaluationCounts()
        var conditions: [String: SpeakerEvaluationCounts] = [:]
        var decisions: [String: SpeakerMatch] = [:]
        for probe in corpus.probes {
            guard !probe.id.isEmpty, ids.insert(probe.id).inserted,
                  !probe.sessionID.isEmpty, !enrollmentSessions.contains(probe.sessionID),
                  !probe.labelConfirmationID.isEmpty, !probe.condition.isEmpty,
                  probe.personID.map({ enrolledPeople.contains($0) }) ?? true else {
                throw SpeakerRecognitionError.invalidCorpus("Probe labels must be explicit, IDs unique, and sessions held out")
            }
            let result = try SpeakerMatcher.match(probe.embedding, examples: corpus.enrollment, policy: policy)
            decisions[probe.id] = result
            counts.record(truth: probe.personID, result: result.personID, selfID: corpus.selfPersonID)
            conditions[probe.condition, default: SpeakerEvaluationCounts()].record(
                truth: probe.personID, result: result.personID, selfID: corpus.selfPersonID)
        }
        return SpeakerEvaluationReport(recipe: first.embedding.recipe, policy: policy,
            counts: counts, conditions: conditions, decisions: decisions)
    }
}
