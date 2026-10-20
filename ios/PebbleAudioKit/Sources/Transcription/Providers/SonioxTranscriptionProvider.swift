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

    /// Containers this provider will be offered, best first.
    ///
    /// Ogg Speex is the watch's own frames repackaged — 4.08% of the WAV, no decode, no re-encode
    /// (`OggSpeex`). Soniox lists `ogg` among the formats it "automatically detects" and says
    /// nothing about codecs (https://soniox.com/docs/stt/async/async-transcription), so this is an
    /// educated bet on the docs alone — so it was settled by measurement against the production
    /// endpoint instead (2026-09-08). See `CloudUploadFormats.passthrough` for that evidence and
    /// for why this is a constant rather than something the app renegotiates at runtime.
    public static let uploadFormat: CloudAudioFormat = CloudUploadFormats.passthrough

    public var uploadFormat: CloudAudioFormat { Self.uploadFormat }

    /// The container for the synchronous path, which is handed decoded PCM and so cannot package
    /// the watch's frames.
    public static let pcmFormat: CloudAudioFormat = CloudUploadFormats.fromPcm

    /// This backend's identity in stored rows and diagnostics.
    public static let cloudProvider: CloudProvider = .soniox

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
    /// What the app has learned about which containers Soniox will read. Consulted by the
    /// SYNCHRONOUS path here (the background path is driven by the coordinator, which owns the
    /// same store), and written to when this path is the one that discovers a rejection.
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

        let pcm = try await collectPcm(pcmChunks: pcmChunks)

        // This path receives DECODED PCM, so passthrough is not available to it: it sends FLAC,
        // which Soniox documents.
        let audio = CloudAudioBody.encode(
            pcm: pcm, sampleRateHz: sampleRateHz, format: Self.pcmFormat)
        let fileId = try await uploadFile(key: key, audio: audio)
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

    public func uploadPlan(audio: CloudAudioBody, sampleRateHz: Int) async -> CloudUploadPlan? {
        guard cloudConsent(), let key = apiKey()?.nonBlank else { return nil }
        // Size-checked on the bytes that actually go on the wire, not on the PCM they came from.
        // Deliberately more permissive than the old `wav.count > maxUploadBytes`: a passthrough
        // body is 4% of the WAV and a FLAC one ~37%, so segments that used to be rejected here —
        // and then sat `Pending` forever, see the note on
        // `BackgroundCloudUploadCoordinator.submitPending` — now fit with room to spare.
        if audio.bytes.count > maxUploadBytes { return nil }
        return CloudUploadPlan(
            url: "\(baseUrl)/v1/files",
            headers: ["Authorization": "Bearer \(key)"],
            textFields: [],
            file: MultipartBody.FilePart(
                name: "file",
                filename: audio.filename("segment"),
                contentType: audio.contentType,
                bytes: audio.bytes
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

    private func collectPcm(pcmChunks: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var pcm = Data()
        for try await chunk in pcmChunks where !chunk.isEmpty {
            // Bounds the PCM held in memory, which is what this guard was always really about;
            // the encoded body is smaller than the PCM in every format we send.
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
        return pcm
    }

    private func uploadFile(key: String, audio: CloudAudioBody) async throws -> String {
        let boundary = "PebbleAudioKit-\(UUID().uuidString)"
        let (body, contentType) = MultipartBody.encode(
            boundary: boundary,
            textFields: [],
            file: MultipartBody.FilePart(
                name: "file",
                filename: audio.filename("segment"),
                contentType: audio.contentType,
                bytes: audio.bytes
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
                body: body,
                carriesAudio: true
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
                // Soniox stores the file first and transcodes it here, so a container it cannot
                // read surfaces as a transcription-level error with no status of its own. Carried
                // structurally (`httpStatus: 0`) so the format classifier can read the wording
                // rather than the upload coordinator re-parsing a rendered sentence.
                throw TranscriptionError.transcriptionFailed(
                    "Soniox transcription error: \(meta.errorMessage ?? "unknown")",
                    underlying: CloudFormatComplaint(
                        httpStatus: 0, evidence: meta.errorMessage ?? "")
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

    func mapTranscript(_ transcript: SonioxTranscript) throws -> TranscriptionResult {
        // EVERY token, whitespace included. Soniox sends some spaces as tokens of their own —
        // most often the one after a comma (", right") and between words of a script it does
        // not separate itself — and this used to drop every blank token before grouping, which
        // glued the next word onto the one before it in 765 of the 1,176 transcripts of a real
        // backup (5,140 joins), while Soniox's own `text` kept them. `groupIntoSegments` keeps
        // the space and lets nothing else about a blank token count.
        let tokens = (transcript.tokens ?? []).filter { !($0.text ?? "").isEmpty }
        let spokenTokens = tokens.filter { $0.isAudioEvent != true && !($0.text ?? "").isBlank }
        let text = transcript.text?.trimmed.nonBlank
            ?? Self.joinedText(tokens).trimmed
        if text.isBlank {
            throw TranscriptionError.noSpeechDetected("Soniox returned no speech")
        }
        return TranscriptionResult(
            text: text,
            providerId: id,
            modelUsed: model(),
            segments: groupIntoSegments(tokens),
            // Words stay the spoken tokens: the transcript's word aligner walks letters, not
            // spaces, so the spacing above moves no highlight.
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

    /// A token that is a word (or part of one): not blank, not an audio event.
    static func isSpoken(_ token: SonioxBatchToken) -> Bool {
        token.isAudioEvent != true && !(token.text ?? "").isBlank
    }

    /// What a token adds to the text: its own text, or for an audio event only the space
    /// around it, so leaving the event out cannot join the words either side of it.
    static func spokenText(_ token: SonioxBatchToken) -> String {
        let text = token.text ?? ""
        guard token.isAudioEvent == true else { return text }
        return text.contains(where: \.isWhitespace) ? " " : ""
    }

    static func joinedText(_ tokens: [SonioxBatchToken]) -> String {
        tokens.map(spokenText).joined()
    }

    /// Groups consecutive tokens into segments, breaking on a speaker change or a silence gap.
    /// Internal rather than private so the per-turn confidence summary can be asserted directly
    /// against a real response body, without standing up the four-request control plane.
    ///
    /// Takes every token. Only spoken ones decide a segment's speaker, timing, boundaries and
    /// confidence; a blank token or an audio event adds its space to the segment it falls in
    /// and nothing else.
    func groupIntoSegments(_ tokens: [SonioxBatchToken]) -> [TranscriptSegment] {
        guard let first = tokens.first(where: Self.isSpoken) else { return [] }
        var segments: [TranscriptSegment] = []
        var current = ""
        var start = first.startMs ?? 0
        var end = first.endMs ?? 0
        var speaker = first.speaker
        var prevEnd = first.startMs ?? 0
        var confidences: [Double] = []

        func flush() {
            let cleaned = current.trimmed
            if !cleaned.isEmpty {
                let summary = TokenConfidence.summary(confidences)
                segments.append(
                    TranscriptSegment(
                        text: cleaned,
                        startMs: start,
                        endMs: max(end, start),
                        speaker: speaker,
                        confidence: summary.mean,
                        minConfidence: summary.min
                    )
                )
            }
            current = ""
            confidences.removeAll(keepingCapacity: true)
        }

        for token in tokens {
            guard Self.isSpoken(token) else {
                // A segment's leading and trailing space is trimmed anyway.
                if !current.isEmpty { current += Self.spokenText(token) }
                continue
            }
            let tokenStart = token.startMs ?? 0
            let speakerChanged = token.speaker != speaker
            let longGap = tokenStart - prevEnd > Self.segmentGapMs
            if !current.isEmpty && (speakerChanged || longGap) {
                flush()
                start = tokenStart
                speaker = token.speaker
            }
            current += token.text ?? ""
            if let confidence = token.confidence { confidences.append(confidence) }
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

    /// Every failed Soniox response, with its status and body preserved as a
    /// `CloudFormatComplaint` alongside the rendered message. The message is what the user's
    /// diagnostics show; the complaint carries the status and body structurally, so the upload
    /// coordinator never has to parse a sentence to find a status.
    private func failure(stage: String, status: Int, body: String) -> TranscriptionError {
        .transcriptionFailed(
            "Soniox \(stage) failed (\(status)): \(body.prefix(240))",
            underlying: CloudFormatComplaint(httpStatus: status, evidence: body))
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
        /// Soniox's own 0…1 confidence for this token. It has been in every response body all
        /// along — the reference response for
        /// `GET /v1/transcriptions/{id}/transcript` shows it — and this decoder simply had no key
        /// for it, so `JSONDecoder` dropped it silently from 585 transcripts. See the note on
        /// `TranscriptSegment.confidence` for why it is collected and not yet used.
        var confidence: Double?

        enum CodingKeys: String, CodingKey {
            case text
            case startMs = "start_ms"
            case endMs = "end_ms"
            case speaker
            case isAudioEvent = "is_audio_event"
            case confidence
        }
    }
}

/// Per-turn summary of a provider's per-token confidences.
///
/// Shared by the async and realtime Soniox paths so the two cannot describe the same number
/// differently. Rounded to four decimals: that is far finer than any distribution question this
/// is meant to answer, and it keeps the stored JSON free of `0.9500000000000001`.
enum TokenConfidence {
    static func summary(_ values: [Double]) -> (mean: Double?, min: Double?) {
        guard !values.isEmpty else { return (nil, nil) }
        let mean = values.reduce(0, +) / Double(values.count)
        return (round4(mean), round4(values.min() ?? mean))
    }

    private static func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    fileprivate var isBlank: Bool { trimmed.isEmpty }
    fileprivate var nonBlank: String? { isBlank ? nil : self }
}
