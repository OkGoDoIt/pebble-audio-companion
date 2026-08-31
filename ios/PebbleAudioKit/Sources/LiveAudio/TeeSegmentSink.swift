import Foundation
import SegmentStore
import WireProtocol

// Port of the `TeeSegmentSink` half of `app/.../LiveAudioMonitor.kt`.

/// Forwards everything to the durable `SegmentStore` first (durability is what checkpoints are
/// computed from), then feeds the live monitor.
public final class TeeSegmentSink: SegmentSink {
    private let store: SegmentStore
    private let monitor: LiveAudioMonitor
    private let nowMs: @Sendable () -> Int64
    /// Optional live-audio fan-out for real-time cloud transcription; nil disables it.
    private let tap: LiveAudioTap?
    /// Called when a segment becomes newly eligible for closed-segment processing.
    private let onSegmentClosed: @Sendable () -> Void

    public init(
        store: SegmentStore,
        monitor: LiveAudioMonitor,
        nowMs: @escaping @Sendable () -> Int64,
        tap: LiveAudioTap? = nil,
        onSegmentClosed: @escaping @Sendable () -> Void = {}
    ) {
        self.store = store
        self.monitor = monitor
        self.nowMs = nowMs
        self.tap = tap
        self.onSegmentClosed = onSegmentClosed
    }

    public func openSegment(
        start: StreamStart, receivedAtMs: Int64, provenance: SegmentProvenance?
    ) async throws {
        let previousId = await store.openSegmentId
        try await store.openSegment(start: start, receivedAtMs: receivedAtMs, provenance: provenance)
        let segmentId = await store.openSegmentId
        if let previousId, previousId != segmentId {
            tap?.emit(.segmentClosed(segmentId: previousId))
            onSegmentClosed()
        }
        if let segmentId { await emitSegmentOpened(segmentId) }
    }

    public func appendFrames(streamId: UInt32, frames: [SegmentFrame]) async throws -> [SegmentFrame] {
        let receivingSegmentId = await store.openSegmentId
        // Only forward what the store actually persisted: a post-RESUME rewind re-sends frames
        // the store dedupes, and the live waveform / live transcription must not replay them.
        let accepted = try await store.appendFrames(streamId: streamId, frames: frames)
        if !accepted.isEmpty {
            await monitor.onFrames(segmentId: receivingSegmentId, frames: accepted, receivedAtMs: nowMs())
            if let tap, let receivingSegmentId {
                tap.emit(.framesAppended(segmentId: receivingSegmentId, frames: accepted))
            }
        }

        let nextSegmentId = await store.openSegmentId
        if let receivingSegmentId, receivingSegmentId != nextSegmentId {
            tap?.emit(.segmentClosed(segmentId: receivingSegmentId))
            onSegmentClosed()
            if let nextSegmentId { await emitSegmentOpened(nextSegmentId) }
        }
        return accepted
    }

    public func recordGap(streamId: UInt32, gap: GapRecord) async throws {
        try await store.recordGap(streamId: streamId, gap: gap)
        let silence: Bool
        if case .watchReported(let reasonRaw, _) = gap.origin {
            silence = UInt8(exactly: reasonRaw).flatMap(GapReason.init(rawValue:))?.isSilence == true
        } else {
            silence = false
        }
        await monitor.onGap(
            receivedAtMs: nowMs(),
            approxDurationMs: Int64(gap.missingFrameCount) * 20,
            silence: silence)
    }

    public func closeSegment(reason: SegmentCloseReason) async throws {
        let closingId = await store.openSegmentId
        try await store.closeSegment(reason: reason)
        if let closingId {
            tap?.emit(.segmentClosed(segmentId: closingId))
            onSegmentClosed()
        }
    }

    private func emitSegmentOpened(_ segmentId: String) async {
        guard let meta = await store.readMeta(segmentId) else { return }
        tap?.emit(
            .segmentOpened(
                LiveAudioEvent.SegmentOpened(
                    segmentId: segmentId,
                    sampleRateHz: Int(meta.sampleRateHz),
                    bitRateBps: Int(meta.bitRateBps),
                    frameSamples: meta.frameSamples
                )
            )
        )
    }
}
