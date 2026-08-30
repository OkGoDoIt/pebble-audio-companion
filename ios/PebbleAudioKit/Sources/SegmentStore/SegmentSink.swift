import Foundation
import WireProtocol

// Port of `core/transport/.../SegmentSink.kt` — the durable-storage seam between the receiver
// session and the segment store. Declared here (rather than in Receiver) so Receiver can depend
// on SegmentStore without a cycle. This file is the FIXED cross-module contract: change it only
// with a matching change on both sides.

/// One encoded audio frame, addressed by stream sequence and cumulative sample index.
public struct SegmentFrame: Sendable, Equatable {
    public let sequence: UInt32
    public let sampleIndex: UInt64
    public let payload: [UInt8]

    public init(sequence: UInt32, sampleIndex: UInt64, payload: [UInt8]) {
        self.sequence = sequence
        self.sampleIndex = sampleIndex
        self.payload = payload
    }
}

/// Why a gap record exists in a segment.
public enum GapOrigin: Sendable, Equatable {
    /// The watch explicitly reported the gap via STREAM_GAP.
    case watchReported(reasonRaw: Int, watchDropCounter: UInt32)
    /// Synthesized by the receiver after observing a sequence discontinuity in STREAM_DATA.
    case sequenceSkip
}

public struct GapRecord: Sendable, Equatable {
    public let firstMissingSequence: UInt32
    /// 0 = unknown / elapsed-time-only gap.
    public let missingFrameCount: UInt32
    public let firstMissingSampleIndex: UInt64
    public let origin: GapOrigin

    public init(
        firstMissingSequence: UInt32,
        missingFrameCount: UInt32,
        firstMissingSampleIndex: UInt64,
        origin: GapOrigin
    ) {
        self.firstMissingSequence = firstMissingSequence
        self.missingFrameCount = missingFrameCount
        self.firstMissingSampleIndex = firstMissingSampleIndex
        self.origin = origin
    }
}

/// Why a segment was closed.
public enum SegmentCloseReason: Sendable, Equatable {
    /// The watch sent STREAM_STOP.
    case stopped(reasonRaw: Int, finalSequence: UInt32, finalSampleIndex: UInt64)
    /// The BLE link dropped (or the session ended) while the stream was open.
    case interrupted
    /// A new STREAM_START arrived while a segment was still open.
    case superseded
}

/// Diagnostics-only provenance attached to a segment.
public struct SegmentProvenance: Sendable, Equatable {
    public let fwVersionPacked: UInt32
    public let protocolVersion: Int

    public init(fwVersionPacked: UInt32, protocolVersion: Int) {
        self.fwVersionPacked = fwVersionPacked
        self.protocolVersion = protocolVersion
    }
}

/// Durable storage seam consumed by `ReceiverSession`; implemented by SegmentStore.
/// All functions are async and must only return once the data is durable — the session
/// computes checkpoint sequences from what these calls have accepted.
public protocol SegmentSink: Sendable {
    /// Opens a segment for a newly started stream. Any previously open segment was closed.
    func openSegment(start: StreamStart, receivedAtMs: Int64, provenance: SegmentProvenance?) async throws

    /// Appends frames to the open segment; durable on return. Returns the frames actually
    /// persisted — a post-RESUME spool rewind re-sends frames the sink may already hold, and
    /// downstream consumers (live waveform, live transcription) must only see what was new.
    func appendFrames(streamId: UInt32, frames: [SegmentFrame]) async throws -> [SegmentFrame]

    /// Records a gap (watch-reported or synthesized) in the open segment.
    func recordGap(streamId: UInt32, gap: GapRecord) async throws

    /// Closes the open segment. No-op when no segment is open.
    func closeSegment(reason: SegmentCloseReason) async throws
}

/// Receiver-side flags and storage hints carried in CHECKPOINT; provided by SegmentStore.
public protocol ReceiverPolicy: Sendable {
    /// Bitmask of ProtocolConstants RECEIVER_FLAG_* values.
    func receiverFlags() -> UInt32
    func freeStorageHintKb() -> UInt32
}

/// Persisted state that lets a restarted process resume a receiver session.
public struct ReceiverResumeState: Sendable, Equatable, Codable {
    public let lastStreamId: UInt32
    /// Highest contiguous sequence persisted, or nil when nothing was persisted.
    public let lastContiguousSequence: UInt32?
    public let lastSampleIndex: UInt64

    public init(lastStreamId: UInt32, lastContiguousSequence: UInt32?, lastSampleIndex: UInt64) {
        self.lastStreamId = lastStreamId
        self.lastContiguousSequence = lastContiguousSequence
        self.lastSampleIndex = lastSampleIndex
    }
}

public protocol ReceiverResumeStore: Sendable {
    func save(_ state: ReceiverResumeState) async
    func load() async -> ReceiverResumeState?
    func clear() async
}
