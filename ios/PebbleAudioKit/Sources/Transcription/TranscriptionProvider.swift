import Foundation

// Port of `core/transcription/.../TranscriptionProvider.kt` + `StreamingTranscriptionProvider.kt`
// — the FIXED provider seam shared by the router, processor, providers, and live transcribers.
// Change only with a coordinated change on all sides.

/// Routing modes (raw values match the Kotlin enum names — the old app persisted them by name,
/// and the migration importer reads those strings).
public enum TranscriptionMode: String, CaseIterable, Sendable, Codable {
    case localOnly = "LocalOnly"
    case remoteOnly = "RemoteOnly"
    case localFirst = "LocalFirst"
    case remoteFirst = "RemoteFirst"
}

public enum ProviderStatus: Sendable, Equatable {
    /// Not usable yet (e.g. model not downloaded, no credentials).
    case notReady
    case initializing
    case ready
    case error
}

public struct TranscriptSegment: Sendable, Equatable, Codable {
    public let text: String
    public let startMs: Int64
    public let endMs: Int64
    public let speaker: String?

    public init(text: String, startMs: Int64, endMs: Int64, speaker: String? = nil) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
    }
}

public struct TranscriptWord: Sendable, Equatable, Codable {
    public let text: String
    public let startMs: Int64
    public let endMs: Int64

    public init(text: String, startMs: Int64, endMs: Int64) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let providerId: String
    /// Model/version identifier for provenance records.
    public let modelUsed: String?
    /// Provider-supplied phrase/window timings, relative to the start of the audio.
    public let segments: [TranscriptSegment]
    /// Provider-supplied word timings, when available.
    public let words: [TranscriptWord]

    public init(
        text: String,
        providerId: String,
        modelUsed: String?,
        segments: [TranscriptSegment] = [],
        words: [TranscriptWord] = []
    ) {
        self.text = text
        self.providerId = providerId
        self.modelUsed = modelUsed
        self.segments = segments
        self.words = words
    }
}

public enum TranscriptionError: Error, Sendable {
    /// Valid terminal outcome, not a provider failure: routers must NOT fall back on it.
    case noSpeechDetected(String)
    case providerUnavailable(providerId: String)
    case transcriptionFailed(String, underlying: Error? = nil)
}

/// One speech-to-text backend (local or cloud), batch flavor: whole closed segments.
public protocol TranscriptionProvider: Sendable {
    var id: String { get }

    func isAvailable() async -> Bool

    /// Transcribes 16 kHz mono PCM16 audio supplied in bounded chunks (never whole-segment
    /// buffers). Throws `TranscriptionError.noSpeechDetected` when the audio contains no usable
    /// speech and other `TranscriptionError`s on failure.
    func transcribe(pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int) async throws
        -> TranscriptionResult
}

/// One incremental update from a real-time (streaming) transcription session.
/// `finalText` is the stable recognized-so-far transcript; `partialText` is the volatile tail.
public struct StreamingTranscriptUpdate: Sendable, Equatable {
    public let finalText: String
    public let partialText: String
    public let segments: [TranscriptSegment]
    public let isFinal: Bool

    public init(
        finalText: String,
        partialText: String = "",
        segments: [TranscriptSegment] = [],
        isFinal: Bool = false
    ) {
        self.finalText = finalText
        self.partialText = partialText
        self.segments = segments
        self.isFinal = isFinal
    }

    /// Best-effort display text: stable transcript plus the volatile tail.
    public var displayText: String {
        [finalText, partialText].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// A real-time transcription backend: audio streams in, partial/final updates stream back.
/// Foreground-only (a live socket cannot survive iOS suspension).
public protocol StreamingTranscriptionProvider: Sendable {
    var id: String { get }

    func isAvailable() async -> Bool

    /// Streams updates while `pcm` (s16le mono at `sampleRateHz`) flows. The returned stream
    /// finishes when the session ends and throws `TranscriptionError` on failure. Cancel the
    /// consuming task to stop streaming.
    func transcribeStream(pcm: AsyncThrowingStream<Data, Error>, sampleRateHz: Int)
        -> AsyncThrowingStream<StreamingTranscriptUpdate, Error>
}
