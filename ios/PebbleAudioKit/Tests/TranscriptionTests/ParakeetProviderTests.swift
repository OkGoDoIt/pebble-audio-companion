import Foundation
import Testing

@testable import Transcription

// Hermetic provider tests: the native engine is a fake, so no model is downloaded and no
// recognizer runs. What is covered is the contract the pipeline depends on — availability,
// the error mapping (missing model ⇒ providerUnavailable, blank output ⇒ noSpeechDetected),
// provenance, and the PCM/no-speech helpers ported from the Kotlin provider.

// MARK: - Fakes

private struct FakeLocation: ParakeetModelLocating {
    var path: URL?
    func installedModelPath(for spec: ParakeetModelSpec) -> URL? { path }
}

private final class FakeEngine: ParakeetNativeEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var loadCalls: [String] = []
    private var wavCalls: [String] = []
    private var responseIndex = 0

    let supported: Bool
    let responses: [String]
    let loadFailure: ParakeetEngineError?
    let transcribeFailure: ParakeetEngineError?
    private(set) var interrupts = 0
    private(set) var releases = 0

    init(
        supported: Bool = true,
        responses: [String] = [#"{"response":"hello there"}"#],
        loadFailure: ParakeetEngineError? = nil,
        transcribeFailure: ParakeetEngineError? = nil
    ) {
        self.supported = supported
        self.responses = responses
        self.loadFailure = loadFailure
        self.transcribeFailure = transcribeFailure
    }

    var isSupported: Bool { supported }
    var loads: [String] { lock.withLock { loadCalls } }
    var transcribedWavs: [String] { lock.withLock { wavCalls } }

    func load(modelPath: String, identity: String) async throws {
        if let loadFailure { throw loadFailure }
        lock.withLock { loadCalls.append("\(modelPath)#\(identity)") }
    }

    func transcribe(wavPath: String) async throws -> String {
        if let transcribeFailure { throw transcribeFailure }
        return lock.withLock {
            wavCalls.append(wavPath)
            let response = responses[min(responseIndex, responses.count - 1)]
            responseIndex += 1
            return response
        }
    }

    func interrupt() { lock.withLock { interrupts += 1 } }
    func release() async { lock.withLock { releases += 1 } }
}

private struct StubProvider: TranscriptionProvider {
    let id: String
    func isAvailable() async -> Bool { true }
    func transcribe(pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int) async throws
        -> TranscriptionResult
    {
        TranscriptionResult(text: "stub", providerId: id, modelUsed: nil)
    }
}

// MARK: - Audio helpers

private let sampleRate = 16_000

/// A loud 440 Hz tone — comfortably over the RMS/peak voice gate.
private func tone(ms: Int) -> Data {
    var samples = [Int16]()
    let count = sampleRate * ms / 1_000
    samples.reserveCapacity(count)
    for index in 0..<count {
        let phase = Double(index) * 2 * Double.pi * 440 / Double(sampleRate)
        samples.append(Int16(8_000 * sin(phase)))
    }
    return samples.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func silence(ms: Int) -> Data {
    Data(count: sampleRate * 2 * ms / 1_000)
}

private func chunks(_ data: Data, size: Int = 3_200) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + size, data.endIndex)
            continuation.yield(data[offset..<end])
            offset = end
        }
        continuation.finish()
    }
}

