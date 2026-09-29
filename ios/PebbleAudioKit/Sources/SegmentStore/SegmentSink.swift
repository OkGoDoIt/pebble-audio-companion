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

/// What the store already holds for a stream that is being CONTINUED — the answer `openSegment`
/// gives to a RESUME re-announcement.
///
/// The receiver needs it to hold the reconnect to account. When the watch's spool cannot grow it
/// recycles its oldest chunk and records a gap only for frames it had not yet SENT; frames it had
/// sent into a link that was already dying vanish without a record, and the firmware relies on
/// "the receiver's own sequence check" to notice (`spool.c`, `prv_drop_oldest_chunk`). That check
/// needs a starting point, and a RESUME used to give it none: the receiver adopted whatever the
/// first notice after the reconnect said, so the hole between the last frame it stored and the
/// watch's first overflow record was never compared against anything. In the 2026-09-29 backup
/// that was 32 reconnects and 5,634 frames (113 s) that Today and Live painted as recorded.
public struct StreamContinuation: Sendable, Equatable {
    /// One past the highest sequence of this stream the store holds.
    public let nextSequence: UInt32
    /// The sample index that goes with `nextSequence`.
    public let nextSampleIndex: UInt64
    /// Stretches at or past `nextSequence` already recorded as gaps — lost or quiet — before the
    /// link dropped. They are accounted for: nothing will ever arrive for them, and they must not
    /// be recorded a second time.
    public let recordedRanges: [RecordedRange]
    /// True when the segment now open is the one holding that audio (continued in place, or an
    /// interrupted one reattached): frames the watch re-sends below `nextSequence` are its own,
    /// and the store may use them to refill its recorded gaps. False when the stream carries on
    /// in a NEW segment: frames below `nextSequence` then belong to an earlier segment and must
    /// never be stored a second time.
    public let continuesSameSegment: Bool

    public struct RecordedRange: Sendable, Equatable {
        public let firstSequence: UInt32
        public let frameCount: UInt32
        public let firstSampleIndex: UInt64

        public init(firstSequence: UInt32, frameCount: UInt32, firstSampleIndex: UInt64) {
            self.firstSequence = firstSequence
            self.frameCount = frameCount
            self.firstSampleIndex = firstSampleIndex
        }
    }

    public init(
        nextSequence: UInt32,
        nextSampleIndex: UInt64,
        recordedRanges: [RecordedRange] = [],
        continuesSameSegment: Bool
    ) {
        self.nextSequence = nextSequence
        self.nextSampleIndex = nextSampleIndex
        self.recordedRanges = recordedRanges
        self.continuesSameSegment = continuesSameSegment
    }
}

/// Durable storage seam consumed by `ReceiverSession`; implemented by SegmentStore.
/// All functions are async and must only return once the data is durable — the session
/// computes checkpoint sequences from what these calls have accepted.
public protocol SegmentSink: Sendable {
    /// Opens a segment for a newly started stream. Any previously open segment was closed.
    ///
    /// For a RESUME re-announcement, returns what is already stored for the stream (nil when
    /// nothing is, and always nil for a fresh stream). A decorator MUST return what its
    /// downstream returned: answering nil for a stream the store does hold silently reopens the
    /// hole this exists to close.
    @discardableResult
    func openSegment(
        start: StreamStart, receivedAtMs: Int64, provenance: SegmentProvenance?
    ) async throws -> StreamContinuation?

    /// Appends frames to the open segment; durable on return. Returns the frames actually
    /// persisted — a post-RESUME spool rewind re-sends frames the sink may already hold, and
    /// downstream consumers (live waveform, live transcription) must only see what was new.
    func appendFrames(streamId: UInt32, frames: [SegmentFrame]) async throws -> [SegmentFrame]

    /// Records a gap (watch-reported or synthesized) in the open segment.
    func recordGap(streamId: UInt32, gap: GapRecord) async throws

    /// Closes the open segment. No-op when no segment is open.
    func closeSegment(reason: SegmentCloseReason) async throws

    /// Forces everything appended so far to durable storage.
    ///
    /// Appends are deliberately NOT fsynced one by one — see `SegmentStore.appendFrames`. The
    /// receiver calls this immediately before it sends a CHECKPOINT, because the checkpoint is
    /// what authorizes the watch to free its spool, and the invariant is "checkpoint only what is
    /// flushed". Everything not yet flushed is still held by the watch, so a crash costs nothing.
    func flush() async throws
}

extension SegmentSink {
    /// Fakes and in-memory sinks are durable by construction.
    public func flush() async throws {}
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
