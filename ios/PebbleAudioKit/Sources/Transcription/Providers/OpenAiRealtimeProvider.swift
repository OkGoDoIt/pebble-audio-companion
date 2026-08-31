import AudioCodec
import Foundation

// Port of `core/transcription/.../OpenAiRealtimeProvider.kt`.

/// Real-time (streaming) transcription over the OpenAI Realtime API WebSocket
/// (`wss://api.openai.com/v1/realtime?intent=transcription`). Configures a transcription
/// session, resamples the watch's 16 kHz audio to the 24 kHz the API expects (linear, via
/// `PcmResampler`), streams it as base64 `input_audio_buffer.append` events, and folds the
/// `...input_audio_transcription.delta`/`.completed` events into `StreamingTranscriptUpdate`s.
/// Foreground-only; OpenAI realtime has no diarization.
public final class OpenAiRealtimeProvider: StreamingTranscriptionProvider {
    public static let defaultUrl = "wss://api.openai.com/v1/realtime?intent=transcription"
    public static let defaultModel = "gpt-live-transcribe"
    public static let targetSampleRate = 24_000

    private static let deltaEvent = "conversation.item.input_audio_transcription.delta"
    private static let completedEvent = "conversation.item.input_audio_transcription.completed"
    private static let errorEvent = "error"

    public let id = "openai-realtime"

    private let connector: any WebSocketConnector
    private let apiKey: @Sendable () -> String?
    private let cloudConsent: @Sendable () -> Bool
    private let model: @Sendable () -> String
    private let url: String
    private let targetRate: Int

    public init(
        connector: any WebSocketConnector = URLSessionWebSocketConnector(),
        apiKey: @escaping @Sendable () -> String?,
        cloudConsent: @escaping @Sendable () -> Bool,
        model: @escaping @Sendable () -> String = { OpenAiRealtimeProvider.defaultModel },
        url: String = OpenAiRealtimeProvider.defaultUrl,
        targetSampleRate: Int = OpenAiRealtimeProvider.targetSampleRate
    ) {
        self.connector = connector
        self.apiKey = apiKey
        self.cloudConsent = cloudConsent
        self.model = model
        self.url = url
        self.targetRate = targetSampleRate
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
                        throw TranscriptionError.transcriptionFailed("invalid OpenAI URL: \(self.url)")
                    }
                    let socket = self.connector.connect(
                        url: socketUrl, headers: ["Authorization": "Bearer \(key)"]
                    )
                    connection = socket
                    try await socket.send(text: self.sessionConfig())

                    let sourceRate = sampleRateHz
                    let targetRate = self.targetRate
                    sender = Task {
                        do {
                            for try await chunk in pcm where !chunk.isEmpty {
                                let resampled = PcmResampler.resampleLinearMono16(
                                    pcm: chunk, fromRate: sourceRate, toRate: targetRate
                                )
                                try await socket.send(
                                    text: Self.appendEvent(base64Audio: resampled.base64EncodedString())
                                )
                            }
                            try await socket.send(text: #"{"type":"input_audio_buffer.commit"}"#)
                        } catch {
                            // A send failure surfaces through the receive loop when the socket dies.
                        }
                    }

                    let decoder = JSONDecoder()
                    let accumulator = OpenAiRealtimeAccumulator()
                    while true {
                        try Task.checkCancellation()
                        guard case .text(let frame) = try await socket.receive() else { continue }
                        let event = try decoder.decode(RtEvent.self, from: Data(frame.utf8))
                        switch event.type {
                        case Self.deltaEvent:
                            continuation.yield(accumulator.delta(event.delta ?? ""))
                        case Self.completedEvent:
                            continuation.yield(accumulator.completed(event.transcript ?? ""))
                        case Self.errorEvent:
                            throw TranscriptionError.transcriptionFailed(
                                "OpenAI realtime error: \(event.error?.message ?? "unknown")"
                            )
                        default:
                            break
                        }
                    }
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

    private func sessionConfig() -> String {
        #"{"type":"session.update","session":{"type":"transcription","#
            + #""audio":{"input":{"format":{"type":"audio/pcm","rate":\#(targetRate)},"#
            + #""transcription":{"model":"\#(model())"}}}}}"#
    }

    private static func appendEvent(base64Audio: String) -> String {
        #"{"type":"input_audio_buffer.append","audio":"\#(base64Audio)"}"#
    }

    private struct RtEvent: Decodable {
        var type: String?
        var delta: String?
        var transcript: String?
        var error: RtError?
    }

    private struct RtError: Decodable {
        var message: String?
        var type: String?
    }
}

/// Pure folding of OpenAI realtime transcription events: `delta`s accumulate into the volatile
/// tail; a `completed` finalizes the current item into the stable transcript. Extracted for unit
/// testing.
public final class OpenAiRealtimeAccumulator {
    private var completedText = ""
    private var partial = ""

    public init() {}

    public func delta(_ text: String) -> StreamingTranscriptUpdate {
        partial += text
        return update()
    }

    public func completed(_ transcript: String) -> StreamingTranscriptUpdate {
        let cleaned = transcript.trimmed
        if !cleaned.isEmpty {
            if !completedText.isEmpty { completedText += " " }
            completedText += cleaned
        }
        partial = ""
        return update()
    }

    private func update() -> StreamingTranscriptUpdate {
        StreamingTranscriptUpdate(
            finalText: completedText.trimmed,
            partialText: partial.trimmed,
            isFinal: false
        )
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    fileprivate var isBlank: Bool { trimmed.isEmpty }
    fileprivate var nonBlank: String? { isBlank ? nil : self }
}
