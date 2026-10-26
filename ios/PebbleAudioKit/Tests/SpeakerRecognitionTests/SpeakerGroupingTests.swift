import Foundation
import Testing
@testable import SpeakerRecognition

@Suite struct SpeakerGroupingTests {
    private let recipe = SpeakerEmbeddingRecipe(modelID: "test", modelRevision: "1", weightsSHA256: "digest",
                                                runtimeID: "fake", preprocessingID: "16k", dimensions: 2)
    private func item(_ id: String, _ source: String, _ degrees: Double) throws -> SpeakerGrouping.Item {
        SpeakerGrouping.Item(id: id, sourceID: source, embedding: try SpeakerEmbedding(recipe: recipe,
            values: [Float(cos(degrees * .pi / 180)), Float(sin(degrees * .pi / 180))]))
    }

    @Test func aVoiceRecurringAcrossRecordingsIsOneGroupAndOtherVoicesStayApart() throws {
        let items = [
            try item("a1", "rec1", 0), try item("a2", "rec2", 10), try item("a3", "rec3", 20), try item("a4", "rec1", 5),
            try item("b1", "rec1", 90), try item("b2", "rec2", 95), try item("b3", "rec4", 100),
            try item("c1", "rec5", 180), try item("c2", "rec5", 182), try item("c3", "rec5", 185),
        ]
        let groups = SpeakerGrouping.group(items, threshold: 0.6)
        #expect(groups.map { Set($0) } == [["a1", "a2", "a3", "a4"], ["b1", "b2", "b3"]],
                "c is one recording only, so it isn't asked about")
    }

    @Test func aChainOfSimilarPairsDoesNotJoinTwoDistinctVoices() throws {
        // 0°, 30°, 60°, 90°: neighbours are alike (cos 30° ≈ 0.87) but the ends are not (cos 90° = 0).
        let items = [try item("p", "r1", 0), try item("q", "r2", 30), try item("r", "r3", 60), try item("s", "r4", 90)]
        let groups = SpeakerGrouping.group(items, threshold: 0.75, minimumItems: 2)
        #expect(!groups.contains { $0.count == 4 }, "Average linkage keeps the chain apart")
    }
}
