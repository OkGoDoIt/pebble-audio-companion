import AppDB
import CryptoKit
import Foundation
import Receiver
import SegmentStore
import SpeakerRecognition
import Testing
import WireProtocol
@testable import CompanionRuntime

private actor ScriptedModels: VoiceModelManaging {
    func state() -> SpeakerModelInstallState { .installed }
    func isInstalled() -> Bool { true }
    func install(progress: @escaping @Sendable (Double) -> Void) { progress(1) }
    func cancel() {}
}

/// Hears Dana's voice everywhere, two crops per window, and counts what it is asked to do.
private actor ScriptedAnalyzer: SpeakerSpeechAnalyzing {
    var windows: [Range<Int>] = []
    var releases = 0
    func setEnabled(_ enabled: Bool) {}
    func release() { releases += 1 }
    func analyze(_ audio: SpeakerAnalysisAudio) async throws -> SpeakerAnalysis {
        windows.append(audio.sourceStartSample..<(audio.sourceStartSample + audio.pcm16LE.count / 2))
        let voice = try SpeakerEmbedding(recipe: VoiceSpeakerNamingTests.recipe, values: VoiceSpeakerNamingTests.dana)
        return SpeakerAnalysis(turns: [
            SpeakerTurn(startSample: audio.sourceStartSample, endSample: audio.sourceStartSample + 32_000,
                        clusterID: "voice", embedding: voice, overlap: false, speechConfidence: 0.95),
            SpeakerTurn(startSample: audio.sourceStartSample + 32_000, endSample: audio.sourceStartSample + 64_000,
                        clusterID: "voice", embedding: voice, overlap: false, speechConfidence: 0.95),
        ], recipeID: "test-recipe", elapsedMilliseconds: 1)
    }
}

@Suite struct VoiceSpeakerNamingTests {
    static let recipe = SpeakerEmbeddingRecipe(modelID: "test", modelRevision: "1", weightsSHA256: "digest",
                                               runtimeID: "fake", preprocessingID: "16k", dimensions: 3)
    static let dana: [Float] = [1, 0, 0]
    static let stranger: [Float] = [0, 1, 0]
    static let danaID = UUID()

    private func roster() throws -> SpeakerMatchRoster {
        try SpeakerMatchRoster(examples: try (0..<2).map { index in
            ConfirmedSpeakerExample(id: "e\(index)", personID: Self.danaID, confirmationID: "c\(index)", sessionID: "s",
                                    embedding: try SpeakerEmbedding(recipe: Self.recipe, values: Self.dana))
        }, policy: VoiceRecognitionService.initialPolicy)
    }
    private func print(_ start: Int64, _ end: Int64, _ voice: [Float], confidence: Double = 0.9) throws
        -> (record: VoiceTurnPrint, embedding: SpeakerEmbedding) {
        (VoiceTurnPrint(startMediaMs: start, endMediaMs: end, speechConfidence: confidence, runID: "run",
                        recipeJSON: Data("{}".utf8), sealedEmbedding: Data([1])),
         try SpeakerEmbedding(recipe: Self.recipe, values: voice))
    }
    private func names(_ prints: [(record: VoiceTurnPrint, embedding: SpeakerEmbedding)], turns: [Range<Int64>]?) throws
        -> (names: [VoiceAutomaticAttribution], unnamed: [(record: VoiceTurnPrint, voice: SpeakerEmbedding)]) {
        try VoiceRecognitionService.speakerNames(prints, turns: turns, roster: roster(), segmentId: "seg",
                                                 sourceRevision: "r", recipeID: "test-recipe")
    }

