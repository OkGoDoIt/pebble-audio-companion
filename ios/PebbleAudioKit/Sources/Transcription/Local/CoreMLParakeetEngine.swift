import CoreML
import Foundation
#if os(iOS)
    import os
#endif

// Parakeet TDT on Core ML: the mel front end and the encoder are Core ML models (the encoder on the
// Neural Engine), the token search is `ParakeetTDTDecoder`.
//
// Measured on an iPhone 17 / iOS 27 on real watch audio (2026-11-25, through FluidAudio's decoder),
// against the Core AI export of the same checkpoint: 18-98x realtime instead of 4x, 650-860 MB at
// peak instead of ~2.2 GB, and the same speed with the app in the background.
//
// A bundle directory holds `config.json` (the install marker), `Preprocessor.mlmodelc`,
// `Encoder.mlmodelc`, `decoder.f16` (`ParakeetTDTWeights`) and `parakeet_vocab.json`. The encoder
// takes exactly 15 s: longer audio never reaches it, because the provider cuts this runtime's
// ranges at quiet points under `maxRangeMs`.
//
// The answer is the JSON `ParakeetNativeResponse.parse` reads, WITH word times — the frames the
// search emitted at — which neither older local runtime gives.

public final class CoreMLParakeetEngine: ParakeetNativeEngine, @unchecked Sendable {
    /// The one instance the provider, the live path and the store's preparer share: the encoder is
    /// most of a gigabyte resident, and two of them would be two.
    public static let shared = CoreMLParakeetEngine()

    /// The longest range this engine takes. A little under the encoder's 15 s so a range measured in
    /// whole analysis windows always fits.
    public static let maxRangeMs = 14_900
    static let windowSamples = 240_000
    static let sampleRateHz = 16_000
    static let maxFrames = 188

    private static let minLoadMemoryMb: Int64 = 300
    private static let minTranscriptionMemoryMb: Int64 = 96

    private let queue = DispatchQueue(
        label: "dev.audiocompanion.parakeet.coreml", qos: .userInitiated)
    private let lock = NSLock()
    private var model: LoadedModel?
    private var loadedIdentity: String?
    private var generation = 0
    private var leases = 0
    private var releaseRequested = false
    private var running: CancelFlag?

    public init() {}

    public var isSupported: Bool {
        #if targetEnvironment(simulator)
            // The simulator has no Neural Engine and runs the encoder far below realtime.
            return false
        #else
            return true
        #endif
    }

    public var loadGeneration: Int { lock.withLock { generation } }

    // MARK: - Loading

    public func load(modelPath: String, identity: String) async throws {
        if lock.withLock({ model != nil && loadedIdentity == identity }) {
            lock.withLock { releaseRequested = false }
            return
        }
        let available = Self.availableMemoryMb()
        guard available >= Self.minLoadMemoryMb else {
            throw ParakeetEngineError.insufficientMemory(
                availableMb: available, requiredMb: Self.minLoadMemoryMb)
        }
        try await onQueue { [self] in
            if lock.withLock({ model != nil && loadedIdentity == identity }) { return }
            drop()
            let loaded: LoadedModel
            do {
                loaded = try LoadedModel(directory: URL(fileURLWithPath: modelPath, isDirectory: true))
            } catch let error as ParakeetEngineError {
                throw error
            } catch {
                throw ParakeetEngineError.modelLoadFailed("\(error)")
            }
            lock.withLock {
                model = loaded
                loadedIdentity = identity
                generation += 1
                releaseRequested = false
            }
        }
    }

    // MARK: - Transcribing

    public func transcribe(wavPath: String) async throws -> String {
        let available = Self.availableMemoryMb()
        guard available >= Self.minTranscriptionMemoryMb else {
            throw ParakeetEngineError.insufficientMemory(
                availableMb: available, requiredMb: Self.minTranscriptionMemoryMb)
        }
        let flag = CancelFlag()
        defer { releaseIfRequestedAndIdle() }
        return try await withTaskCancellationHandler {
            try await onQueue { [self] in
                guard let model = lock.withLock({ self.model }) else {
                    throw ParakeetEngineError.notLoaded
                }
                lock.withLock { running = flag }
                defer { lock.withLock { running = nil } }
                let samples: [Float]
                do {
                    samples = try Self.samples(ofWav: URL(fileURLWithPath: wavPath))
                } catch {
                    throw ParakeetEngineError.nativeFailure("could not read audio: \(error)")
                }
                let words = try model.transcribe(samples, isCancelled: { flag.isSet })
                // A cancelled run returns whatever it had, often nothing, and an empty transcript
                // reads as silence to everything above.
                if flag.isSet { throw CancellationError() }
                return try Self.response(words)
            }
        } onCancel: {
            flag.set()
        }
    }

