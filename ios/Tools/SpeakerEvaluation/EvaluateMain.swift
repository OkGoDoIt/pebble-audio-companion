import Foundation

@main enum EvaluateSpeakerEmbeddings {
    struct Input: Decodable {
        let corpus: SpeakerEvaluationCorpus
        let policy: SpeakerMatchPolicy
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw SpeakerRecognitionError.invalidCorpus("Usage: evaluate-embeddings INPUT.json")
        }
        let input = try JSONDecoder().decode(Input.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let report = try SpeakerEvaluator.evaluate(input.corpus, policy: input.policy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
