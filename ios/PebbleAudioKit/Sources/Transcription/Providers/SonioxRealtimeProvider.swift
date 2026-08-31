import Foundation

// Port of `core/transcription/.../SonioxRealtimeProvider.kt`.

/// Real-time (streaming) transcription over the Soniox WebSocket API
/// (`wss://stt-rt.soniox.com/transcribe-websocket`). Sends a config frame, streams raw s16le mono
/// audio as binary frames, and folds the incoming token stream (finalized vs. partial, with
/// per-token speakers) into `StreamingTranscriptUpdate`s. End of audio is signalled with an empty
/// text frame. Foreground-only: a live socket cannot survive iOS suspension.
public final class SonioxRealtimeProvider: StreamingTranscriptionProvider {
    public static let defaultUrl = "wss://stt-rt.soniox.com/transcribe-websocket"
    public static let defaultModel = "stt-rt-v5"

    /// Soniox raw-audio format token for 16-bit signed little-endian PCM.
    /// It is "s16le", NOT "pcm_s16le" — the wrong value makes the server reject the stream and
    /// the live socket fail.
    public static let rawPcmFormat = "s16le"

    public let id = "soniox-realtime"

    private let connector: any WebSocketConnector
    private let apiKey: @Sendable () -> String?
    private let cloudConsent: @Sendable () -> Bool
    private let diarizationEnabled: @Sendable () -> Bool
    private let languageHints: @Sendable () -> [String]
    private let contextText: @Sendable () -> String?
    private let contextTerms: @Sendable () -> [String]
    private let model: @Sendable () -> String
    private let url: String

    public init(
        connector: any WebSocketConnector = URLSessionWebSocketConnector(),
        apiKey: @escaping @Sendable () -> String?,
        cloudConsent: @escaping @Sendable () -> Bool,
        diarizationEnabled: @escaping @Sendable () -> Bool = { false },
        languageHints: @escaping @Sendable () -> [String] = { [] },
        contextText: @escaping @Sendable () -> String? = { nil },
        contextTerms: @escaping @Sendable () -> [String] = { [] },
        model: @escaping @Sendable () -> String = { SonioxRealtimeProvider.defaultModel },
        url: String = SonioxRealtimeProvider.defaultUrl
    ) {
        self.connector = connector
        self.apiKey = apiKey
        self.cloudConsent = cloudConsent
        self.diarizationEnabled = diarizationEnabled
        self.languageHints = languageHints
        self.contextText = contextText
        self.contextTerms = contextTerms
        self.model = model
        self.url = url
    }

    public func isAvailable() async -> Bool {
        cloudConsent() && !(apiKey() ?? "").isBlank
    }