    /// The bug behind "no voices are ever matched": a clip at a time named scattered fragments.
    /// A recognised speaker's name now covers whole turns, the ones too short to have a crop too.
    @Test func everyTurnOfARecognizedSpeakerCarriesTheName() throws {
        let prints = try [print(0, 2_500, Self.dana), print(2_500, 5_000, Self.dana), print(5_000, 7_500, Self.dana),
                          print(20_000, 22_500, Self.stranger), print(22_500, 25_000, Self.stranger), print(25_000, 27_500, Self.stranger)]
        let turns: [Range<Int64>] = [0..<3_000, 3_000..<7_000, 7_500..<8_000, 21_000..<24_000, 24_000..<27_000]
        let out = try names(prints, turns: turns)
        #expect(out.names.map(\.personId) == [Self.danaID.uuidString.lowercased()])
        #expect(out.names.map { $0.startMediaMs..<$0.endMediaMs } == [0..<8_000], "Adjacent turns read as one name")
        #expect(out.names.first?.calibrationID == VoiceRecognitionService.speakerPolicy.calibrationID)
    }

    /// An unknown voice is offered with its pooled voice: that, not a noisy crop, is what can be
    /// recognised in another recording.
    @Test func anUnknownSpeakerIsOfferedByItsClearestClipsWithItsPooledVoice() throws {
        let prints = try [print(0, 2_500, Self.stranger, confidence: 0.8), print(2_500, 5_000, Self.stranger, confidence: 0.95),
                          print(5_000, 7_500, Self.stranger, confidence: 0.9), print(7_500, 10_000, Self.stranger, confidence: 0.7)]
        let out = try names(prints, turns: [0..<10_000])
        #expect(out.names.isEmpty)
        #expect(out.unnamed.map(\.record.startMediaMs).sorted() == [0, 2_500, 5_000], "The clearest three")
        #expect(out.unnamed.allSatisfy { $0.voice.values == Self.stranger })
    }

    @Test func aSpeakerHeardTooBrieflyStaysUnnamed() throws {
        let out = try names([try print(0, 2_500, Self.dana), try print(2_500, 5_000, Self.dana)], turns: [0..<5_000])
        #expect(out.names.isEmpty && out.unnamed.isEmpty)
    }

    @Test func withNoTranscriptTheClipsThemselvesAreNamed() throws {
        let prints = try [print(0, 2_500, Self.dana), print(2_500, 5_000, Self.dana), print(5_000, 7_500, Self.dana)]
        #expect(try names(prints, turns: nil).names.map { $0.startMediaMs..<$0.endMediaMs } == [0..<7_500])
    }

    // --- the service, end to end, on a real recording file ---

