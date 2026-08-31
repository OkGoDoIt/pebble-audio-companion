import Foundation
import Transcription

// Port of the `LiveTranscriptPreview` model from `app/.../LiveTranscriber.kt`.

/// Rolling transcript preview of a still-recording segment.
public struct LiveTranscriptPreview: Sendable, Equatable {
    public let segmentId: String
    public let text: String
    /// Timed text spans from completed live chunks, relative to this segment's first sample.
    public let segments: [TranscriptSegment]
    /// Frame-log records consumed so far (index into readFrames, not a sequence number).
    public let transcribedFrameCount: Int
    /// Stream sample index the preview has consumed up to (for waveform coloring).
    public let lastSampleIndexExclusive: UInt64
    public let updatedAtMs: Int64
    /// Which engine produced this preview (e.g. "cactus-local", "soniox"); nil when unknown.
    public let providerId: String?
    /// Model/service identifier for the live source, when known.
    public let modelUsed: String?

    public init(
        segmentId: String,
        text: String,
        segments: [TranscriptSegment] = [],
        transcribedFrameCount: Int,
        lastSampleIndexExclusive: UInt64,
        updatedAtMs: Int64,
        providerId: String? = nil,
        modelUsed: String? = nil
    ) {
        self.segmentId = segmentId
        self.text = text
        self.segments = segments
        self.transcribedFrameCount = transcribedFrameCount
        self.lastSampleIndexExclusive = lastSampleIndexExclusive
        self.updatedAtMs = updatedAtMs
        self.providerId = providerId
        self.modelUsed = modelUsed
    }
}
