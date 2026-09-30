import Foundation
import GRDB

// What a recorded stretch HOLDS, as opposed to whether it was recorded at all.
//
// Coverage answers "was the recorder running and did the audio arrive" (recorded / quiet /
// missing / paused / off). This answers the next question for recorded audio: was there a
// conversation in it, or only sound — music, a TV, a café, a fan, a few stray words. The two
// are kept apart on purpose. Folding "no conversation" into `CoverageKind` would shrink the
// recorded hours and make the recorder look less reliable than it is, which is the trust story
// the coverage view exists to tell; and the verdict here is a judgement that can be wrong and
// overruled, while coverage is a fact.
//
// Nothing here deletes or hides anything. A span is a label on time. The audio stays playable,
// the transcript stays readable, and a person's correction (`audio_content_overrides`) always
// beats the classifier. Design and measurements: `docs/audio-content-classification.md`.
//
// Two tables with opposite lifetimes (migration `v14-audio-content`):
// - `audio_content_spans` + `audio_content_segments` are DERIVED: recomputed from a segment's
//   transcript whenever it or the method changes. Losing them costs a re-run of a cheap stage.
// - `audio_content_overrides` is AUTHORITATIVE: what a person said about a stretch. Never
//   dropped by a rebuild, and kept by wall-clock range so it survives a re-transcription.

/// The kind of a recorded stretch. Time with no span at all is UNCLASSIFIED (not transcribed
/// yet, or never), which is a third state readers must keep distinct.
public enum AudioContentKind: String, Sendable, Codable, CaseIterable {
    case conversation
    case noConversation
}

/// What the stretch holds, when that is KNOWN. A descriptor is present only where the method
/// that set it met its accuracy bar; anything else is plain "no conversation".
public enum AudioContentDescriptor {
    /// Some words were transcribed, too few to be a conversation (under two a minute). A fact
    /// about the transcript, not a guess about the room, so it is always safe to show.
    public static let fewWords = "fewWords"
}

/// Who or what made a verdict. Strings, not an enum, because a later method adds its own and
/// a stored row must stay readable by an older build.
public enum AudioContentDecider {
    /// The transcriber settled the whole segment as having no speech (`NoSpeech`).
    public static let noSpeech = "noSpeech"
    /// Word rate in the minute's transcript: under two words a minute is no conversation.
    public static let wordRate = "wordRate"
    /// The minute's words are the transcriber's own repetition loop over quiet audio
    /// (`TranscriptArtefacts`), so what it "said" was never said.
    public static let loop = "loop"
    /// A short stretch of talk with nothing else said around it: a stray remark, not a
    /// conversation (`AudioContentMethod.isolatedMaximumWords`).
    public static let isolatedWords = "isolatedWords"
    /// A person's correction.
    public static let user = "user"
}

/// One classified stretch of the wall clock — the contract the History screens read
/// (`docs/redesign/2026-09-30-history-tab-plan.md` §7.6).
public struct AudioContentSpan: Equatable, Sendable {
    public var startMs: Int64
    public var endMs: Int64
    public var kind: AudioContentKind
    /// See `AudioContentDescriptor`. Nil means "no conversation", styled like quiet.
    public var descriptor: String?
    /// The measured precision of the rule that decided this span, on hand-labelled minutes of
    /// real recordings — not a model's self-report. 1 for a person's own correction.
    public var confidence: Double
    public var decidedBy: String
    /// The method version that produced the verdict (`AudioContentMethod.version`); a
    /// correction carries the version current when it was read. Change detection is `digest`.
    public var version: Int
    /// Transcribed words in the stretch (loop artefacts excluded), for a reader that wants to
    /// say how much was said. Proportional where a span was cut by a correction.
    public var wordCount: Int

    public init(
        startMs: Int64, endMs: Int64, kind: AudioContentKind, descriptor: String? = nil,
        confidence: Double, decidedBy: String, version: Int, wordCount: Int = 0
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.kind = kind
        self.descriptor = descriptor
        self.confidence = confidence
        self.decidedBy = decidedBy
        self.version = version
        self.wordCount = wordCount
    }

    public var durationMs: Int64 { endMs - startMs }
}

/// What History reads. Time not covered by any returned span is unclassified.
public protocol AudioContentSource: Sendable {
    /// Effective spans (corrections applied) overlapping the window, in time order, clipped to
    /// it, never overlapping each other.
    func spans(overlappingMs window: Range<Int64>) async throws -> [AudioContentSpan]
    /// A cheap value that changes whenever any span or correction overlapping the window does.
    func digest(overlappingMs window: Range<Int64>) async throws -> Int64
}