private func makeTemp() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("parakeet-provider-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let defaultSpec = ParakeetModelCatalog.byId(ParakeetModelCatalog.defaultModelId)

private func makeProvider(
    installed: Bool = true, engine: FakeEngine, temp: URL
) -> ParakeetTranscriptionProvider {
    ParakeetTranscriptionProvider(
        spec: defaultSpec,
        location: FakeLocation(path: installed ? temp.appendingPathComponent("model") : nil),
        engine: engine,
        temporaryDirectory: temp
    )
}

// MARK: - Tests

@Suite struct ParakeetProviderTests {
    @Test func aMissingModelIsProviderUnavailableAndNeverLoadsAnything() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine()
        let provider = makeProvider(installed: false, engine: engine, temp: temp)

        #expect(await provider.isAvailable() == false)
        await #expect(throws: TranscriptionError.self) {
            try await provider.transcribe(pcmChunks: chunks(tone(ms: 500)), sampleRateHz: sampleRate)
        }
        do {
            _ = try await provider.transcribe(
                pcmChunks: chunks(tone(ms: 500)), sampleRateHz: sampleRate
            )
            Issue.record("expected providerUnavailable")
        } catch let error as TranscriptionError {
            guard case .providerUnavailable(let id) = error else {
                Issue.record("expected providerUnavailable, got \(error)")
                return
            }
            #expect(id == "cactus-local")
        }
        // Transcription must NEVER trigger a download or a model load.
        #expect(engine.loads.isEmpty)
    }

    @Test func withoutACactusBinaryTheProviderIsUnavailable() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let provider = makeProvider(engine: FakeEngine(supported: false), temp: temp)
        #expect(await provider.isAvailable() == false)
    }

    @Test func installedModelMakesTheProviderAvailable() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        #expect(await makeProvider(engine: FakeEngine(), temp: temp).isAvailable())
    }

    @Test func blankNativeOutputIsNoSpeech() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let provider = makeProvider(
            engine: FakeEngine(responses: [#"{"response":"   "}"#]), temp: temp
        )
        do {
            _ = try await provider.transcribe(
                pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate
            )
            Issue.record("expected noSpeechDetected")
        } catch let error as TranscriptionError {
            guard case .noSpeechDetected = error else {
                Issue.record("expected noSpeechDetected, got \(error)")
                return
            }
        }
    }

    @Test func bracketedNonSpeechMarkersAreNoSpeech() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let provider = makeProvider(
            engine: FakeEngine(responses: [#"{"response":"[BLANK_AUDIO]"}"#]), temp: temp
        )
        await #expect(throws: TranscriptionError.self) {
            try await provider.transcribe(pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
        }
    }

    @Test func digitalSilenceIsNoSpeechBeforeTheEngineIsTouched() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine()
        let provider = makeProvider(engine: engine, temp: temp)
        await #expect(throws: TranscriptionError.self) {
            try await provider.transcribe(
                pcmChunks: chunks(silence(ms: 2_000)), sampleRateHz: sampleRate
            )
        }
        #expect(engine.loads.isEmpty)
        #expect(engine.transcribedWavs.isEmpty)
    }

    @Test func audioShorterThanTheMinimumIsNoSpeech() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine()
        let provider = makeProvider(engine: engine, temp: temp)
        await #expect(throws: TranscriptionError.self) {
            try await provider.transcribe(pcmChunks: chunks(tone(ms: 50)), sampleRateHz: sampleRate)
        }
        #expect(engine.transcribedWavs.isEmpty)
    }

    @Test func aTranscriptCarriesProviderIdModelProvenanceAndSegmentOffsets() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine(
            responses: [
                #"{"response":"good morning","segments":[{"start":0.5,"end":1.2,"text":"good morning"}],"words":[{"start":0.5,"end":0.8,"word":"good"}]}"#
            ]
        )
        let provider = makeProvider(engine: engine, temp: temp)

        // 3 s of silence then 2 s of tone: the speech range must start well after zero, and the
        // native timings (relative to the range) must be shifted into segment time.
        let audio = silence(ms: 3_000) + tone(ms: 2_000)
        let result = try await provider.transcribe(
            pcmChunks: chunks(audio), sampleRateHz: sampleRate
        )

        #expect(result.text == "good morning")
        #expect(result.providerId == "cactus-local")
        #expect(result.modelUsed == "parakeet-tdt-0.6b-v3-int8:v1.10")
        #expect(engine.loads.count == 1)
        #expect(engine.loads.first?.hasSuffix("#parakeet-tdt-0.6b-v3-int8:v1.10") == true)
        let segment = try #require(result.segments.first)
        #expect(segment.text == "good morning")
        // 3 s of silence minus the 450 ms preroll, plus the native 0.5 s offset.
        #expect(segment.startMs > 2_500)
        #expect(result.words.first?.startMs == segment.startMs)
        // The staged WAV is cleaned up.
        #expect(FileManager.default.fileExists(atPath: engine.transcribedWavs[0]) == false)
    }

    @Test func aSqueezedMemoryBudgetIsProviderUnavailableNotAFailure() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let provider = makeProvider(
            engine: FakeEngine(
                loadFailure: .insufficientMemory(availableMb: 40, requiredMb: 150)
            ),
            temp: temp
        )
        do {
            _ = try await provider.transcribe(
                pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate
            )
            Issue.record("expected providerUnavailable")
        } catch let error as TranscriptionError {
            guard case .providerUnavailable = error else {
                Issue.record("expected providerUnavailable, got \(error)")
                return
            }
        }
    }

    @Test func aNativeErrorIsATranscriptionFailure() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let provider = makeProvider(
            engine: FakeEngine(transcribeFailure: .nativeFailure("tensor blew up")), temp: temp
        )
        do {
            _ = try await provider.transcribe(
                pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate
            )
            Issue.record("expected transcriptionFailed")
        } catch let error as TranscriptionError {
            guard case .transcriptionFailed(let message, _) = error else {
                Issue.record("expected transcriptionFailed, got \(error)")
                return
            }
            #expect(message.contains("tensor blew up"))
        }
    }

    @Test func longAudioIsSplitIntoBoundedNativeCalls() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine(responses: [#"{"response":"part one"}"#, #"{"response":"part two"}"#])
        let provider = makeProvider(engine: engine, temp: temp)
        // 70 s of continuous tone ⇒ two calls at the 45 s cap.
        let result = try await provider.transcribe(
            pcmChunks: chunks(tone(ms: 70_000)), sampleRateHz: sampleRate
        )
        #expect(engine.transcribedWavs.count == 2)
        #expect(result.text == "part one part two")
    }

    @Test func releasingTheModelForwardsToTheEngine() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine()
        let provider = makeProvider(engine: engine, temp: temp)
        await provider.releaseModel(reason: "backgrounded")
        #expect(engine.releases == 1)
        // Never used ⇒ the idle sweep has nothing to release.
        await provider.releaseModelIfIdle(nowMs: 10_000_000, idleTimeoutMs: 1_000)
        #expect(engine.releases == 1)
    }
}

