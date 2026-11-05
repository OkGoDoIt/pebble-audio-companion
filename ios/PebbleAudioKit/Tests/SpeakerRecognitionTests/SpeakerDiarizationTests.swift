import Foundation
import Testing
@testable import SpeakerRecognition

@Suite struct SpeakerDiarizationTests {
    static let recipe = SpeakerEmbeddingRecipe(modelID: "test", modelRevision: "1", weightsSHA256: "digest",
        runtimeID: "fake", preprocessingID: "16k", dimensions: 128)

    /// A deterministic stand-in for a noisy reading of a voice.
    struct Noise: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }
    static func voice(_ axis: Int) -> [Float] { (0..<128).map { $0 == axis ? 1 : 0 } }
    /// How much of a crop is voice: 0.55 gives two crops of one voice a similarity near 0.3, about
    /// what real watch audio shows, while two crops of different voices sit near zero.
    static func crop(_ voice: [Float], _ index: Int, _ noise: inout Noise, signal: Float = 0.55) throws -> SpeakerEmbedding {
        let random = (0..<128).map { _ in Float.random(in: -1...1, using: &noise) }
        let norm = random.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return try SpeakerEmbedding(recipe: recipe, values: zip(voice, random).map { signal * $0 + (1 - signal) * $1 / norm })
    }

    /// Two people taking turns. No crop is alike enough to compare directly: pooling is the point.
    @Test func twoPeopleAreToldApartThoughNoTwoCropsAreClearlyAlike() throws {
        var noise = Noise(state: 7)
        var crops: [SpeakerDiarization.Crop] = []
        var truth: [Int] = []
        var at: Int64 = 0
        for turn in 0..<8 {
            for index in 0..<4 {
                crops.append(.init(startMs: at, endMs: at + 2_500,
                                   embedding: try Self.crop(Self.voice(turn % 2), index, &noise)))
                truth.append(turn % 2)
                at += 2_500
            }
            at += 3_000
        }
        let pairs = zip(crops, crops.dropFirst())
        let alike = try pairs.map { try $0.0.embedding.cosineSimilarity(to: $0.1.embedding) }
        #expect(alike.max()! < 0.75, "A fixture with clean crops would prove nothing")
        let speakers = SpeakerDiarization.speakers(crops)
        #expect(Set(speakers).count == 2)
        let mapping = Dictionary(zip(truth, speakers), uniquingKeysWith: { first, _ in first })
        #expect(zip(truth, speakers).allSatisfy { mapping[$0] == $1 }, "One voice, one speaker, across the whole recording")
    }

    @Test func aStretchTakesItsSpeakerFromItsCropsOrFromBothSidesOfIt() throws {
        var noise = Noise(state: 1)
        func crop(_ start: Int64, _ end: Int64) throws -> SpeakerDiarization.Crop {
            .init(startMs: start, endMs: end, embedding: try Self.crop(Self.voice(0), 0, &noise))
        }
        let crops = try [crop(0, 2_000), crop(2_000, 4_000), crop(10_000, 12_000), crop(30_000, 32_000)]
        let speakers = [0, 0, 1, 0]
        func speaker(_ range: Range<Int64>) -> Int? { SpeakerDiarization.speaker(of: range, crops: crops, speakers: speakers) }
        #expect(speaker(500..<3_500) == 0)
        #expect(speaker(1_000..<11_000) == 0, "Mostly the first speaker's crops")
        #expect(speaker(4_000..<4_500) == 0, "Only one side is close")
        #expect(speaker(6_000..<8_000) == nil, "Different speakers each side")
        #expect(speaker(20_000..<21_000) == nil, "Too far from any crop to place")
        #expect(SpeakerDiarization.speakers([]).isEmpty)
    }

    @Test func aPooledVoiceIsTheNormalizedMeanOfItsCrops() throws {
        let recipe = SpeakerEmbeddingRecipe(modelID: "t", modelRevision: "1", weightsSHA256: "d", runtimeID: "f",
                                            preprocessingID: "p", dimensions: 2)
        let pooled = try SpeakerEmbedding.pooled([
            try SpeakerEmbedding(recipe: recipe, values: [1, 0]), try SpeakerEmbedding(recipe: recipe, values: [0, 1]),
        ])
        #expect(abs(pooled.values[0] - 0.7071) < 0.001 && abs(pooled.values[1] - 0.7071) < 0.001)
        #expect(throws: SpeakerRecognitionError.invalidEmbedding) { try SpeakerEmbedding.pooled([]) }
    }
}