/// One stored span: a stretch of ONE segment, on both of its clocks.
public struct SegmentAudioContentSpan: Equatable, Sendable {
    public var segmentId: String
    public var index: Int
    public var startMs: Int64
    public var endMs: Int64
    /// The same stretch on the segment's stored-audio clock — what a transcript's turn
    /// timings are on, and what the AI-input and boundary masks are cut by.
    public var mediaStartMs: Int64
    public var mediaEndMs: Int64
    public var kind: AudioContentKind
    public var descriptor: String?
    public var confidence: Double
    public var decidedBy: String
    public var version: Int
    public var wordCount: Int

    public init(
        segmentId: String, index: Int, startMs: Int64, endMs: Int64, mediaStartMs: Int64,
        mediaEndMs: Int64, kind: AudioContentKind, descriptor: String? = nil,
        confidence: Double, decidedBy: String, version: Int, wordCount: Int = 0
    ) {
        self.segmentId = segmentId
        self.index = index
        self.startMs = startMs
        self.endMs = endMs
        self.mediaStartMs = mediaStartMs
        self.mediaEndMs = mediaEndMs
        self.kind = kind
        self.descriptor = descriptor
        self.confidence = confidence
        self.decidedBy = decidedBy
        self.version = version
        self.wordCount = wordCount
    }

    public var span: AudioContentSpan {
        AudioContentSpan(
            startMs: startMs, endMs: endMs, kind: kind, descriptor: descriptor,
            confidence: confidence, decidedBy: decidedBy, version: version, wordCount: wordCount)
    }
}

/// A person's statement about a stretch of time: "this was a conversation" (or was not).
public struct AudioContentOverride: Equatable, Sendable, Identifiable {
    public var id: String
    public var startMs: Int64
    public var endMs: Int64
    public var kind: AudioContentKind
    public var createdAtMs: Int64

    public init(id: String, startMs: Int64, endMs: Int64, kind: AudioContentKind, createdAtMs: Int64) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.kind = kind
        self.createdAtMs = createdAtMs
    }
}

public struct AudioContentStore: AudioContentSource {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    // MARK: Derived: per-segment spans

