import AudioCodec
import Foundation
import SegmentStore

// Port of `app/.../AudioExportManager.kt`.

public struct AudioExportedFile: Sendable, Equatable {
    public let segmentId: String
    public let path: String
    public let bytes: Int64

    public init(segmentId: String, path: String, bytes: Int64) {
        self.segmentId = segmentId
        self.path = path
        self.bytes = bytes
    }
}

public struct AudioExportResult: Sendable, Equatable {
    public let directory: String
    public let files: [AudioExportedFile]
    public let skippedOpenSegments: Int

    public init(directory: String, files: [AudioExportedFile], skippedOpenSegments: Int = 0) {
        self.directory = directory
        self.files = files
        self.skippedOpenSegments = skippedOpenSegments
    }

    public var fileCount: Int { files.count }
}

/// Which frames of a segment's frame log a range of its stored audio is.
///
/// A conversation owns a RANGE of a segment's stored audio, in milliseconds from the segment's
/// first stored frame (the clock transcript timings are on). Frame `i` of the sequence-sorted
/// log covers `[i × d, (i + 1) × d)` ms, so the range `[start, end)` is frames
/// `[start / d, end / d)`. Playback and export both slice with this one function, because two
/// conversations that share a segment have to meet on the same frame: computed twice, slightly
/// differently, the last frame of one would also be the first of the next — or nobody's.
///
/// `nil` bounds mean "from the first frame" and "to the last there is", which is how a whole
/// segment and the still-growing end of the open one are written.
public enum SegmentFrameRange {
    public static func frames(
        fromMediaMs startMs: Int64?, toMediaMs endMs: Int64?, frameCount: Int,
        frameDurationMs: Int64 = 20
    ) -> Range<Int> {
        let duration = max(frameDurationMs, 1)
        let count = max(frameCount, 0)
        let lower = min(max(Int((startMs ?? 0) / duration), 0), count)
        let upper = endMs.map { min(max(Int($0 / duration), lower), count) } ?? count
        return lower..<upper
    }
}

/// Writes user-accessible WAV copies of stored watch audio.
///
/// The durable store remains the compact Speex frame log. Exports are opt-in because WAV uses
/// much more disk space, but the resulting files are normal audio files visible in the export
/// directory (`Documents/PebbleAudioExports` in the app, so the Files app can see them). The
/// automatic-export pass is `exportAllClosedSegments(overwrite: false)`: it skips still-open
/// segments and never rewrites a WAV that already exists.
public final class AudioExportManager: Sendable {
    private let exportRoot: URL
    private let listSegments: @Sendable () -> [SegmentMeta]
    private let readMeta: @Sendable (String) -> SegmentMeta?
    private let readFrames: @Sendable (String) -> [FrameRecord]
    private let decodePcm: @Sendable (SegmentMeta, [FrameRecord]) -> AsyncThrowingStream<Data, Error>

    public init(
        exportRoot: URL,
        listSegments: @escaping @Sendable () -> [SegmentMeta],
        readMeta: @escaping @Sendable (String) -> SegmentMeta?,
        readFrames: @escaping @Sendable (String) -> [FrameRecord],
        decodePcm: @escaping @Sendable (SegmentMeta, [FrameRecord]) -> AsyncThrowingStream<Data, Error>
    ) {
        self.exportRoot = exportRoot
        self.listSegments = listSegments
        self.readMeta = readMeta
        self.readFrames = readFrames
        self.decodePcm = decodePcm
    }

