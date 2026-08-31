import AudioCodec
import Foundation

// Port of `core/transcription/.../OpenAiTranscriptionProvider.kt`.

/// Cloud transcription provider for bounded, durable segment chunks.
///
/// Uses OpenAI's Audio API `transcriptions` endpoint. PCM is uploaded only when the current
/// transcription mode can use cloud transcription and an API key is configured. Keys arrive via
/// the injected closure (Keychain lookups live in the app layer — never read from disk here).
public final class OpenAiTranscriptionProvider: TranscriptionProvider, CloudUploadCapable {
    public static let defaultEndpointUrl = "https://api.openai.com/v1/audio/transcriptions"
    public static let defaultModelsUrl = "https://api.openai.com/v1/models"
    public static let defaultModel = "gpt-transcribe"

    /// OpenAI's speaker-diarization model; returns `diarized_json` with per-segment speakers.
    public static let diarizeModel = "gpt-4o-transcribe-diarize"

    static let wavHeaderBytes = 44
    public static let defaultMaxUploadBytes = 24_000_000
    private static let bytesPerSample = 2

    public let id = "openai"

    private let transport: any HttpTransport
    private let apiKey: @Sendable () -> String?
    private let cloudConsent: @Sendable () -> Bool
    private let model: @Sendable () -> String
    /// When true, transcription is routed through the diarization model (`diarizeModel`,
    /// `diarized_json`) so segments carry a `speaker`. This overrides `model`, since only the
    /// diarize model returns speaker labels. The tradeoff is no word-level timings.
    private let diarizationEnabled: @Sendable () -> Bool
    /// Bounded keyword list for STT steering; ignored for diarize models.
    private let sttPrompt: @Sendable () -> String?
    let endpointUrl: String
    let modelsUrl: String
    private let maxUploadBytes: Int

    public init(
        transport: any HttpTransport,
        apiKey: @escaping @Sendable () -> String?,
        cloudConsent: @escaping @Sendable () -> Bool,
        model: @escaping @Sendable () -> String = { OpenAiTranscriptionProvider.defaultModel },
        diarizationEnabled: @escaping @Sendable () -> Bool = { false },
        sttPrompt: @escaping @Sendable () -> String? = { nil },
        endpointUrl: String = OpenAiTranscriptionProvider.defaultEndpointUrl,
        modelsUrl: String = OpenAiTranscriptionProvider.defaultModelsUrl,
        maxUploadBytes: Int = OpenAiTranscriptionProvider.defaultMaxUploadBytes
    ) {
        precondition(
            maxUploadBytes > Self.wavHeaderBytes,
            "maxUploadBytes must leave room for a WAV header"
        )
        self.transport = transport
        self.apiKey = apiKey
        self.cloudConsent = cloudConsent
        self.model = model
        self.diarizationEnabled = diarizationEnabled
        self.sttPrompt = sttPrompt
        self.endpointUrl = endpointUrl
        self.modelsUrl = modelsUrl
        self.maxUploadBytes = maxUploadBytes
    }

    public func isAvailable() async -> Bool {
        cloudConsent() && !(apiKey() ?? "").isBlank
    }

    // Connectivity-probe seam (see CloudConnectivityChecks.swift).
    var connectivityTransport: any HttpTransport { transport }
    var connectivityApiKey: String? { apiKey() }

    public func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>,
        sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        guard cloudConsent() else {
            throw TranscriptionError.providerUnavailable(providerId: id)
        }
        guard let key = apiKey()?.nonBlank else {
            throw TranscriptionError.providerUnavailable(providerId: id)
        }

        var transcripts: [ChunkResult] = []
        var chunkIndex = 0
        var chunkStartMs: Int64 = 0
        let pcmUploadLimit = maxUploadBytes - Self.wavHeaderBytes
        var buffer = Data()

        for try await chunk in pcmChunks {
            var offset = 0
            while offset < chunk.count {
                let writable = min(pcmUploadLimit - buffer.count, chunk.count - offset)
                if writable <= 0 {
                    let pcm = buffer
                    buffer = Data()
                    transcripts.append(
                        try await uploadChunk(
                            key: key,
                            pcm: pcm,
                            sampleRateHz: sampleRateHz,
                            chunkIndex: chunkIndex,
                            chunkStartMs: chunkStartMs
                        )
                    )
                    chunkIndex += 1
                    chunkStartMs += Self.durationMs(byteCount: pcm.count, sampleRateHz: sampleRateHz)
                    continue
                }
                let start = chunk.startIndex + offset
                buffer.append(chunk[start..<(start + writable)])
                offset += writable
            }
        }
        if !buffer.isEmpty {
            transcripts.append(
                try await uploadChunk(
                    key: key,
                    pcm: buffer,
                    sampleRateHz: sampleRateHz,
                    chunkIndex: chunkIndex,
                    chunkStartMs: chunkStartMs
                )
            )
        }

