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

/// File-backed transcript storage: one `<root>/transcription/transcripts/<segment_id>.transcript.json`
/// per transcribed segment, written via temp file + atomic rename like every other durable
/// file store in this app. `root` is the same directory the `SegmentStore` lives under.
public final class FileTranscriptStore: Sendable {
    public static let suffix = ".transcript.json"

    private let transcriptsDir: URL
    private let nowMs: @Sendable () -> Int64

    public init(root: URL, nowMs: @escaping @Sendable () -> Int64) {
        self.transcriptsDir =
            root
            .appendingPathComponent("transcription", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        self.nowMs = nowMs
    }

    private func transcriptURL(_ segmentId: String) -> URL {
        transcriptsDir.appendingPathComponent("\(segmentId)\(Self.suffix)")
    }

    @discardableResult
    public func save(_ segmentId: String, result: RoutedTranscription) throws -> SegmentTranscript {
        let transcript = SegmentTranscript(
            segmentId: segmentId,
            text: result.text,
            modeUsed: result.modeUsed,
            providerId: result.providerId,
            modelUsed: result.modelUsed,
            createdAtMs: nowMs(),
            segments: result.segments,
            words: result.words
        )
        try write(transcript)
        return transcript
    }

    public func load(_ segmentId: String) -> SegmentTranscript? {
        let url = transcriptURL(segmentId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SegmentTranscript.self, from: data)
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

    public func delete(_ segmentId: String) throws {
        try removeIfExists(transcriptURL(segmentId))
    }

    public func deleteAll() throws {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: transcriptsDir, includingPropertiesForKeys: nil)) ?? []
        for url in entries {
            let name = url.lastPathComponent
            if name.hasSuffix(Self.suffix) || name.hasSuffix("\(Self.suffix).tmp") {
                try removeIfExists(url)
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