    /// The input each classified segment was last computed from (`AudioContentMethod.inputKey`).
    /// One query at launch; after that the classifier keeps its own copy.
    public func inputKeys() async throws -> [String: String] {
        try await db.reader.read { db in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT segmentId, inputKey FROM audio_content_segments") {
                out[row["segmentId"]] = row["inputKey"]
            }
            return out
        }
    }

    /// Replaces one segment's spans in one transaction, and records what they were computed
    /// from. Spans must belong to `segmentId`.
    public func replace(
        segmentId: String, inputKey: String, spans: [SegmentAudioContentSpan], atMs: Int64
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM audio_content_spans WHERE segmentId = ?", arguments: [segmentId])
            for span in spans {
                try db.execute(
                    sql: """
                        INSERT INTO audio_content_spans (
                            segmentId, spanIndex, startMs, endMs, mediaStartMs, mediaEndMs,
                            kind, descriptor, confidence, decidedBy, version, wordCount,
                            rowHash, updatedAtMs)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        segmentId, span.index, span.startMs, span.endMs, span.mediaStartMs,
                        span.mediaEndMs, span.kind.rawValue, span.descriptor, span.confidence,
                        span.decidedBy, span.version, span.wordCount, Self.rowHash(span), atMs,
                    ])
            }
            try db.execute(
                sql: """
                    INSERT INTO audio_content_segments (segmentId, inputKey, updatedAtMs)
                    VALUES (?, ?, ?)
                    ON CONFLICT(segmentId) DO UPDATE SET
                        inputKey = excluded.inputKey, updatedAtMs = excluded.updatedAtMs
                    """,
                arguments: [segmentId, inputKey, atMs])
        }
    }

    /// One segment's stored spans, in order.
    public func spans(segmentId: String) async throws -> [SegmentAudioContentSpan] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM audio_content_spans WHERE segmentId = ? ORDER BY spanIndex",
                arguments: [segmentId]
            ).compactMap(Self.span)
        }
    }

    /// Every stored span whose verdict masks model input or speech evidence — `noConversation`
    /// with words in it. The launch-time load of the in-memory mask; small, because wordless
    /// stretches carry nothing to mask and are left out.
    public func maskingSpans() async throws -> [SegmentAudioContentSpan] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM audio_content_spans
                    WHERE kind = ? AND wordCount > 0
                    ORDER BY segmentId, spanIndex
                    """,
                arguments: [AudioContentKind.noConversation.rawValue]
            ).compactMap(Self.span)
        }
    }

    /// Delete-cascade and retention: a segment that no longer exists keeps no classification.
    /// Corrections are kept; they are about time, not about a file.
    public func forget(segmentIds: [String]) async throws {
        guard !segmentIds.isEmpty else { return }
        try await db.writer.write { db in
            let marks = databaseQuestionMarks(count: segmentIds.count)
            let args = StatementArguments(segmentIds)
            try db.execute(sql: "DELETE FROM audio_content_spans WHERE segmentId IN (\(marks))", arguments: args)
            try db.execute(sql: "DELETE FROM audio_content_segments WHERE segmentId IN (\(marks))", arguments: args)
        }
    }

    // MARK: Authoritative: corrections

    /// Records a person's correction for `[startMs, endMs)`. A later correction over the same
    /// time wins over an earlier one; `removeOverride` undoes one.
    @discardableResult
    public func addOverride(
        startMs: Int64, endMs: Int64, kind: AudioContentKind, atMs: Int64,
        id: String = UUID().uuidString.lowercased()
    ) async throws -> AudioContentOverride {
        let override = AudioContentOverride(
            id: id, startMs: startMs, endMs: max(endMs, startMs), kind: kind, createdAtMs: atMs)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audio_content_overrides (id, startMs, endMs, kind, createdAtMs)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    override.id, override.startMs, override.endMs, override.kind.rawValue,
                    override.createdAtMs,
                ])
        }
        return override
    }

    public func removeOverride(id: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM audio_content_overrides WHERE id = ?", arguments: [id])
        }
    }

    public func overrides(overlappingMs window: Range<Int64>) async throws -> [AudioContentOverride] {
        try await db.reader.read { try Self.overrides(in: $0, window) }
    }

    // MARK: AudioContentSource

    public func spans(overlappingMs window: Range<Int64>) async throws -> [AudioContentSpan] {
        let (stored, overrides) = try await db.reader.read { db in
            (try Self.stored(in: db, window), try Self.overrides(in: db, window))
        }
        return Self.effectiveSpans(stored: stored.map(\.span), overrides: overrides, window: window)
    }

    public func digest(overlappingMs window: Range<Int64>) async throws -> Int64 {
        try await db.reader.read { db in
            let args: StatementArguments = [window.lowerBound, window.upperBound]
            let spans = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS n, COALESCE(SUM(rowHash), 0) AS h FROM audio_content_spans
                    WHERE endMs > ? AND startMs < ?
                    """,
                arguments: args)
            let overrides = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS n, COALESCE(SUM(startMs % 1000003 + endMs % 999983), 0) AS h,
                           COALESCE(MAX(createdAtMs), 0) AS t
                    FROM audio_content_overrides WHERE endMs > ? AND startMs < ?
                    """,
                arguments: args)
            let n1: Int64 = spans?["n"] ?? 0, h1: Int64 = spans?["h"] ?? 0
            let n2: Int64 = overrides?["n"] ?? 0, h2: Int64 = overrides?["h"] ?? 0
            let t2: Int64 = overrides?["t"] ?? 0
            var hasher = Hasher64()
            for value in [n1, h1, n2, h2, t2] { hasher.combine(value) }
            return hasher.value
        }
    }

    // MARK: Pure: corrections applied over the computed spans

    /// Applies corrections over the computed spans and merges what touches.
    ///
    /// A correction only relabels time that is classified: it never invents a span over a gap
    /// or over audio still waiting to be transcribed, because a person's "this was a
    /// conversation" is about the audio they heard, and unrecorded time has none. Where two
    /// corrections overlap, the later one wins. Adjacent pieces merge when they say the same
    /// thing (kind, descriptor, decider, version) and touch within a second — the seam between
    /// two segments, which is not information.
    public static func effectiveSpans(
        stored: [AudioContentSpan], overrides: [AudioContentOverride], window: Range<Int64>
    ) -> [AudioContentSpan] {
        let computed = stored
            .map { span -> AudioContentSpan in
                var span = span
                span.startMs = max(span.startMs, window.lowerBound)
                span.endMs = min(span.endMs, window.upperBound)
                return span
            }
            .filter { $0.endMs > $0.startMs }
            .sorted { $0.startMs < $1.startMs }
        let corrections = overrides.sorted { $0.createdAtMs < $1.createdAtMs }

        var pieces: [AudioContentSpan] = []
        for span in computed {
            // Cut points inside this span: every correction edge that falls within it.
            var cuts: [Int64] = [span.startMs, span.endMs]
            for correction in corrections {
                for edge in [correction.startMs, correction.endMs]
                where edge > span.startMs && edge < span.endMs {
                    cuts.append(edge)
                }
            }
            cuts = Array(Set(cuts)).sorted()
            for (low, high) in zip(cuts, cuts.dropFirst()) {
                var piece = span
                piece.startMs = low
                piece.endMs = high
                piece.wordCount = span.durationMs > 0
                    ? Int((Int64(span.wordCount) * (high - low) + span.durationMs / 2) / span.durationMs)
                    : 0
                if let correction = corrections.last(where: { $0.startMs <= low && $0.endMs >= high }) {
                    piece.kind = correction.kind
                    piece.descriptor = nil
                    piece.confidence = 1
                    piece.decidedBy = AudioContentDecider.user
                }
                pieces.append(piece)
            }
        }

        var merged: [AudioContentSpan] = []
        for piece in pieces {
            if var last = merged.last, piece.startMs - last.endMs <= 1_000,
                piece.startMs >= last.startMs, last.kind == piece.kind,
                last.descriptor == piece.descriptor, last.decidedBy == piece.decidedBy,
                last.version == piece.version
            {
                last.endMs = max(last.endMs, piece.endMs)
                last.confidence = min(last.confidence, piece.confidence)
                last.wordCount += piece.wordCount
                merged[merged.count - 1] = last
            } else {
                // Segments do not overlap on the wall clock; if a sidecar ever says otherwise,
                // the later one starts where the earlier ends rather than drawing twice.
                var piece = piece
                if let last = merged.last, piece.startMs < last.endMs { piece.startMs = last.endMs }
                if piece.endMs > piece.startMs { merged.append(piece) }
            }
        }
        return merged
    }

    // MARK: Rows

    static func stored(in db: Database, _ window: Range<Int64>) throws -> [SegmentAudioContentSpan] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM audio_content_spans WHERE endMs > ? AND startMs < ?
                ORDER BY startMs
                """,
            arguments: [window.lowerBound, window.upperBound]
        ).compactMap(span)
    }

    static func overrides(in db: Database, _ window: Range<Int64>) throws -> [AudioContentOverride] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM audio_content_overrides WHERE endMs > ? AND startMs < ?
                ORDER BY createdAtMs
                """,
            arguments: [window.lowerBound, window.upperBound]
        ).compactMap { row in
            guard let kind = AudioContentKind(rawValue: row["kind"]) else { return nil }
            return AudioContentOverride(
                id: row["id"], startMs: row["startMs"], endMs: row["endMs"], kind: kind,
                createdAtMs: row["createdAtMs"])
        }
    }

    static func span(_ row: Row) -> SegmentAudioContentSpan? {
        guard let kind = AudioContentKind(rawValue: row["kind"]) else { return nil }
        return SegmentAudioContentSpan(
            segmentId: row["segmentId"], index: row["spanIndex"], startMs: row["startMs"],
            endMs: row["endMs"], mediaStartMs: row["mediaStartMs"], mediaEndMs: row["mediaEndMs"],
            kind: kind, descriptor: row["descriptor"], confidence: row["confidence"],
            decidedBy: row["decidedBy"], version: row["version"], wordCount: row["wordCount"])
    }

    /// Order-independent per-row fingerprint, so `SUM` over a window changes when any row in it
    /// does. 32 bits keeps the sum of a year of rows well inside an Int64.
    static func rowHash(_ span: SegmentAudioContentSpan) -> Int64 {
        var hasher = Hasher64()
        hasher.combine(span.segmentId)
        hasher.combine(Int64(span.index))
        hasher.combine(span.startMs)
        hasher.combine(span.endMs)
        hasher.combine(span.kind.rawValue)
        hasher.combine(span.descriptor ?? "")
        hasher.combine(span.decidedBy)
        hasher.combine(Int64(span.version))
        hasher.combine(Int64(span.wordCount))
        hasher.combine(Int64((span.confidence * 1_000).rounded()))
        return hasher.value & 0xFFFF_FFFF
    }
}

/// FNV-1a, 64-bit. `Hasher` is seeded per process, which is useless for a value that is
/// stored in one launch and compared in the next.
struct Hasher64 {
    private(set) var value: Int64 = Int64(bitPattern: 0xcbf2_9ce4_8422_2325)

    mutating func combine(_ string: String) {
        for byte in string.utf8 { mix(byte) }
        mix(0xFF)
    }

    mutating func combine(_ number: Int64) {
        withUnsafeBytes(of: number.littleEndian) { for byte in $0 { mix(byte) } }
    }

    private mutating func mix(_ byte: UInt8) {
        var bits = UInt64(bitPattern: value)
        bits ^= UInt64(byte)
        bits = bits &* 0x0000_0100_0000_01B3
        value = Int64(bitPattern: bits)
    }
}
