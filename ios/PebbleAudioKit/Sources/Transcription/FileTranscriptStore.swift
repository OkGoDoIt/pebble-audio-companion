import Foundation

// Port of `core/transcription/.../TranscriptStore.kt`.
//
// JSON compatibility note: the KMP app wrote these files with kotlinx.serialization and
// `encodeDefaults = false`, so any field whose value equals its Kotlin default (nullable
// `modelUsed`/`speaker` that are null, empty `segments`/`words` lists) is OMITTED from the
// JSON. The custom Codable implementation below reproduces that exactly — the migration
// importer reads files the old app wrote, and the old app's parser must remain able to read
// ours (same pattern as `SegmentMeta`).

/// Durable transcript for one segment, with the provenance required by the guide: provider,
/// model, mode used, and creation time. Stored beside (not inside) the segment metadata so the
/// transcript survives independent of receive-path rewrites.
public struct SegmentTranscript: Equatable, Sendable {
    public var segmentId: String
    public var text: String
    public var modeUsed: TranscriptionMode
    public var providerId: String
    public var modelUsed: String?
    public var createdAtMs: Int64
    public var segments: [TranscriptSegment]
    public var words: [TranscriptWord]

    public init(
        segmentId: String,
        text: String,
        modeUsed: TranscriptionMode,
        providerId: String,
        modelUsed: String? = nil,
        createdAtMs: Int64,
        segments: [TranscriptSegment] = [],
        words: [TranscriptWord] = []
    ) {
        self.segmentId = segmentId
        self.text = text
        self.modeUsed = modeUsed
        self.providerId = providerId
        self.modelUsed = modelUsed
        self.createdAtMs = createdAtMs
        self.segments = segments
        self.words = words
    }
}

extension SegmentTranscript: Codable {
    private enum CodingKeys: String, CodingKey {
        case segmentId, text, modeUsed, providerId, modelUsed, createdAtMs, segments, words
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segmentId = try c.decode(String.self, forKey: .segmentId)
        text = try c.decode(String.self, forKey: .text)
        modeUsed = try c.decode(TranscriptionMode.self, forKey: .modeUsed)
        providerId = try c.decode(String.self, forKey: .providerId)
        modelUsed = try c.decodeIfPresent(String.self, forKey: .modelUsed)
        createdAtMs = try c.decode(Int64.self, forKey: .createdAtMs)
        segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        words = try c.decodeIfPresent([TranscriptWord].self, forKey: .words) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(segmentId, forKey: .segmentId)
        try c.encode(text, forKey: .text)
        try c.encode(modeUsed, forKey: .modeUsed)
        try c.encode(providerId, forKey: .providerId)
        try c.encodeIfPresent(modelUsed, forKey: .modelUsed)
        try c.encode(createdAtMs, forKey: .createdAtMs)
        if !segments.isEmpty { try c.encode(segments, forKey: .segments) }
        if !words.isEmpty { try c.encode(words, forKey: .words) }
    }
}

extension SegmentTranscript {
    /// This transcript without what was said in `ranges` of the segment's stored audio: the
    /// turns and the words that START in one of them are removed and `text` is rebuilt from
    /// the turns that are left.
    ///
    /// The exact complement of `piece(_:)`. A conversation owns the turns whose first instant
    /// falls in its piece, so deleting that piece removes those turns and no others; timings
    /// stay in the segment's media clock, which the delete does not move (the audio is
    /// silenced in place, `SegmentStore.silenceAudio`). A transcript with no turn timings has
    /// nothing to cut by and belongs, whole, to the piece that starts the segment — so it goes
    /// when a range reaches back to the segment's start and stays otherwise.
    ///
    /// Returns `self`, untouched, when nothing falls in the ranges.
    public func redacting(_ ranges: [Range<Int64>]) -> SegmentTranscript {
        guard !ranges.isEmpty else { return self }
        func isRedacted(_ startMs: Int64) -> Bool { ranges.contains { $0.contains(startMs) } }
        guard !segments.isEmpty else {
            guard ranges.contains(where: { $0.lowerBound <= 0 && !$0.isEmpty }),
                !text.isEmpty || !words.isEmpty
            else { return self }
            var copy = self
            copy.text = ""
            copy.words = []
            return copy
        }
        guard segments.contains(where: { isRedacted($0.startMs) })
            || words.contains(where: { isRedacted($0.startMs) })
        else { return self }
        var copy = self
        copy.segments = segments.filter { !isRedacted($0.startMs) }
        copy.words = words.filter { !isRedacted($0.startMs) }
        copy.text = copy.segments.map(\.text).joined(separator: " ")
        return copy
    }
}

