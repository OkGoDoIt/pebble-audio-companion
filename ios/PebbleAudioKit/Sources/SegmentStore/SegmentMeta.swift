import Foundation
import WireProtocol

// Port of `core/storage/.../SegmentMeta.kt`.
//
// JSON compatibility note: the KMP app wrote these sidecars with kotlinx.serialization and
// `encodeDefaults = false`, so any field whose value equals its Kotlin default (including
// nullable fields that are null) is OMITTED from the JSON, and unsigned fields serialize as
// unsigned decimals. The custom Codable implementations below reproduce that exactly — the
// migration importer reads files the old app wrote, and the old app's parser must remain able
// to read ours.

/// Sidecar metadata for one segment, persisted as `segments/<segment_id>.meta.json` via
/// temp-file + atomic rename. The frame log (`.spxlog`) is the durable source of truth for
/// frames; recovery reconciles this meta against it.
public struct SegmentMeta: Equatable, Sendable {
    public var segmentId: String
    public var streamId: UInt32
    public var protocolVersion: Int
    public var codecIdRaw: UInt8
    public var channels: Int
    public var frameSamples: Int
    public var sampleRateHz: UInt32
    public var bitRateBps: UInt32
    public var frameDurationMs: Int
    /// Watch wall clock at stream start (UTC ms).
    public var startTimeMs: UInt64
    /// Watch monotonic clock at stream start (ms).
    public var startMonotonicMs: UInt64
    /// Phone wall clock when the segment was opened (ms).
    public var receivedAtMs: Int64
    public var firstSequence: UInt32?
    public var lastSequence: UInt32?
    public var firstSampleIndex: UInt64?
    public var lastSampleIndexExclusive: UInt64?
    public var frameCount: Int64
    /// Bytes of the segment's frame log on disk (as of the last meta flush).
    public var logBytes: Int64
    public var gaps: [GapMeta]
    /// Nil while the segment is open.
    public var closeReason: CloseReasonMeta?
    /// Phone wall clock when this segment was closed, or nil while open/legacy.
    public var closedAtMs: Int64?
    public var transcriptionState: TranscriptionState
    public var provenance: ProvenanceMeta?
    /// Highest sequence persisted in this stream BEFORE this segment existed (set on rotation
    /// successors). A post-RESUME spool rewind can re-send frames older than this segment; while
    /// the segment is still empty its own `lastSequence` is nil, so this floor keeps those
    /// already-persisted frames from being appended again as duplicates.
    public var dedupeFloorSequence: UInt32?
    /// IANA timezone id of the phone at segment open (Q16 — all display anchors where
    /// recorded). NEW in the rebuild: files written by the KMP app lack it (decodes nil,
    /// callers fall back to the device's current zone per plan 6.4), and nil is omitted on
    /// encode so migration-read files round-trip byte-identically.
    public var recordedTimeZone: String?

    public init(
        segmentId: String,
        streamId: UInt32,
        protocolVersion: Int,
        codecIdRaw: UInt8,
        channels: Int,
        frameSamples: Int,
        sampleRateHz: UInt32,
        bitRateBps: UInt32,
        frameDurationMs: Int,
        startTimeMs: UInt64,
        startMonotonicMs: UInt64,
        receivedAtMs: Int64,
        firstSequence: UInt32? = nil,
        lastSequence: UInt32? = nil,
        firstSampleIndex: UInt64? = nil,
        lastSampleIndexExclusive: UInt64? = nil,
        frameCount: Int64 = 0,
        logBytes: Int64 = 0,
        gaps: [GapMeta] = [],
        closeReason: CloseReasonMeta? = nil,
        closedAtMs: Int64? = nil,
        transcriptionState: TranscriptionState = .pending,
        provenance: ProvenanceMeta? = nil,
        dedupeFloorSequence: UInt32? = nil,
        recordedTimeZone: String? = nil
    ) {
        self.segmentId = segmentId
        self.streamId = streamId
        self.protocolVersion = protocolVersion
        self.codecIdRaw = codecIdRaw
        self.channels = channels
        self.frameSamples = frameSamples
        self.sampleRateHz = sampleRateHz
        self.bitRateBps = bitRateBps
        self.frameDurationMs = frameDurationMs
        self.startTimeMs = startTimeMs
        self.startMonotonicMs = startMonotonicMs
        self.receivedAtMs = receivedAtMs
        self.firstSequence = firstSequence
        self.lastSequence = lastSequence
        self.firstSampleIndex = firstSampleIndex
        self.lastSampleIndexExclusive = lastSampleIndexExclusive
        self.frameCount = frameCount
        self.logBytes = logBytes
        self.gaps = gaps
        self.closeReason = closeReason
        self.closedAtMs = closedAtMs
        self.transcriptionState = transcriptionState
        self.provenance = provenance
        self.dedupeFloorSequence = dedupeFloorSequence
        self.recordedTimeZone = recordedTimeZone
    }