@Suite struct ParakeetPcmTests {
    @Test func voiceGateSeparatesToneFromSilenceAndHiss() {
        #expect(ParakeetPcm.isVoiced(tone(ms: 100)))
        #expect(ParakeetPcm.isVoiced(silence(ms: 100)) == false)
        #expect(ParakeetPcm.isVoiced(Data()) == false)
    }

    @Test func rangesMergeAcrossShortGapsAndSplitAtTheChunkCap() {
        let bytesPerSecond = sampleRate * 2
        let merged = ParakeetPcm.merge(
            [
                PcmSpeechRange(startByte: 0, endByte: bytesPerSecond),
                // 1 s apart — under the 1.5 s merge gap.
                PcmSpeechRange(startByte: bytesPerSecond * 2, endByte: bytesPerSecond * 3),
                // 5 s later — a separate utterance.
                PcmSpeechRange(startByte: bytesPerSecond * 8, endByte: bytesPerSecond * 9),
            ],
            sampleRateHz: sampleRate
        )
        #expect(merged.count == 2)
        #expect(merged[0] == PcmSpeechRange(startByte: 0, endByte: bytesPerSecond * 3))

        let split = ParakeetPcm.splitLong(
            [PcmSpeechRange(startByte: 0, endByte: bytesPerSecond * 100)], sampleRateHz: sampleRate
        )
        #expect(split.count == 3)  // 45 s + 45 s + 10 s
        #expect(split.allSatisfy { $0.byteLength <= bytesPerSecond * 45 })
        #expect(split.last?.endByte == bytesPerSecond * 100)
    }

    @Test func rangeTimingsAreSampleAccurate() {
        let range = PcmSpeechRange(startByte: sampleRate * 2, endByte: sampleRate * 4)
        #expect(range.startMs(sampleRateHz: sampleRate) == 1_000)
        #expect(range.endMs(sampleRateHz: sampleRate) == 2_000)
    }

    @Test func noSpeechCoversMarkersStraysAndEmptyText() {
        #expect(ParakeetPcm.isNoSpeech(""))
        #expect(ParakeetPcm.isNoSpeech("."))
        #expect(ParakeetPcm.isNoSpeech("   "))
        #expect(ParakeetPcm.isNoSpeech("[BLANK_AUDIO]"))
        #expect(ParakeetPcm.isNoSpeech("(silence)"))
        #expect(ParakeetPcm.isNoSpeech("...!"))
        #expect(ParakeetPcm.isNoSpeech("ok") == false)
        #expect(ParakeetPcm.isNoSpeech("good morning") == false)
    }

    @Test func nativeResponsesParseTextSegmentsAndWords() {
        let parsed = ParakeetNativeResponse.parse(
            #"{"text":"hi","segments":[{"start":1.0,"end":2.5,"text":" hi ","speaker":"A"}],"words":[{"start":1.0,"end":1.2,"word":"hi"}]}"#
        )
        #expect(parsed.text == "hi")
        #expect(parsed.segments == [TranscriptSegment(text: "hi", startMs: 1_000, endMs: 2_500, speaker: "A")])
        #expect(parsed.words == [TranscriptWord(text: "hi", startMs: 1_000, endMs: 1_200)])
        // Not JSON at all ⇒ the raw string is the transcript (Kotlin parity).
        #expect(ParakeetNativeResponse.parse("plain text").text == "plain text")
        // JSON without a recognised text key ⇒ likewise.
        #expect(ParakeetNativeResponse.parse(#"{"other":1}"#).text == #"{"other":1}"#)
    }
}

