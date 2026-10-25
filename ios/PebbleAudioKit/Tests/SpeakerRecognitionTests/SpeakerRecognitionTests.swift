import Foundation
import CryptoKit
import Testing
@testable import SpeakerRecognition

private func audio(_ value: Int16 = 1_000, count: Int = 32_000,
                   gap: Bool = false, singleSpeaker: Bool = true) -> SpeakerAudioSample {
    let samples = [Int16](repeating: value.littleEndian, count: count)
    let pcm = samples.withUnsafeBytes { Data($0) }
    return SpeakerAudioSample(pcm16LE: pcm, evidence: SpeakerAudioEvidence(
        sourceID: "source", sourceRevision: "revision", sessionID: "session",
        startSample: 0, endSample: count, speechOnly: true, singleSpeaker: singleSpeaker,
        containsDiscontinuity: gap))
}

@Suite struct SpeakerRecognitionTests {
    @Test func audioRejectsSilenceClippingOverlapAndGaps() throws {
        #expect(throws: SpeakerRecognitionError.self) { try audio(0).validate() }
        #expect(throws: SpeakerRecognitionError.self) { try audio(.max).validate() }
        #expect(throws: SpeakerRecognitionError.self) { try audio(gap: true).validate() }
        #expect(throws: SpeakerRecognitionError.self) { try audio(singleSpeaker: false).validate() }
        #expect(throws: SpeakerRecognitionError.self) { try audio(count: 31_999).validate() }
        #expect(try audio().validate().durationSeconds == 2)
    }

    @Test func disabledDoesNotLoadModelOrInspectPrivateAudio() async throws {
        let provider = CactusSpeakerEmbeddingProvider(model: CactusSpeakerModel(
            directory: URL(fileURLWithPath: "/missing-model")))
        #expect(!provider.isEnabled)
        await #expect(throws: SpeakerRecognitionError.disabled) {
            _ = try await provider.embedding(for: audio(0))
        }
    }

    @Test func cosineRejectsWrongRecipeAndDegenerateVectors() throws {
        let recipe = CactusSpeakerModel.recipe
        #expect(throws: SpeakerRecognitionError.invalidEmbedding) {
            try SpeakerEmbedding(recipe: recipe, values: Array(repeating: 0, count: 256))
        }
        #expect(throws: SpeakerRecognitionError.invalidEmbedding) {
            try SpeakerEmbedding(recipe: recipe, values: [Float.nan])
        }
        let first = try SpeakerEmbedding(recipe: recipe, values: Array(repeating: 1, count: 256))
        #expect(abs(try first.cosineSimilarity(to: first) - 1) < 0.00001)
        let changed = SpeakerEmbeddingRecipe(modelID: recipe.modelID,
            modelRevision: recipe.modelRevision, weightsSHA256: recipe.weightsSHA256,
            runtimeID: recipe.runtimeID, preprocessingID: "changed", dimensions: 256)
        let second = try SpeakerEmbedding(recipe: changed, values: first.values)
        #expect(throws: SpeakerRecognitionError.incompatibleRecipe) { try first.cosineSimilarity(to: second) }
    }

    @Test func malformedPCMAndInconsistentRangeAreRejected() {
        let evidence = audio().evidence
        #expect(throws: SpeakerRecognitionError.self) {
            try SpeakerAudioSample(pcm16LE: audio().pcm16LE + Data([1]), evidence: evidence).validate()
        }
        #expect(throws: SpeakerRecognitionError.self) {
            try SpeakerAudioSample(pcm16LE: audio().pcm16LE, sampleRate: 8_000, evidence: evidence).validate()
        }
        #expect(throws: SpeakerRecognitionError.self) {
            try SpeakerAudioSample(pcm16LE: audio(count: 40_000).pcm16LE, evidence: evidence).validate()
        }
    }

    @Test func disablingDiscardsInFlightResultAndSkipsFutureCalls() async throws {
        let engine = SuspendedEngine()
        let provider = CactusSpeakerEmbeddingProvider(model: CactusSpeakerModel(
            directory: URL(fileURLWithPath: "/unused")), engine: engine)
        await provider.setEnabled(true)
        let task = Task { try await provider.embedding(for: audio()) }
        await engine.waitUntilStarted()
        await provider.setEnabled(false)
        await engine.finish()
        await #expect(throws: SpeakerRecognitionError.disabled) { try await task.value }
        await #expect(throws: SpeakerRecognitionError.disabled) { try await provider.embedding(for: audio()) }
        #expect(await engine.calls == 1)
        #expect(await engine.releases == 1)
    }

    @Test func cancellationDiscardsInFlightResult() async throws {
        let engine = SuspendedEngine()
        let provider = CactusSpeakerEmbeddingProvider(model: CactusSpeakerModel(
            directory: URL(fileURLWithPath: "/unused")), engine: engine)
        await provider.setEnabled(true)
        let task = Task { try await provider.embedding(for: audio()) }
        await engine.waitUntilStarted()
        task.cancel()
        await engine.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func reapplyingEnabledSettingDoesNotInvalidateWork() async throws {
        let engine = SuspendedEngine()
        let provider = CactusSpeakerEmbeddingProvider(model: CactusSpeakerModel(
            directory: URL(fileURLWithPath: "/unused")), engine: engine)
        await provider.setEnabled(true)
        let task = Task { try await provider.embedding(for: audio()) }
        await engine.waitUntilStarted()
        await provider.setEnabled(true)
        await engine.finish()
        #expect(try await task.value.embedding.values.count == 256)
    }

    @Test func nativeResponsesRejectFailureMissingValuesAndWrongDimension() {
        for json in ["{\"success\":false,\"error\":\"bad\"}",
                     "{\"success\":true}", "{\"success\":true,\"embedding\":[1,2]}"] {
            #expect(throws: (any Error).self) { try CactusSpeakerEngine.parseResponse(Data(json.utf8)) }
        }
    }

    @Test func vendoredRuntimeBytesMatchTheEmbeddingRecipe() throws {
        let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for (slice, expected) in [("ios-arm64", CactusSpeakerModel.deviceRuntimeSHA256),
                                  ("ios-arm64-simulator", CactusSpeakerModel.simulatorRuntimeSHA256)] {
            let file = kit.appendingPathComponent("Frameworks/CactusBinary.xcframework/\(slice)/libCactusBinary.a")
            let actual = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            #expect(actual == expected, "Runtime updates require a new embedding recipe and evaluation")
        }
    }
}

private actor SuspendedEngine: SpeakerEmbeddingEngine {
    var calls = 0
    var releases = 0
    private var started: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<NativeSpeakerEmbedding, Never>?

    func embed(sample: SpeakerAudioSample, model: CactusSpeakerModel,
               authorize: @escaping @Sendable () throws -> Void) async throws -> NativeSpeakerEmbedding {
        try authorize()
        calls += 1
        started?.resume()
        started = nil
        let result = await withCheckedContinuation { pending = $0 }
        try authorize()
        return result
    }
    func release() { releases += 1 }
    func waitUntilStarted() async {
        if calls == 0 { await withCheckedContinuation { started = $0 } }
    }
    func finish() {
        pending?.resume(returning: NativeSpeakerEmbedding(values: Array(repeating: 1, count: 256), inferenceMilliseconds: 1))
        pending = nil
    }
}
