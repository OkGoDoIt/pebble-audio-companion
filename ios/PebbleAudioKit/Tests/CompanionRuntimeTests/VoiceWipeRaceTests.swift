import AppDB
import CryptoKit
import Foundation
import Receiver
import SegmentStore
import SpeakerRecognition
import Testing
@testable import CompanionRuntime

private actor WipeGatedVoiceModels: VoiceModelManaging {
    let checked = OneShot<Bool>()
    let resume = OneShot<Bool>()
    func state() -> SpeakerModelInstallState { .installed }
    func isInstalled() async -> Bool {
        checked.complete(true)
        return await resume.value() ?? false
    }
    func install(progress: @escaping @Sendable (Double) -> Void) {}
    func cancel() {}
}

private actor WipeVoiceAnalyzer: SpeakerSpeechAnalyzing {
    var calls = 0
    func setEnabled(_ enabled: Bool) {}
    func release() {}
    func analyze(_ audio: SpeakerAnalysisAudio) throws -> SpeakerAnalysis {
        calls += 1
        let embedding = try SpeakerEmbedding(recipe: SpeakerEmbeddingRecipe(modelID: "test", modelRevision: "1",
            weightsSHA256: "digest", runtimeID: "fake", preprocessingID: "16k", dimensions: 2), values: [1, 0])
        return SpeakerAnalysis(turns: [SpeakerTurn(startSample: 0, endSample: 64_000,
            clusterID: "voice", embedding: embedding, overlap: false, speechConfidence: 0.95)],
            recipeID: "test-recipe", elapsedMilliseconds: 1)
    }
}

@Suite struct VoiceWipeRaceTests {
    @Test func wipeCancelsEnrollmentBeforeItCanCreateASourceAndCaptureTheNewGeneration() async throws {
        let fixture = try RuntimeFixture()
        let person = try await PeopleStore(db: fixture.database).ensureCurrentUser(displayName: "Roger")
        let models = WipeGatedVoiceModels(), analyzer = WipeVoiceAnalyzer()
        let voice = VoiceRecognitionService(database: fixture.database,
            files: SegmentFileReader(root: fixture.root), models: models, analyzer: analyzer,
            policy: VoiceRecognitionService.initialPolicy, recipeID: "test-recipe",
            protector: VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256)))
        var environment = await fixture.runtime.environment
        environment.voiceRecognition = voice
        let runtime = CompanionRuntime(environment: environment)
        let enrollment = Task {
            try await voice.enrollPCM(personId: person.id,
                pcm16LE: Data(repeating: 1, count: 128_000), sessionID: "confirmed-before-wipe")
        }
        // No voice_sources row or VoiceWorkToken exists yet. Invalidating only the database
        // generation cannot protect against this continuation capturing the new generation.
        _ = await models.checked.value()
        #expect(await runtime.deleteAllRecordings() == 0)
        await models.resume.complete(true)
        do { _ = try await enrollment.value; Issue.record("Pre-wipe enrollment recreated a profile") }
        catch is CancellationError {}
        #expect(await analyzer.calls == 0)
        #expect(try await VoiceIdentityStore(db: fixture.database).examples().isEmpty)
        #expect(try await PeopleStore(db: fixture.database).currentUserPersonId() == person.id)
    }
}
