import Foundation

// Port of `core/storage/.../FileReceiverResumeStore.kt`.

/// On-disk JSON shape. kotlinx.serialization compatibility: fields equal to their defaults are
/// omitted on encode (`lastContiguousSequence` when nil, `lastSampleIndex` when 0) and default
/// on decode, so files the old KMP app wrote parse identically.
private struct ResumeStateJson {
    var lastStreamId: UInt32
    var lastContiguousSequence: UInt32?
    var lastSampleIndex: UInt64
}

extension ResumeStateJson: Codable {
    private enum CodingKeys: String, CodingKey {
        case lastStreamId, lastContiguousSequence, lastSampleIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastStreamId = try c.decode(UInt32.self, forKey: .lastStreamId)
        lastContiguousSequence = try c.decodeIfPresent(UInt32.self, forKey: .lastContiguousSequence)
        lastSampleIndex = try c.decodeIfPresent(UInt64.self, forKey: .lastSampleIndex) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lastStreamId, forKey: .lastStreamId)
        try c.encodeIfPresent(lastContiguousSequence, forKey: .lastContiguousSequence)
        if lastSampleIndex != 0 { try c.encode(lastSampleIndex, forKey: .lastSampleIndex) }
    }
}

/// Persisted receiver resume state (`receiver_state.json`, plan 6.2 step 5): survives process
/// death so a reconnect can resume from the last stream id/sequence. Written via temp file +
/// atomic rename.
public final class FileReceiverResumeStore: ReceiverResumeStore, Sendable {
    private let root: URL
    private let path: URL
    private let tmpPath: URL

    public init(root: URL) {
        self.root = root
        self.path = root.appendingPathComponent("receiver_state.json")
        self.tmpPath = root.appendingPathComponent("receiver_state.json.tmp")
    }

    public func save(_ state: ReceiverResumeState) async {
        // The seam's save is non-throwing; a failed write self-heals on the next checkpoint
        // (the resume state is a hint, the segment store holds the durable audio).
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = ResumeStateJson(
            lastStreamId: state.lastStreamId,
            lastContiguousSequence: state.lastContiguousSequence,
            lastSampleIndex: state.lastSampleIndex
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        guard (try? data.write(to: tmpPath)) != nil else { return }
        _ = rename(tmpPath.path, path.path)
    }

    public func load() async -> ReceiverResumeState? {
        guard FileManager.default.fileExists(atPath: path.path),
            let data = try? Data(contentsOf: path),
            let parsed = try? JSONDecoder().decode(ResumeStateJson.self, from: data)
        else { return nil }
        return ReceiverResumeState(
            lastStreamId: parsed.lastStreamId,
            lastContiguousSequence: parsed.lastContiguousSequence,
            lastSampleIndex: parsed.lastSampleIndex
        )
    }

    public func clear() async {
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path) { try? fm.removeItem(at: path) }
        if fm.fileExists(atPath: tmpPath.path) { try? fm.removeItem(at: tmpPath) }
    }
}