    public var isOpen: Bool { closeReason == nil }

    /// Terminal-success transcription states only. Disabled is deliberately NOT terminal: a
    /// segment that could not be transcribed because no provider was usable becomes eligible
    /// again once one is (model downloaded, key added, mode changed).
    public var isFullyTranscribed: Bool {
        transcriptionState == .complete || transcriptionState == .noSpeech
    }
}

extension SegmentMeta: Codable {
    private enum CodingKeys: String, CodingKey {
        case segmentId, streamId, protocolVersion, codecIdRaw, channels, frameSamples
        case sampleRateHz, bitRateBps, frameDurationMs, startTimeMs, startMonotonicMs
        case receivedAtMs, firstSequence, lastSequence, firstSampleIndex
        case lastSampleIndexExclusive, frameCount, logBytes, gaps, closeReason, closedAtMs
        case transcriptionState, provenance, dedupeFloorSequence, recordedTimeZone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segmentId = try c.decode(String.self, forKey: .segmentId)
        streamId = try c.decode(UInt32.self, forKey: .streamId)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        codecIdRaw = try c.decode(UInt8.self, forKey: .codecIdRaw)
        channels = try c.decode(Int.self, forKey: .channels)
        frameSamples = try c.decode(Int.self, forKey: .frameSamples)
        sampleRateHz = try c.decode(UInt32.self, forKey: .sampleRateHz)
        bitRateBps = try c.decode(UInt32.self, forKey: .bitRateBps)
        frameDurationMs = try c.decode(Int.self, forKey: .frameDurationMs)
        startTimeMs = try c.decode(UInt64.self, forKey: .startTimeMs)
        startMonotonicMs = try c.decode(UInt64.self, forKey: .startMonotonicMs)
        receivedAtMs = try c.decode(Int64.self, forKey: .receivedAtMs)
        firstSequence = try c.decodeIfPresent(UInt32.self, forKey: .firstSequence)
        lastSequence = try c.decodeIfPresent(UInt32.self, forKey: .lastSequence)
        firstSampleIndex = try c.decodeIfPresent(UInt64.self, forKey: .firstSampleIndex)
        lastSampleIndexExclusive = try c.decodeIfPresent(UInt64.self, forKey: .lastSampleIndexExclusive)
        frameCount = try c.decodeIfPresent(Int64.self, forKey: .frameCount) ?? 0
        logBytes = try c.decodeIfPresent(Int64.self, forKey: .logBytes) ?? 0
        gaps = try c.decodeIfPresent([GapMeta].self, forKey: .gaps) ?? []
        closeReason = try c.decodeIfPresent(CloseReasonMeta.self, forKey: .closeReason)
        closedAtMs = try c.decodeIfPresent(Int64.self, forKey: .closedAtMs)
        transcriptionState =
            try c.decodeIfPresent(TranscriptionState.self, forKey: .transcriptionState) ?? .pending
        provenance = try c.decodeIfPresent(ProvenanceMeta.self, forKey: .provenance)
        dedupeFloorSequence = try c.decodeIfPresent(UInt32.self, forKey: .dedupeFloorSequence)
        recordedTimeZone = try c.decodeIfPresent(String.self, forKey: .recordedTimeZone)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(segmentId, forKey: .segmentId)
        try c.encode(streamId, forKey: .streamId)
        try c.encode(protocolVersion, forKey: .protocolVersion)
        try c.encode(codecIdRaw, forKey: .codecIdRaw)
        try c.encode(channels, forKey: .channels)
        try c.encode(frameSamples, forKey: .frameSamples)
        try c.encode(sampleRateHz, forKey: .sampleRateHz)
        try c.encode(bitRateBps, forKey: .bitRateBps)
        try c.encode(frameDurationMs, forKey: .frameDurationMs)
        try c.encode(startTimeMs, forKey: .startTimeMs)
        try c.encode(startMonotonicMs, forKey: .startMonotonicMs)
        try c.encode(receivedAtMs, forKey: .receivedAtMs)
        try c.encodeIfPresent(firstSequence, forKey: .firstSequence)
        try c.encodeIfPresent(lastSequence, forKey: .lastSequence)
        try c.encodeIfPresent(firstSampleIndex, forKey: .firstSampleIndex)
        try c.encodeIfPresent(lastSampleIndexExclusive, forKey: .lastSampleIndexExclusive)
        if frameCount != 0 { try c.encode(frameCount, forKey: .frameCount) }
        if logBytes != 0 { try c.encode(logBytes, forKey: .logBytes) }
        if !gaps.isEmpty { try c.encode(gaps, forKey: .gaps) }
        try c.encodeIfPresent(closeReason, forKey: .closeReason)
        try c.encodeIfPresent(closedAtMs, forKey: .closedAtMs)
        if transcriptionState != .pending {
            try c.encode(transcriptionState, forKey: .transcriptionState)
        }
        try c.encodeIfPresent(provenance, forKey: .provenance)
        try c.encodeIfPresent(dedupeFloorSequence, forKey: .dedupeFloorSequence)
        try c.encodeIfPresent(recordedTimeZone, forKey: .recordedTimeZone)
    }
}

