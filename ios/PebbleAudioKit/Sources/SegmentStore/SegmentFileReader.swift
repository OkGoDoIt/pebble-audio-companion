import Foundation
import WireProtocol

// A synchronous, Sendable view of the spool on disk.
//
// `SegmentStore` is an actor, but three kit consumers — `AudioExportManager`,
// `SegmentPlaybackController` and `LiveTranscriber` — take SYNCHRONOUS `@Sendable` readers
// (`listSegments`/`readMeta`/`readFrames`), because they decode on their own executors and
// cannot await the store from inside those seams. Tests satisfy them with closures over local
// fixtures; the app needs a real one, and this is it.
//
// It owns no mutable state: every call reads the files. That makes it safe to hand to any
// executor, and it means the open segment is seen at its last sidecar flush — the same
// staleness `SegmentStore.readMeta` documents for its own index.

public struct SegmentFileReader: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private var segmentsDir: URL { root.appendingPathComponent("segments", isDirectory: true) }

    private func metaURL(_ segmentId: String) -> URL {
        segmentsDir.appendingPathComponent(segmentId + SegmentStore.metaSuffix)
    }

    private func logURL(_ segmentId: String) -> URL {
        segmentsDir.appendingPathComponent(segmentId + SegmentStore.logSuffix)
    }

    public func readMeta(_ segmentId: String) -> SegmentMeta? {
        guard let data = try? Data(contentsOf: metaURL(segmentId)) else { return nil }
        return try? JSONDecoder().decode(SegmentMeta.self, from: data)
    }

    public func listSegments() -> [SegmentMeta] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: segmentsDir, includingPropertiesForKeys: nil)) ?? []
        return
            entries
            .filter { $0.lastPathComponent.hasSuffix(SegmentStore.metaSuffix) }
            .compactMap {
                readMeta(String($0.lastPathComponent.dropLast(SegmentStore.metaSuffix.count)))
            }
            .sorted { a, b in
                if a.receivedAtMs != b.receivedAtMs { return a.receivedAtMs < b.receivedAtMs }
                return a.segmentId < b.segmentId
            }
    }

    /// Frames in stream order. Gap refills append after later frames, so the on-disk log is not
    /// strictly ordered — every consumer wants stream order.
    public func readFrames(_ segmentId: String) -> [FrameRecord] {
        guard let data = try? Data(contentsOf: logURL(segmentId)) else { return [] }
        return SegmentFrameLog.parse([UInt8](data)).records.sorted { $0.sequence < $1.sequence }
    }
}

/// The frame-log record parser, shared by the store and the file reader.
enum SegmentFrameLog {
    static func parse(_ bytes: [UInt8]) -> (records: [FrameRecord], validBytes: Int) {
        var records: [FrameRecord] = []
        var offset = 0
        var reader = WireReader(bytes)
        while true {
            if reader.remaining < SegmentStore.recordHeaderBytes { break }
            let sequence = reader.u32()
            let sampleIndex = reader.u64()
            let len = reader.u16()
            if len > ProtocolConstants.maxEncodedFrameBytes || reader.remaining < len { break }
            records.append(
                FrameRecord(
                    sequence: sequence, sampleIndex: sampleIndex, payload: reader.readBytes(len)
                )
            )
            offset += SegmentStore.recordHeaderBytes + len
        }
        return (records, offset)
    }
}
