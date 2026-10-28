import AppDB
import AudioCodec
import CryptoKit
import Foundation
import Receiver
import SegmentStore
import SpeakerRecognition
import Testing
import Transcription
import WireProtocol
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

    @Test func oneConfirmedVoiceHeardAsTwoClustersIsKeptButAnotherVoiceIsLeftOut() throws {
        let raw = try Self.embedding()
        let me = try SpeakerEmbedding(recipe: raw.recipe, values: [1, 0])
        let meTurnedAway = try SpeakerEmbedding(recipe: raw.recipe, values: [0.8, 0.6])   // cosine 0.8
        let someoneElse = try SpeakerEmbedding(recipe: raw.recipe, values: [0, 1])       // cosine 0
        let audio = SpeakerAnalysisAudio(pcm16LE: Data(repeating: 0, count: 320_000),
            sourceID: "s", sourceRevision: "r", sessionID: "session", sourceStartSample: 0)
        func turn(_ start: Int, _ cluster: String, _ embedding: SpeakerEmbedding, overlap: Bool = false) -> SpeakerTurn {
            SpeakerTurn(startSample: start * 16_000, endSample: (start + 2) * 16_000, clusterID: cluster,
                        embedding: embedding, overlap: overlap, speechConfidence: 0.95)
        }
        let analysis = SpeakerAnalysis(turns: [
            turn(0, "a", me), turn(2, "a", me), turn(4, "b", meTurnedAway),
            turn(6, "c", someoneElse), turn(8, "a", me, overlap: true),
        ], recipeID: "recipe", elapsedMilliseconds: 1)
        let kept = try VoiceRecognitionService.enrollmentTurns(analysis, audio: audio, sameVoiceSimilarity: 0.55)
        #expect(kept.turns.map { $0.startSample / 16_000 } == [0, 2, 4])
        #expect(kept.otherVoiceSamples == 32_000, "Two seconds sounded like someone else")

        let onlyOverlap = SpeakerAnalysis(turns: [turn(0, "a", me, overlap: true)], recipeID: "recipe", elapsedMilliseconds: 1)
        #expect(throws: VoiceEnrollmentError.notEnoughSpeech) {
            try VoiceRecognitionService.enrollmentTurns(onlyOverlap, audio: audio, sameVoiceSimilarity: 0.55)
        }
    }

    @Test func aPassageKeepsItsLeastAlikeCropsAndAFullProfileRetiresTheMostRedundant() throws {
        let raw = try Self.embedding()
        func vector(_ degrees: Double) throws -> SpeakerEmbedding {
            try SpeakerEmbedding(recipe: raw.recipe, values: [Float(cos(degrees * .pi / 180)), Float(sin(degrees * .pi / 180))])
        }
        func turn(_ start: Int, _ degrees: Double, confidence: Double = 0.9) throws -> SpeakerTurn {
            SpeakerTurn(startSample: start * 32_000, endSample: (start + 1) * 32_000, clusterID: "a",
                        embedding: try vector(degrees), overlap: false, speechConfidence: confidence)
        }
        // Five crops: three nearly identical (0°, 1°, 2°), two different (40°, 80°).
        let turns = [try turn(0, 0, confidence: 0.99), try turn(1, 1), try turn(2, 2), try turn(3, 40), try turn(4, 80)]
        let kept = VoiceRecognitionService.diverse(turns, limit: 3)
        #expect(kept.map { $0.startSample / 32_000 } == [0, 3, 4], "One of the near-duplicates, and both different ones")

        // A full profile of 4: a near-duplicate pair from one sample, a sole crop, a guided sample.
        let prior = [
            (id: "dup-a", confirmationID: "talk", guided: false, embedding: try vector(10)),
            (id: "dup-b", confirmationID: "talk", guided: false, embedding: try vector(11)),
            (id: "sole", confirmationID: "other", guided: false, embedding: try vector(12)),
            (id: "setup", confirmationID: "setup", guided: true, embedding: try vector(13)),
        ]
        let retired = VoiceRecognitionService.retirements(prior: prior, incoming: [try vector(90)], capacity: 4)
        #expect(retired.count == 1)
        #expect(retired.first == "dup-a" || retired.first == "dup-b",
                "A sample's last crop and a guided sample are spared while a duplicate remains")
        #expect(VoiceRecognitionService.retirements(prior: prior, incoming: [], capacity: 4).isEmpty)
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
        // "Play Longer" widens a clip only within its own side of the gap, so it always plays.
        #expect(source.contextRange(startMediaMs: 3_500, endMediaMs: 4_000, paddingMs: 6_000) == 3_000..<6_000)
        #expect(source.contextRange(startMediaMs: 1_000, endMediaMs: 2_000, paddingMs: 500) == 500..<2_500)
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

    /// Backgrounded on a charger the voice step is asked (it applies its own rule and pace),
    /// and the pass comes back when the pace allows the next slice: not the 1 s cadence, and
    /// not the 30 s idle wait that held recognition to 20 s of audio per 30 s on G17.
    @Test func aBackgroundedVoiceSliceSetsTheNextWake() async throws {
        let calls = CallRecorder()
        var steps = PipelineSteps()
        steps.isForeground = { false }
        steps.backgroundWorkDecision = { .run }
        steps.regroup = { false }
        steps.recognizeVoices = { calls.record("voice"); return true }
        steps.voiceSliceDueInMs = { 3_000 }
        let sleep = try await PipelinePass(steps: steps, clock: TestClock()).run()
        #expect(calls.calls == ["voice"])
        #expect(sleep == 3_000)
    }

    /// The conversations just had are checked before a history run's backlog.
    @Test func newRecordingsAreCheckedBeforeAHistoryRun() async throws {
        let db = try AppDatabase.inMemory()
        let store = VoiceIdentityStore(db: db)
        try await store.setMode(.local)
        for id in ["old", "new"] { _ = try await store.prepareSource(segmentId: id, revision: id) }
        try await store.enqueueJob(runID: "history-run", segmentId: "old", startMediaMs: 0,
            endMediaMs: 2_000, recipeID: "test-recipe", nowMs: 1)
        try await store.enqueueJob(runID: "recent:new:1:1:new", segmentId: "new", startMediaMs: 0,
            endMediaMs: 2_000, recipeID: "test-recipe", nowMs: 2)
        #expect(try await store.claimNextJob()?.segmentId == "new")
        #expect(try await store.claimNextJob()?.segmentId == "old")
    }
}