/// File-backed transcript storage: one `<root>/transcription/transcripts/<segment_id>.transcript.json`
/// per transcribed segment, written via temp file + atomic rename like every other durable
/// file store in this app. `root` is the same directory the `SegmentStore` lives under.
///
/// Beside a transcript there may be a `<segment_id>.redactions.json`: the stretches of the
/// segment's stored audio that were deleted (see `redact`).
public final class FileTranscriptStore: Sendable {
    public static let suffix = ".transcript.json"
    public static let redactionsSuffix = ".redactions.json"

    private let transcriptsDir: URL
    private let nowMs: @Sendable () -> Int64
    /// Serializes the writers. `save` reads the redactions and then writes the transcript, and
    /// `redact` writes the redactions and then rewrites the transcript; interleaved, a save
    /// that had already read "no redactions" would put the deleted words back a moment after
    /// the delete removed them. Readers take no lock: every write is a whole-file rename.
    private let writeLock = NSLock()
    /// Segments deleted through this store since it was created. Guarded by `writeLock`.
    /// See `save` for what it is for; segment ids are never reused, so an id only ever
    /// enters this set.
    private let deletedSegments = DeletedSegments()

    private final class DeletedSegments: @unchecked Sendable {
        var ids: Set<String> = []
    }

    public init(root: URL, nowMs: @escaping @Sendable () -> Int64) {
        self.transcriptsDir =
            root
            .appendingPathComponent("transcription", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        self.nowMs = nowMs
    }

    private func transcriptURL(_ segmentId: String) -> URL {
        // `isDirectory: false` matters: without it Foundation asks the file system whether the
        // path is a directory on every call, and this is called once per transcript per pass.
        transcriptsDir.appendingPathComponent("\(segmentId)\(Self.suffix)", isDirectory: false)
    }

    private func redactionsURL(_ segmentId: String) -> URL {
        transcriptsDir.appendingPathComponent(
            "\(segmentId)\(Self.redactionsSuffix)", isDirectory: false)
    }

    /// Saves a transcription result — minus anything that falls in a stretch of the segment
    /// that has been deleted (`redact`). Returns what was written.
    ///
    /// The redactions are applied HERE, to every save, because a transcript can land after the
    /// delete that should have removed part of it: a transcription that was already running,
    /// or an upload the OS carried on with while the app was suspended, was made from the
    /// audio as it was and would otherwise write the deleted words straight back.
    ///
    /// For the same reason a save for a segment that has been DELETED writes nothing. The
    /// transcription that was running when the recording was deleted finishes a moment later
    /// and saves; with no segment, no task and no conversation left to hang it on, that file
    /// was the whole transcript of a deleted recording, sitting in the directory until the
    /// next Delete All. The result is still returned, so the caller's bookkeeping — which
    /// finds no task to complete — runs as it would have.
    @discardableResult
    public func save(_ segmentId: String, result: RoutedTranscription) throws -> SegmentTranscript {
        try writeLock.withLock {
            let transcript = SegmentTranscript(
                segmentId: segmentId,
                text: result.text,
                modeUsed: result.modeUsed,
                providerId: result.providerId,
                modelUsed: result.modelUsed,
                createdAtMs: nowMs(),
                segments: result.segments,
                words: result.words
            ).redacting(loadRedactions(segmentId))
            guard !deletedSegments.ids.contains(segmentId) else { return transcript }
            try write(transcript)
            return transcript
        }
    }

    // MARK: - Redaction (deleting part of a segment)

    /// Removes what was said in `mediaRangeMs` of the segment's stored audio, for good.
    ///
    /// Two writes, in this order. First the range joins the segment's redaction sidecar, which
    /// `save` reads: from that moment no transcript of this segment can be written with words
    /// in the range, whoever produces it and whenever it lands. Then the transcript on disk,
    /// if there is one, is rewritten without them (`SegmentTranscript.redacting`).
    ///
    /// Returns the transcript as it now stands, or nil when the segment has none yet — which
    /// is not a failure: the sidecar is what covers the transcript still to come.
    ///
    /// The range is kept as given and never widened to "the rest of the segment": a segment
    /// interrupted by a dropped link can be reattached and grow, and audio recorded after the
    /// delete is not part of what was deleted.
    @discardableResult
    public func redact(_ segmentId: String, mediaRangeMs: Range<Int64>) throws -> SegmentTranscript? {
        guard !mediaRangeMs.isEmpty else { return load(segmentId) }
        return try writeLock.withLock {
            let ranges = Self.merged(loadRedactions(segmentId) + [mediaRangeMs])
            try writeRedactions(segmentId, ranges)
            guard let transcript = load(segmentId) else { return nil }
            let redacted = transcript.redacting(ranges)
            // Untouched when nothing fell in the range, so `version` only moves with the words.
            if redacted != transcript { try write(redacted) }
            return redacted
        }
    }

    /// The stretches of this segment's stored audio that have been deleted, merged and in
    /// order. Empty for a segment nothing was deleted from, which is nearly all of them.
    public func redactions(_ segmentId: String) -> [Range<Int64>] {
        loadRedactions(segmentId)
    }

    /// On-disk shape of the sidecar. Plain numbers rather than `Range`'s own encoding, so the
    /// file says what it means to whoever opens it.
    private struct RedactionFile: Codable {
        struct Span: Codable {
            var startMs: Int64
            var endMs: Int64
        }
        var segmentId: String
        var ranges: [Span]
    }

    private func loadRedactions(_ segmentId: String) -> [Range<Int64>] {
        guard let data = try? Data(contentsOf: redactionsURL(segmentId)),
            let file = try? JSONDecoder().decode(RedactionFile.self, from: data)
        else { return [] }
        return Self.merged(
            file.ranges.compactMap { $0.endMs > $0.startMs ? $0.startMs..<$0.endMs : nil })
    }

    private func writeRedactions(_ segmentId: String, _ ranges: [Range<Int64>]) throws {
        try FileManager.default.createDirectory(
            at: transcriptsDir, withIntermediateDirectories: true)
        let tmp = transcriptsDir.appendingPathComponent(
            "\(segmentId)\(Self.redactionsSuffix).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = RedactionFile(
            segmentId: segmentId,
            ranges: ranges.map { .init(startMs: $0.lowerBound, endMs: $0.upperBound) })
        try encoder.encode(file).write(to: tmp)
        try atomicMove(from: tmp, to: redactionsURL(segmentId))
    }

    /// Sorted, with overlapping and touching ranges joined.
    static func merged(_ ranges: [Range<Int64>]) -> [Range<Int64>] {
        var out: [Range<Int64>] = []
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }

    public func load(_ segmentId: String) -> SegmentTranscript? {
        let url = transcriptURL(segmentId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SegmentTranscript.self, from: data)
    }

    /// A cheap identity for the transcript file: its size and modification time, or "absent".
    /// One `stat`, no read. Anything derived from the decoded transcript can be memoised
    /// against this and recomputed only when the file actually changes.
    ///
    /// Literally one `stat(2)`. It used to be `FileManager.attributesOfItem(atPath:)`, which is
    /// not: Foundation also lists and reads every extended attribute and runs the file through
    /// `CFURLCopyResourcePropertiesForKeys`. The AI stages call this for every member of every
    /// conversation on every pass, and on 2026-09-16 that was 3.3 s of a 5.2 s profile — 64 % of
    /// the app's CPU — confirming that a library nobody had touched was still the same.
    public func version(_ segmentId: String) -> String {
        var status = stat()
        guard stat(transcriptURL(segmentId).path, &status) == 0 else { return "absent" }
        let modified =
            Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1e9
        return "\(status.st_size)@\(modified)"
    }

    /// Just the turn timings, for callers that need to know WHERE speech was and not what was
    /// said — the conversation-boundary layer regroups over every segment in the library, and
    /// `load` would decode the per-word timing array of each one to throw it away. On a full
    /// library that is the megabytes-of-word-JSON shape that already cost this app a main-thread
    /// stall once. Nil means "no transcript file", which is NOT the same as "no speech" and is
    /// what the settling rule keys off.
    public func loadSpeechTimings(_ segmentId: String) -> [TranscriptSegment]? {
        struct TimingsOnly: Decodable { var segments: [TranscriptSegment]? }
        let url = transcriptURL(segmentId)
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(TimingsOnly.self, from: data)
        else { return nil }
        return decoded.segments ?? []
    }

    /// The transcript without its per-word timings — everything a reader of TURNS needs (the
    /// archive sync's export), at a fraction of the decode: the word array is most of the file
    /// and is skipped, not decoded and thrown away.
    public func loadWithoutWords(_ segmentId: String) -> SegmentTranscript? {
        struct TurnsOnly: Decodable {
            var segmentId: String
            var text: String
            var modeUsed: TranscriptionMode
            var providerId: String
            var modelUsed: String?
            var createdAtMs: Int64
            var segments: [TranscriptSegment]?
        }
        guard let data = try? Data(contentsOf: transcriptURL(segmentId)),
            let decoded = try? JSONDecoder().decode(TurnsOnly.self, from: data)
        else { return nil }
        return SegmentTranscript(
            segmentId: decoded.segmentId, text: decoded.text, modeUsed: decoded.modeUsed,
            providerId: decoded.providerId, modelUsed: decoded.modelUsed,
            createdAtMs: decoded.createdAtMs, segments: decoded.segments ?? [])
    }

    public func list() -> [SegmentTranscript] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: transcriptsDir, includingPropertiesForKeys: nil)) ?? []
        return
            entries
            .filter { $0.lastPathComponent.hasSuffix(Self.suffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { load(String($0.lastPathComponent.dropLast(Self.suffix.count))) }
            .sorted { $0.createdAtMs < $1.createdAtMs }  // stable, matching Kotlin sortedBy
    }

    /// The segment is gone: its transcript goes, and so does the record of what had been
    /// deleted from it — there is nothing left for a redaction to be about.
    public func delete(_ segmentId: String) throws {
        try writeLock.withLock {
            // Before the files: a save that arrives after this must find the segment deleted
            // even if removing a file throws.
            deletedSegments.ids.insert(segmentId)
            try removeIfExists(transcriptURL(segmentId))
            try removeIfExists(redactionsURL(segmentId))
        }
    }

    public func deleteAll() throws {
        try writeLock.withLock {
            let entries =
                (try? FileManager.default.contentsOfDirectory(
                    at: transcriptsDir, includingPropertiesForKeys: nil)) ?? []
            for url in entries {
                let name = url.lastPathComponent
                if name.hasSuffix(Self.suffix) {
                    deletedSegments.ids.insert(String(name.dropLast(Self.suffix.count)))
                }
                if name.hasSuffix(Self.suffix) || name.hasSuffix("\(Self.suffix).tmp")
                    || name.hasSuffix(Self.redactionsSuffix)
                    || name.hasSuffix("\(Self.redactionsSuffix).tmp")
                {
                    try removeIfExists(url)
                }
            }
        }
    }

    private func removeIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func write(_ transcript: SegmentTranscript) throws {
        try FileManager.default.createDirectory(
            at: transcriptsDir, withIntermediateDirectories: true)
        let tmp = transcriptsDir.appendingPathComponent(
            "\(transcript.segmentId)\(Self.suffix).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: tmp)
        try atomicMove(from: tmp, to: transcriptURL(transcript.segmentId))
    }

    /// POSIX rename: atomically replaces `to` (Kotlin `FileSystem.atomicMove` semantics).
    private func atomicMove(from: URL, to: URL) throws {
        if rename(from.path, to.path) != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: to.path])
        }
    }
}
