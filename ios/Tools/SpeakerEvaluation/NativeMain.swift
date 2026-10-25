import Foundation

/// Compiled with the exact package sources by run-native.sh; no duplicate inference code.
@main enum SpeakerNativeEvaluation {
    struct Manifest: Decodable {
        let policy: SpeakerMatchPolicy
        let selfPersonID: UUID?
        let samples: [Sample]
    }
    struct Sample: Decodable {
        let id: String
        let pcmPath: String
        let partition: String
        let personID: UUID?
        let confirmationID: String
        let condition: String
        let evidence: SpeakerAudioEvidence
    }
    struct Smoke: Encodable {
        let recipe: SpeakerEmbeddingRecipe
        let dimensions: Int
        let allFinite: Bool
        let unitNorm: Double
        let repeatCosine: Double
        let durationSeconds: Double
        let firstInferenceMilliseconds: Double?
        let secondInferenceMilliseconds: Double?
        let elapsedSeconds: Double
        let accuracyMeasured = false
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, ["smoke", "evaluate"].contains(args[1]) else {
            throw SpeakerRecognitionError.invalidCorpus("Usage: speaker-native smoke MODEL_DIR PCM16LE | evaluate MODEL_DIR MANIFEST.json")
        }
        let provider = CactusSpeakerEmbeddingProvider(model: CactusSpeakerModel(directory: URL(fileURLWithPath: args[2])))
        await provider.setEnabled(true)
        do {
            if args[1] == "smoke" {
                let pcm = try Data(contentsOf: URL(fileURLWithPath: args[3]))
                let evidence = SpeakerAudioEvidence(sourceID: "explicit-smoke-fixture", sourceRevision: "smoke",
                    sessionID: "smoke", startSample: 0, endSample: pcm.count / 2,
                    speechOnly: true, singleSpeaker: true, containsDiscontinuity: false)
                let sample = SpeakerAudioSample(pcm16LE: pcm, evidence: evidence)
                let start = Date()
                let first = try await provider.embedding(for: sample)
                let second = try await provider.embedding(for: sample)
                let values = first.embedding.values
                let result = Smoke(recipe: first.embedding.recipe, dimensions: values.count,
                    allFinite: values.allSatisfy(\.isFinite),
                    unitNorm: sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) }),
                    repeatCosine: try first.embedding.cosineSimilarity(to: second.embedding),
                    durationSeconds: first.quality.durationSeconds,
                    firstInferenceMilliseconds: first.inferenceMilliseconds,
                    secondInferenceMilliseconds: second.inferenceMilliseconds,
                    elapsedSeconds: Date().timeIntervalSince(start))
                try printJSON(result)
            } else {
                let url = URL(fileURLWithPath: args[3])
                let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
                var enrollment: [ConfirmedSpeakerExample] = []
                var probes: [SpeakerEvaluationProbe] = []
                // Validate partitions/labels before any inference. Session/ID leakage is also
                // checked by the evaluator; repeated input paths are rejected up front.
                var paths = Set<String>()
                let sessions = Set(manifest.samples.filter { $0.partition == "enrollment" }.map { $0.evidence.sessionID })
                for entry in manifest.samples {
                    let file = URL(fileURLWithPath: entry.pcmPath, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                    guard ["enrollment", "probe"].contains(entry.partition),
                          !entry.confirmationID.isEmpty, !entry.condition.isEmpty,
                          paths.insert(file.resolvingSymlinksInPath().path).inserted,
                          entry.partition != "enrollment" || entry.personID != nil,
                          entry.partition != "probe" || !sessions.contains(entry.evidence.sessionID) else {
                        throw SpeakerRecognitionError.invalidCorpus("Explicit labels, unique crops and held-out sessions are required")
                    }
                }
                for entry in manifest.samples {
                    let file = URL(fileURLWithPath: entry.pcmPath, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                    let result = try await provider.embedding(for: SpeakerAudioSample(
                        pcm16LE: Data(contentsOf: file), evidence: entry.evidence))
                    if entry.partition == "enrollment", let personID = entry.personID {
                        enrollment.append(ConfirmedSpeakerExample(id: entry.id, personID: personID,
                            confirmationID: entry.confirmationID, sessionID: entry.evidence.sessionID,
                            embedding: result.embedding))
                    } else {
                        probes.append(SpeakerEvaluationProbe(id: entry.id, sessionID: entry.evidence.sessionID,
                            personID: entry.personID, labelConfirmationID: entry.confirmationID,
                            condition: entry.condition, embedding: result.embedding))
                    }
                }
                try printJSON(SpeakerEvaluator.evaluate(SpeakerEvaluationCorpus(enrollment: enrollment,
                    probes: probes, selfPersonID: manifest.selfPersonID), policy: manifest.policy))
            }
            await provider.setEnabled(false)
        } catch {
            await provider.setEnabled(false)
            throw error
        }
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