@Suite struct SelectableLocalTranscriptionProviderTests {
    @Test func theSelectedIdPicksTheEngine() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let selection = SelectionBox(value: "en-US")
        let provider = SelectableLocalTranscriptionProvider(
            selected: { selection.value },
            location: FakeLocation(path: temp),
            engine: FakeEngine(),
            makeAppleSpeech: { StubProvider(id: "speechanalyzer-\($0.identifier)") }
        )

        #expect(provider.id == "speechanalyzer-en-US")
        #expect(provider.choice == .appleSpeech(locale: Locale(identifier: "en-US")))

        selection.value = "parakeet-ctc-1.1b-int8"
        #expect(provider.id == "cactus-local")
        #expect(provider.choice == .parakeet(ParakeetModelCatalog.byId("parakeet-ctc-1.1b-int8")))
        #expect(await provider.isAvailable())

        // Back to Apple Speech: the same cached instance, no new provider per lookup.
        selection.value = "en-US"
        #expect(provider.id == "speechanalyzer-en-US")
    }

    @Test func aFreshInstallDefaultsToAppleSpeech() async throws {
        let provider = SelectableLocalTranscriptionProvider(
            selected: { "" },
            location: FakeLocation(path: nil),
            engine: FakeEngine(),
            makeAppleSpeech: { StubProvider(id: "apple-\($0.identifier)") }
        )
        #expect(provider.choice == .appleSpeech(locale: .current))
        #expect(provider.id.hasPrefix("apple-"))
    }

    /// The migrated-user case: the setting names a Parakeet model that was never downloaded on
    /// this phone. It must transcribe with Apple Speech (a missing download is not a reason to
    /// leave audio untranscribed) AND report that it is doing so.
    @Test func aSelectedButUninstalledParakeetModelFallsBackToAppleSpeech() async throws {
        let provider = SelectableLocalTranscriptionProvider(
            selected: { "parakeet-tdt-0.6b-v3-int8" },
            location: FakeLocation(path: nil),
            engine: FakeEngine(),
            makeAppleSpeech: { StubProvider(id: "apple-\($0.identifier)") }
        )

        let spec = ParakeetModelCatalog.byId("parakeet-tdt-0.6b-v3-int8")
        // The user's CHOICE is untouched — only what runs today changes.
        #expect(provider.choice == .parakeet(spec))
        #expect(provider.resolution == .parakeetUnavailable(spec: spec, reason: .notInstalled))
        #expect(provider.resolution.selectedParakeet == spec)
        #expect(provider.id.hasPrefix("apple-"))
        #expect(await provider.isAvailable())
    }

    /// No Cactus slice in the build ⇒ no Parakeet model can ever run, and the reason is
    /// distinct from "not downloaded" because no download would fix it.
    @Test func anUnsupportedEngineAlsoFallsBackAndSaysWhy() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let provider = SelectableLocalTranscriptionProvider(
            selected: { "parakeet-ctc-1.1b-int8" },
            location: FakeLocation(path: temp),
            engine: FakeEngine(supported: false),
            makeAppleSpeech: { StubProvider(id: "apple-\($0.identifier)") }
        )

        #expect(
            provider.resolution
                == .parakeetUnavailable(
                    spec: ParakeetModelCatalog.byId("parakeet-ctc-1.1b-int8"),
                    reason: .notSupportedOnThisDevice
                )
        )
        #expect(provider.id.hasPrefix("apple-"))
    }

    /// The `apple-speech` sentinel must never be parsed as a language tag (a bug fixed once
    /// already: `Locale("apple-speech")` made SpeechTranscriber report an unsupported language).
    @Test func theAppleSpeechSentinelIsNotALocale() {
        #expect(
            LocalTranscriptionEngineChoice.resolve(
                modelId: LocalTranscriptionEngineChoice.appleSpeechId
            ) == .appleSpeech(locale: .current)
        )
        #expect(!LocalTranscriptionEngineChoice.isLanguageTag("apple-speech"))
        #expect(!LocalTranscriptionEngineChoice.isLanguageTag("parakeet-tdt-0.6b-v3-int8"))
        #expect(LocalTranscriptionEngineChoice.isLanguageTag("en-US"))
    }

    @Test func releasingForwardsToTheSharedCactusEngine() async {
        let engine = FakeEngine()
        let provider = SelectableLocalTranscriptionProvider(
            selected: { "parakeet-tdt-0.6b-v3-int8" },
            location: FakeLocation(path: nil),
            engine: engine,
            makeAppleSpeech: { StubProvider(id: "apple-\($0.identifier)") }
        )
        await provider.releaseModel(reason: "memory warning")
        #expect(engine.releases == 1)
    }
}

private final class SelectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String

    init(value: String) { stored = value }

    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
