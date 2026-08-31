import AudioCodec
import Foundation

// Port of `core/transcription/.../SonioxTranscriptionProvider.kt`.

/// Cloud transcription provider backed by the Soniox async REST API
/// (`https://api.soniox.com/v1`). A bounded, durable segment is transcribed by:
///
///  1. `POST /v1/files` (multipart) -> file id,
///  2. `POST /v1/transcriptions` (json, references the file) -> transcription id,
///  3. poll `GET /v1/transcriptions/{id}` until `status` is `completed`/`error`,
///  4. `GET /v1/transcriptions/{id}/transcript` -> tokens, then best-effort delete of both.
///
/// The synchronous `transcribe` runs the whole flow (polling included), so it plugs into the
/// processor/router for closed segments with no changes to the local path. Speaker diarization is
/// opt-in (`diarizationEnabled`); per-token speakers are grouped into `TranscriptSegment`s. The
/// detached background-upload variant is the `CloudUploadCapable` conformance below.
public final class SonioxTranscriptionProvider: TranscriptionProvider, CloudUploadCapable {
    public static let providerId = "soniox"
    public static let defaultBaseUrl = "https://api.soniox.com"
    public static let defaultModel = "stt-async-v5"
    public static let defaultPollIntervalMs: Int64 = 2_000
    public static let defaultMaxPollAttempts = 150
    public static let defaultMaxUploadBytes = 100 * 1024 * 1024
    static let segmentGapMs: Int64 = 800
    private static let statusCompleted = "completed"
    private static let statusError = "error"

    public let id = SonioxTranscriptionProvider.providerId

    private let transport: any HttpTransport
    private let apiKey: @Sendable () -> String?
    private let cloudConsent: @Sendable () -> Bool
    private let diarizationEnabled: @Sendable () -> Bool
    private let languageHints: @Sendable () -> [String]
    private let contextText: @Sendable () -> String?
    private let contextTerms: @Sendable () -> [String]
    private let model: @Sendable () -> String
    let baseUrl: String
    private let pollIntervalMs: Int64
    private let maxPollAttempts: Int
    private let maxUploadBytes: Int
    /// Injectable so tests can poll without real delays.
    private let sleep: @Sendable (Int64) async throws -> Void

    public init(
        transport: any HttpTransport,
        apiKey: @escaping @Sendable () -> String?,
        cloudConsent: @escaping @Sendable () -> Bool,
        diarizationEnabled: @escaping @Sendable () -> Bool = { false },
        languageHints: @escaping @Sendable () -> [String] = { [] },
        contextText: @escaping @Sendable () -> String? = { nil },
        contextTerms: @escaping @Sendable () -> [String] = { [] },
        model: @escaping @Sendable () -> String = { SonioxTranscriptionProvider.defaultModel },
        baseUrl: String = SonioxTranscriptionProvider.defaultBaseUrl,
        pollIntervalMs: Int64 = SonioxTranscriptionProvider.defaultPollIntervalMs,
        maxPollAttempts: Int = SonioxTranscriptionProvider.defaultMaxPollAttempts,
        maxUploadBytes: Int = SonioxTranscriptionProvider.defaultMaxUploadBytes,
        sleep: @escaping @Sendable (Int64) async throws -> Void = { ms in
            try await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
        }
    ) {
        self.transport = transport
        self.apiKey = apiKey
        self.cloudConsent = cloudConsent
        self.diarizationEnabled = diarizationEnabled
        self.languageHints = languageHints
        self.contextText = contextText
        self.contextTerms = contextTerms
        self.model = model
        self.baseUrl = baseUrl
        self.pollIntervalMs = pollIntervalMs
        self.maxPollAttempts = maxPollAttempts
        self.maxUploadBytes = maxUploadBytes
        self.sleep = sleep
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
        guard cloudConsent() else { throw TranscriptionError.providerUnavailable(providerId: id) }
        guard let key = apiKey()?.nonBlank else {
            throw TranscriptionError.providerUnavailable(providerId: id)
        }

        let wav = try await encodeWav(pcmChunks: pcmChunks, sampleRateHz: sampleRateHz)

        let fileId = try await uploadFile(key: key, wav: wav)
        do {
            let result = try await transcribeUploadedFile(key: key, fileId: fileId)
            await deleteQuietly(key: key, url: "\(baseUrl)/v1/files/\(fileId)")
            return result
        } catch {
            await deleteQuietly(key: key, url: "\(baseUrl)/v1/files/\(fileId)")
            throw error
        }
    }

