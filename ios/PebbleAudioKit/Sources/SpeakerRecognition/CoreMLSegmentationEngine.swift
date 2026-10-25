import CoreML
import Foundation

protocol SpeakerSegmentationEngine: Sendable {
    func scores(pcm16LE: Data, model: CoreMLSegmentationModel,
                authorize: @escaping @Sendable () throws -> Void) async throws -> [Float]
    func release() async
}

/// Core ML uses the published powerset model directly. Queue confinement bounds inference
/// concurrency and model memory; authorization is checked on both sides of every native call.
final class CoreMLSegmentationEngine: SpeakerSegmentationEngine {
    private final class State: @unchecked Sendable {
        var model: MLModel?
        var directory: URL?
        func release() { model = nil; directory = nil }
    }
    private let state = State()
    private static let queue = DispatchQueue(label: "dev.audiocompanion.speaker-segmentation", qos: .utility)

    func scores(pcm16LE: Data, model: CoreMLSegmentationModel,
                authorize: @escaping @Sendable () throws -> Void) async throws -> [Float] {
        guard !pcm16LE.isEmpty, pcm16LE.count <= 320_000, pcm16LE.count.isMultiple(of: 2) else {
            throw SpeakerRecognitionError.invalidAudio("Segmentation window must be <=10 seconds PCM16LE")
        }
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { [state] in
                do {
                    try authorize()
                    if state.model == nil || state.directory != model.directory {
                        state.release()
                        try model.verify()
                        try authorize()
                        let configuration = MLModelConfiguration()
                        // This small model benchmarks quickly on CPU; no GPU work or ANE warmup.
                        configuration.computeUnits = .cpuOnly
                        state.model = try MLModel(contentsOf: model.directory, configuration: configuration)
                        state.directory = model.directory
                    }
                    try authorize()
                    let input = try MLMultiArray(shape: [1, 1, 160_000], dataType: .float32)
                    let pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
                    pointer.update(repeating: 0, count: 160_000)
                    pcm16LE.withUnsafeBytes { bytes in
                        let values = bytes.bindMemory(to: UInt8.self)
                        for i in 0..<(values.count / 2) {
                            pointer[i] = Float(Int16(bitPattern: UInt16(values[i * 2])
                                | UInt16(values[i * 2 + 1]) << 8)) / 32768
                        }
                    }
                    let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
                    let output = try state.model!.prediction(from: provider)
                    try authorize()
                    guard let values = output.featureValue(for: "log_probs")?.multiArrayValue,
                          values.shape.map(\.intValue) == [1, 589, 7] else {
                        throw SpeakerRecognitionError.nativeFailure("Unexpected segmentation output shape")
                    }
                    let probabilities = (0..<values.count).map { exp(values[$0].floatValue) }
                    try Self.validate(probabilities)
                    continuation.resume(returning: probabilities)
                } catch { state.release(); continuation.resume(throwing: error) }
            }
        }
    }

    func release() async {
        await withCheckedContinuation { continuation in
            Self.queue.async { [state] in state.release(); continuation.resume() }
        }
    }

    static func validate(_ scores: [Float]) throws {
        guard scores.count == 589 * 7,
              scores.allSatisfy({ $0.isFinite && (0...1.00001).contains($0) }) else {
            throw SpeakerRecognitionError.nativeFailure("Invalid segmentation output")
        }
        for frame in 0..<589 {
            guard abs(scores[(frame * 7)..<(frame * 7 + 7)].reduce(0, +) - 1) < 0.02 else {
                throw SpeakerRecognitionError.nativeFailure("Invalid segmentation probabilities")
            }
        }
    }
}
