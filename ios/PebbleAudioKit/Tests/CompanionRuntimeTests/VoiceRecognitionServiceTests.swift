import AppDB
import AudioCodec
import CryptoKit
import Foundation
import Receiver
import SegmentStore
import SpeakerRecognition
import Testing
import Transcription
@testable import CompanionRuntime

private actor VoiceTestModels: VoiceModelManaging {
    var installs = 0
    func state() -> SpeakerModelInstallState { .installed }
    func isInstalled() -> Bool { true }
    func install(progress: @escaping @Sendable (Double) -> Void) { installs += 1; progress(1) }
    func cancel() {}
}

private actor VoiceTestAnalyzer: SpeakerSpeechAnalyzing {
    let started = OneShot<Bool>()
    let resume = OneShot<Bool>()
    let shouldWait: Bool
    var calls = 0
    var variantCalls = 0
    let makeVariants: Bool
    init(wait: Bool = false, variants: Bool = false) { shouldWait = wait; makeVariants = variants }
    func confirmedEmbedding(for sample: SpeakerAudioSample) async throws -> SpeakerEmbedding? {
        guard makeVariants else { return nil }
        variantCalls += 1
        #expect(sample.pcm16LE.count == 64_000)
        #expect(sample.evidence.endSample - sample.evidence.startSample == 32_000)
        #expect(sample.evidence.singleSpeaker && sample.evidence.speechOnly && !sample.evidence.containsDiscontinuity)
        let raw = try VoiceRecognitionServiceTests.embedding()
        return try SpeakerEmbedding(recipe: raw.recipe, values: [0, 1])
    }
    func setEnabled(_ enabled: Bool) {}
    func release() {}
    func analyze(_ audio: SpeakerAnalysisAudio) async throws -> SpeakerAnalysis {
        calls += 1
        started.complete(true)
        if shouldWait { _ = await resume.value() }
        let embedding = try VoiceRecognitionServiceTests.embedding()
        return SpeakerAnalysis(turns: [
            SpeakerTurn(startSample: audio.sourceStartSample, endSample: audio.sourceStartSample + 32_000,
                clusterID: "voice", embedding: embedding, overlap: false, speechConfidence: 0.95),
            SpeakerTurn(startSample: audio.sourceStartSample + 32_000, endSample: audio.sourceStartSample + 64_000,
                clusterID: "voice", embedding: embedding, overlap: false, speechConfidence: 0.95),
        ], recipeID: "test-recipe", elapsedMilliseconds: 1)
    }
}

private struct UnavailableVoiceKey: VoiceProfileProtecting {
    let locked: Bool
    func hasKey() throws -> Bool {
        if locked { throw VoiceProfileProtectionError.deviceLocked }
        return false
    }
    func seal(_ plaintext: Data) throws -> Data { throw VoiceProfileProtectionError.keyMissing }
    func open(_ envelope: Data) throws -> Data { throw VoiceProfileProtectionError.keyMissing }
}