    /// Create -> poll -> fetch -> map for an already-uploaded file; always best-effort deletes
    /// the transcription record (the caller owns deleting the file).
    private func transcribeUploadedFile(key: String, fileId: String) async throws -> TranscriptionResult {
        let transcriptionId = try await createTranscription(key: key, fileId: fileId)
        do {
            try await awaitCompletion(key: key, transcriptionId: transcriptionId)
            let transcript = try await fetchTranscript(key: key, transcriptionId: transcriptionId)
            let result = try mapTranscript(transcript)
            await deleteQuietly(key: key, url: "\(baseUrl)/v1/transcriptions/\(transcriptionId)")
            return result
        } catch {
            await deleteQuietly(key: key, url: "\(baseUrl)/v1/transcriptions/\(transcriptionId)")
            throw error
        }
    }

    // MARK: - CloudUploadCapable: background-upload the file, finish the control plane when awake

    public func uploadPlan(wav: Data, sampleRateHz: Int) async -> CloudUploadPlan? {
        guard cloudConsent(), let key = apiKey()?.nonBlank else { return nil }
        if wav.count > maxUploadBytes { return nil }
        return CloudUploadPlan(
            url: "\(baseUrl)/v1/files",
            headers: ["Authorization": "Bearer \(key)"],
            textFields: [],
            file: MultipartBody.FilePart(
                name: "file", filename: "segment.wav", contentType: "audio/wav", bytes: wav
            )
        )
    }

    public func onUploadResponse(httpStatus: Int, body: String) async throws -> CloudUploadStep {
        guard (200..<300).contains(httpStatus) else {
            throw failure(stage: "file upload", status: httpStatus, body: body)
        }
        guard let fileId = try? JSONDecoder().decode(SonioxFile.self, from: Data(body.utf8)).id else {
            throw TranscriptionError.transcriptionFailed("Soniox upload returned no file id")
        }
        return .needsControlPlane(fileId)
    }

    public func completeControlPlane(controlState: String) async throws -> TranscriptionResult {
        guard let key = apiKey()?.nonBlank else {
            throw TranscriptionError.providerUnavailable(providerId: id)
        }
        do {
            let result = try await transcribeUploadedFile(key: key, fileId: controlState)
            await deleteQuietly(key: key, url: "\(baseUrl)/v1/files/\(controlState)")
            return result
        } catch {
            await deleteQuietly(key: key, url: "\(baseUrl)/v1/files/\(controlState)")
            throw error
        }
    }

    // MARK: - Flow steps

    private func encodeWav(
        pcmChunks: AsyncThrowingStream<Data, Error>,
        sampleRateHz: Int
    ) async throws -> Data {
        var pcm = Data()
        for try await chunk in pcmChunks where !chunk.isEmpty {
            if pcm.count + chunk.count > maxUploadBytes {
                throw TranscriptionError.transcriptionFailed(
                    "segment audio exceeds \(maxUploadBytes) byte Soniox upload limit"
                )
            }
            pcm.append(chunk)
        }
        if pcm.isEmpty {
            throw TranscriptionError.noSpeechDetected("empty audio for Soniox upload")
        }
        return PcmWav.encodeMono16(pcm: pcm, sampleRateHz: sampleRateHz)
    }

