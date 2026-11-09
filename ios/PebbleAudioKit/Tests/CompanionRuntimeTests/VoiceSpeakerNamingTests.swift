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
    static let danaID = UUID().uuidString.lowercased()

    private func speaker(_ id: Int64, _ crops: [(Int64, Int64)], person: String? = nil, suggested: String? = nil) -> VoiceNamingSpeaker {
        VoiceNamingSpeaker(id: id, crops: crops.map { VoiceSpeakerCrop(startMs: $0.0, endMs: $0.1, confidencePercent: 90) },
                           personId: person, suggestedPersonId: suggested, score: 0.7)
    }
    private func names(_ speakers: [VoiceNamingSpeaker], turns: [Range<Int64>]?, blocked: [Range<Int64>] = []) -> [VoiceAutomaticAttribution] {
        VoiceRecognitionService.names(VoiceNamingRecording(segmentId: "seg", speakers: speakers, blocked: blocked), turns: turns,
                                      sourceRevision: "r", recipeID: "test-recipe", runID: "run")
    }

    /// The bug behind "no voices are ever matched": a clip at a time named scattered fragments.
    /// A recognised speaker's name now covers whole turns, the ones too short to have a crop too.
    @Test func everyTurnOfARecognizedSpeakerCarriesTheName() {
        let out = names([speaker(1, [(0, 2_500), (2_500, 5_000), (5_000, 7_500)], person: Self.danaID),
                         speaker(2, [(20_000, 22_500), (22_500, 25_000), (25_000, 27_500)])],
                        turns: [0..<3_000, 3_000..<7_000, 7_500..<8_000, 21_000..<24_000, 24_000..<27_000])
        #expect(out.map(\.personId) == [Self.danaID])
        #expect(out.map { $0.startMediaMs..<$0.endMediaMs } == [0..<8_000], "Adjacent turns read as one name")
        #expect(out.first?.calibrationID == VoiceRecognitionService.clusterCalibrationID)
    }

    /// Who a voice might be is offered as a question and never read as a name.
    @Test func aPossibleMatchIsASuggestionNotAName() {
        let out = names([speaker(1, [(0, 2_500), (2_500, 5_000), (5_000, 7_500)], suggested: Self.danaID)], turns: [0..<7_000])
        #expect(out.map(\.disposition) == [.suggestion])
    }

    @Test func turnsAPersonDecidedAboutStayTheirsAndNothingIsNamedAcrossThem() {
        let out = names([speaker(1, [(0, 2_500), (2_500, 5_000), (5_000, 7_500)], person: Self.danaID)],
                        turns: [0..<2_000, 2_000..<4_000, 4_000..<7_000], blocked: [2_500..<3_000])
        #expect(out.map { $0.startMediaMs..<$0.endMediaMs } == [0..<2_000, 4_000..<7_000])
    }

    @Test func withNoTranscriptTheClipsThemselvesAreNamed() {
        let out = names([speaker(1, [(0, 2_500), (2_500, 5_000), (5_000, 7_500)], person: Self.danaID)], turns: nil)
        #expect(out.map { $0.startMediaMs..<$0.endMediaMs } == [0..<7_500])
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

/// The workflow itself: voices sort themselves, one answer names a voice everywhere, and what
/// arrives later follows. Recordings here are analysed prints, with no audio or models.
@Suite struct VoiceClusterWorkflowTests {
    static let recipe = SpeakerEmbeddingRecipe(modelID: "test", modelRevision: "1", weightsSHA256: "digest",
                                               runtimeID: "fake", preprocessingID: "16k", dimensions: 4)
    static let a: [Float] = [1, 0, 0, 0], b: [Float] = [0, 1, 0, 0], c: [Float] = [0, 0, 1, 0]
    /// Close enough to `a` to ask about, not close enough to assume.
    static let nearA: [Float] = [0.45, 0, 0, 0.893]

    struct Archive {
        let db: AppDatabase
        let identity: VoiceIdentityStore
        let service: VoiceRecognitionService
        let protector = VoiceProfileCipher(ephemeralKey: SymmetricKey(size: .bits256))
        var clock = 1_793_000_000_000

        init() async throws {
            db = try AppDatabase.inMemory()
            identity = VoiceIdentityStore(db: db)
            service = VoiceRecognitionService(database: db, files: SegmentFileReader(root: URL(fileURLWithPath: "/no-audio")),
                models: ScriptedModels(), analyzer: ScriptedAnalyzer(), policy: VoiceRecognitionService.initialPolicy,
                recipeID: "test-recipe", protector: protector)
            try await service.setEnabled(true)
        }

        /// A recording in which one voice was heard for four crops.
        mutating func record(_ voice: [Float]) async throws -> String {
            clock += 900_000
            let segment = "seg-\(clock)-test-1"
            _ = try await identity.prepareSource(segmentId: segment, revision: "r")
            try await identity.enqueueJob(runID: "recent:\(segment)", segmentId: segment, startMediaMs: 0, endMediaMs: 12_000, recipeID: "test-recipe")
            let job = try #require(try await identity.claimNextJob())
            let embedding = try SpeakerEmbedding(recipe: VoiceClusterWorkflowTests.recipe, values: voice)
            let saved = try VoicePrintCodec.save(embedding)
            let prints = try (0..<4).map { index in
                VoiceTurnPrint(startMediaMs: Int64(index) * 3_000, endMediaMs: Int64(index + 1) * 3_000, speechConfidence: 0.9,
                               runID: job.runID, recipeJSON: try JSONEncoder().encode(VoiceClusterWorkflowTests.recipe),
                               sealedEmbedding: try protector.seal(saved.bytes))
            }
            let corpus = try await identity.configuration().corpusRevision
            #expect(try await identity.advanceJob(id: job.id, expectedCursorMediaMs: 0, nextCursorMediaMs: 12_000, attributions: [],
                window: 0..<12_000, prints: prints, matchedCorpus: corpus, nameWhenDone: true))
            return segment
        }

        func settle() async throws {
            for _ in 0..<8 {
                _ = await service.renameFromPrints()
                if try await service.status().pendingRecordings == 0 { break }
            }
        }

        func names(_ segment: String) async throws -> [VoiceResolvedAttribution] {
            try await SpeakerCorrectionStore(db: db).snapshot(segmentIds: [segment]).automaticAttributions
        }
    }

    /// Before anyone has named anything, there's already something to ask about.
    @Test func voicesSortThemselvesBeforeAnyoneIsNamed() async throws {
        var archive = try await Archive()
        for _ in 0..<3 { _ = try await archive.record(Self.a) }
        for _ in 0..<2 { _ = try await archive.record(Self.b) }
        try await archive.settle()
        let groups = try await archive.service.unknownVoiceGroups()
        #expect(groups.map(\.recordingCount) == [3, 2], "Most heard first")
        #expect(groups.allSatisfy { $0.suggestedPersonId == nil })
    }

    /// A voice heard once isn't worth asking about yet.
    @Test func aVoiceHeardOnceIsNotAsked() async throws {
        var archive = try await Archive()
        _ = try await archive.record(Self.a)
        try await archive.settle()
        #expect(try await archive.service.unknownVoiceGroups().isEmpty)
    }

    /// The whole point: one answer names a voice everywhere, and later recordings need none.
    @Test func oneAnswerNamesAVoiceEverywhereAndWhatArrivesLaterFollows() async throws {
        var archive = try await Archive()
        let dana = try await PeopleStore(db: archive.db).createPerson(name: "Dana")
        var recordings: [String] = []
        for _ in 0..<3 { recordings.append(try await archive.record(Self.a)) }
        let other = try await archive.record(Self.b)
        _ = try await archive.record(Self.b)
        try await archive.settle()
        let group = try #require(try await archive.service.unknownVoiceGroups().first { $0.recordingCount == 3 })
        _ = try await archive.service.nameUnknownVoice(group, personId: dana.id)
        try await archive.settle()
        for recording in recordings {
            #expect(try await archive.names(recording).map(\.person.name) == ["Dana"])
        }
        #expect(try await archive.names(other).isEmpty)
        #expect(try await archive.service.unknownVoiceGroups().map(\.recordingCount) == [2], "One voice left to ask about")

        let later = try await archive.record(Self.a)
        try await archive.settle()
        #expect(try await archive.names(later).map(\.person.name) == ["Dana"], "Nobody was asked")
    }

    /// A close voice is a question for them to answer, and "no" is remembered.
    @Test func aNearbyVoiceIsAskedAboutAndNoIsRemembered() async throws {
        var archive = try await Archive()
        let dana = try await PeopleStore(db: archive.db).createPerson(name: "Dana")
        for _ in 0..<3 { _ = try await archive.record(Self.a) }
        try await archive.settle()
        let named = try #require(try await archive.service.unknownVoiceGroups().first)
        _ = try await archive.service.nameUnknownVoice(named, personId: dana.id)
        let near = try await archive.record(Self.nearA)
        _ = try await archive.record(Self.nearA)
        try await archive.settle()
        let asked = try #require(try await archive.service.unknownVoiceGroups().first)
        #expect(asked.suggestedPersonId == dana.id)
        #expect(try await archive.names(near).map(\.attribution.disposition) == [.suggestion], "Asked, not assumed")

        let coverage = try await archive.service.coverage()
        #expect(coverage.byPerson.first { $0.personId == dana.id }?.possibleMatches == 1)

        try await archive.service.rejectSuggestion(asked, personId: dana.id)
        try await archive.settle()
        #expect(try await archive.service.unknownVoiceGroups().first?.suggestedPersonId == nil)
        #expect(try await archive.names(near).isEmpty)
    }

    /// A person's own label on one paragraph is enough to name the voice it's in.
    @Test func aNameOnOneParagraphNamesTheVoiceItsIn() async throws {
        var archive = try await Archive()
        let oliver = try await PeopleStore(db: archive.db).createPerson(name: "Oliver")
        var recordings: [String] = []
        for _ in 0..<3 { recordings.append(try await archive.record(Self.c)) }
        try await archive.settle()
        // What naming a paragraph does: the name on that audio, and a sample of the voice.
        let labelled = recordings[0]
        let sealed = try archive.protector.seal(JSONEncoder().encode(
            try SpeakerEmbedding(recipe: VoiceClusterWorkflowTests.recipe, values: Self.c)))
        try await SpeakerCorrectionStore(db: archive.db).set(segmentId: labelled, startMediaMs: 0, endMediaMs: 3_000, personId: oliver.id)
        try await archive.db.writer.write { d in
            let recipe = try JSONEncoder().encode(VoiceClusterWorkflowTests.recipe)
            try d.execute(sql: """
                INSERT INTO voice_examples(id,personId,confirmationID,sessionID,segmentId,startMediaMs,endMediaMs,
                    sourceRevision,recipeID,recipeJSON,embeddingJSON,qualityJSON,createdAtMs)
                VALUES ('e','\(oliver.id)','c','s',?,0,3000,'r','test-recipe',?,?,?,1)
                """, arguments: [labelled, recipe, sealed, Data("{}".utf8)])
            try d.execute(sql: "UPDATE voice_print_sources SET matchedCorpus = -1")
        }
        try await archive.settle()
        for recording in recordings.dropFirst() {
            #expect(try await archive.names(recording).map(\.person.name) == ["Oliver"])
        }
        #expect(try await archive.service.unknownVoiceGroups().isEmpty)
    }

    /// "More than one person": the recordings they left out stay unnamed and aren't them.
    @Test func recordingsLeftOutOfAnAnswerAreNotThatPerson() async throws {
        var archive = try await Archive()
        let dana = try await PeopleStore(db: archive.db).createPerson(name: "Dana")
        var recordings: [String] = []
        for _ in 0..<4 { recordings.append(try await archive.record(Self.a)) }
        try await archive.settle()
        let group = try #require(try await archive.service.unknownVoiceGroups().first)
        _ = try await archive.service.nameUnknownVoice(group.limited(to: Set(recordings.prefix(2))), personId: dana.id)
        try await archive.settle()
        #expect(try await archive.names(recordings[0]).map(\.person.name) == ["Dana"])
        #expect(try await archive.names(recordings[3]).isEmpty)
    }

    /// Don't ask about this voice: gone, and it stays gone as more of it is heard.
    @Test func aVoiceYouStoppedAskingAboutStaysGone() async throws {
        var archive = try await Archive()
        for _ in 0..<3 { _ = try await archive.record(Self.b) }
        try await archive.settle()
        try await archive.service.dismissUnknownVoice(try #require(try await archive.service.unknownVoiceGroups().first))
        try await archive.settle()
        #expect(try await archive.service.unknownVoiceGroups().isEmpty)
        _ = try await archive.record(Self.b)
        _ = try await archive.record(Self.b)
        try await archive.settle()
        #expect(try await archive.service.unknownVoiceGroups().isEmpty)
    }

    /// One bad clip leaves that recording out without giving up on the voice.
    @Test func ignoringOneClipLeavesTheRestOfTheVoice() async throws {
        var archive = try await Archive()
        var recordings: [String] = []
        for _ in 0..<3 { recordings.append(try await archive.record(Self.b)) }
        try await archive.settle()
        try await archive.service.ignoreUnknownClip(segmentId: recordings[0], startMediaMs: 0, endMediaMs: 3_000)
        try await archive.settle()
        let group = try #require(try await archive.service.unknownVoiceGroups().first)
        #expect(group.recordingCount == 2)
        #expect(!group.crops.contains { $0.segmentId == recordings[0] })
    }

    @Test func forgettingAVoiceTakesItsNamesAway() async throws {
        var archive = try await Archive()
        let dana = try await PeopleStore(db: archive.db).createPerson(name: "Dana")
        var recordings: [String] = []
        for _ in 0..<3 { recordings.append(try await archive.record(Self.a)) }
        try await archive.settle()
        _ = try await archive.service.nameUnknownVoice(try #require(try await archive.service.unknownVoiceGroups().first), personId: dana.id)
        try await archive.settle()
        #expect(try await archive.names(recordings[0]).count == 1)
        try await archive.service.forgetProfile(personId: dana.id)
        try await archive.settle()
        #expect(try await archive.names(recordings[0]).isEmpty)
        #expect(try await archive.service.unknownVoiceGroups().first?.recordingCount == 3, "The voice is back to being asked about")
    }

    /// The question is gone the moment it's answered, before the sort that follows from it, and
    /// the answer comes back out cleanly while the offer to undo is up.
    @Test func anAnswerShowsAtOnceAndCanBeTakenBack() async throws {
        var archive = try await Archive()
        let dana = try await PeopleStore(db: archive.db).createPerson(name: "Dana")
        var recordings: [String] = []
        for _ in 0..<3 { recordings.append(try await archive.record(Self.a)) }
        try await archive.settle()
        let group = try #require(try await archive.service.unknownVoiceGroups().first)
        try await archive.service.confirmUnknownVoice(group, personId: dana.id)
        #expect(try await archive.service.unknownVoiceGroups().isEmpty, "No sort has run yet")
        try await archive.settle()
        #expect(try await archive.names(recordings[0]).map(\.person.name) == ["Dana"])

        try await archive.service.undoUnknownVoice(group, personId: dana.id)
        try await archive.settle()
        #expect(try await archive.names(recordings[0]).isEmpty)
        #expect(try await archive.service.unknownVoiceGroups().first?.recordingCount == 3, "Asked about again")
    }

    /// An answer goes to the speakers the person was looking at, however they've been sorted since.
    @Test func anAnswerFollowsItsSpeakersWhenASortRenumbersTheVoice() async throws {
        var archive = try await Archive()
        let dana = try await PeopleStore(db: archive.db).createPerson(name: "Dana")
        var recordings: [String] = []
        for _ in 0..<3 { recordings.append(try await archive.record(Self.a)) }
        let other = try await archive.record(Self.b)
        _ = try await archive.record(Self.b)
        try await archive.settle()
        let onScreen = try #require(try await archive.service.unknownVoiceGroups().first { $0.recordingCount == 3 })
        let oldest = try #require(onScreen.crops.min { $0.segmentId < $1.segmentId })
        try await archive.service.ignoreUnknownClip(segmentId: oldest.segmentId, startMediaMs: oldest.startMediaMs, endMediaMs: oldest.endMediaMs)
        try await archive.settle()
        #expect(try await archive.service.unknownVoiceGroups().first { $0.recordingCount == 2 && $0.clusterId != onScreen.clusterId } != nil)

        let kept = Set(recordings).subtracting([oldest.segmentId])
        try await archive.service.confirmUnknownVoice(onScreen.limited(to: kept), personId: dana.id)
        try await archive.settle()
        for recording in kept { #expect(try await archive.names(recording).map(\.person.name) == ["Dana"]) }
        #expect(try await archive.names(other).isEmpty, "The other voice keeps its own question")
    }

    /// "That wasn't them": the name comes off that conversation's speakers and stays off.
    @Test func sayingAConversationWasNotThemTakesTheNameOffAndKeepsItOff() async throws {
        var archive = try await Archive()
        let dana = try await PeopleStore(db: archive.db).createPerson(name: "Dana")
        var recordings: [String] = []
        for _ in 0..<3 { recordings.append(try await archive.record(Self.a)) }
        try await archive.settle()
        let group = try #require(try await archive.service.unknownVoiceGroups().first)
        try await archive.service.confirmUnknownVoice(group, personId: dana.id)
        try await archive.settle()
        let wrong = try #require(group.crops.first { $0.segmentId == recordings[0] })
        try await archive.service.notThisPerson(speakerIds: [try #require(Int64(wrong.id))], personId: dana.id)
        try await archive.settle()
        #expect(try await archive.names(recordings[0]).filter { $0.attribution.disposition == .recognized }.isEmpty)
        #expect(try await archive.names(recordings[1]).map(\.person.name) == ["Dana"], "The rest stand")
    }

    /// A run needs nobody named: sorting voices is how the first question comes about.
    @Test func aRunCanStartBeforeAnyoneHasBeenNamed() async throws {
        let archive = try await Archive()
        _ = try await archive.service.recognizeHistory(fromMs: 0, toMs: 1_000)
        #expect(try await archive.service.historyPlans().count == 1)
    }

    /// The person screen's counts: more audio found than was ever saved.
    @Test func coverageCountsWhatEachPersonWasNamedOn() async throws {
        var archive = try await Archive()
        let dana = try await PeopleStore(db: archive.db).createPerson(name: "Dana")
        for _ in 0..<3 { _ = try await archive.record(Self.a) }
        for _ in 0..<2 { _ = try await archive.record(Self.b) }
        try await archive.settle()
        let group = try #require(try await archive.service.unknownVoiceGroups().first { $0.recordingCount == 3 })
        _ = try await archive.service.nameUnknownVoice(group, personId: dana.id)
        try await archive.settle()
        let coverage = try await archive.service.coverage()
        #expect(coverage.speechMs == 5 * 12_000)
        #expect(coverage.namedMs == 3 * 12_000)
        #expect(coverage.byPerson.first?.personId == dana.id)
    }
}

extension VoiceClusterWorkflowTests {
    @Test func splitPreviewSaveRegroupAndUndoPreserveAllAudio() async throws {
        var archive = try await Archive()
        for _ in 0..<3 { _ = try await archive.record(Self.a) }
        try await archive.settle()
        let original = try #require(try await archive.service.unknownVoiceGroups().first)
        let preview = try await archive.service.splitPreview(speakerIDs: original.speakerIds)
        #expect(preview.atoms.count == 12)
        #expect(preview.groups.count == 3)
        let refined = try await preview.refined(group: 0, individual: true)
        #expect(refined.groups.count == 6)
        #expect(Set(refined.groups.flatMap { $0 }).count == 12)
        let undo = try await archive.service.saveSplit(refined)
        try await archive.settle()
        let split = try await archive.service.unknownVoiceGroups(limit: 100)
        #expect(split.count == 6, "Even a single crop stays reachable")
        #expect(split.reduce(0) { $0 + $1.speechMs } == original.speechMs)
        #expect(split.allSatisfy { $0.repaired })
        // Restarting the service's store client retains durable constraints.
        let inputs = try await VoiceSpeakerStore(db: archive.db).clusterInputs(minimumCrops: 3)
        #expect(inputs.count == 6)
        #expect(inputs.allSatisfy { !$0.separations.isEmpty && $0.requiresReview })
        try await archive.service.undoSplit(undo)
        try await archive.settle()
        let restored = try await archive.service.unknownVoiceGroups()
        #expect(restored.count == 1)
        #expect(restored.first?.speechMs == original.speechMs)
        #expect(try await VoiceSplitStore(db: archive.db).constraints().isEmpty)
    }

    @Test func anUnreadablePrintRemainsReviewableThroughSaveAndRegroup() async throws {
        var archive = try await Archive()
        for _ in 0..<2 { _ = try await archive.record(Self.a) }
        try await archive.settle()
        let original = try #require(try await archive.service.unknownVoiceGroups().first)
        // Simulate an original sample that is no longer available, while its saved crop remains.
        try await archive.db.writer.write { d in
            try d.execute(sql: "DELETE FROM voice_turn_prints WHERE id=(SELECT MIN(id) FROM voice_turn_prints)")
        }
        let preview = try await archive.service.splitPreview(speakerIDs: original.speakerIds)
        #expect(preview.atoms.count == 8)
        let all = try await preview.refined(group: 0, individual: true)
        _ = try await archive.service.saveSplit(all)
        try await archive.settle()
        let groups = try await archive.service.unknownVoiceGroups(limit: 100)
        #expect(groups.reduce(0) { $0 + $1.speechMs } == original.speechMs)
        #expect(groups.allSatisfy { $0.repaired })
        #expect(groups.count == all.groups.count)
    }

    @Test func savingAStaleSplitOrIncompletePartitionNeverLosesClips() async throws {
        var archive = try await Archive()
        for _ in 0..<2 { _ = try await archive.record(Self.a) }
        try await archive.settle()
        let original = try #require(try await archive.service.unknownVoiceGroups().first)
        var preview = try await archive.service.splitPreview(speakerIDs: original.speakerIds)
        let good = preview
        preview.groups[0].removeLast()
        await #expect(throws: VoiceSplitError.self) { try await archive.service.saveSplit(preview) }
        #expect(try await VoiceSplitStore(db: archive.db).constraints().isEmpty)
        let person = try await PeopleStore(db: archive.db).createPerson(name: "Dana")
        try await archive.service.confirmUnknownVoice(original, personId: person.id)
        await #expect(throws: VoiceSplitError.self) { try await archive.service.saveSplit(good) }
        #expect(try await VoiceSplitStore(db: archive.db).constraints().isEmpty)
    }

    @Test func undoDoesNotEraseANewerNameAndSelectionUsesSpeakerIDs() async throws {
        var archive = try await Archive()
        for _ in 0..<2 { _ = try await archive.record(Self.a) }
        try await archive.settle()
        let original = try #require(try await archive.service.unknownVoiceGroups().first)
        let preview = try await archive.service.splitPreview(speakerIDs: original.speakerIds)
        let refined = try await preview.refined(group: 0, individual: true)
        let undo = try await archive.service.saveSplit(refined)
        try await archive.settle()
        let group = try #require(try await archive.service.unknownVoiceGroups(limit: 100).first { $0.speechMs == 3_000 })
        let person = try await PeopleStore(db: archive.db).createPerson(name: "Dana")
        try await archive.service.confirmUnknownVoice(group, personId: person.id)
        try await archive.settle()
        await #expect(throws: VoiceSplitError.self) { try await archive.service.undoSplit(undo) }
        let names = try await archive.names(group.crops[0].segmentId)
        #expect(names.count == 1)
        #expect((names.first?.attribution.endMediaMs ?? 0) - (names.first?.attribution.startMediaMs ?? 0) <= 3_000)
        #expect(try await VoiceSplitStore(db: archive.db).constraints().isEmpty == false)
        let other = VoiceUnmatchedCrop(id: "999",segmentId: group.crops[0].segmentId,startMediaMs: 6_000,endMediaMs: 9_000,
            sourceRevision: "r",recipeID: "r",embeddingJSON: Data(),speechConfidence: 1)
        let mixed = VoiceRecognitionService.UnknownVoiceGroup(clusterId: 1,crops: [group.crops[0],other])
        #expect(mixed.selecting(clips: [group.crops[0].id]).crops.count == 1)
    }
}

extension VoiceSpeakerNamingTests {
    @Test func repairedClipDoesNotNameTheRestOfAMixedTranscriptParagraph() {
        var first = speaker(1, [(0,3_000)], person: "dana")
        first.repaired = true
        var second = speaker(2, [(3_000,6_000)])
        second.repaired = true
        let result = names([first,second], turns: [0..<12_000])
        #expect(result.count == 1)
        #expect(result.first?.startMediaMs == 0)
        #expect(result.first?.endMediaMs == 3_000)
    }
}
