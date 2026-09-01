import Foundation

// Port of `core/transcription/.../SonioxRealtimeProvider.kt`.

/// Real-time (streaming) transcription over the Soniox WebSocket API
/// (`wss://stt-rt.soniox.com/transcribe-websocket`). Sends a config frame, streams raw s16le mono
/// audio as binary frames, and folds the incoming token stream (finalized vs. partial, with
/// per-token speakers) into `StreamingTranscriptUpdate`s. End of audio is signalled with an empty
/// text frame, and a keepalive holds the socket open through the silences the watch's
/// voice-activity gate produces (see `keepaliveMessage`). A live socket still cannot survive iOS
/// suspending the process; that loss surfaces as `WebSocketDroppedError` for the caller to
/// reconnect through.
public final class SonioxRealtimeProvider: StreamingTranscriptionProvider {
    public static let defaultUrl = "wss://stt-rt.soniox.com/transcribe-websocket"
    public static let defaultModel = "stt-rt-v5"

    /// Soniox raw-audio format token for 16-bit signed little-endian PCM.
    /// It is "s16le", NOT "pcm_s16le" — the wrong value makes the server reject the stream and
    /// the live socket fail.
    public static let rawPcmFormat = "s16le"

    /// Soniox closes a realtime socket that has received neither audio nor a keepalive for more
    /// than 20 seconds, answering `{"error_code": 408, "error_message": "Request timeout."}`.
    ///
    /// That is a problem for THIS product specifically: our audio is voice-activity gated, so a
    /// quiet room sends nothing at all, and a recording routinely contains stretches of minutes
    /// with no frames. Without a keepalive the socket does not survive an ordinary pause in the
    /// conversation — the timeout is not a network fault, it is the protocol working as designed
    /// against a source that is legitimately silent.
    public static let keepaliveMessage = #"{"type":"keepalive"}"#

    /// How often the keepalive ticker checks in. Soniox suggests 5–10 s against its 20 s
    /// deadline; at 5 s the worst case (audio arriving just after a tick) still leaves ~10 s of
    /// margin, so a single dropped or delayed frame cannot cost us the socket.
    public static let keepaliveIntervalMs: UInt64 = 5_000

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
    private let keepaliveIntervalMs: UInt64

    public init(
        connector: any WebSocketConnector = URLSessionWebSocketConnector(),
        apiKey: @escaping @Sendable () -> String?,
        cloudConsent: @escaping @Sendable () -> Bool,
        diarizationEnabled: @escaping @Sendable () -> Bool = { false },
        languageHints: @escaping @Sendable () -> [String] = { [] },
        contextText: @escaping @Sendable () -> String? = { nil },
        contextTerms: @escaping @Sendable () -> [String] = { [] },
        model: @escaping @Sendable () -> String = { SonioxRealtimeProvider.defaultModel },
        url: String = SonioxRealtimeProvider.defaultUrl,
        keepaliveIntervalMs: UInt64 = SonioxRealtimeProvider.keepaliveIntervalMs
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
        self.keepaliveIntervalMs = keepaliveIntervalMs
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
                var keepalive: Task<Void, Never>?
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
                    let activity = SonioxSendActivity()
                    sender = Task {
                        do {
                            for try await chunk in pcm where !chunk.isEmpty {
                                try await socket.send(data: chunk)
                                activity.noteAudioSent()
                            }
                            activity.noteEndOfAudio()
                            try await socket.send(text: "")
                        } catch {
                            // A send failure surfaces through the receive loop when the socket dies.
                            activity.noteEndOfAudio()
                        }
                    }

                    // Hold the socket open across silences the watch did not send us. Only fires
                    // when a whole tick passed with no audio, so a talking user costs nothing
                    // extra, and stops at end-of-audio so it never races the final flush.
                    let tickMs = self.keepaliveIntervalMs
                    keepalive = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: tickMs * 1_000_000)
                            if Task.isCancelled || !activity.shouldSendKeepalive() { continue }
                            try? await socket.send(text: Self.keepaliveMessage)
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
                                Self.realtimeErrorText(code: message.errorCode, text: errorMessage)
                            )
                        }
                        let finished = message.finished ?? false
                        continuation.yield(
                            accumulator.accept(tokens: message.tokens ?? [], finished: finished)
                        )
                        if finished { break receiveLoop }
                    }
                    keepalive?.cancel()
                    sender?.cancel()
                    connection?.close()
                    continuation.finish()
                } catch {
                    keepalive?.cancel()
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

    /// Renders a server-reported realtime error so the shared failure vocabulary can read it.
    ///
    /// Soniox sends an HTTP-shaped `error_code` beside its prose (408 request timeout, 401 bad
    /// key, 402 out of credit, 429 throttled, 413 stream too long). Putting it in parentheses is
    /// not cosmetic: `TranscriptionFailureKind.httpStatus(in:)` looks for exactly that shape, so
    /// "(408)" is what turns "Request timeout." into `.timedOut` — and therefore into the app's
    /// own sentence — instead of the generic `.providerTrouble` the bare prose would land on.
    static func realtimeErrorText(code: Int?, text: String) -> String {
        guard let code, (100...599).contains(code) else {
            return "Soniox realtime error: \(text)"
        }
        return "Soniox realtime error (\(code)): \(text)"
    }

    /// Test hook: decode one server frame and render its error exactly as the receive loop does.
    static func errorTextForTesting(json: String) throws -> String {
        let message = try JSONDecoder().decode(RtMessage.self, from: Data(json.utf8))
        return realtimeErrorText(code: message.errorCode, text: message.errorMessage ?? "")
    }

    private struct RtMessage: Decodable {
        var tokens: [SonioxRtToken]?
        var finished: Bool?
        var errorCode: Int?
        var errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case tokens
            case finished
            case errorCode = "error_code"
            case errorMessage = "error_message"
        }

        /// Hand-written and forgiving on purpose. The one message we most need to read is the
        /// error frame, and a synthesized decoder throws away the whole frame — error prose
        /// included — if any single field arrives in an unexpected shape (`error_code` as a
        /// string, say). Then the user gets a `DecodingError` in place of the real reason.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.tokens = try? container.decodeIfPresent([SonioxRtToken].self, forKey: .tokens)
            self.finished = try? container.decodeIfPresent(Bool.self, forKey: .finished)
            self.errorMessage = try? container.decodeIfPresent(String.self, forKey: .errorMessage)
            if let code = try? container.decodeIfPresent(Int.self, forKey: .errorCode) {
                self.errorCode = code
            } else {
                self.errorCode = (try? container.decodeIfPresent(String.self, forKey: .errorCode))
                    .flatMap { $0 }.flatMap(Int.init)
            }
        }
    }
}

/// Tracks what the sender has put on the wire, so the keepalive ticker fires only during a real
/// silence and never after end-of-audio.
///
/// Starts as "audio seen" so the first tick after connecting is skipped: the config frame has
/// just gone out, and the stream has not had a chance to be quiet yet.
final class SonioxSendActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var audioSinceLastTick = true
    private var endOfAudioSent = false

    func noteAudioSent() {
        lock.withLock { audioSinceLastTick = true }
    }

    func noteEndOfAudio() {
        lock.withLock { endOfAudioSent = true }
    }

    /// True when a whole tick passed with no audio and the stream is still expecting more.
    /// Consumes the flag, so consecutive silent ticks each send one keepalive.
    func shouldSendKeepalive() -> Bool {
        lock.withLock {
            if endOfAudioSent { return false }
            if audioSinceLastTick {
                audioSinceLastTick = false
                return false
            }
            return true
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