    public func interrupt() {
        lock.withLock { running }?.set()
    }

    // MARK: - Releasing (the contract is `ParakeetNativeEngine`'s)

    public func release() async {
        interrupt()
        try? await onQueue { self.drop() }
    }

    public func releaseWhenIdle() async {
        lock.withLock { releaseRequested = true }
        releaseIfRequestedAndIdle()
    }

    public func beginUse() { lock.withLock { leases += 1 } }

    public func endUse() {
        lock.withLock { leases = max(0, leases - 1) }
        releaseIfRequestedAndIdle()
    }

    /// Drops the model unless it is in use: the preparer loaded it, but the pipeline may have
    /// started on it since.
    func releaseUnlessBusy() async {
        try? await onQueue { [self] in
            if lock.withLock({ leases == 0 }) { drop() }
        }
    }

    private func releaseIfRequestedAndIdle() {
        guard lock.withLock({ releaseRequested && leases == 0 }) else { return }
        queue.async { [self] in
            let due = lock.withLock { () -> Bool in
                guard releaseRequested, leases == 0 else { return false }
                releaseRequested = false
                return true
            }
            if due { drop() }
        }
    }

    private func drop() {
        lock.withLock {
            model = nil
            loadedIdentity = nil
        }
    }

    // MARK: - Plumbing