@Suite struct VoiceRecognitionServiceTests {
    static func embedding() throws -> SpeakerEmbedding {
        try SpeakerEmbedding(recipe: SpeakerEmbeddingRecipe(modelID: "test", modelRevision: "1",
            weightsSHA256: "digest", runtimeID: "fake", preprocessingID: "16k", dimensions: 2), values: [1, 0])
    }
    private func service(_ db: AppDatabase, analyzer: VoiceTestAnalyzer, models: VoiceTestModels) -> VoiceRecognitionService {
        VoiceRecognitionService(database: db, files: SegmentFileReader(root: URL(fileURLWithPath: "/no-audio")),
            models: models, analyzer: analyzer, policy: VoiceRecognitionService.initialPolicy, recipeID: "test-recipe",
            protector: VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256)))
    }

    @Test func explicitPhoneEnrollmentWhileOffIsAtomicAndDoesNotEnableOrDownload() async throws {
        let db = try AppDatabase.inMemory()
        let person = try await PeopleStore(db: db).createPerson(name: "Roger")
        let analyzer = VoiceTestAnalyzer(), models = VoiceTestModels()
        let service = service(db, analyzer: analyzer, models: models)
        let outcome = try await service.enrollPCM(personId: person.id,
            pcm16LE: Data(repeating: 1, count: 128_000), sessionID: "human-session")
        #expect(outcome.examplesAdded == 2)
        let store = VoiceIdentityStore(db: db)
        #expect(try await store.configuration().mode == .off)
        let examples = try await store.examples()
        #expect(examples.count == 2)
        #expect(Set(examples.map(\.confirmationID)).count == 1)
        #expect(Set(examples.map(\.sessionID)) == ["human-session"])
        #expect(examples.allSatisfy { $0.segmentId.hasPrefix("enrollment:") })
        #expect(await models.installs == 0)
        #expect(await service.processPending() == false)
        #expect(await analyzer.calls == 1)
    }

    @Test func encryptedCodecVariantImprovesCompatibilityWithoutInflatingIndependentSamples() async throws {
        let db = try AppDatabase.inMemory()
        let person = try await PeopleStore(db: db).createPerson(name: "Roger")
        let analyzer = VoiceTestAnalyzer(variants: true)
        let cipher = VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256))
        let service = VoiceRecognitionService(database: db,
            files: SegmentFileReader(root: URL(fileURLWithPath: "/no-audio")), models: VoiceTestModels(),
            analyzer: analyzer, policy: VoiceRecognitionService.initialPolicy,
            recipeID: "test-recipe", protector: cipher)
        let outcome = try await service.enrollPCM(personId: person.id,
            pcm16LE: Data(repeating: 1, count: 128_000), sessionID: "one-human-confirmation")
        let examples = try await service.examples()
        #expect(outcome.examplesAdded == 2 && examples.count == 2)
        #expect(await analyzer.variantCalls == 2)
        #expect(Set(examples.map(\.confirmationID)).count == 1)
        let store = VoiceIdentityStore(db: db)
        try await service.setEnabled(true)
        _ = try await store.prepareSource(segmentId: "query", revision: "query-digest")
        try await store.enqueueJob(runID: "query", segmentId: "query", startMediaMs: 0,
            endMediaMs: 2_000, recipeID: "test-recipe")
        let job = try #require(try await store.claimNextJob())
        let raw = try Self.embedding()
        let query = try SpeakerEmbedding(recipe: raw.recipe, values: [0, 1])
        let turn = SpeakerTurn(startSample: 0, endSample: 32_000, clusterID: "query", embedding: query,
            overlap: false, speechConfidence: 0.95)
        let analysis = SpeakerAnalysis(turns: [turn], recipeID: "test-recipe", elapsedMilliseconds: 0)
        let matches = try VoiceRecognitionService.match(analysis, job: job, examples: examples,
            policy: VoiceRecognitionService.initialPolicy, window: 0..<2_000, protector: cipher)
        #expect(matches.map(\.personId) == [person.id])
        #expect(matches.first?.score == 1)
        let oneCrop = try VoiceRecognitionService.match(analysis, job: job, examples: Array(examples.prefix(1)),
            policy: VoiceRecognitionService.initialPolicy, window: 0..<2_000, protector: cipher)
        #expect(oneCrop.isEmpty, "A codec variant never satisfies the second independent-crop requirement")
        let legacyExamples = try examples.map { source in
            var source = source
            source.embeddingJSON = try cipher.seal(JSONEncoder().encode(query))
            return source
        }
        let legacy = try VoiceRecognitionService.match(analysis, job: job, examples: legacyExamples,
            policy: VoiceRecognitionService.initialPolicy, window: 0..<2_000, protector: cipher)
        #expect(legacy.map(\.personId) == [person.id])

    }

    @Test func cancelDuringInferenceCannotSavePartialEnrollment() async throws {
        let db = try AppDatabase.inMemory()
        let person = try await PeopleStore(db: db).createPerson(name: "Roger")
        let analyzer = VoiceTestAnalyzer(wait: true)
        let service = service(db, analyzer: analyzer, models: VoiceTestModels())
        let task = Task { try await service.enrollPCM(personId: person.id,
            pcm16LE: Data(repeating: 1, count: 128_000), sessionID: "explicit-session") }
        _ = await analyzer.started.value()
        service.cancelEnrollment()
        analyzer.resume.complete(true)
        do { _ = try await task.value; Issue.record("Cancelled enrollment should not save") }
        catch is CancellationError {}
        #expect(try await VoiceIdentityStore(db: db).examples().isEmpty)
    }

    @Test func restoredMissingKeyClearsOnlyDerivedIdentityButLockedKeyPreservesIt() async throws {
        for locked in [false, true] {
            let db = try AppDatabase.inMemory()
            let person = try await PeopleStore(db: db).createPerson(name: "Roger")
            let store = VoiceIdentityStore(db: db)
            try await store.setMode(.local)
            _ = try await store.prepareSource(segmentId: "existing-audio", revision: "digest")
            let context = try #require(try await store.workContext(segmentId: "existing-audio"))
            #expect(try await store.commitExample(VoiceConfirmedExample(personId: person.id,
                confirmationID: "human", sessionID: "session", segmentId: "existing-audio",
                startMediaMs: 0, endMediaMs: 2_000, sourceRevision: "digest", recipeID: "recipe",
                recipeJSON: Data("{}".utf8), embeddingJSON: Data("{}".utf8), qualityJSON: Data("{}".utf8)),
                token: context.token))
            try await SpeakerCorrectionStore(db: db).set(segmentId: "existing-audio", startMediaMs: 0,
                endMediaMs: 2_000, personId: person.id, makeCurrentUser: true)
            let service = VoiceRecognitionService(database: db,
                files: SegmentFileReader(root: URL(fileURLWithPath: "/no-audio")), models: VoiceTestModels(),
                analyzer: VoiceTestAnalyzer(), policy: VoiceRecognitionService.initialPolicy,
                recipeID: "recipe", protector: UnavailableVoiceKey(locked: locked))
            if locked {
                await #expect(throws: VoiceProfileProtectionError.deviceLocked) { try await service.status() }
                #expect(try await store.configuration().mode == .local)
                #expect(try await store.examples().count == 1)
            } else {
                let status = try await service.status()
                #expect(status.configuration.mode == .off)
                #expect(status.lastMessage?.contains("Set up the voices again") == true)
                #expect(try await store.examples().isEmpty)
            }
            let manual = try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["existing-audio"])
            #expect(manual.currentUserPersonId == person.id)
            #expect(manual.corrections.first?.person?.id == person.id)
            #expect(try await store.workContext(segmentId: "existing-audio") != nil)
        }
    }

    @Test func enrollmentRejectsOverlapAndDifferentAcousticVoicesEvenWithOneHumanLabel() throws {
        let embedding = try Self.embedding()
        let audio = SpeakerAnalysisAudio(pcm16LE: Data(repeating: 0, count: 128_000),
            sourceID: "s", sourceRevision: "r", sessionID: "session", sourceStartSample: 0)
        for overlap in [true, false] {
            let analysis = SpeakerAnalysis(turns: [
                SpeakerTurn(startSample: 0, endSample: 32_000, clusterID: "a", embedding: embedding,
                    overlap: false, speechConfidence: 0.95),
                SpeakerTurn(startSample: 32_000, endSample: 64_000, clusterID: overlap ? "a" : "b",
                    embedding: embedding, overlap: overlap, speechConfidence: 0.95),
            ], recipeID: "recipe", elapsedMilliseconds: 1)
            #expect(throws: VoiceEnrollmentError.multipleSpeakers) {
                try VoiceRecognitionService.enrollmentTurns(analysis, audio: audio)
            }
        }
    }

    @Test func storedMediaWindowsNeverJoinTheTwoSidesOfAQuietOrLossGap() throws {
        var frames: [FrameRecord] = []
        for index in 0..<300 {
            let sequence = index < 150 ? index : index + 50
            frames.append(FrameRecord(sequence: UInt32(sequence),
                sampleIndex: UInt64(sequence * 320), payload: [1]))
        }
        let source = try VoiceAudioSource(meta: Fixture.meta(), frames: frames)
        #expect(source.endMediaMs == 6_000)
        #expect(source.nextRange(afterMediaMs: 0, throughMediaMs: 6_000) == 0..<3_000)
        #expect(source.nextRange(afterMediaMs: 3_000, throughMediaMs: 6_000) == 3_000..<6_000)
        #expect(source.nextRange(afterMediaMs: 2_000, throughMediaMs: 6_000) == 3_000..<6_000)
        #expect(throws: VoiceEnrollmentError.interruptedAudio) {
            try source.pcm(startMediaMs: 2_000, endMediaMs: 4_000)
        }
    }

    @Test func silencedDeletedFramesAreExcludedFromEnrollmentWindows() throws {
        let meta = Fixture.meta()
        let silence = try SpeexSilence.frame(sampleRateHz: Int(meta.sampleRateHz), bitRateBps: Int(meta.bitRateBps))
        let frames: [FrameRecord] = (0..<301).map { index in
            FrameRecord(sequence: UInt32(index), sampleIndex: UInt64(index * 320),
                        payload: index == 150 ? silence : [1])
        }
        let source = try VoiceAudioSource(meta: meta, frames: frames)
        #expect(source.nextRange(afterMediaMs: 0, throughMediaMs: 6_020) == 0..<3_000)
        #expect(source.nextRange(afterMediaMs: 3_000, throughMediaMs: 6_020) == 3_020..<6_020)
        #expect(throws: VoiceEnrollmentError.interruptedAudio) {
            try source.pcm(startMediaMs: 2_000, endMediaMs: 4_000)
        }
    }

    @Test func backgroundChargerPermissionDoesNotPermitSpeakerInference() async throws {
        let calls = CallRecorder()
        var steps = PipelineSteps()
        steps.isForeground = { false }
        steps.backgroundWorkDecision = { .run }
        steps.recognizeVoices = { calls.record("voice"); return true }
        _ = try await PipelinePass(steps: steps, clock: TestClock()).run()
        #expect(!calls.calls.contains("voice"))
    }
}