    /// The app's export directory: `Documents/PebbleAudioExports`.
    public static func defaultExportRoot() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("PebbleAudioExports", isDirectory: true)
    }

    public var directory: String { exportRoot.path }

    public func exportSegment(_ segmentId: String, overwrite: Bool = true) async throws -> AudioExportResult {
        guard let meta = readMeta(segmentId) else {
            return AudioExportResult(directory: directory, files: [])
        }
        let file = try await exportOne(meta, overwrite: overwrite)
        return AudioExportResult(directory: directory, files: [file].compactMap { $0 })
    }

    /// Exports one RANGE of a segment's stored audio — the piece of it a conversation owns —
    /// as its own WAV. `nil` bounds mean from the segment's first frame and to its last; both
    /// nil is the whole segment, and is exactly `exportSegment(_:overwrite:)`.
    ///
    /// A partial range is written under its own name (the segment's, plus the range), never
    /// the segment's: the automatic pass skips any segment whose WAV already exists, so a
    /// piece written under the segment's name would stand in for the whole recording from
    /// then on, with most of it missing.
    public func exportSegment(
        _ segmentId: String, fromMediaMs startMs: Int64?, toMediaMs endMs: Int64?,
        overwrite: Bool = true
    ) async throws -> AudioExportResult {
        guard (startMs ?? 0) > 0 || endMs != nil else {
            return try await exportSegment(segmentId, overwrite: overwrite)
        }
        guard let meta = readMeta(segmentId) else {
            return AudioExportResult(directory: directory, files: [])
        }
        let frames = readFrames(segmentId)
        let frameMs = Int64(max(meta.frameDurationMs, 1))
        let range = SegmentFrameRange.frames(
            fromMediaMs: startMs, toMediaMs: endMs, frameCount: frames.count,
            frameDurationMs: frameMs)
        // Named by the frames actually written, so two exports of the same piece land on the
        // same file and a piece that has since grown gets a new one.
        let name =
            "\(exportBaseName(meta))-\(Int64(range.lowerBound) * frameMs)-"
            + "\(Int64(range.upperBound) * frameMs)ms"
        let file = try await write(
            meta, frames: Array(frames[range]), name: name, overwrite: overwrite)
        return AudioExportResult(directory: directory, files: [file].compactMap { $0 })
    }

    public func exportAllClosedSegments(overwrite: Bool = false) async throws -> AudioExportResult {
        var skippedOpen = 0
        var exported: [AudioExportedFile] = []
        for meta in listSegments() {
            if meta.isOpen {
                skippedOpen += 1
                continue
            }
            if let file = try await exportOne(meta, overwrite: overwrite) {
                exported.append(file)
            }
        }
        return AudioExportResult(directory: directory, files: exported, skippedOpenSegments: skippedOpen)
    }

    private func exportOne(_ meta: SegmentMeta, overwrite: Bool) async throws -> AudioExportedFile? {
        try await write(
            meta, frames: readFrames(meta.segmentId), name: exportBaseName(meta),
            overwrite: overwrite)
    }

    /// Decodes `frames` into `<name>.wav`. Nothing is written for no frames: an empty WAV in
    /// Files reads as a recording that failed.
    private func write(
        _ meta: SegmentMeta, frames: [FrameRecord], name: String, overwrite: Bool
    ) async throws -> AudioExportedFile? {
        if frames.isEmpty { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let outputURL = exportRoot.appendingPathComponent("\(name).wav")
        if !overwrite && fm.fileExists(atPath: outputURL.path) {
            let attributes = try? fm.attributesOfItem(atPath: outputURL.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return AudioExportedFile(segmentId: meta.segmentId, path: outputURL.path, bytes: size)
        }

        let expectedPcmBytes = Int(
            min(
                Int64(frames.count) * Int64(meta.frameSamples) * Int64(MemoryLayout<Int16>.size),
                Int64(Int32.max)))
        var written: Int64 = 0
        fm.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        do {
            let header = PcmWav.headerMono16(pcmSizeBytes: expectedPcmBytes, sampleRateHz: Int(meta.sampleRateHz))
            try handle.write(contentsOf: header)
            written += Int64(header.count)
            for try await pcm in decodePcm(meta, frames) {
                try handle.write(contentsOf: pcm)
                written += Int64(pcm.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        return AudioExportedFile(segmentId: meta.segmentId, path: outputURL.path, bytes: written)
    }

    private func exportBaseName(_ meta: SegmentMeta) -> String {
        let timePart = String(meta.receivedAtMs)
        let shortId = String(meta.segmentId.suffix(12))
        return sanitizeFilename("pebble-audio-\(timePart)-\(shortId)")
    }

    private func sanitizeFilename(_ name: String) -> String {
        String(
            name.map { char in
                (char.isLetter || char.isNumber || char == "-" || char == "_") ? char : "-"
            })
    }
}