    /// Core ML calls block, so they run on one serial queue, which also serializes the model's
    /// reused buffers.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try autoreleasepool { try body() } })
            }
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// The staged file is always the provider's own canonical 16 kHz mono s16le WAV (44-byte
    /// header); anything else is refused rather than misread.
    static func samples(ofWav url: URL) throws -> [Float] {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count > 44, Array(bytes[0..<4]) == Array("RIFF".utf8),
            bytes[22] == 1, bytes[24] == 0x80, bytes[25] == 0x3E, bytes[34] == 16
        else { throw ParakeetEngineError.nativeFailure("not a 16 kHz mono 16-bit WAV") }
        return (0..<(bytes.count - 44) / 2).map { index in
            let low = UInt16(bytes[44 + index * 2])
            let high = UInt16(bytes[45 + index * 2])
            return Float(Int16(bitPattern: low | (high << 8))) / 32_768
        }
    }

    static func response(_ words: [ParakeetVocabulary.Word]) throws -> String {
        func timed(_ word: ParakeetVocabulary.Word, _ key: String) -> [String: Any] {
            [
                key: word.text, "start": Double(word.startMs) / 1_000,
                "end": Double(word.endMs) / 1_000,
            ]
        }
        let root: [String: Any] = [
            "text": words.map(\.text).joined(separator: " "),
            "words": words.map { timed($0, "word") },
            "segments": phrases(words).map { timed($0, "text") },
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    /// Words into phrases, broken at the end of a sentence and at pauses, so a 15 s range is not one
    /// block of text with one start time.
    static func phrases(_ words: [ParakeetVocabulary.Word]) -> [ParakeetVocabulary.Word] {
        var phrases: [ParakeetVocabulary.Word] = []
        var open: ParakeetVocabulary.Word?
        for word in words {
            guard let current = open else {
                open = word
                continue
            }
            let pause = word.startMs - current.endMs
            let ended = current.text.last.map { ".?!".contains($0) } ?? false
            if (ended && pause >= 240) || pause >= 1_200 {
                phrases.append(current)
                open = word
            } else {
                open = .init(
                    text: current.text + " " + word.text, startMs: current.startMs,
                    endMs: word.endMs)
            }
        }
        if let open { phrases.append(open) }
        return phrases
    }

    private static func availableMemoryMb() -> Int64 {
        #if os(iOS)
            let bytes = os_proc_available_memory()
            return bytes > 0 ? Int64(bytes) / (1_024 * 1_024) : .max
        #else
            return .max
        #endif
    }
}

/// A loaded bundle. Only ever touched on the engine's queue.
private final class LoadedModel {
    private let preprocessor: MLModel
    private let encoder: MLModel
    private let decoder: ParakeetTDTDecoder
    private let vocabulary: ParakeetVocabulary
    private let audio: MLMultiArray
    private let audioLength: MLMultiArray

    init(directory: URL) throws {
        // The mel front end is an FFT: a few milliseconds of CPU, and not worth a Neural Engine
        // program of its own.
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let neural = MLModelConfiguration()
        neural.computeUnits = .cpuAndNeuralEngine
        preprocessor = try MLModel(
            contentsOf: directory.appendingPathComponent("Preprocessor.mlmodelc"), configuration: cpu)
        encoder = try MLModel(
            contentsOf: directory.appendingPathComponent("Encoder.mlmodelc"), configuration: neural)
        decoder = ParakeetTDTDecoder(
            weights: try ParakeetTDTWeights(
                contentsOf: directory.appendingPathComponent("decoder.f16")))
        vocabulary = try ParakeetVocabulary(
            contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
        audio = try MLMultiArray(
            shape: [1, NSNumber(value: CoreMLParakeetEngine.windowSamples)], dataType: .float32)
        audioLength = try MLMultiArray(shape: [1], dataType: .int32)
    }

    func transcribe(_ samples: [Float], isCancelled: () -> Bool) throws -> [ParakeetVocabulary.Word] {
        let window = CoreMLParakeetEngine.windowSamples
        var words: [ParakeetVocabulary.Word] = []
        // One window for everything the provider sends; the loop is for a caller that sends more.
        var start = 0
        while start < samples.count {
            if isCancelled() { return words }
            let slice = Array(samples[start..<min(start + window, samples.count)])
            let offsetMs = start * 1_000 / CoreMLParakeetEngine.sampleRateHz
            words += try recognize(slice, isCancelled: isCancelled).map {
                .init(text: $0.text, startMs: $0.startMs + offsetMs, endMs: $0.endMs + offsetMs)
            }
            start += window
        }
        return words
    }

    private func recognize(_ samples: [Float], isCancelled: () -> Bool) throws
        -> [ParakeetVocabulary.Word]
    {
        audio.withUnsafeMutableBufferPointer(ofType: Float.self) { out, _ in
            for index in 0..<CoreMLParakeetEngine.windowSamples {
                out[index] = index < samples.count ? samples[index] : 0
            }
        }
        audioLength[0] = NSNumber(value: samples.count)
        let mel = try preprocessor.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "audio_signal": audio, "audio_length": audioLength,
            ]))
        guard let features = mel.featureValue(for: "mel")?.multiArrayValue,
            let featureLength = mel.featureValue(for: "mel_length")?.multiArrayValue
        else { throw ParakeetEngineError.nativeFailure("the mel front end returned nothing") }
        let encoded = try encoder.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "mel": features, "mel_length": featureLength,
            ]))
        guard let output = encoded.featureValue(for: "encoder")?.multiArrayValue,
            let length = encoded.featureValue(for: "encoder_length")?.multiArrayValue
        else { throw ParakeetEngineError.nativeFailure("the encoder returned nothing") }
        let frames = min(CoreMLParakeetEngine.maxFrames, length[0].intValue)
        return vocabulary.words(
            decoder.decode(
                encoded: Self.rows(of: output, frames: frames), frames: frames,
                isCancelled: isCancelled))
    }

    /// `[1, 1024, T]` → `T × 1024`, row-major.
    private static func rows(of output: MLMultiArray, frames: Int) -> [Float] {
        let width = ParakeetTDTWeights.encoder
        let strides = output.strides.map(\.intValue)
        return [Float](unsafeUninitializedCapacity: frames * width) { out, count in
            output.withUnsafeBufferPointer(ofType: Float.self) { source in
                for unit in 0..<width {
                    let base = unit * strides[1]
                    for frame in 0..<frames {
                        out[frame * width + unit] = source[base + frame * strides[2]]
                    }
                }
            }
            count = frames * width
        }
    }
}

/// The first load compiles the encoder for this phone's Neural Engine (15-30 s on an iPhone 17), so
/// it happens once, in the foreground, under the row's "finishing up".
public struct CoreMLModelPreparer: ParakeetModelPreparing {
    public init() {}

    public func prepare(spec: ParakeetModelSpec, directory: URL) async throws {
        let engine = CoreMLParakeetEngine.shared
        let before = engine.loadGeneration
        try await engine.load(modelPath: directory.path, identity: spec.modelUsed)
        if engine.loadGeneration != before { await engine.releaseUnlessBusy() }
    }
}