public struct GapMeta: Equatable, Sendable {
    public var firstMissingSequence: UInt32
    public var missingFrameCount: UInt32
    public var firstMissingSampleIndex: UInt64
    /// "watch" (STREAM_GAP) or "sequence_skip" (synthesized by the receiver).
    public var origin: String
    public var reasonRaw: Int?
    public var watchDropCounter: UInt32?

    public init(
        firstMissingSequence: UInt32,
        missingFrameCount: UInt32,
        firstMissingSampleIndex: UInt64,
        origin: String,
        reasonRaw: Int? = nil,
        watchDropCounter: UInt32? = nil
    ) {
        self.firstMissingSequence = firstMissingSequence
        self.missingFrameCount = missingFrameCount
        self.firstMissingSampleIndex = firstMissingSampleIndex
        self.origin = origin
        self.reasonRaw = reasonRaw
        self.watchDropCounter = watchDropCounter
    }

    public static let originWatch = "watch"
    public static let originSequenceSkip = "sequence_skip"

    public static func from(_ gap: GapRecord) -> GapMeta {
        switch gap.origin {
        case .watchReported(let reasonRaw, let watchDropCounter):
            return GapMeta(
                firstMissingSequence: gap.firstMissingSequence,
                missingFrameCount: gap.missingFrameCount,
                firstMissingSampleIndex: gap.firstMissingSampleIndex,
                origin: originWatch,
                reasonRaw: reasonRaw,
                watchDropCounter: watchDropCounter
            )
        case .sequenceSkip:
            return GapMeta(
                firstMissingSequence: gap.firstMissingSequence,
                missingFrameCount: gap.missingFrameCount,
                firstMissingSampleIndex: gap.firstMissingSampleIndex,
                origin: originSequenceSkip
            )
        }
    }
}

