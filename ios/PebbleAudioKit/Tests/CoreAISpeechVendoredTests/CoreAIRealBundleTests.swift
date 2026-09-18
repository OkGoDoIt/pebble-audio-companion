import Foundation
import Testing

@testable import CoreAISpeechVendored
@testable import Transcription

// The correctness proof for the vendored copy: real watch recordings through the vendored code
// (and through the engine adapter the app uses) must produce text byte-identical to what the
// upstream CLI — with swift-transformers doing the detokenizing — produced for the same bundle.
//
// Needs Core AI at run time (macOS 27 has it) and two environment variables:
//   PEBBLE_COREAI_BUNDLE    a `--streaming` export directory (metadata.json + 3 .aimodel)
//   PEBBLE_COREAI_FIXTURES  a directory with `wavs/<name>.wav` and `results/<prefix><name>.hyp.txt`
//                           (+ `<prefix><name>.out`, the CLI's full output, for the timestamps)
//   PEBBLE_COREAI_HYP_PREFIX  the results prefix, default "f16stream_"
// Without them every test here is skipped (not passed), so plain `swift test` stays green.

private enum Env {
    static let bundle = ProcessInfo.processInfo.environment["PEBBLE_COREAI_BUNDLE"]
    static let fixtures = ProcessInfo.processInfo.environment["PEBBLE_COREAI_FIXTURES"]
    static let prefix = ProcessInfo.processInfo.environment["PEBBLE_COREAI_HYP_PREFIX"] ?? "f16stream_"
    static var isConfigured: Bool { bundle != nil && fixtures != nil }
}

/// One WAV with the CLI's transcript for it.
private struct Fixture {
    let name: String
    let wav: URL
    let hyp: String
    /// `[start – end] text` lines from the CLI's `.out`, when that file is present.
    let segments: [(start: Double, end: Double, text: String)]?