    private func uploadFile(key: String, wav: Data) async throws -> String {
        let boundary = "PebbleAudioKit-\(UUID().uuidString)"
        let (body, contentType) = MultipartBody.encode(
            boundary: boundary,
            textFields: [],
            file: MultipartBody.FilePart(
                name: "file", filename: "segment.wav", contentType: "audio/wav", bytes: wav
            )
        )
        let response = try await transport.execute(
            HttpTransportRequest(
                method: "POST",
                url: "\(baseUrl)/v1/files",
                headers: [
                    "Authorization": "Bearer \(key)",
                    "Content-Type": contentType,
                ],
                body: body
            )
        )
        guard response.isSuccess else {
            throw failure(stage: "file upload", status: response.status, body: response.text)
        }
        guard let id = try? JSONDecoder().decode(SonioxFile.self, from: response.body).id else {
            throw TranscriptionError.transcriptionFailed("Soniox upload returned no file id")
        }
        return id
    }

    private func createTranscription(key: String, fileId: String) async throws -> String {
        let request = CreateTranscription(
            model: model(),
            fileId: fileId,
            enableSpeakerDiarization: diarizationEnabled(),
            languageHints: languageHints().isEmpty ? nil : languageHints(),
            context: sonioxContextFrom(contextText: contextText, contextTerms: contextTerms)
        )
        let body = try JSONEncoder().encode(request)
        let response = try await transport.execute(
            HttpTransportRequest(
                method: "POST",
                url: "\(baseUrl)/v1/transcriptions",
                headers: [
                    "Authorization": "Bearer \(key)",
                    "Content-Type": "application/json",
                ],
                body: body
            )
        )
        guard response.isSuccess else {
            throw failure(stage: "create transcription", status: response.status, body: response.text)
        }
        guard let id = try? JSONDecoder().decode(SonioxTranscriptionMeta.self, from: response.body).id
        else {
            throw TranscriptionError.transcriptionFailed("Soniox create returned no id")
        }
        return id
    }

    private func awaitCompletion(key: String, transcriptionId: String) async throws {
        for attempt in 0..<maxPollAttempts {
            let response = try await transport.execute(
                HttpTransportRequest(
                    method: "GET",
                    url: "\(baseUrl)/v1/transcriptions/\(transcriptionId)",
                    headers: ["Authorization": "Bearer \(key)"]
                )
            )
            guard response.isSuccess else {
                throw failure(stage: "poll", status: response.status, body: response.text)
            }
            let meta = try JSONDecoder().decode(SonioxTranscriptionMeta.self, from: response.body)
            switch meta.status {
            case Self.statusCompleted:
                return
            case Self.statusError:
                throw TranscriptionError.transcriptionFailed(
                    "Soniox transcription error: \(meta.errorMessage ?? "unknown")"
                )
            default:
                if attempt < maxPollAttempts - 1 { try await sleep(pollIntervalMs) }
            }
        }
        throw TranscriptionError.transcriptionFailed("Soniox transcription timed out")
    }

    private func fetchTranscript(key: String, transcriptionId: String) async throws -> SonioxTranscript {
        let response = try await transport.execute(
            HttpTransportRequest(
                method: "GET",
                url: "\(baseUrl)/v1/transcriptions/\(transcriptionId)/transcript",
                headers: ["Authorization": "Bearer \(key)"]
            )
        )
        guard response.isSuccess else {
            throw failure(stage: "fetch transcript", status: response.status, body: response.text)
        }
        return try JSONDecoder().decode(SonioxTranscript.self, from: response.body)
    }

    private func mapTranscript(_ transcript: SonioxTranscript) throws -> TranscriptionResult {
        let spokenTokens = (transcript.tokens ?? []).filter {
            $0.isAudioEvent != true && !($0.text ?? "").isBlank
        }
        let text = transcript.text?.trimmed.nonBlank
            ?? spokenTokens.map { $0.text ?? "" }.joined().trimmed
        if text.isBlank {
            throw TranscriptionError.noSpeechDetected("Soniox returned no speech")
        }
        return TranscriptionResult(
            text: text,
            providerId: id,
            modelUsed: model(),
            segments: groupIntoSegments(spokenTokens),
            words: spokenTokens.compactMap { token in
                let cleaned = (token.text ?? "").trimmed
                if cleaned.isEmpty { return nil }
                let startMs = token.startMs ?? 0
                return TranscriptWord(
                    text: cleaned,
                    startMs: startMs,
                    endMs: max(token.endMs ?? 0, startMs)
                )
            }
        )
    }

