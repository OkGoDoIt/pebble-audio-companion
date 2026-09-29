import AudioCodec
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
    /// Whether the one-time prepare pass has run (only asked for `requiresPreparation` specs).
    var prepared = true
    func installedModelPath(for spec: ParakeetModelSpec) -> URL? { path }
    func isPrepared(_ spec: ParakeetModelSpec) -> Bool { prepared }
}

/// A location whose `.prepared` flag the provider can withdraw and restore, as the real one can.
private final class MutableLocation: ParakeetModelLocating, @unchecked Sendable {
    let path: URL?
    private let lock = NSLock()
    private var flag: Bool

    init(path: URL?, prepared: Bool) {
        self.path = path
        self.flag = prepared
    }

    var prepared: Bool { lock.withLock { flag } }
    func installedModelPath(for spec: ParakeetModelSpec) -> URL? { path }
    func isPrepared(_ spec: ParakeetModelSpec) -> Bool { lock.withLock { flag } }
    func setPrepared(_ spec: ParakeetModelSpec, _ prepared: Bool) { lock.withLock { flag = prepared } }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64 = 1_000_000
    var now: Int64 { lock.withLock { ms } }
    func advance(_ by: Int64) { lock.withLock { ms += by } }
}

private final class FakeEngine: ParakeetNativeEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var loadCalls: [String] = []
    private var wavCalls: [String] = []
    private var wavPeaks: [Int] = []
    private var responseIndex = 0

    let supported: Bool
    let responses: [String]
    let loadFailure: ParakeetEngineError?
    /// How many loads fail with `loadFailure` before loads start succeeding (all, by default).
    let failingLoads: Int
    let transcribeFailure: ParakeetEngineError?
    /// What `discardCompiledCache` answers.
    let discardOutcome: ParakeetCacheDiscard
    /// When set, `transcribe` waits for `openGate()` and ignores cancellation — a call that
    /// never comes back on its own.
    let hangs: Bool
    private(set) var interrupts = 0
    private(set) var releases = 0
    private var attempts = 0
    private var discardCalls = 0
    private var successfulLoads = 0
    private var begins = 0
    private var ends = 0
    private var softReleases = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var gateOpen = false

    init(
        supported: Bool = true,
        responses: [String] = [#"{"response":"hello there"}"#],
        loadFailure: ParakeetEngineError? = nil,
        failingLoads: Int = .max,
        transcribeFailure: ParakeetEngineError? = nil,
        discardOutcome: ParakeetCacheDiscard = .discarded,
        hangs: Bool = false
    ) {
        self.supported = supported
        self.responses = responses
        self.loadFailure = loadFailure
        self.failingLoads = failingLoads
        self.transcribeFailure = transcribeFailure
        self.discardOutcome = discardOutcome
        self.hangs = hangs
    }

    /// Every `load` call, including the ones that threw.
    var loadAttempts: Int { lock.withLock { attempts } }
    var discards: Int { lock.withLock { discardCalls } }
    var leasesTaken: Int { lock.withLock { begins } }
    var leasesReturned: Int { lock.withLock { ends } }
    var idleReleases: Int { lock.withLock { softReleases } }
    var loadGeneration: Int { lock.withLock { successfulLoads } }

    func beginUse() { lock.withLock { begins += 1 } }
    func endUse() { lock.withLock { ends += 1 } }
    func releaseWhenIdle() async { lock.withLock { softReleases += 1 } }

    func openGate() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            gateOpen = true
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    var isSupported: Bool { supported }
    var loads: [String] { lock.withLock { loadCalls } }
    var transcribedWavs: [String] { lock.withLock { wavCalls } }
    /// Loudest sample of each staged WAV, read while the file still exists.
    var stagedPeaks: [Int] { lock.withLock { wavPeaks } }

    func load(modelPath: String, identity: String) async throws {
        let attempt = lock.withLock { () -> Int in
            attempts += 1
            return attempts
        }
        if let loadFailure, attempt <= failingLoads { throw loadFailure }
        lock.withLock {
            loadCalls.append("\(modelPath)#\(identity)")
            successfulLoads += 1
        }
    }

    func discardCompiledCache(modelPath: String, unlessLoadedSince generation: Int) async
        -> ParakeetCacheDiscard
    {
        lock.withLock { discardCalls += 1 }
        return discardOutcome
    }

    func transcribe(wavPath: String) async throws -> String {
        if hangs {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let open = lock.withLock { () -> Bool in
                    if gateOpen { return true }
                    gate = continuation
                    return false
                }
                if open { continuation.resume() }
            }
        }
        if let transcribeFailure { throw transcribeFailure }
        let peak = (try? Data(contentsOf: URL(fileURLWithPath: wavPath)))
            .map { ParakeetQuietAudioBoost.peak(of: $0.dropFirst(PcmWav.headerBytes)) } ?? -1
        return lock.withLock {
            wavCalls.append(wavPath)
            wavPeaks.append(peak)
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
private func tone(ms: Int, amplitude: Double = 8_000) -> Data {
    var samples = [Int16]()
    let count = sampleRate * ms / 1_000
    samples.reserveCapacity(count)
    for index in 0..<count {
        let phase = Double(index) * 2 * Double.pi * 440 / Double(sampleRate)
        samples.append(Int16(amplitude * sin(phase)))
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

private let coreAISpec = ParakeetModelCatalog.byId(ParakeetModelCatalog.coreAIModelId)

private func makeProvider(
    installed: Bool = true, engine: FakeEngine, temp: URL, spec: ParakeetModelSpec = defaultSpec,
    prepared: Bool = true, foreground: Bool = true, boost: Bool = false
) -> ParakeetTranscriptionProvider {
    ParakeetTranscriptionProvider(
        spec: spec,
        location: FakeLocation(
            path: installed ? temp.appendingPathComponent("model") : nil, prepared: prepared
        ),
        engine: engine,
        temporaryDirectory: temp,
        isForeground: { foreground },
        boostQuietAudio: { boost }
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
        // The whole segment is one chunk starting at zero (no interior gate), so the native
        // 0.5 s offset is the segment offset.
        #expect(segment.startMs == 500)
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

    /// Quiet interior audio is transcribed too: the interior voice gate dropped 17% of the words
    /// the cloud heard in the user's recordings (whole quiet speakers). Only a chunk boundary
    /// looks at loudness now, and it moves to the quietest point before the cap.
    @Test func quietSpeechInsideASegmentIsHandedToTheEngine() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine()
        // Loud, then 10 s at RMS ~19 (where the cloud-heard words the old gate dropped sat;
        // its thresholds were RMS 45 / peak 240), then loud.
        let quiet = tone(ms: 10_000, amplitude: 27)
        #expect(ParakeetPcm.isVoiced(quiet.prefix(3_200)) == false)
        let audio = tone(ms: 2_000) + quiet + tone(ms: 2_000)
        _ = try await makeProvider(engine: engine, temp: temp)
            .transcribe(pcmChunks: chunks(audio), sampleRateHz: sampleRate)
        #expect(engine.transcribedWavs.count == 1)
    }

    @Test func aChunkBoundaryMovesToTheQuietestPointBeforeTheCap() {
        let rate = sampleRate
        let windowBytes = ParakeetPcm.msToBytes(ParakeetPcm.analysisWindowMs, sampleRateHz: rate)
        // 50 s of loud windows with one quiet window at 42.0 s.
        var levels = Array(repeating: WindowLevel(rms: 500, peak: 2_000), count: 500)
        levels[420] = WindowLevel(rms: 3, peak: 10)
        let byteCount = 500 * windowBytes
        let chunks = ParakeetPcm.chunks(levels: levels, byteCount: byteCount, sampleRateHz: rate)
        #expect(chunks.count == 2)
        let cutMs = chunks[0].endMs(sampleRateHz: rate)
        #expect(cutMs == 42_050)  // the middle of window 420
        #expect(chunks[1].startByte == chunks[0].endByte)
        #expect(chunks[1].endByte == byteCount)
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

    /// A Core AI model that has not had its foreground prepare pass is not started cold from a
    /// background pass: `providerUnavailable` (so the router may fall back), and the engine is
    /// never touched. In the foreground, or once prepared, it runs.
    @Test func anUnpreparedCoreAIModelIsUnavailableInTheBackgroundOnly() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let background = FakeEngine()
        let provider = makeProvider(
            engine: background, temp: temp, spec: coreAISpec, prepared: false, foreground: false
        )
        // `isAvailable` answers for NOW, so the queue parks the segment instead of re-decoding
        // it on every retry just to be refused; `transcribe` still refuses on its own.
        #expect(await provider.isAvailable() == false)
        do {
            _ = try await provider.transcribe(pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
            Issue.record("expected providerUnavailable")
        } catch let error as TranscriptionError {
            guard case .providerUnavailable(let id) = error else {
                Issue.record("expected providerUnavailable, got \(error)")
                return
            }
            #expect(id == "coreai-local")
        }
        #expect(background.loads.isEmpty)

        let foreground = FakeEngine()
        _ = try await makeProvider(
            engine: foreground, temp: temp, spec: coreAISpec, prepared: false, foreground: true
        ).transcribe(pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
        #expect(foreground.loads.count == 1)

        let prepared = FakeEngine()
        _ = try await makeProvider(
            engine: prepared, temp: temp, spec: coreAISpec, prepared: true, foreground: false
        ).transcribe(pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
        #expect(prepared.loads.count == 1)
        #expect(prepared.loads.first?.hasSuffix("#parakeet-tdt-0.6b-v3-coreai:v1") == true)

        // The rule is Core AI's: an unprepared flag on a Cactus spec means nothing.
        let cactus = FakeEngine()
        _ = try await makeProvider(
            engine: cactus, temp: temp, spec: defaultSpec, prepared: false, foreground: false
        ).transcribe(pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
        #expect(cactus.loads.count == 1)
    }

    // MARK: Stale compiled cache (2026-09-29)

    private func recoveringProvider(
        engine: FakeEngine, location: MutableLocation, temp: URL, foreground: Bool,
        spec: ParakeetModelSpec = coreAISpec, clock: Clock = Clock(), log: LogLines = LogLines()
    ) -> ParakeetTranscriptionProvider {
        ParakeetTranscriptionProvider(
            spec: spec, location: location, engine: engine, temporaryDirectory: temp,
            nowMs: { clock.now }, isForeground: { foreground }, boostQuietAudio: { false },
            log: { log.append($0) }
        )
    }

    /// The case on the user's phone: a prepared Core AI model whose compiled cache iOS evicted
    /// half of. In the foreground the provider drops the cache, loads cold, and the segment is
    /// transcribed on the same call — with `.prepared` restored and the recovery on record.
    @Test func aPreparedModelThatStopsLoadingRebuildsItsCacheInTheForeground() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine(loadFailure: .modelLoadFailed("no ANE program"), failingLoads: 1)
        let location = MutableLocation(path: temp.appendingPathComponent("model"), prepared: true)
        let log = LogLines()
        let provider = recoveringProvider(
            engine: engine, location: location, temp: temp, foreground: true, log: log
        )

        let result = try await provider.transcribe(
            pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate
        )

        #expect(result.text == "hello there")
        #expect(engine.discards == 1)
        #expect(engine.loadAttempts == 2)
        #expect(location.prepared)
        #expect(log.lines.contains { $0.contains("discarded its compiled cache") })
        #expect(log.lines.contains { $0.contains("rebuilt its compiled cache") })
    }

    /// Backgrounded, the cold rebuild is not started (it is the prepare pass's job, which only
    /// runs in the foreground): the cache is dropped, `.prepared` is withdrawn, the router gets
    /// `providerUnavailable` — and every later background segment is refused without the engine
    /// being touched, instead of re-running the doomed load.
    @Test func inTheBackgroundTheStaleCacheIsDroppedAndTheRebuildWaitsForTheForeground()
        async throws
    {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine(loadFailure: .modelLoadFailed("no ANE program"), failingLoads: 1)
        let location = MutableLocation(path: temp.appendingPathComponent("model"), prepared: true)
        let background = recoveringProvider(
            engine: engine, location: location, temp: temp, foreground: false
        )

        for _ in 0..<3 {
            do {
                _ = try await background.transcribe(
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
        #expect(engine.loadAttempts == 1)
        #expect(engine.discards == 1)
        #expect(location.prepared == false)

        // The app comes forward: the next segment loads cold and marks the model prepared again.
        let foreground = recoveringProvider(
            engine: engine, location: location, temp: temp, foreground: true
        )
        let result = try await foreground.transcribe(
            pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate
        )
        #expect(result.text == "hello there")
        #expect(location.prepared)
    }

    /// A model that will not load even after the rebuild is left alone for a pause: the next
    /// segments fail at once, without a load attempt and without spooling their audio to disk.
    @Test func aModelThatStillWillNotLoadIsNotRetriedForEverySegment() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine(loadFailure: .modelLoadFailed("no ANE program"))
        let location = MutableLocation(path: temp.appendingPathComponent("model"), prepared: true)
        let clock = Clock()
        let provider = recoveringProvider(
            engine: engine, location: location, temp: temp, foreground: true, clock: clock
        )

        func attempt() async -> String? {
            do {
                _ = try await provider.transcribe(
                    pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate
                )
                return nil
            } catch TranscriptionError.transcriptionFailed(let message, _) {
                return message
            } catch {
                return "unexpected \(error)"
            }
        }

        let first = await attempt()
        #expect(first?.contains("failed to initialize local model") == true)
        #expect(engine.loadAttempts == 2)
        #expect(engine.discards == 1)

        let spooled = { (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] }
        let before = spooled()
        let second = await attempt()
        #expect(second?.contains("next attempt after a pause") == true)
        #expect(TranscriptionFailureKind.classify(second) == .modelMissing)
        #expect(engine.loadAttempts == 2)
        #expect(spooled() == before)
        #expect(await provider.isAvailable() == false)

        // After the pause the model is tried again — plainly, since the cache was already dropped
        // and `.prepared` withdrawn; there is nothing left to discard.
        clock.advance(ParakeetTranscriptionProvider.loadRetryPauseMs)
        #expect(await provider.isAvailable())
        _ = await attempt()
        #expect(engine.loadAttempts == 3)
        #expect(engine.discards == 1)
    }

    /// Two callers failed on the same stale cache; the other one has already rebuilt the model
    /// by the time this one asks to discard. The engine says so, and this call just loads — it
    /// does not throw away the model (and cache) the other call just built, and `.prepared`
    /// stays. On 2026-09-29 that race is what dropped a freshly rebuilt model.
    @Test func aDiscardAfterSomeoneElseRecoveredJustLoads() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine(
            loadFailure: .modelLoadFailed("no ANE program"), failingLoads: 1,
            discardOutcome: .loadedSince)
        let location = MutableLocation(path: temp.appendingPathComponent("model"), prepared: true)
        let result = try await recoveringProvider(
            engine: engine, location: location, temp: temp, foreground: false
        ).transcribe(pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
        #expect(result.text == "hello there")
        #expect(location.prepared)
        #expect(engine.loadAttempts == 2)
    }

    /// The model was released between its load and its use (a memory warning). Nothing failed:
    /// the segment parks (`providerUnavailable`) instead of reading "the on-device model
    /// couldn't load" on a model that loaded a moment earlier.
    @Test func aModelReleasedBeforeUseParksTheSegmentInsteadOfFailingIt() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let provider = makeProvider(
            engine: FakeEngine(transcribeFailure: .notLoaded), temp: temp, spec: coreAISpec)
        do {
            _ = try await provider.transcribe(pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
            Issue.record("expected providerUnavailable")
        } catch TranscriptionError.providerUnavailable {
        } catch {
            Issue.record("expected providerUnavailable, got \(error)")
        }
    }

    /// A memory refusal parks the provider for a pause — `isAvailable()` says no, so the queue
    /// stops decoding and spooling every segment once a second just to be refused again.
    @Test func aMemoryRefusalParksTheProviderForAPause() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let clock = Clock()
        let engine = FakeEngine(loadFailure: .insufficientMemory(availableMb: 90, requiredMb: 700))
        let provider = recoveringProvider(
            engine: engine, location: MutableLocation(path: temp.appendingPathComponent("model"), prepared: true),
            temp: temp, foreground: true, clock: clock)
        #expect(await provider.isAvailable())
        _ = try? await provider.transcribe(pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
        #expect(await provider.isAvailable() == false)
        #expect(engine.discards == 0)  // memory is not a stale cache
        clock.advance(ParakeetTranscriptionProvider.memoryRetryPauseMs)
        #expect(await provider.isAvailable())
    }

    /// The segment holds a use lease from before its load to after its last range, so a soft
    /// release cannot drop the model in between.
    @Test func theModelIsLeasedForTheWholeSegment() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine(responses: [#"{"response":"part one"}"#, #"{"response":"part two"}"#])
        _ = try await makeProvider(engine: engine, temp: temp)
            .transcribe(pcmChunks: chunks(tone(ms: 70_000)), sampleRateHz: sampleRate)
        #expect(engine.leasesTaken == 1)
        #expect(engine.leasesReturned == 1)
    }

    /// A call that never comes back is abandoned at its deadline — the caller is not held
    /// hostage by it — and the engine is interrupted.
    @Test func aRangeThatNeverAnswersIsAbandonedAtItsDeadline() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine(hangs: true)
        defer { engine.openGate() }
        let provider = ParakeetTranscriptionProvider(
            spec: defaultSpec,
            location: FakeLocation(path: temp.appendingPathComponent("model")),
            engine: engine, temporaryDirectory: temp, boostQuietAudio: { false },
            rangeDeadlineMs: { _ in 50 })
        let started = Date()
        do {
            _ = try await provider.transcribe(pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
            Issue.record("expected a failure")
        } catch TranscriptionError.transcriptionFailed(let message, _) {
            #expect(message.contains("no answer from the engine"))
        }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(engine.interrupts >= 1)
    }

    /// A scratch-file write failure is the phone's trouble, not the recording's: it must classify
    /// as a (retried) local engine failure, never as unreadable audio (given up on for good).
    @Test func aScratchWriteFailureIsRetriedNotGivenUpOn() {
        #expect(
            TranscriptionFailureKind.classify(ParakeetTranscriptionProvider.scratchWriteFailed)
                == .localEngineFailed)
        #expect(TranscriptionFailureKind.localEngineFailed.isWorthRevisiting)
    }

    /// An UNprepared model whose cold load fails gets one discard-and-rebuild per process in the
    /// foreground (a re-import meeting the old cache) — and only one.
    @Test func anUnpreparedModelGetsOneRebuildAttemptPerProcess() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let clock = Clock()
        let engine = FakeEngine(loadFailure: .modelLoadFailed("dead entry"), failingLoads: 1)
        let location = MutableLocation(path: temp.appendingPathComponent("model"), prepared: false)
        let provider = recoveringProvider(
            engine: engine, location: location, temp: temp, foreground: true, clock: clock)
        let result = try await provider.transcribe(
            pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
        #expect(result.text == "hello there")
        #expect(engine.discards == 1)
        #expect(location.prepared)

        // A second failure in the same process is held, not rebuilt again.
        let second = FakeEngine(loadFailure: .modelLoadFailed("dead entry"))
        let again = recoveringProvider(
            engine: second, location: MutableLocation(path: temp.appendingPathComponent("model"), prepared: false),
            temp: temp, foreground: true, clock: clock)
        _ = try? await again.transcribe(pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
        _ = try? await again.transcribe(pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
        #expect(second.discards == 1)
        #expect(second.loadAttempts == 2)
    }

    /// The idle sweep uses the SOFT release: it must not interrupt a segment still running.
    @Test func theIdleSweepLetsGoSoftly() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine()
        let clock = Clock()
        let provider = recoveringProvider(
            engine: engine, location: MutableLocation(path: temp.appendingPathComponent("model"), prepared: true),
            temp: temp, foreground: true, clock: clock)
        _ = try await provider.transcribe(pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate)
        clock.advance(60_000)
        await provider.releaseModelIfIdle(nowMs: clock.now, idleTimeoutMs: 30_000)
        #expect(engine.idleReleases == 1)
        #expect(engine.releases == 0)
        #expect(engine.interrupts == 0)
    }

    /// Cactus has no compiled cache: a load failure is held, never "recovered".
    @Test func aCactusLoadFailureIsHeldWithoutADiscard() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let engine = FakeEngine(loadFailure: .modelLoadFailed("bad weights"))
        let location = MutableLocation(path: temp.appendingPathComponent("model"), prepared: true)
        let provider = recoveringProvider(
            engine: engine, location: location, temp: temp, foreground: true, spec: defaultSpec
        )
        for _ in 0..<2 {
            _ = try? await provider.transcribe(
                pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate
            )
        }
        #expect(engine.loadAttempts == 1)
        #expect(engine.discards == 0)
    }

    /// With the boost switch on, the WAV the engine reads peaks at −3 dBFS; off, it is the
    /// audio as recorded.
    @Test func theQuietAudioBoostReachesTheStagedWav() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        // A quiet tone: peak 300 clears the voice gate (240) but sits ~40 dB under full scale.
        var quiet = [Int16]()
        for index in 0..<(sampleRate * 800 / 1_000) {
            quiet.append(Int16(300 * sin(Double(index) * 2 * Double.pi * 440 / Double(sampleRate))))
        }
        let audio = quiet.withUnsafeBufferPointer { Data(buffer: $0) }

        let plain = FakeEngine()
        _ = try await makeProvider(engine: plain, temp: temp, boost: false)
            .transcribe(pcmChunks: chunks(audio), sampleRateHz: sampleRate)
        #expect(plain.stagedPeaks == [300])

        let boosted = FakeEngine()
        _ = try await makeProvider(engine: boosted, temp: temp, boost: true)
            .transcribe(pcmChunks: chunks(audio), sampleRateHz: sampleRate)
        #expect(boosted.stagedPeaks == [23_197])
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
        let coreAI = FakeEngine()
        let provider = SelectableLocalTranscriptionProvider(
            selected: { "parakeet-tdt-0.6b-v3-int8" },
            location: FakeLocation(path: nil),
            engine: engine,
            coreAIEngine: coreAI,
            makeAppleSpeech: { StubProvider(id: "apple-\($0.identifier)") }
        )
        await provider.releaseModel(reason: "memory warning")
        // Both runtimes' engines, because either could be holding a model.
        #expect(engine.releases == 1)
        #expect(coreAI.releases == 1)
    }

    /// The spec's runtime picks the engine: a Core AI selection runs on the Core AI engine and
    /// never touches Cactus, and its availability is judged by THAT engine — so a build without
    /// Core AI reports "not supported here" for it while Cactus models still run.
    @Test func theSpecsRuntimePicksTheEngine() async throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let cactus = FakeEngine()
        let coreAI = FakeEngine(responses: [#"{"text":"core ai","segments":[{"start":0.5,"end":1.0,"text":"core ai"}]}"#])
        let selection = SelectionBox(value: ParakeetModelCatalog.coreAIModelId)
        let provider = SelectableLocalTranscriptionProvider(
            selected: { selection.value },
            location: FakeLocation(path: temp),
            engine: cactus,
            coreAIEngine: coreAI,
            makeAppleSpeech: { StubProvider(id: "apple-\($0.identifier)") }
        )
        #expect(provider.resolution == .parakeet(coreAISpec))
        let result = try await provider.transcribe(
            pcmChunks: chunks(tone(ms: 800)), sampleRateHz: sampleRate
        )
        #expect(result.text == "core ai")
        #expect(result.providerId == "coreai-local")
        #expect(provider.id == "coreai-local")
        #expect(result.modelUsed == "parakeet-tdt-0.6b-v3-coreai:v1")
        #expect(coreAI.loads.count == 1)
        #expect(cactus.loads.isEmpty)

        let noCoreAI = SelectableLocalTranscriptionProvider(
            selected: { selection.value },
            location: FakeLocation(path: temp),
            engine: cactus,
            coreAIEngine: FakeEngine(supported: false),
            makeAppleSpeech: { StubProvider(id: "apple-\($0.identifier)") }
        )
        #expect(
            noCoreAI.resolution
                == .parakeetUnavailable(spec: coreAISpec, reason: .notSupportedOnThisDevice)
        )
        #expect(noCoreAI.id.hasPrefix("apple-"))
        selection.value = "parakeet-tdt-0.6b-v3-int8"
        #expect(noCoreAI.resolution == .parakeet(defaultSpec))
    }
}

@Suite struct ParakeetEngineFactoryTests {
    /// The runtime gate is a compile-time + OS-version fact; pin what THIS host reports so a
    /// change in the `#if` shows up here.
    @Test func coreAISupportFollowsTheSdkAndTheOsVersion() {
        #if canImport(CoreAI) && !targetEnvironment(simulator)
            if #available(iOS 27, macOS 27, *) {
                #expect(ParakeetEngineFactory.isSupported(.coreAI))
                #expect(ParakeetEngineFactory.make(runtime: .coreAI).isSupported)
                #expect(ParakeetEngineFactory.makePreparer(runtime: .coreAI) is CoreAIModelPreparer)
            } else {
                #expect(ParakeetEngineFactory.isSupported(.coreAI) == false)
            }
        #else
            #expect(ParakeetEngineFactory.isSupported(.coreAI) == false)
            #expect(ParakeetEngineFactory.make(runtime: .coreAI) is UnsupportedParakeetEngine)
            #expect(ParakeetEngineFactory.makePreparer(runtime: .coreAI) is UnsupportedModelPreparation)
        #endif
        #expect(ParakeetEngineFactory.makePreparer(runtime: .cactus) is NoModelPreparation)
        #expect(ParakeetEngineFactory.isSupported(.cactus) == ParakeetEngineFactory.make().isSupported)
    }

    @Test func unsupportedPreparationRefusesWithThePlatformError() async {
        await #expect(throws: ParakeetEngineError.unsupportedPlatform) {
            try await UnsupportedModelPreparation().prepare(spec: coreAISpec, directory: URL(fileURLWithPath: "/tmp"))
        }
    }

    #if canImport(CoreAI)
        /// The JSON the Core AI engine hands the provider parses back to the same segments.
        @Test func coreAIResponseJsonRoundTripsThroughTheProviderParser() {
            guard #available(iOS 27, macOS 27, *) else { return }
            let json = CoreAIParakeetEngine.encode([
                .init(start: 1.92, end: 6.72, text: "We don't"),
                .init(start: 10.56, end: 17.28, text: "True is uh eight points"),
            ])
            let parsed = ParakeetNativeResponse.parse(json)
            #expect(parsed.text == "We don't True is uh eight points")
            #expect(parsed.segments.map(\.text) == ["We don't", "True is uh eight points"])
            #expect(parsed.segments.map(\.startMs) == [1_920, 10_560])
            #expect(parsed.segments.map(\.endMs) == [6_720, 17_280])
            #expect(parsed.words.isEmpty)
            #expect(ParakeetNativeResponse.parse(CoreAIParakeetEngine.encode([])).text == "")
        }
    #endif
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