    static func all() throws -> [Fixture] {
        guard let root = Env.fixtures else { return [] }
        let wavs = URL(fileURLWithPath: root).appendingPathComponent("wavs")
        let results = URL(fileURLWithPath: root).appendingPathComponent("results")
        let names = try FileManager.default.contentsOfDirectory(atPath: wavs.path)
            .filter { $0.hasSuffix(".wav") }.sorted()
        return try names.compactMap { file in
            let name = String(file.dropLast(4))
            let hypURL = results.appendingPathComponent("\(Env.prefix)\(name).hyp.txt")
            guard FileManager.default.fileExists(atPath: hypURL.path) else { return nil }
            let hyp = try String(contentsOf: hypURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let outURL = results.appendingPathComponent("\(Env.prefix)\(name).out")
            let segments = (try? String(contentsOf: outURL, encoding: .utf8)).map(parseSegments)
            return Fixture(name: name, wav: wavs.appendingPathComponent(file), hyp: hyp, segments: segments)
        }
    }

    private static func parseSegments(_ out: String) -> [(start: Double, end: Double, text: String)] {
        let pattern = /^\[\s*([0-9.]+) –\s*([0-9.]+)\]  (.*)$/
        return out.split(separator: "\n").compactMap { line in
            guard let match = line.wholeMatch(of: pattern), let start = Double(match.1),
                let end = Double(match.2)
            else { return nil }
            return (start, end, String(match.3))
        }
    }
}

#if canImport(CoreAI)
    /// The bundle loaded once for the whole run: init is the specialization pass (seconds).
    @available(macOS 27, iOS 27, *)
    private actor SharedModel {
        static let shared = SharedModel()
        private var model: SpeechRecognitionModel?

        func get() async throws -> SpeechRecognitionModel {
            if let model { return model }
            let url = URL(fileURLWithPath: try #require(Env.bundle), isDirectory: true)
            let loaded = try await SpeechRecognitionModel(resourcesAt: url)
            model = loaded
            return loaded
        }
    }

    /// The upstream CLI's `--stream` replay, verbatim: chunk-sized pushes, default endpointing,
    /// finalized segments joined with one space.
    @available(macOS 27, iOS 27, *)
    private func replayLikeTheCLI(_ model: SpeechRecognitionModel, wav: URL) async throws
        -> (text: String, segments: [CoreAISpeechVendored.TranscriptSegment])
    {
        let pcm = try MelSpectrogram.loadAndResample(wav, targetSampleRate: await model.sampleRate)
        let updates = try await model.startStream()
        let active = try #require(await model.activeStreamingConfig)
        let collector = Task { () -> [CoreAISpeechVendored.TranscriptSegment] in
            var finals: [CoreAISpeechVendored.TranscriptSegment] = []
            for try await update in updates {
                if case .finalized(let segment) = update { finals.append(segment) }
            }
            return finals
        }
        let pushSize = active.chunkFrames * active.samplesPerEncoderFrame
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + pushSize, pcm.count)
            try await model.append(pcm: Array(pcm[offset..<end]))
            offset = end
        }
        _ = try await model.finishStream()
        let segments = try await collector.value
        return (segments.map(\.text).joined(separator: " "), segments)
    }

    @Suite(.serialized, .enabled(if: Env.isConfigured, "set PEBBLE_COREAI_BUNDLE and PEBBLE_COREAI_FIXTURES"))
    struct CoreAIRealBundleTests {
        @Test func fixturesArePresent() throws {
            let fixtures = try Fixture.all()
            #expect(!fixtures.isEmpty, "no <name>.wav with a matching \(Env.prefix)<name>.hyp.txt")
        }

        /// The vendored model + `ParakeetTokenizer`, fed like the CLI, on every fixture.
        @Test func vendoredCodeMatchesTheUpstreamCLIByteForByte() async throws {
            guard #available(macOS 27, iOS 27, *) else { return }
            let model = try await SharedModel.shared.get()
            #expect(await model.architecture == "Parakeet TDT")
            for fixture in try Fixture.all() {
                let (text, segments) = try await replayLikeTheCLI(model, wav: fixture.wav)
                #expect(text == fixture.hyp, "\(fixture.name): text differs from the CLI")
                if let expected = fixture.segments {
                    #expect(segments.count == expected.count, "\(fixture.name): segment count")
                    for (got, want) in zip(segments, expected) {
                        #expect(got.text == want.text, "\(fixture.name): segment text")
                        #expect(abs(got.startTime - want.start) < 0.005, "\(fixture.name): start")
                        #expect(abs(got.endTime - want.end) < 0.005, "\(fixture.name): end")
                    }
                }
            }
        }

        /// The adapter the app actually calls: WAV path in, provider JSON out, same text and the
        /// same segment timestamps as the CLI printed.
        @Test func engineAdapterMatchesTheUpstreamCLI() async throws {
            guard #available(macOS 27, iOS 27, *) else { return }
            let engine = CoreAIParakeetEngine()
            try await engine.load(modelPath: try #require(Env.bundle), identity: "parity")
            for fixture in try Fixture.all() {
                let json = try await engine.transcribe(wavPath: fixture.wav.path)
                let parsed = ParakeetNativeResponse.parse(json)
                #expect(parsed.text == fixture.hyp, "\(fixture.name): engine text differs from the CLI")
                #expect(parsed.words.isEmpty)
                if let expected = fixture.segments {
                    #expect(parsed.segments.count == expected.count, "\(fixture.name): segment count")
                    for (got, want) in zip(parsed.segments, expected) {
                        #expect(got.text == want.text)
                        #expect(abs(Double(got.startMs) / 1_000 - want.start) < 0.005)
                        #expect(abs(Double(got.endMs) / 1_000 - want.end) < 0.005)
                        #expect(got.speaker == nil)
                    }
                }
            }
            await engine.release()
        }

        /// `interrupt()` must cut a long transcription short AND leave the engine usable: the
        /// session it abandons would otherwise block the next `startStream`.
        @Test func interruptReturnsPromptlyAndTheEngineStaysUsable() async throws {
            guard #available(macOS 27, iOS 27, *) else { return }
            let fixtures = try Fixture.all()
            let longest = try #require(
                fixtures.max { a, b in
                    (try? a.wav.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
                        < (try? b.wav.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
                }
            )
            let engine = CoreAIParakeetEngine()
            try await engine.load(modelPath: try #require(Env.bundle), identity: "interrupt")

            let started = ContinuousClock.now
            let work = Task { try await engine.transcribe(wavPath: longest.wav.path) }
            try await Task.sleep(for: .milliseconds(300))
            engine.interrupt()
            do {
                _ = try await work.value
                Issue.record("expected the interrupted transcription to throw")
            } catch is CancellationError {
            } catch {
                Issue.record("expected CancellationError, got \(error)")
            }
            #expect(ContinuousClock.now - started < .seconds(10))

            // Usable afterwards, on the shortest fixture, with the right answer.
            let shortest = try #require(fixtures.first { $0.name != longest.name } ?? fixtures.first)
            let json = try await engine.transcribe(wavPath: shortest.wav.path)
            #expect(ParakeetNativeResponse.parse(json).text == shortest.hyp)
            await engine.release()
        }

        /// The store's prepare pass: load + warm, then release unless something is running.
        @Test func prepareWarmsAndReleaseUnlessBusyDropsTheIdleModel() async throws {
            guard #available(macOS 27, iOS 27, *) else { return }
            let engine = CoreAIParakeetEngine()
            try await engine.prepare(modelPath: try #require(Env.bundle), identity: "prepare")
            #expect(engine.loadedModelIdentity == "prepare")
            await engine.releaseUnlessBusy()
            #expect(engine.loadedModelIdentity == nil)
            // A transcription on a released engine is a load failure, not a crash.
            await #expect(throws: ParakeetEngineError.modelLoadFailed("no model loaded")) {
                _ = try await engine.transcribe(wavPath: "/nonexistent.wav")
            }
        }
    }
#endif