    /// Groups consecutive tokens into segments, breaking on a speaker change or a silence gap.
    private func groupIntoSegments(_ tokens: [SonioxBatchToken]) -> [TranscriptSegment] {
        guard let first = tokens.first else { return [] }
        var segments: [TranscriptSegment] = []
        var current = ""
        var start = first.startMs ?? 0
        var end = first.endMs ?? 0
        var speaker = first.speaker
        var prevEnd = first.startMs ?? 0

        func flush() {
            let cleaned = current.trimmed
            if !cleaned.isEmpty {
                segments.append(
                    TranscriptSegment(
                        text: cleaned, startMs: start, endMs: max(end, start), speaker: speaker
                    )
                )
            }
            current = ""
        }

        for token in tokens {
            let tokenStart = token.startMs ?? 0
            let speakerChanged = token.speaker != speaker
            let longGap = tokenStart - prevEnd > Self.segmentGapMs
            if !current.isEmpty && (speakerChanged || longGap) {
                flush()
                start = tokenStart
                speaker = token.speaker
            }
            current += token.text ?? ""
            end = token.endMs ?? 0
            prevEnd = token.endMs ?? 0
        }
        flush()
        return segments
    }

    /// Best-effort cleanup; leaving a file/transcription behind is not worth failing over.
    private func deleteQuietly(key: String, url: String) async {
        _ = try? await transport.execute(
            HttpTransportRequest(
                method: "DELETE", url: url, headers: ["Authorization": "Bearer \(key)"]
            )
        )
    }

    private func failure(stage: String, status: Int, body: String) -> TranscriptionError {
        .transcriptionFailed("Soniox \(stage) failed (\(status)): \(body.prefix(240))")
    }

    // MARK: - Wire shapes

    private struct SonioxFile: Decodable {
        var id: String?
    }

    private struct CreateTranscription: Encodable {
        var model: String
        var fileId: String
        var enableSpeakerDiarization: Bool
        var languageHints: [String]?
        var context: SonioxContext?

        enum CodingKeys: String, CodingKey {
            case model
            case fileId = "file_id"
            case enableSpeakerDiarization = "enable_speaker_diarization"
            case languageHints = "language_hints"
            case context
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(fileId, forKey: .fileId)
            // kotlinx.serialization omits default values: false is the default, so only encode
            // the flag when diarization is on (keeps the wire body byte-compatible).
            if enableSpeakerDiarization {
                try container.encode(true, forKey: .enableSpeakerDiarization)
            }
            try container.encodeIfPresent(languageHints, forKey: .languageHints)
            try container.encodeIfPresent(context, forKey: .context)
        }
    }

    private struct SonioxTranscriptionMeta: Decodable {
        var id: String?
        var status: String?
        var errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case id
            case status
            case errorMessage = "error_message"
        }
    }

    struct SonioxTranscript: Decodable {
        var text: String?
        var tokens: [SonioxBatchToken]?
    }

    struct SonioxBatchToken: Decodable {
        var text: String?
        var startMs: Int64?
        var endMs: Int64?
        var speaker: String?
        var isAudioEvent: Bool?

        enum CodingKeys: String, CodingKey {
            case text
            case startMs = "start_ms"
            case endMs = "end_ms"
            case speaker
            case isAudioEvent = "is_audio_event"
        }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    fileprivate var isBlank: Bool { trimmed.isEmpty }
    fileprivate var nonBlank: String? { isBlank ? nil : self }
}
