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
        let frames = readFrames(meta.segmentId)
        if frames.isEmpty { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let outputURL = exportRoot.appendingPathComponent("\(exportBaseName(meta)).wav")
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