/// Voice samples recorded through the watch: read from the recording the audio lands in, which
/// is usually still open, and kept as their own source so the recording growing or closing
/// never removes them.
@Suite struct WatchVoiceSampleTests {
    static let t0: Int64 = 1_792_000_000_000

    /// Runs on the watch's sample clock: 0–6 s, then 8–14 s after a skipped quiet stretch, then
    /// a 0.2 s fragment at 15 s. The recording is left open, as during a live sample.
    /// `arrivalLagMs` is how far behind the phone the watch's sample clock ran as this arrived.
    static func openRecording(_ root: URL, arrivalLagMs: Int64 = 0) async throws -> (SegmentStore, String) {
        let store = SegmentStore(root: root, nowMs: { t0 + (arrivalLagMs == 0 ? 20_000 : 15_200 + arrivalLagMs) })
        _ = try await store.openSegment(start: Fixture.streamStart(startTimeMs: UInt64(t0)),
                                        receivedAtMs: t0 + arrivalLagMs, provenance: nil)
        // Real encoded tone, not the codec's silence packet: that packet marks deleted audio.
        let encoder = try SpeexFrameEncoder()
        let speech = [UInt8](try encoder.encodeFrame((0..<320).map { i -> Int16 in
            Int16(6_000 * sin(2 * .pi * 220 * Double(i) / 16_000))
        }))
        func run(_ sequence: Range<Int>, at firstFrame: Int) -> [SegmentFrame] {
            sequence.enumerated().map { offset, sequence in
                SegmentFrame(sequence: UInt32(sequence), sampleIndex: UInt64(firstFrame + offset) * 320, payload: speech)
            }
        }
        _ = try await store.appendFrames(streamId: 0x5EED_0001,
            frames: run(0..<300, at: 0) + run(300..<600, at: 400) + run(600..<610, at: 750))
        return (store, try #require(await store.openSegmentId))
    }

    private func service(_ db: AppDatabase, root: URL, analyzer: VoiceTestAnalyzer) -> VoiceRecognitionService {
        VoiceRecognitionService(database: db, files: SegmentFileReader(root: root), models: VoiceTestModels(),
            analyzer: analyzer, policy: VoiceRecognitionService.initialPolicy, recipeID: "test-recipe",
            protector: VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256)))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-sample-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func readsOnlyTheWindowJoiningRunsAcrossSkippedQuietAndDroppingFragments() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await Self.openRecording(root)
        let reader = WatchVoiceSampleReader(files: SegmentFileReader(root: root))
        let audio = try #require(try reader.audio(fromWallMs: Self.t0 + 1_000, toWallMs: Self.t0 + 15_500))
        // 5 s of the first run (from 1 s), all 6 s of the second; the 0.2 s fragment is left out.
        let expectedBytes: Int = 550 * 640
        #expect(audio.pcm16LE.count == expectedBytes)
        let reach: Int64 = Self.t0 + 15_200
        #expect(audio.receivedThroughWallMs == reach)
        let skipped = try #require(try reader.audio(fromWallMs: Self.t0 + 6_100, toWallMs: Self.t0 + 7_900))
        #expect(skipped.pcm16LE.isEmpty, "Nothing was said in the skipped stretch, but audio has arrived past it")
    }

    /// G17 on 2026-10-26: the watch's sample clock was 15 minutes behind the phone (it stops
    /// while the mic is off), so a window taken straight from the phone's clock found nothing.
    @Test func aPhoneClockWindowFindsTheAudioWhenTheWatchClockIsFifteenMinutesBehind() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lag: Int64 = 900_000
        let (_, segmentId) = try await Self.openRecording(root, arrivalLagMs: lag)
        let head = Self.t0 + 15_200
        let sidecar = root.appendingPathComponent("segments/\(segmentId)\(SegmentStore.metaSuffix)").path
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(head + lag) / 1_000)], ofItemAtPath: sidecar)
        let service = service(try AppDatabase.inMemory(), root: root, analyzer: VoiceTestAnalyzer())
        let phoneStart: Int64 = Self.t0 + 1_000 + lag
        let phoneEnd: Int64 = Self.t0 + 14_000 + lag
        let audio = try #require(await service.watchSampleAudio(phoneStartMs: phoneStart, phoneEndMs: phoneEnd,
                                                                now: head + lag + 1_000))
        let expectedBytes: Int = 550 * 640
        #expect(audio.pcm16LE.count == expectedBytes, "1–14 s plus the delivery pad, on the watch's clock")
        let received: Int64 = head + lag
        #expect(audio.receivedThroughWallMs == received)
        // On the recording's clock, which its arrival already put within delivery of this one.
        let watchFrom: Int64 = phoneStart - SegmentMeta.deliveryMs
        #expect(audio.watchFromMs == watchFrom)
        #expect(await service.watchSampleAudio(phoneStartMs: phoneStart, phoneEndMs: phoneEnd,
                                               now: head + lag + 3_600_000) == nil, "No recent watch audio")
    }

    @Test func watchSampleIsItsOwnSourceAndSkipsThePhoneCodecVariant() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await Self.openRecording(root)
        let db = try AppDatabase.inMemory()
        let person = try await PeopleStore(db: db).createPerson(name: "Roger")
        let analyzer = VoiceTestAnalyzer(variants: true)
        let service = service(db, root: root, analyzer: analyzer)
        let outcome = try await service.enrollWatch(personId: person.id, fromWallMs: Self.t0,
                                                    toWallMs: Self.t0 + 6_000, sessionID: "watch-sample")
        #expect(outcome.examplesAdded == 2 && outcome.confirmationID != nil)
        let examples = try await service.examples()
        let sources: Set<String> = Set(examples.map { String($0.segmentId.prefix(17)) })
        #expect(sources == ["watch-enrollment:"])
        #expect(Set(examples.map(\.sessionID)) == ["watch-sample"])
        let microphones: [VoiceSampleMicrophone] = examples.map { VoiceSampleMicrophone.of(segmentId: $0.segmentId) }
        #expect(microphones == [.watch, .watch])
        #expect(await analyzer.variantCalls == 0, "Watch audio already has the watch's codec")
        await #expect(throws: VoiceEnrollmentError.notEnoughSpeech) {
            try await service.enrollWatch(personId: person.id, fromWallMs: Self.t0 + 6_100,
                                          toWallMs: Self.t0 + 7_900, sessionID: "quiet")
        }
    }

    @Test func rememberingAPassageOfAnOpenRecordingSurvivesTheRecordingClosing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, segmentId) = try await Self.openRecording(root)
        let db = try AppDatabase.inMemory()
        let person = try await PeopleStore(db: db).createPerson(name: "Dana")
        let service = service(db, root: root, analyzer: VoiceTestAnalyzer())
        try await service.setEnabled(true)
        _ = try await service.enroll(personId: person.id, segmentId: segmentId, startMediaMs: 1_000, endMediaMs: 5_000)
        #expect(try await service.examples().count == 2)
        try await store.closeSegment(reason: .stopped(reasonRaw: Int(StopReason.shutdown.rawValue),
                                                      finalSequence: 609, finalSampleIndex: 760 * 320))
        // Recognition reads the closed recording under a new revision, which erases artifacts
        // tied to the old one. The remembered voice must not be one of them.
        _ = try await VoiceIdentityStore(db: db).prepareSource(segmentId: segmentId, revision: "closed")
        let examples = try await service.examples()
        #expect(examples.count == 2)
        let sources: Set<String> = Set(examples.map { String($0.segmentId.prefix(17)) })
        #expect(sources == ["watch-enrollment:"])
        #expect(Set(examples.map(\.sessionID)) == [segmentId])
    }

    /// On battery a new recording is queued but its audio is not analyzed; on a charger it is.
    @Test func aRecordingWaitsForAChargerAndIsCheckedOnOne() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, segmentId) = try await Self.openRecording(root)
        let db = try AppDatabase.inMemory()
        let person = try await PeopleStore(db: db).createPerson(name: "Dana")
        let analyzer = VoiceTestAnalyzer()
        let service = service(db, root: root, analyzer: analyzer)
        try await service.setEnabled(true)
        _ = try await service.enroll(personId: person.id, segmentId: segmentId, startMediaMs: 1_000, endMediaMs: 5_000)
        try await store.closeSegment(reason: .stopped(reasonRaw: Int(StopReason.shutdown.rawValue),
                                                      finalSequence: 609, finalSampleIndex: 760 * 320))
        try await service.enqueueSegment(segmentId: segmentId)
        let afterEnrolling = await analyzer.calls

        let onBattery = await service.pass(segmentStore: store, mayAnalyze: { false })
        #expect(onBattery.windows == 0)
        #expect(await analyzer.calls == afterEnrolling)
        #expect(try await service.status().pendingRecordings == 1)

        let charging = await service.pass(segmentStore: store, mayAnalyze: { true })
        #expect(charging.windows > 0 && charging.didWork)
        #expect(await analyzer.calls > afterEnrolling)
    }

    @Test func aSampleSituationGoesWithItsLastCrop() async throws {
        let db = try AppDatabase.inMemory()
        let person = try await PeopleStore(db: db).createPerson(name: "Roger")
        let service = VoiceRecognitionService(database: db, files: SegmentFileReader(root: URL(fileURLWithPath: "/no-audio")),
            models: VoiceTestModels(), analyzer: VoiceTestAnalyzer(), policy: VoiceRecognitionService.initialPolicy,
            recipeID: "test-recipe", protector: VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256)))
        let outcome = try await service.enrollPCM(personId: person.id, pcm16LE: Data(repeating: 1, count: 128_000),
                                                  sessionID: "phone")
        let situations = VoiceSampleSituationStore(db: db)
        try await situations.set("quiet", confirmationID: try #require(outcome.confirmationID))
        let ids = try await service.examples().map(\.id)
        try await service.removeExamples(ids: [ids[0]])
        #expect(try await situations.all().count == 1, "One crop remains, so the sample still exists")
        try await service.removeExamples(ids: [ids[1]])
        #expect(try await situations.all().isEmpty)
    }
}

