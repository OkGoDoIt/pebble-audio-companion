import Foundation
import Testing
@testable import SpeakerRecognition

private actor SegmentationFixture: SpeakerSegmentationEngine {
    let kinds: [Int]
    var calls: [Int] = []
    let weakBoundary: Bool
    init(_ kinds: [Int], weakBoundary: Bool = false) { self.kinds = kinds; self.weakBoundary = weakBoundary }
    func scores(pcm16LE: Data, model: CoreMLSegmentationModel,
                authorize: @escaping @Sendable () throws -> Void) throws -> [Float] {
        try authorize()
        let kind = kinds[min(calls.count, kinds.count - 1)]
        calls.append(pcm16LE.count)
        var output = [Float](repeating: 0, count: 589 * 7)
        for frame in 0..<589 { output[frame * 7 + kind] = 1 }
        if weakBoundary, kind != 0 { output[kind] = 0.56; output[0] = 0.44 }
        return output
    }
    func release() {}
}

private actor EmbeddingFixture: SpeakerEmbeddingEngine {
    var calls = 0
    func embed(sample: SpeakerAudioSample, model: CactusSpeakerModel,
               authorize: @escaping @Sendable () throws -> Void) throws -> NativeSpeakerEmbedding {
        try authorize()
        calls += 1
        var values = [Float](repeating: 0, count: 256)
        values[sample.pcm16LE[0] == 0xE8 ? 0 : 1] = 1 // PCM1000 versus2000 fixtures.
        return NativeSpeakerEmbedding(values: values, inferenceMilliseconds: 1)
    }
    func release() {}
}

@Suite struct SpeakerDiarizerTests {
    private func pcm(_ sample: Int16, seconds: Int) -> Data {
        [Int16](repeating: sample.littleEndian, count: 16_000 * seconds).withUnsafeBytes { Data($0) }
    }
    private func analyzer(_ segmentation: SegmentationFixture, _ engine: EmbeddingFixture) -> LocalSpeakerDiarizer {
        let url = URL(fileURLWithPath: "/unused")
        return LocalSpeakerDiarizer(embedding: CactusSpeakerEmbeddingProvider(
            model: CactusSpeakerModel(directory: url), engine: engine),
            segmentation: segmentation, model: CoreMLSegmentationModel(directory: url))
    }
    private func input(_ pcm: Data) -> SpeakerAnalysisAudio {
        SpeakerAnalysisAudio(pcm16LE: pcm, sourceID: "source", sourceRevision: "revision",
                             sessionID: "session", sourceStartSample: 32_000)
    }

    @Test func slotPermutationsAreClusteredAndCoordinatesRemainInOriginalSource() async throws {
        let segmentation = SegmentationFixture([1, 2, 1])
        let engine = EmbeddingFixture()
        let analyzer = analyzer(segmentation, engine)
        await analyzer.setEnabled(true)
        let result = try await analyzer.analyze(input(pcm(1000, seconds: 20) + pcm(2000, seconds: 10)))
        #expect(await segmentation.calls == [320_000, 320_000, 320_000])
        #expect(result.turns.count == 12)
        #expect(result.turns[0].clusterID == result.turns[4].clusterID)
        #expect(result.turns[0].clusterID != result.turns[8].clusterID)
        #expect(result.turns[0].startSample == 32_000)
        #expect(result.turns.last?.endSample == 512_000)
        #expect(await engine.calls == 12)
    }

    @Test func oneUncertainBoundaryFrameDoesNotRejectAnOtherwiseCleanPassage() async throws {
        let segmentation = SegmentationFixture([1], weakBoundary: true)
        let analyzer = analyzer(segmentation, EmbeddingFixture())
        await analyzer.setEnabled(true)
        let result = try await analyzer.analyze(input(pcm(1000, seconds: 3)))
        let turn = try #require(result.turns.first)
        #expect(turn.embedding != nil)
        #expect(turn.speechConfidence > 0.99)
    }

    @Test func missedChangeWithinOneModelSlotDoesNotPoolDifferentVoices() async throws {
        let segmentation = SegmentationFixture([1])
        let engine = EmbeddingFixture()
        let analyzer = analyzer(segmentation, engine)
        await analyzer.setEnabled(true)
        let result = try await analyzer.analyze(input(pcm(1000, seconds: 5) + pcm(2000, seconds: 5)))
        #expect(result.turns.count == 4)
        #expect(result.turns[0].clusterID == result.turns[1].clusterID)
        #expect(result.turns[2].clusterID == result.turns[3].clusterID)
        #expect(result.turns[0].clusterID != result.turns[2].clusterID)
        #expect(result.turns.allSatisfy { $0.embedding != nil && $0.endSample - $0.startSample == 40_000 })
    }

    @Test func overlapNeverProducesEnrollmentEmbeddingAndShortWindowIsClipped() async throws {
        let segmentation = SegmentationFixture([4])
        let engine = EmbeddingFixture()
        let analyzer = analyzer(segmentation, engine)
        await analyzer.setEnabled(true)
        let result = try await analyzer.analyze(input(pcm(1000, seconds: 3)))
        let turn = try #require(result.turns.first)
        #expect(turn.startSample == 32_000)
        #expect(turn.endSample == 80_000)
        #expect(turn.overlap)
        #expect(turn.embedding == nil)
        #expect(turn.clusterID == nil)
        #expect(await engine.calls == 0)
    }

    @Test func offAndOversizedInputsDoNotReachModels() async throws {
        let segmentation = SegmentationFixture([1])
        let engine = EmbeddingFixture()
        let analyzer = analyzer(segmentation, engine)
        await #expect(throws: SpeakerRecognitionError.disabled) { try await analyzer.analyze(input(Data())) }
        await analyzer.setEnabled(true)
        await #expect(throws: SpeakerRecognitionError.self) { try await analyzer.analyze(input(pcm(1000, seconds: 31))) }
        #expect(await segmentation.calls.isEmpty)
    }

    @Test func silenceHasNoTurnAndNativeScoreShapeIsValidated() async throws {
        let segmentation = SegmentationFixture([0])
        let engine = EmbeddingFixture()
        let analyzer = analyzer(segmentation, engine)
        await analyzer.setEnabled(true)
        #expect(try await analyzer.analyze(input(pcm(0, seconds: 3))).turns.isEmpty)
        #expect(throws: SpeakerRecognitionError.self) {
            try CoreMLSegmentationEngine.validate([1])
        }
    }
}
