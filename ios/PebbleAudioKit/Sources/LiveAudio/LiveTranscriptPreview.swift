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

extension LiveTranscriptPreview {
    /// The one preview the live screen shows, from the two live sources that can produce one.
    ///
    /// They cover disjoint stretches of the same open segment by construction: the chunk path
    /// stands down (`LiveTranscriber.markCoveredByOtherSource`) while the realtime socket
    /// delivers, and takes over from the handoff point if the socket dies. So the preview is
    /// their union in time — cloud first, then whatever the chunk path covered after it — and
    /// nothing disappears from the screen when the source changes mid-recording.
    ///
    /// `providerId` is whichever source produced the NEWEST text, because that is what the
    /// screen's provenance line names. Anything else would let a live cloud transcript claim to
    /// be on-device, or an on-device fallback claim to be Soniox.
    public static func merged(
        cloud: LiveTranscriptPreview?, local: LiveTranscriptPreview?
    ) -> LiveTranscriptPreview? {
        guard let cloud else { return local }
        guard let local else { return cloud }

        // Everything the chunk path produced beyond the cloud's coverage. Timings are relative
        // to the segment's first sample on both sides, so they compare directly.
        let cloudEndMs = cloud.segments.map(\.endMs).max()
        let tail: [TranscriptSegment]
        if let cloudEndMs {
            tail = local.segments.filter { $0.startMs >= cloudEndMs }
        } else {
            tail = local.segments
        }
        let overlapsEntirely = !local.segments.isEmpty && tail.isEmpty
        let newest = local.updatedAtMs > cloud.updatedAtMs ? local : cloud

        // With no timings on either side there is nothing to align, so the newer text stands
        // alone rather than being concatenated into a duplicate.
        guard !cloud.segments.isEmpty || !local.segments.isEmpty else { return newest }
        if overlapsEntirely { return cloud }

        let segments = cloud.segments + tail
        let text = segments.map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        return LiveTranscriptPreview(
            segmentId: cloud.segmentId,
            text: text.isEmpty ? newest.text : text,
            segments: segments,
            transcribedFrameCount: max(cloud.transcribedFrameCount, local.transcribedFrameCount),
            lastSampleIndexExclusive: max(
                cloud.lastSampleIndexExclusive, local.lastSampleIndexExclusive),
            updatedAtMs: max(cloud.updatedAtMs, local.updatedAtMs),
            providerId: newest.providerId,
            modelUsed: newest.modelUsed
        )
    }
}
