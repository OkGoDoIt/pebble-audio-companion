import AudioCodec
import Foundation
import SegmentStore
import Testing

@testable import Transcription

// A MEASUREMENT, not a unit test: the on-device engines, run through the PRODUCTION providers on
// the user's real watch audio, scored against the cloud transcript of the same segment.
//
// Runs only when `PEBBLE_ENGINE_COMPARE_ROOT` points at an app-container backup and
// `PEBBLE_ENGINE_COMPARE_SEGMENTS` names comma-separated segment ids. `PEBBLE_COREAI_BUNDLE`
// (a Parakeet Core AI bundle directory, e.g. copied off the phone) enables the Core AI engine;
// Apple Speech runs when this Mac has its assets. The cloud transcript is a REFERENCE, not ground
// truth — a word error rate against it says how far the engines are from Soniox, not from the
// truth — but a large gap, or one that closes when the interior gate is removed, is real.
@Suite(.serialized) struct LocalEngineComparison {
    private struct Transcript: Decodable {
        let segmentId: String
        let providerId: String
        let text: String
    }

    @Test func enginesAgainstTheCloudTranscript() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["PEBBLE_ENGINE_COMPARE_ROOT"],
            let ids = env["PEBBLE_ENGINE_COMPARE_SEGMENTS"]?.split(separator: ",").map(String.init),
            !ids.isEmpty
        else { return }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let reader = SegmentFileReader(root: root)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        var engines: [(name: String, provider: any TranscriptionProvider)] = []
        #if canImport(CoreAI)
            if let bundle = env["PEBBLE_COREAI_BUNDLE"], #available(macOS 27, iOS 27, *) {
                let spec = ParakeetModelCatalog.byId(ParakeetModelCatalog.coreAIModelId)
                let location = FixedLocation(path: URL(fileURLWithPath: bundle, isDirectory: true))
                engines.append((
                    "coreai parakeet",
                    ParakeetTranscriptionProvider(
                        spec: spec, location: location, engine: CoreAIParakeetEngine.shared,
                        temporaryDirectory: temp, boostQuietAudio: { false })
                ))
                // The `ParakeetQuietAudioBoost` experiment on the same engine and audio.
                if env["PEBBLE_ENGINE_COMPARE_BOOST"] != nil {
                    engines.append((
                        "coreai boost",
                        ParakeetTranscriptionProvider(
                            spec: spec, location: location, engine: CoreAIParakeetEngine.shared,
                            temporaryDirectory: temp, boostQuietAudio: { true })
                    ))
                }
            }
        #endif
        let apple = SpeechAnalyzerProvider(locale: Locale(identifier: "en-US"))
        if await apple.isAvailable() { engines.append(("apple speech", apple)) }
        print("engines: \(engines.map(\.name))")

        for id in ids {
            let transcriptURL = root.appendingPathComponent(
                "transcription/transcripts/\(id).transcript.json")
            guard let data = try? Data(contentsOf: transcriptURL),
                let reference = try? JSONDecoder().decode(Transcript.self, from: data),
                let meta = reader.readMeta(id)
            else {
                print("\(id): no reference transcript or audio")
                continue
            }
            let frames = reader.readFrames(id)
            let rate = Int(meta.sampleRateHz)
            let decoder = SpeexFrameDecoder(
                sampleRateHz: rate, bitRateBps: Int(meta.bitRateBps), frameSamples: meta.frameSamples)
            let pcm = try decoder.decodeAll(frames: frames.map { Data($0.payload) })
            let audioSeconds = Double(pcm.count / 2) / Double(rate)
            let refWords = Self.words(reference.text)
            // Parakeet v3 knows 25 European languages; a reference in another script measures
            // nothing about English accuracy, so it is reported and skipped.
            let letters = reference.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let latin = letters.filter(\.isASCII).count
            guard letters.isEmpty || Double(latin) / Double(letters.count) > 0.9 else {
                print("\(id): reference is not in a Latin script; skipped")
                continue
            }
            let levels = ParakeetPcm.windowLevels(byteCount: pcm.count, sampleRateHz: rate) {
                pcm.subdata(in: $0..<min(pcm.count, $0 + $1))
            }
            let rmsDb = levels.map { 20 * log10(max(Double($0.rms), 1) / 32_767) }.sorted()
            let peak = levels.map(\.peak).max() ?? 0
            print(
                "\(id): \(Int(audioSeconds)) s of audio, reference \(reference.providerId) "
                    + "\(refWords.count) words | window RMS p50 "
                    + "\(String(format: "%.0f", rmsDb.isEmpty ? -99 : rmsDb[rmsDb.count / 2])) dBFS, p90 "
                    + "\(String(format: "%.0f", rmsDb.isEmpty ? -99 : rmsDb[rmsDb.count * 9 / 10])) dBFS"
                    + " | peak \(String(format: "%.0f", 20 * log10(max(Double(peak), 1) / 32_767))) dBFS")
            // What the retired interior voice gate would have let through: everything outside
            // its ranges silenced, so the same engine hears only what it used to be handed.
            let gated = Self.silencingOutside(
                ParakeetPcm.speechRanges(byteCount: pcm.count, sampleRateHz: rate) {
                    pcm.subdata(in: $0..<min(pcm.count, $0 + $1))
                }, of: pcm)
            var runs: [(name: String, provider: any TranscriptionProvider, audio: Data)] = []
            for engine in engines {
                runs.append((engine.name, engine.provider, pcm))
                if env["PEBBLE_ENGINE_COMPARE_OLD_GATE"] != nil, engine.name == "coreai parakeet" {
                    runs.append((engine.name + " oldgate", engine.provider, gated))
                }
            }
            for engine in runs {
                let started = Date()
                do {
                    let result = try await engine.provider.transcribe(
                        pcmChunks: Self.stream(engine.audio), sampleRateHz: rate)
                    let seconds = Date().timeIntervalSince(started)
                    let hypothesis = Self.words(result.text)
                    let wer = Self.wordErrorRate(reference: refWords, hypothesis: hypothesis)
                    print(
                        "  \(engine.name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                            + "WER \(String(format: "%5.1f", wer * 100))% | \(hypothesis.count) words"
                            + " | \(String(format: "%.1f", audioSeconds / max(seconds, 0.001)))x realtime"
                            + " | \"\(result.text.prefix(90))\"")
                } catch {
                    print("  \(engine.name): \(error)")
                }
            }
        }
    }

    /// Segments the app settled as `NoSpeech`, heard again by today's Core AI path: how much
    /// the old verdict hid. `PEBBLE_NOSPEECH_SEGMENTS` names them (same backup root). Prints,
    /// per segment, whether the retired interior gate found ANY voiced range (none means that
    /// gate alone decided "no speech") and what the whole-segment path hears now.
    @Test func noSpeechVerdictsHeardAgain() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["PEBBLE_ENGINE_COMPARE_ROOT"],
            let ids = env["PEBBLE_NOSPEECH_SEGMENTS"]?.split(separator: ",").map(String.init),
            !ids.isEmpty
        else { return }
        #if canImport(CoreAI)
            guard let bundle = env["PEBBLE_COREAI_BUNDLE"], #available(macOS 27, iOS 27, *)
            else { return }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            let reader = SegmentFileReader(root: root)
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nospeech-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let spec = ParakeetModelCatalog.byId(ParakeetModelCatalog.coreAIModelId)
            let provider = ParakeetTranscriptionProvider(
                spec: spec,
                location: FixedLocation(path: URL(fileURLWithPath: bundle, isDirectory: true)),
                engine: CoreAIParakeetEngine.shared, temporaryDirectory: temp,
                boostQuietAudio: { false })
            var withWords = 0
            var gateDecided = 0
            for id in ids {
                guard let meta = reader.readMeta(id) else {
                    print("\(id): no audio")
                    continue
                }
                let rate = Int(meta.sampleRateHz)
                let decoder = SpeexFrameDecoder(
                    sampleRateHz: rate, bitRateBps: Int(meta.bitRateBps),
                    frameSamples: meta.frameSamples)
                let pcm = try decoder.decodeAll(
                    frames: reader.readFrames(id).map { Data($0.payload) })
                let seconds = Double(pcm.count / 2) / Double(rate)
                let ranges = ParakeetPcm.speechRanges(byteCount: pcm.count, sampleRateHz: rate) {
                    pcm.subdata(in: $0..<min(pcm.count, $0 + $1))
                }
                if ranges.isEmpty { gateDecided += 1 }
                let heard: String
                do {
                    let result = try await provider.transcribe(
                        pcmChunks: Self.stream(pcm), sampleRateHz: rate)
                    let words = Self.words(result.text)
                    if words.count >= 5 { withWords += 1 }
                    heard = "\(words.count) words | \"\(result.text.prefix(110))\""
                } catch {
                    heard = "\(error)"
                }
                print(
                    "\(id): \(Int(seconds)) s | old gate ranges \(ranges.count) | now: \(heard)")
            }
            print(
                "summary: \(ids.count) segments, \(gateDecided) had no voiced range under the old "
                    + "gate, \(withWords) now yield 5+ words")
        #endif
    }

    /// How long a Core AI load takes from each of `PEBBLE_COREAI_LOAD_TIMING`'s comma-separated
    /// bundle paths, released in between. Answers whether the specialization cache follows the
    /// model's CONTENT or its PATH: load a bundle, move it, load it again — seconds means the
    /// cache still applied, a minute and more means it specialized from scratch.
    @Test func coreAILoadTiming() async throws {
        guard let raw = ProcessInfo.processInfo.environment["PEBBLE_COREAI_LOAD_TIMING"] else {
            return
        }
        #if canImport(CoreAI)
            if #available(macOS 27, iOS 27, *) {
                let engine = CoreAIParakeetEngine.shared
                for path in raw.split(separator: ",").map(String.init) {
                    let started = Date()
                    do {
                        try await engine.load(modelPath: path, identity: "timing \(path)")
                        print(
                            "load \(path): \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                    } catch {
                        print("load \(path) failed: \(error)")
                    }
                    await engine.release()
                }
            }
        #endif
    }

    // MARK: - Helpers

    private struct FixedLocation: ParakeetModelLocating {
        let path: URL
        func installedModelPath(for spec: ParakeetModelSpec) -> URL? { path }
        func isPrepared(_ spec: ParakeetModelSpec) -> Bool { true }
    }

    private static func stream(_ pcm: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + 32_000, pcm.count)
                continuation.yield(pcm.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
    }

    static func silencingOutside(_ ranges: [PcmSpeechRange], of pcm: Data) -> Data {
        var out = Data(count: pcm.count)
        for range in ranges {
            let lo = max(0, range.startByte), hi = min(pcm.count, range.endByte)
            if hi > lo { out.replaceSubrange(lo..<hi, with: pcm.subdata(in: lo..<hi)) }
        }
        return out
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
    }

    /// Word-level Levenshtein distance over the reference length.
    static func wordErrorRate(reference: [String], hypothesis: [String]) -> Double {
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        var previous = Array(0...hypothesis.count)
        for (i, ref) in reference.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: hypothesis.count)
            for (j, hyp) in hypothesis.enumerated() {
                current[j + 1] = min(
                    previous[j + 1] + 1, current[j] + 1, previous[j] + (ref == hyp ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[hypothesis.count]) / Double(reference.count)
    }
}
