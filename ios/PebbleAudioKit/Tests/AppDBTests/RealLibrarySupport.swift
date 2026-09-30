import Foundation
import SegmentStore

@testable import AppDB

// A READ-ONLY copy of a real library — segment metas plus the durable transcripts beside them —
// for the characterisation suites (`RealSegmentBoundaryTests`,
// `RealSegmentSplitDistributionTests`). Nothing here writes, and every suite that uses it skips
// cleanly where the backup is absent.

/// Just enough of the durable transcript sidecar to build evidence — AppDB cannot see
/// `Transcription.SegmentTranscript` (the dependency runs the other way).
private struct RealTranscript: Decodable {
    struct Turn: Decodable {
        var startMs: Int64
        var endMs: Int64
        var text: String?
        var speaker: String?
    }
    var segments: [Turn]?
}

struct RealLibrary: Sendable {
    var metas: [SegmentMeta]
    /// Built the way the app builds it: word counts and the segmenter's features from the text.
    var evidence: [String: SegmentSpeechEvidence]

    var metasById: [String: SegmentMeta] {
        Dictionary(metas.map { ($0.segmentId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func transcriptsPath(forSegments segmentsPath: String) -> String {
        URL(fileURLWithPath: segmentsPath)
            .deletingLastPathComponent()
            .appendingPathComponent("transcription/transcripts").path
    }

    static func isAvailable(segmentsPath: String) -> Bool {
        FileManager.default.fileExists(atPath: segmentsPath, isDirectory: nil)
            && FileManager.default.fileExists(
                atPath: transcriptsPath(forSegments: segmentsPath), isDirectory: nil)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: RealLibrary] = [:]

    /// Decoding a library is most of these suites' run time, so each path is read once.
    static func load(segmentsPath: String) throws -> RealLibrary {
        lock.lock()
        defer { lock.unlock() }
        if let hit = loaded[segmentsPath] { return hit }
        let decoder = JSONDecoder()
        let metas = try FileManager.default
            .contentsOfDirectory(
                at: URL(fileURLWithPath: segmentsPath), includingPropertiesForKeys: nil
            )
            .filter { $0.lastPathComponent.hasSuffix(".meta.json") }
            .map { try decoder.decode(SegmentMeta.self, from: Data(contentsOf: $0)) }
        let transcripts = URL(fileURLWithPath: transcriptsPath(forSegments: segmentsPath))
        var evidence: [String: SegmentSpeechEvidence] = [:]
        for meta in metas {
            let url = transcripts.appendingPathComponent("\(meta.segmentId).transcript.json")
            let speech: [SpeechSpan]? = (try? Data(contentsOf: url))
                .flatMap { try? decoder.decode(RealTranscript.self, from: $0) }
                .map {
                    ($0.segments ?? []).map { turn in
                        SpeechSpan(
                            startMs: turn.startMs, endMs: turn.endMs, text: turn.text ?? "",
                            speaker: turn.speaker)
                    }
                }
            evidence[meta.segmentId] = SegmentSpeechEvidence.of(meta, transcriptSpeech: speech)
        }
        let library = RealLibrary(metas: metas, evidence: evidence)
        loaded[segmentsPath] = library
        return library
    }

    func group(_ policy: BoundaryPolicy, evidence: [String: SegmentSpeechEvidence]? = nil)
        -> [GroupedConversation]
    {
        ConversationGrouper.group(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence ?? self.evidence, policy: policy)
    }
}