        let text = transcripts.map(\.text).joined(separator: "\n").trimmed
        if text.isEmpty {
            throw TranscriptionError.noSpeechDetected("OpenAI returned an empty transcript")
        }
        return TranscriptionResult(
            text: text,
            providerId: id,
            modelUsed: effectiveModel(),
            segments: transcripts.flatMap(\.segments),
            words: transcripts.flatMap(\.words)
        )
    }

    /// The diarize model takes precedence when diarization is on; only it returns speakers.
    func effectiveModel() -> String {
        diarizationEnabled() ? Self.diarizeModel : model()
    }

    private func sttPrompt(forModel modelValue: String) -> String? {
        if modelValue.lowercased().contains("diarize") { return nil }
        return sttPrompt()?.trimmed.nonBlank
    }

    private func responseFormat(model: String) -> String {
        switch model {
        case Self.diarizeModel: return "diarized_json"
        case "whisper-1": return "verbose_json"
        default: return "json"
        }
    }

    private func uploadChunk(
        key: String,
        pcm: Data,
        sampleRateHz: Int,
        chunkIndex: Int,
        chunkStartMs: Int64
    ) async throws -> ChunkResult {
        if pcm.isEmpty {
            throw TranscriptionError.noSpeechDetected("empty PCM chunk")
        }
        let wav = PcmWav.encodeMono16(pcm: pcm, sampleRateHz: sampleRateHz)
        if wav.count > maxUploadBytes {
            throw TranscriptionError.transcriptionFailed(
                "WAV upload chunk \(wav.count) exceeds \(maxUploadBytes) byte limit"
            )
        }
        let (fields, filePart) = requestParts(wav: wav, filename: "segment-\(chunkIndex).wav")
        let boundary = "PebbleAudioKit-\(UUID().uuidString)"
        let (body, contentType) = MultipartBody.encode(
            boundary: boundary, textFields: fields, file: filePart
        )
        let response = try await transport.execute(
            HttpTransportRequest(
                method: "POST",
                url: endpointUrl,
                headers: [
                    "Authorization": "Bearer \(key)",
                    "Content-Type": contentType,
                ],
                body: body
            )
        )
        if response.status != 200 {
            throw TranscriptionError.transcriptionFailed(
                "OpenAI transcription failed (\(response.status)): \(response.text.prefix(240))"
            )
        }
        return try parseChunk(body: response.body, offsetMs: chunkStartMs)
    }

    /// The multipart text fields + file part shared by the synchronous path and `uploadPlan`.
    private func requestParts(
        wav: Data,
        filename: String
    ) -> (fields: [(String, String)], file: MultipartBody.FilePart) {
        let modelValue = effectiveModel()
        let format = responseFormat(model: modelValue)
        var fields: [(String, String)] = [
            ("model", modelValue),
            ("response_format", format),
        ]
        if format == "verbose_json" {
            fields.append(("timestamp_granularities[]", "segment"))
            fields.append(("timestamp_granularities[]", "word"))
        }
        if let prompt = sttPrompt(forModel: modelValue) {
            fields.append(("prompt", prompt))
        }
        let file = MultipartBody.FilePart(
            name: "file", filename: filename, contentType: "audio/wav", bytes: wav
        )
        return (fields, file)
    }

    private func parseChunk(body: Data, offsetMs: Int64) throws -> ChunkResult {
        let decoder = JSONDecoder()
        switch responseFormat(model: effectiveModel()) {
        case "verbose_json":
            return try decoder.decode(VerboseResponse.self, from: body).toChunkResult(offsetMs: offsetMs)
        case "diarized_json":
            return try decoder.decode(DiarizedResponse.self, from: body).toChunkResult(offsetMs: offsetMs)
        default:
            let plain = try decoder.decode(PlainResponse.self, from: body)
            return ChunkResult(text: plain.text ?? "")
        }
    }

    // MARK: - CloudUploadCapable: single-shot background upload (the response IS the transcript)

    public func uploadPlan(wav: Data, sampleRateHz: Int) async -> CloudUploadPlan? {
        guard cloudConsent(), let key = apiKey()?.nonBlank else { return nil }
        // One background upload is a single request; segments larger than the API limit stay on
        // the synchronous chunked path.
        if wav.count > maxUploadBytes { return nil }
        let (fields, filePart) = requestParts(wav: wav, filename: "segment.wav")
        return CloudUploadPlan(
            url: endpointUrl,
            headers: ["Authorization": "Bearer \(key)"],
            textFields: fields,
            file: filePart
        )
    }

    public func onUploadResponse(httpStatus: Int, body: String) async throws -> CloudUploadStep {
        guard (200..<300).contains(httpStatus) else {
            throw TranscriptionError.transcriptionFailed(
                "OpenAI transcription failed (\(httpStatus)): \(body.prefix(240))"
            )
        }
        let chunk = try parseChunk(body: Data(body.utf8), offsetMs: 0)
        let text = chunk.text.trimmed
        if text.isEmpty {
            throw TranscriptionError.noSpeechDetected("OpenAI returned an empty transcript")
        }
        return .done(
            TranscriptionResult(
                text: text,
                providerId: id,
                modelUsed: effectiveModel(),
                segments: chunk.segments,
                words: chunk.words
            )
        )
    }

    public func completeControlPlane(controlState: String) async throws -> TranscriptionResult {
        throw TranscriptionError.transcriptionFailed("OpenAI uploads have no control-plane step")
    }

    // MARK: - Response shapes

    private struct PlainResponse: Decodable {
        var text: String?
    }

    private struct VerboseResponse: Decodable {
        var text: String?
        var segments: [TimedText]?
        var words: [TimedWord]?

        func toChunkResult(offsetMs: Int64) -> ChunkResult {
            ChunkResult(
                text: text ?? "",
                segments: (segments ?? []).compactMap { segment in
                    let cleaned = (segment.text ?? "").trimmed
                    if cleaned.isEmpty { return nil }
                    return TranscriptSegment(
                        text: cleaned,
                        startMs: offsetMs + msFromSeconds(segment.start ?? 0),
                        endMs: offsetMs + msFromSeconds(segment.end ?? 0)
                    )
                },
                words: (words ?? []).compactMap { word in
                    let cleaned = (word.word ?? "").trimmed
                    if cleaned.isEmpty { return nil }
                    return TranscriptWord(
                        text: cleaned,
                        startMs: offsetMs + msFromSeconds(word.start ?? 0),
                        endMs: offsetMs + msFromSeconds(word.end ?? 0)
                    )
                }
            )
        }
    }

    private struct DiarizedResponse: Decodable {
        var text: String?
        var segments: [DiarizedSegment]?

        func toChunkResult(offsetMs: Int64) -> ChunkResult {
            ChunkResult(
                text: text ?? "",
                segments: (segments ?? []).compactMap { segment in
                    let cleaned = (segment.text ?? "").trimmed
                    if cleaned.isEmpty { return nil }
                    return TranscriptSegment(
                        text: cleaned,
                        startMs: offsetMs + msFromSeconds(segment.start ?? 0),
                        endMs: offsetMs + msFromSeconds(segment.end ?? 0),
                        speaker: segment.speaker
                    )
                }
            )
        }
    }

    private struct DiarizedSegment: Decodable {
        var text: String?
        var start: Double?
        var end: Double?
        var speaker: String?
    }

    private struct TimedText: Decodable {
        var text: String?
        var start: Double?
        var end: Double?
    }

    private struct TimedWord: Decodable {
        var word: String?
        var start: Double?
        var end: Double?
    }

    private struct ChunkResult {
        var text: String
        var segments: [TranscriptSegment] = []
        var words: [TranscriptWord] = []
    }

    private static func durationMs(byteCount: Int, sampleRateHz: Int) -> Int64 {
        Int64(
            (Double(byteCount) / Double(bytesPerSample) / Double(sampleRateHz) * 1_000)
                .rounded(.toNearestOrAwayFromZero)
        )
    }
}

/// Seconds-to-milliseconds with Kotlin `roundToLong` semantics (round-half-up for the positive
/// timestamps these APIs produce).
private func msFromSeconds(_ seconds: Double) -> Int64 {
    Int64((seconds * 1_000).rounded(.toNearestOrAwayFromZero))
}

// Kotlin isBlank/isNotBlank analogues (fileprivate to stay collision-free within the module).
extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    fileprivate var isBlank: Bool { trimmed.isEmpty }
    /// Self when non-blank, else nil (`takeIf { it.isNotBlank() }`).
    fileprivate var nonBlank: String? { isBlank ? nil : self }
}