@Suite struct UnknownVoiceNamingTests {
    @Test func dismissingTheWholeGroupDoesNotTeachOrAllowAStaleAnswerToNameItsClips() async throws {
        let db = try AppDatabase.inMemory()
        let identity = VoiceIdentityStore(db: db)
        let person = try await PeopleStore(db: db).createPerson(name: "Dana")
        let service = VoiceRecognitionService(database: db, files: SegmentFileReader(root: URL(fileURLWithPath: "/no-audio")),
            models: VoiceTestModels(), analyzer: VoiceTestAnalyzer(), policy: VoiceRecognitionService.initialPolicy,
            recipeID: "test-recipe", protector: VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256)))
        var crops: [VoiceUnmatchedCrop] = []
        for segment in ["a", "b", "c", "d"] {
            _ = try await identity.prepareSource(segmentId: segment, revision: "r")
            crops.append(VoiceUnmatchedCrop(segmentId: segment, startMediaMs: 0, endMediaMs: 3_000,
                sourceRevision: "r", recipeID: "test-recipe", embeddingJSON: Data(), speechConfidence: 0.9))
        }
        let group = VoiceRecognitionService.UnknownVoiceGroup(crops: crops)
        try await service.dismissUnknownVoice(group)
        #expect(try await VoiceUnmatchedStore(db: db).excludingIgnored(crops).isEmpty,
                "All four clips are dismissed, including the one beyond the three previews")
        #expect(try await service.nameUnknownVoice(group, personId: person.id) == 0)
        #expect(try await identity.examples().isEmpty)
        #expect(try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["a", "b", "c", "d"]).corrections.isEmpty)
    }

    @Test func namingAVoiceNamesTheWiderRangeAndForgetsTheGroup() async throws {
        let db = try AppDatabase.inMemory()
        let person = try await PeopleStore(db: db).createPerson(name: "Dana")
        let service = VoiceRecognitionService(database: db, files: SegmentFileReader(root: URL(fileURLWithPath: "/no-audio")),
            models: VoiceTestModels(), analyzer: VoiceTestAnalyzer(), policy: VoiceRecognitionService.initialPolicy,
            recipeID: "test-recipe", protector: VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256)))
        func crop(_ segment: String, _ start: Int64) -> VoiceUnmatchedCrop {
            VoiceUnmatchedCrop(segmentId: segment, startMediaMs: start, endMediaMs: start + 3_000, sourceRevision: "r",
                               recipeID: "test-recipe", embeddingJSON: Data(), speechConfidence: 0.9)
        }
        let group = VoiceRecognitionService.UnknownVoiceGroup(crops: [crop("a", 10_000), crop("b", 2_000)])
        _ = try await service.nameUnknownVoice(group, personId: person.id) { crop in
            crop.segmentId == "a" ? 5_000..<20_000 : nil
        }
        let names = try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: ["a", "b"]).corrections
            .map { "\($0.segmentId):\($0.startMediaMs)-\($0.endMediaMs):\($0.person?.name ?? "-")" }.sorted()
        #expect(names == ["a:5000-20000:Dana", "b:2000-5000:Dana"], "The paragraph where there is one, else the clip")
    }
}