extension GapMeta: Codable {
    private enum CodingKeys: String, CodingKey {
        case firstMissingSequence, missingFrameCount, firstMissingSampleIndex, origin
        case reasonRaw, watchDropCounter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstMissingSequence = try c.decode(UInt32.self, forKey: .firstMissingSequence)
        missingFrameCount = try c.decode(UInt32.self, forKey: .missingFrameCount)
        firstMissingSampleIndex = try c.decode(UInt64.self, forKey: .firstMissingSampleIndex)
        origin = try c.decode(String.self, forKey: .origin)
        reasonRaw = try c.decodeIfPresent(Int.self, forKey: .reasonRaw)
        watchDropCounter = try c.decodeIfPresent(UInt32.self, forKey: .watchDropCounter)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(firstMissingSequence, forKey: .firstMissingSequence)
        try c.encode(missingFrameCount, forKey: .missingFrameCount)
        try c.encode(firstMissingSampleIndex, forKey: .firstMissingSampleIndex)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(reasonRaw, forKey: .reasonRaw)
        try c.encodeIfPresent(watchDropCounter, forKey: .watchDropCounter)
    }
}

public struct CloseReasonMeta: Equatable, Sendable {
    /// "stopped", "interrupted", "superseded", or "rotated".
    public var kind: String
    public var stopReasonRaw: Int?
    public var finalSequence: UInt32?
    public var finalSampleIndex: UInt64?

    public init(
        kind: String,
        stopReasonRaw: Int? = nil,
        finalSequence: UInt32? = nil,
        finalSampleIndex: UInt64? = nil
    ) {
        self.kind = kind
        self.stopReasonRaw = stopReasonRaw
        self.finalSequence = finalSequence
        self.finalSampleIndex = finalSampleIndex
    }

    public static let kindStopped = "stopped"
    public static let kindInterrupted = "interrupted"
    public static let kindSuperseded = "superseded"
    public static let kindRotated = "rotated"

    public static let rotated = CloseReasonMeta(kind: kindRotated)
    public static let interrupted = CloseReasonMeta(kind: kindInterrupted)

    public static func from(_ reason: SegmentCloseReason) -> CloseReasonMeta {
        switch reason {
        case .stopped(let reasonRaw, let finalSequence, let finalSampleIndex):
            return CloseReasonMeta(
                kind: kindStopped,
                stopReasonRaw: reasonRaw,
                finalSequence: finalSequence,
                finalSampleIndex: finalSampleIndex
            )
        case .interrupted:
            return interrupted
        case .superseded:
            return CloseReasonMeta(kind: kindSuperseded)
        }
    }
}

extension CloseReasonMeta: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, stopReasonRaw, finalSequence, finalSampleIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        stopReasonRaw = try c.decodeIfPresent(Int.self, forKey: .stopReasonRaw)
        finalSequence = try c.decodeIfPresent(UInt32.self, forKey: .finalSequence)
        finalSampleIndex = try c.decodeIfPresent(UInt64.self, forKey: .finalSampleIndex)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(stopReasonRaw, forKey: .stopReasonRaw)
        try c.encodeIfPresent(finalSequence, forKey: .finalSequence)
        try c.encodeIfPresent(finalSampleIndex, forKey: .finalSampleIndex)
    }
}

/// Raw values match the Kotlin enum constant names, which is how kotlinx.serialization encoded
/// them into the sidecar JSON.
public enum TranscriptionState: String, Codable, CaseIterable, Sendable {
    case pending = "Pending"
    case running = "Running"

    /// Audio is uploading to the cloud provider on the background transport.
    case uploading = "Uploading"
    case complete = "Complete"
    case noSpeech = "NoSpeech"
    case failed = "Failed"
    case disabled = "Disabled"
}

public struct ProvenanceMeta: Equatable, Codable, Sendable {
    public var fwVersionPacked: UInt32
    public var protocolVersion: Int

    public init(fwVersionPacked: UInt32, protocolVersion: Int) {
        self.fwVersionPacked = fwVersionPacked
        self.protocolVersion = protocolVersion
    }
}
