import Foundation
import Synchronization
import Transcription

#if os(iOS)
import CCactus
#endif

public struct SpeakerEmbeddingResult: Sendable {
    public let embedding: SpeakerEmbedding
    public let quality: SpeakerAudioQuality
    public let inferenceMilliseconds: Double?
}

/// No work or model loading occurs at construction. Off by default, with explicit activation.
/// Disabling invalidates queued/in-flight results and waits for native cleanup. It cannot
/// preempt an already executing C call, but its result will never be returned as successful.
public final class CactusSpeakerEmbeddingProvider: Sendable {
    private struct Authorization: Sendable { var enabled = false; var generation: UInt64 = 0 }
    private let authorization = Mutex(Authorization())
    private let engine: any SpeakerEmbeddingEngine
    private let model: CactusSpeakerModel

    public init(model: CactusSpeakerModel) {
        self.model = model
        self.engine = CactusSpeakerEngine()
    }

    init(model: CactusSpeakerModel, engine: any SpeakerEmbeddingEngine) {
        self.model = model
        self.engine = engine
    }

    public var isEnabled: Bool { authorization.withLock { $0.enabled } }

    public func setEnabled(_ enabled: Bool) async {
        authorization.withLock {
            guard $0.enabled != enabled else { return }
            $0.enabled = enabled
            $0.generation &+= 1
        }
        if !enabled { await engine.release() }
    }

    public func releaseModel() async { await engine.release() }

    public func embedding(for sample: SpeakerAudioSample) async throws -> SpeakerEmbeddingResult {
        let generation = try authorization.withLock {
            guard $0.enabled else { throw SpeakerRecognitionError.disabled }
            return $0.generation
        }
        try Task.checkCancellation()
        let quality = try sample.validate()
        let cancelled = Mutex(false)
        let check: @Sendable () throws -> Void = { [self] in
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            try authorization.withLock {
                guard $0.enabled, $0.generation == generation else {
                    throw SpeakerRecognitionError.disabled
                }
            }
        }
        let native = try await withTaskCancellationHandler {
            try await engine.embed(sample: sample, model: model, authorize: check)
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        try check()
        try Task.checkCancellation()
        return SpeakerEmbeddingResult(
            embedding: try SpeakerEmbedding(recipe: CactusSpeakerModel.recipe, values: native.values),
            quality: quality, inferenceMilliseconds: native.inferenceMilliseconds
        )
    }
}

struct NativeSpeakerEmbedding: Sendable {
    let values: [Float]
    let inferenceMilliseconds: Double?
}

protocol SpeakerEmbeddingEngine: Sendable {
    func embed(sample: SpeakerAudioSample, model: CactusSpeakerModel,
               authorize: @escaping @Sendable () throws -> Void) async throws -> NativeSpeakerEmbedding
    func release() async
}

/// The FFI owns a static mel processor, so all speaker-engine instances share ONE serial
/// queue. NativeState's pointer is accessed only there; closures retain it through completion.
/// This is the reason for the narrowly scoped unchecked annotation below.
final class CactusSpeakerEngine: SpeakerEmbeddingEngine {
    private static let queue = DispatchQueue(label: "dev.audiocompanion.speaker.cactus", qos: .utility)
    #if os(iOS)
    private final class NativeState: @unchecked Sendable {
        var handle: UnsafeMutableRawPointer?
        var directory: URL?
        deinit { if let handle { cactus_destroy(handle) } }
        func release() {
            if let handle { cactus_destroy(handle) }
            handle = nil
            directory = nil
        }
    }
    private let state = NativeState()
    #endif

    func embed(sample: SpeakerAudioSample, model: CactusSpeakerModel,
               authorize: @escaping @Sendable () throws -> Void) async throws -> NativeSpeakerEmbedding {
        #if os(iOS)
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { [state] in
                do {
                    try authorize()
                    if state.handle == nil || state.directory != model.directory {
                        state.release()
                        try model.verify()
                        try authorize()
                        CactusPrivacyConfiguration.configure()
                        guard let handle = cactus_init(model.directory.path, nil, false) else {
                            throw SpeakerRecognitionError.modelLoadFailed(Self.lastError())
                        }
                        cactus_telemetry_shutdown()
                        state.handle = handle
                        state.directory = model.directory
                    }
                    try authorize()
                    guard let handle = state.handle else {
                        throw SpeakerRecognitionError.modelLoadFailed("Model was released")
                    }
                    var response = [CChar](repeating: 0, count: 65_536)
                    let status = sample.pcm16LE.withUnsafeBytes { pcm in
                        response.withUnsafeMutableBufferPointer { buffer in
                            cactus_embed_speaker(handle, nil, buffer.baseAddress, buffer.count, nil,
                                pcm.bindMemory(to: UInt8.self).baseAddress, pcm.count, nil, 0)
                        }
                    }
                    try authorize()
                    guard status >= 0, let terminator = response.firstIndex(of: 0) else {
                        throw SpeakerRecognitionError.nativeFailure(Self.lastError())
                    }
                    let data = Data(response[..<terminator].map { UInt8(bitPattern: $0) })
                    let result = try Self.parseResponse(data)
                    continuation.resume(returning: result)
                } catch {
                    // Failed/cancelled work must not keep a possibly poisoned native handle.
                    state.release()
                    continuation.resume(throwing: error)
                }
            }
        }
        #else
        try authorize()
        throw SpeakerRecognitionError.unsupportedPlatform
        #endif
    }

    func release() async {
        #if os(iOS)
        await withCheckedContinuation { continuation in
            Self.queue.async { [state] in
                state.release()
                continuation.resume()
            }
        }
        #endif
    }

    #if os(iOS)
    private static func lastError() -> String {
        cactus_get_last_error().map { String(cString: $0) } ?? "Cactus speaker inference failed"
    }
    #endif

    static func parseResponse(_ data: Data) throws -> NativeSpeakerEmbedding {
        struct Response: Decodable {
            let success: Bool
            let error: String?
            let embedding: [Float]?
            let total_time_ms: Double?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.success, let values = response.embedding else {
            throw SpeakerRecognitionError.nativeFailure(response.error ?? "Missing speaker embedding")
        }
        _ = try SpeakerEmbedding(recipe: CactusSpeakerModel.recipe, values: values)
        if let time = response.total_time_ms, !time.isFinite || time < 0 {
            throw SpeakerRecognitionError.nativeFailure("Invalid inference timing")
        }
        return NativeSpeakerEmbedding(values: values, inferenceMilliseconds: response.total_time_ms)
    }
}