    public func transcribeStream(
        pcm: AsyncThrowingStream<Data, Error>,
        sampleRateHz: Int
    ) -> AsyncThrowingStream<StreamingTranscriptUpdate, Error> {
        AsyncThrowingStream { continuation in
            let session = Task {
                var connection: (any WebSocketConnection)?
                var sender: Task<Void, Never>?
                do {
                    guard self.cloudConsent(), let key = self.apiKey()?.nonBlank else {
                        throw TranscriptionError.providerUnavailable(providerId: self.id)
                    }
                    guard let socketUrl = URL(string: self.url) else {
                        throw TranscriptionError.transcriptionFailed("invalid Soniox URL: \(self.url)")
                    }
                    let socket = self.connector.connect(url: socketUrl, headers: [:])
                    connection = socket
                    try await socket.send(text: self.configJson(key: key, sampleRateHz: sampleRateHz))

                    // Stream audio in the background; signal end-of-audio with an empty text frame.
                    sender = Task {
                        do {
                            for try await chunk in pcm where !chunk.isEmpty {
                                try await socket.send(data: chunk)
                            }
                            try await socket.send(text: "")
                        } catch {
                            // A send failure surfaces through the receive loop when the socket dies.
                        }
                    }

                    let decoder = JSONDecoder()
                    let accumulator = SonioxRealtimeAccumulator(diarization: self.diarizationEnabled())
                    receiveLoop: while true {
                        try Task.checkCancellation()
                        guard case .text(let frame) = try await socket.receive() else { continue }
                        let message = try decoder.decode(RtMessage.self, from: Data(frame.utf8))
                        if let errorMessage = message.errorMessage {
                            throw TranscriptionError.transcriptionFailed(
                                "Soniox realtime error: \(errorMessage)"
                            )
                        }
                        let finished = message.finished ?? false
                        continuation.yield(
                            accumulator.accept(tokens: message.tokens ?? [], finished: finished)
                        )
                        if finished { break receiveLoop }
                    }
                    sender?.cancel()
                    connection?.close()
                    continuation.finish()
                } catch {
                    sender?.cancel()
                    connection?.close()
                    if error is CancellationError || error is WebSocketClosedError {
                        // Socket ended without a protocol error — the KMP flow completes normally.
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in session.cancel() }
        }
    }

    /// The one-shot start-of-stream config frame. Internal for the format regression tests.
    func configJson(key: String, sampleRateHz: Int) -> String {
        var config: [String: Any] = [
            "api_key": key,
            "model": model(),
            "audio_format": Self.rawPcmFormat,
            "sample_rate": sampleRateHz,
            "num_channels": 1,
            "enable_speaker_diarization": diarizationEnabled(),
        ]
        let hints = languageHints()
        if !hints.isEmpty {
            config["language_hints"] = hints
        }
        if let context = buildSonioxContextJsonObject(
            contextText: contextText(), contextTerms: contextTerms()
        ) {
            config["context"] = context
        }
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private struct RtMessage: Decodable {
        var tokens: [SonioxRtToken]?
        var finished: Bool?
        var errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case tokens
            case finished
            case errorMessage = "error_message"
        }
    }
}

/// One realtime token from the Soniox socket.
public struct SonioxRtToken: Sendable, Equatable, Decodable {
    public var text: String
    public var isFinal: Bool
    public var speaker: String?
    public var startMs: Int64?
    public var endMs: Int64?

    public init(
        text: String = "",
        isFinal: Bool = false,
        speaker: String? = nil,
        startMs: Int64? = nil,
        endMs: Int64? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
        self.startMs = startMs
        self.endMs = endMs
    }

    enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
        case speaker
        case startMs = "start_ms"
        case endMs = "end_ms"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
        self.speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        self.startMs = try container.decodeIfPresent(Int64.self, forKey: .startMs)
        self.endMs = try container.decodeIfPresent(Int64.self, forKey: .endMs)
    }
}

/// Pure token-stream folding for Soniox realtime: finalized tokens accumulate into the stable
/// transcript and speaker segments; non-final tokens form the volatile partial tail (replaced
/// each message). Extracted from the socket plumbing so it is unit-testable.
public final class SonioxRealtimeAccumulator {
    private let diarization: Bool
    private var finalTokens: [SonioxRtToken] = []

    public init(diarization: Bool) {
        self.diarization = diarization
    }

    public func accept(tokens: [SonioxRtToken], finished: Bool) -> StreamingTranscriptUpdate {
        var partial = ""
        for token in tokens where !token.text.isEmpty {
            if token.isFinal {
                finalTokens.append(token)
            } else {
                partial += token.text
            }
        }
        return StreamingTranscriptUpdate(
            finalText: finalTokens.map(\.text).joined().trimmed,
            partialText: partial.trimmed,
            segments: diarization ? groupBySpeaker(finalTokens) : [],
            isFinal: finished
        )
    }

    private func groupBySpeaker(_ tokens: [SonioxRtToken]) -> [TranscriptSegment] {
        guard let first = tokens.first else { return [] }
        var segments: [TranscriptSegment] = []
        var current = ""
        var speaker = first.speaker
        var start = first.startMs ?? 0
        var end = first.endMs ?? start

        func flush() {
            let text = current.trimmed
            if !text.isEmpty {
                segments.append(
                    TranscriptSegment(text: text, startMs: start, endMs: max(end, start), speaker: speaker)
                )
            }
            current = ""
        }

        for token in tokens {
            if !current.isEmpty && token.speaker != speaker {
                flush()
                speaker = token.speaker
                start = token.startMs ?? start
            }
            current += token.text
            if let tokenEnd = token.endMs { end = tokenEnd }
        }
        flush()
        return segments
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    fileprivate var isBlank: Bool { trimmed.isEmpty }
    fileprivate var nonBlank: String? { isBlank ? nil : self }
}