    /// Windows of Dana in a recording, the transcript saying where speech is.
    private func checked(turns: [Range<Int64>]?, transcription: String? = nil) async throws
        -> (root: URL, db: AppDatabase, analyzer: ScriptedAnalyzer, service: VoiceRecognitionService, store: SegmentStore, segment: String, before: Int) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-naming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (store, segment) = try await WatchVoiceSampleTests.openRecording(root)
        let db = try AppDatabase.inMemory()
        let person = try await PeopleStore(db: db).createPerson(name: "Dana")
        let analyzer = ScriptedAnalyzer()
        let service = VoiceRecognitionService(database: db, files: SegmentFileReader(root: root), models: ScriptedModels(),
            analyzer: analyzer, policy: VoiceRecognitionService.initialPolicy, recipeID: "test-recipe",
            protector: VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256)), transcriptTurns: { _ in turns })
        try await service.setEnabled(true)
        _ = try await service.enroll(personId: person.id, segmentId: segment, startMediaMs: 1_000, endMediaMs: 5_000)
        try await store.closeSegment(reason: .stopped(reasonRaw: Int(StopReason.shutdown.rawValue),
                                                      finalSequence: 609, finalSampleIndex: 760 * 320))
        if let transcription {
            try await db.writer.write { d in
                try d.execute(sql: "INSERT INTO transcription_tasks(segmentId,state,createdAtMs,updatedAtMs) VALUES (?,?,1,1)",
                              arguments: [segment, transcription])
            }
        }
        try await service.enqueueSegment(segmentId: segment)
        let before = await analyzer.windows.count
        return (root, db, analyzer, service, store, segment, before)
    }
    private func drain(_ service: VoiceRecognitionService, _ store: SegmentStore, maxWindows: Int = 2) async throws {
        for _ in 0..<40 where try await service.status().pendingRecordings > 0 {
            _ = await service.pass(segmentStore: store, maxWindows: maxWindows, mayAnalyze: { true })
        }
        #expect(try await service.status().pendingRecordings == 0)
    }

    @Test func onlySpeechReachesTheModelsAndTheWholeRecordingIsNamedWhenItIsDone() async throws {
        let turns: [Range<Int64>] = [1_000..<5_000, 9_000..<13_000]
        let run = try await checked(turns: turns)
        defer { try? FileManager.default.removeItem(at: run.root) }
        #expect(try await SpeakerCorrectionStore(db: run.db).snapshot(segmentIds: [run.segment]).automaticAttributions.isEmpty)
        try await drain(run.service, run.store)
        let windows = await run.analyzer.windows.dropFirst(run.before)
        // Just the two stretches of speech, each from just before it starts.
        #expect(windows.map { $0.lowerBound / 16 } == [500, 8_500])
        let names = try await SpeakerCorrectionStore(db: run.db).snapshot(segmentIds: [run.segment]).automaticAttributions
        #expect(names.map { $0.attribution.startMediaMs..<$0.attribution.endMediaMs } == turns)
        #expect(names.allSatisfy { $0.person.name == "Dana" })
    }

    @Test func aRecordingWithNoSpeechCostsNoModelTime() async throws {
        let run = try await checked(turns: nil, transcription: "NoSpeech")
        defer { try? FileManager.default.removeItem(at: run.root) }
        try await drain(run.service, run.store)
        #expect(await run.analyzer.windows.count == run.before)
        #expect(try await VoiceIdentityStore(db: run.db).runs().first?.done == 1)
    }

    /// Loading the models verifies 81 files, and opening a recording reads and hashes it.
    @Test func theModelsStayLoadedWhileThereIsWorkAndGoBackWhenIdle() async throws {
        let run = try await checked(turns: [1_000..<5_000, 9_000..<13_000])
        defer { try? FileManager.default.removeItem(at: run.root) }
        let before = await run.analyzer.releases
        _ = await run.service.pass(segmentStore: run.store, maxWindows: 1, mayAnalyze: { true })
        #expect(await run.analyzer.windows.count == run.before + 1)
        #expect(await run.analyzer.releases == before, "More to do: stays loaded")
        try await drain(run.service, run.store, maxWindows: 1)
        #expect(await run.analyzer.releases > before, "Nothing left: released")
    }

    /// A recording seen before queues from its sidecar, its audio left unread: counting 3,400
    /// recordings a read at a time took hours.
    @Test func aRunOverRecordingsSeenBeforeQueuesThemWithoutReadingTheirAudio() async throws {
        let run = try await checked(turns: [1_000..<5_000, 9_000..<13_000])
        defer { try? FileManager.default.removeItem(at: run.root) }
        try await drain(run.service, run.store)
        for file in try FileManager.default.subpathsOfDirectory(atPath: run.root.path) where file.hasSuffix(".spxlog") {
            try FileManager.default.removeItem(at: run.root.appendingPathComponent(file))
        }
        let history = try await run.service.recognizeHistory(fromMs: 0, toMs: Int64(Date().timeIntervalSince1970 * 1_000) + 86_400_000)
        _ = await run.service.pass(segmentStore: run.store, mayAnalyze: { true })
        let plan = try #require(try await run.service.historyPlans().first { $0.runID == history })
        #expect(plan.queuedCount == 1)
    }

    /// Everything is named again on the new rules, and a newer transcript means the same.
    @Test func aNewTranscriptMarksARecordingToBeNamedAgain() async throws {
        let run = try await checked(turns: [1_000..<5_000, 9_000..<13_000], transcription: "Complete")
        defer { try? FileManager.default.removeItem(at: run.root) }
        try await drain(run.service, run.store)
        #expect(try await run.service.status().pendingRecordings == 0)
        try await run.db.writer.write { d in
            try d.execute(sql: "UPDATE transcription_tasks SET state = 'Pending' WHERE segmentId = ?", arguments: [run.segment])
            try d.execute(sql: "UPDATE transcription_tasks SET state = 'Complete' WHERE segmentId = ?", arguments: [run.segment])
        }
        #expect(try await run.service.status().pendingRecordings == 1)
    }
}
