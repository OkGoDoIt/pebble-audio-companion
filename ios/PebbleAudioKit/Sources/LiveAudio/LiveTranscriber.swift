import AudioCodec
import Foundation
import SegmentStore
import Transcription

// Port of `app/.../LiveTranscriber.kt`.

/// Incremental transcription of the currently open (still recording) segment.
///
/// The durable transcription queue only processes closed segments; this actor fills the gap the
/// user sees while a recording is ongoing: every time the open segment has accumulated at least
/// `minChunkFrames` new stored frames, the new tail is decoded and transcribed as one chunk and
/// appended to an in-memory rolling preview. The preview is intentionally not durable — when the
/// segment closes, the normal queue produces the authoritative full-segment transcript and the
/// preview is dropped (`prune`).
///
/// Chunk boundaries can split words, so the preview may differ slightly from the final
/// transcript; that is an accepted preview tradeoff. Runs on the runtime's single transcription
/// loop, so it never races the closed-segment work for a (possibly single-instance) native model.
///
/// Cost note: callers should pass the LOCAL provider (the KMP original took a router restricted
/// to LocalOnly). Routing the preview through a cloud provider would mean one network call per
/// chunk (~110 per 15-minute segment) instead of one per closed segment — surprise cost and
/// audio leaving the device far more often than the user consented to.
public actor LiveTranscriber {
    private let openSegmentId: @Sendable () -> String?
    private let readMeta: @Sendable (String) -> SegmentMeta?
    private let readFrames: @Sendable (String) -> [FrameRecord]
    private let provider: TranscriptionProvider
    private let nowMs: @Sendable () -> Int64
    private let decodePcm: @Sendable (SegmentMeta, [FrameRecord]) -> AsyncThrowingStream<Data, Error>
    /// ~8 s of audio at 20 ms frames: short enough to feel live, long enough for context.
    private let minChunkFrames: Int
    /// Bounds one pass (catch-up after app restart processes the backlog chunk by chunk).
    private let maxChunkFrames: Int
    private let failureBackoffMs: Int64
    /// Open segment + a couple of just-closed segments awaiting their final transcript.
    private let maxEntries: Int

    public private(set) var previews: [String: LiveTranscriptPreview] = [:]

    private var lastFailureAtMs: Int64 = 0

    public init(
        openSegmentId: @escaping @Sendable () -> String?,
        readMeta: @escaping @Sendable (String) -> SegmentMeta?,
        readFrames: @escaping @Sendable (String) -> [FrameRecord],
        provider: TranscriptionProvider,
        nowMs: @escaping @Sendable () -> Int64,
        decodePcm: @escaping @Sendable (SegmentMeta, [FrameRecord]) -> AsyncThrowingStream<Data, Error> =
            LiveTranscriber.defaultDecodePcm,
        minChunkFrames: Int = 400,
        maxChunkFrames: Int = 3_000,
        failureBackoffMs: Int64 = 30_000,
        maxEntries: Int = 3
    ) {
        self.openSegmentId = openSegmentId
        self.readMeta = readMeta
        self.readFrames = readFrames
        self.provider = provider
        self.nowMs = nowMs
        self.decodePcm = decodePcm
        self.minChunkFrames = minChunkFrames
        self.maxChunkFrames = maxChunkFrames
        self.failureBackoffMs = failureBackoffMs
        self.maxEntries = maxEntries
    }

    /// Default decode path over the vendored Speex codec (matches the KMP default argument).
    public static func defaultDecodePcm(
        meta: SegmentMeta, frames: [FrameRecord]
    ) -> AsyncThrowingStream<Data, Error> {
        let decoder = SpeexFrameDecoder(
            sampleRateHz: Int(meta.sampleRateHz),
            bitRateBps: Int(meta.bitRateBps),
            frameSamples: meta.frameSamples
        )
        let payloads = frames.map { Data($0.payload) }
        return decoder.decode(
            frames: AsyncStream { continuation in
                for payload in payloads { continuation.yield(payload) }
                continuation.finish()
            }
        )
    }

    public func textFor(_ segmentId: String) -> String? {
        guard let text = previews[segmentId]?.text,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    public func previewFor(_ segmentId: String) -> LiveTranscriptPreview? { previews[segmentId] }

    /// True when the open segment has enough new audio for another pass (drives loop cadence).
    public func hasPendingWork() -> Bool {
        guard let segmentId = openSegmentId(), let meta = readMeta(segmentId) else { return false }
        let done = previews[segmentId]?.transcribedFrameCount ?? 0
        return meta.frameCount - Int64(done) >= Int64(minChunkFrames)
    }

    /// Transcribes at most one new chunk of the open segment. Returns true when the preview
    /// advanced (more chunks may be pending). Provider failures back off instead of looping hot.
    public func processOnce() async throws -> Bool {
        guard let segmentId = openSegmentId(), let meta = readMeta(segmentId) else { return false }
        if nowMs() - lastFailureAtMs < failureBackoffMs && lastFailureAtMs != 0 { return false }

        let existing = previews[segmentId]
        let done = existing?.transcribedFrameCount ?? 0
        if meta.frameCount - Int64(done) < Int64(minChunkFrames) { return false }
        guard await provider.isAvailable() else { return false }

        let frames = readFrames(segmentId)
        if frames.count - done < minChunkFrames { return false }
        let chunk = Array(frames[done..<min(frames.count, done + maxChunkFrames)])

        let result: TranscriptionResult?
        do {
            result = try await provider.transcribe(
                pcmChunks: decodePcm(meta, chunk), sampleRateHz: Int(meta.sampleRateHz))
        } catch is CancellationError {
            throw CancellationError()
        } catch TranscriptionError.noSpeechDetected {
            result = nil  // Quiet audio is a valid outcome: advance past it without text.
        } catch {
            lastFailureAtMs = nowMs()
            return false
        }
        lastFailureAtMs = 0
        let chunkText = (result?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chunkSegments: [TranscriptSegment]
        if let segments = result?.segments, !segments.isEmpty {
            let offset = chunkStartMs(meta, chunk)
            chunkSegments = segments.map {
                TranscriptSegment(
                    text: $0.text, startMs: $0.startMs + offset, endMs: $0.endMs + offset,
                    speaker: $0.speaker)
            }
        } else if !chunkText.isEmpty {
            chunkSegments = [
                TranscriptSegment(
                    text: chunkText,
                    startMs: chunkStartMs(meta, chunk),
                    endMs: chunkEndMs(meta, chunk))
            ]
        } else {
            chunkSegments = []
        }

        let combined = [existing?.text, chunkText.isEmpty ? nil : chunkText]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        update(
            LiveTranscriptPreview(
                segmentId: segmentId,
                text: combined,
                segments: (existing?.segments ?? []) + chunkSegments,
                transcribedFrameCount: done + chunk.count,
                lastSampleIndexExclusive: chunk.last!.sampleIndex + UInt64(meta.frameSamples),
                updatedAtMs: nowMs(),
                providerId: result?.providerId ?? existing?.providerId,
                modelUsed: result?.modelUsed ?? existing?.modelUsed
            )
        )
        return true
    }

    /// Drops previews that are no longer needed: the segment now has a durable transcript, or it
    /// no longer exists. Call alongside transcription-loop passes.
    public func prune(hasFinalTranscript: @Sendable (String) -> Bool) {
        let kept = previews.filter { segmentId, _ in
            readMeta(segmentId) != nil && !hasFinalTranscript(segmentId)
        }
        if kept.count != previews.count { previews = kept }
    }

    private func update(_ preview: LiveTranscriptPreview) {
        var next = previews
        next[preview.segmentId] = preview
        while next.count > maxEntries {
            guard let oldest = next.values.min(by: { $0.updatedAtMs < $1.updatedAtMs }) else { break }
            next.removeValue(forKey: oldest.segmentId)
        }
        previews = next
    }

    private func chunkStartMs(_ meta: SegmentMeta, _ chunk: [FrameRecord]) -> Int64 {
        sampleOffsetMs(meta, chunk.first!.sampleIndex)
    }

    private func chunkEndMs(_ meta: SegmentMeta, _ chunk: [FrameRecord]) -> Int64 {
        sampleOffsetMs(meta, chunk.last!.sampleIndex + UInt64(meta.frameSamples))
    }

    private func sampleOffsetMs(_ meta: SegmentMeta, _ sampleIndex: UInt64) -> Int64 {
        let base = meta.firstSampleIndex ?? sampleIndex
        let samples = sampleIndex >= base ? sampleIndex - base : 0
        return (Int64(samples) * 1_000) / Int64(meta.sampleRateHz)
    }
}
