import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// A MEASUREMENT AID, not a test: dumps one backup's segments and transcript turns, placed on the
// wall clock by the app's own `SegmentMediaClock`, as JSON lines — so conversation-splitting
// rules can be prototyped and scored outside the app against exactly the positions the app
// would compute. Asserts nothing, writes only to the folder it is told to, and the backup is
// only read.
//
//   PEBBLE_UNITS_EXPORT_BACKUP=<backup root holding segments/ and transcription/>
//   PEBBLE_UNITS_EXPORT_OUT=<folder to write segments.jsonl into>
//
// Nothing it writes may be committed: it is a person's transcripts.

private let exportEnv = ProcessInfo.processInfo.environment
private let exportRoot = exportEnv["PEBBLE_UNITS_EXPORT_BACKUP"]
private let exportOut = exportEnv["PEBBLE_UNITS_EXPORT_OUT"]

private var exportAvailable: Bool {
    guard let exportRoot, exportOut != nil else { return false }
    return FileManager.default.fileExists(atPath: exportRoot + "/segments")
}

private struct ExportTranscript: Decodable {
    struct Turn: Decodable {
        var startMs: Int64
        var endMs: Int64
        var text: String?
        var speaker: String?
    }
    var segments: [Turn]?
    var providerId: String?
}

private struct ExportedTurn: Encodable {
    var i: Int
    var ms: Int64
    var me: Int64
    var ws: Int64
    var we: Int64
    var sp: String?
    var text: String
}

private struct ExportedSegment: Encodable {
    var segmentId: String
    var streamId: UInt32
    var startWallMs: Int64
    var endWallMs: Int64
    var audioMs: Int64
    var receivedAtMs: Int64
    var state: String
    var closeKind: String?
    var userStop: Bool
    var isOpen: Bool
    var exact: Bool
    var timeZone: String?
    var provider: String?
    var hasTranscript: Bool
    /// Wall-clock spans of MISSING audio (loss), and of watch-suppressed silence.
    var loss: [[Int64]]
    var silence: [[Int64]]
    var turns: [ExportedTurn]
}

@Suite(
    "Conversation unit export",
    .enabled(if: exportAvailable, "set PEBBLE_UNITS_EXPORT_BACKUP and PEBBLE_UNITS_EXPORT_OUT")
)
struct ConversationUnitExport {
    @Test func exportSegmentsAndTurns() throws {
        let root = URL(fileURLWithPath: exportRoot!)
        let decoder = JSONDecoder()
        let files: [URL] = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("segments"), includingPropertiesForKeys: nil)
        var metas: [SegmentMeta] = []
        for file in files where file.lastPathComponent.hasSuffix(".meta.json") {
            metas.append(try decoder.decode(SegmentMeta.self, from: Data(contentsOf: file)))
        }
        metas.sort { (x: SegmentMeta, y: SegmentMeta) -> Bool in
            if x.receivedAtMs != y.receivedAtMs { return x.receivedAtMs < y.receivedAtMs }
            return x.segmentId < y.segmentId
        }
        let encoder = JSONEncoder()
        var lines: [String] = []
        for meta in metas {
            let start = ConversationGrouper.segmentStartMs(meta)
            let end = ConversationGrouper.segmentEndMs(meta)
            let span = max(end - start, 0)
            let clock = SegmentMediaClock(meta)
            let toWall: (Int64) -> Int64 = clock.isExact ? { clock.wall(fromMedia: $0) } : { $0 }
            let url = root.appendingPathComponent(
                "transcription/transcripts/\(meta.segmentId).transcript.json")
            var transcript: ExportTranscript?
            if let data = try? Data(contentsOf: url) {
                transcript = try? decoder.decode(ExportTranscript.self, from: data)
            }
            var turns: [ExportedTurn] = []
            let sourceTurns: [ExportTranscript.Turn] = transcript?.segments ?? []
            for (i, turn) in sourceTurns.enumerated() {
                let a: Int64 = min(max(toWall(turn.startMs), 0), span)
                let b: Int64 = min(max(toWall(turn.endMs), a), span)
                turns.append(
                    ExportedTurn(
                        i: i, ms: turn.startMs, me: turn.endMs, ws: start + a, we: start + b,
                        sp: turn.speaker, text: turn.text ?? ""))
            }
            let rate = UInt64(meta.sampleRateHz > 0 ? meta.sampleRateHz : 16_000)
            let frameSamples = UInt64(max(meta.frameSamples, 1))
            var silence: [[Int64]] = []
            if let first = meta.firstSampleIndex {
                for gap in meta.gaps {
                    guard let raw = gap.reasonRaw,
                        let reason = GapReason(rawValue: UInt8(clamping: raw)), reason.isSilence,
                        gap.firstMissingSampleIndex >= first
                    else { continue }
                    let ahead: UInt64 = gap.firstMissingSampleIndex - first
                    let offset = Int64(ahead * 1000 / rate)
                    let missing: UInt64 = UInt64(gap.missingFrameCount) * frameSamples
                    let length = Int64(missing * 1000 / rate)
                    let a: Int64 = min(max(start + offset, start), end)
                    let b: Int64 = min(max(a + length, a), end)
                    if b > a { silence.append([a, b]) }
                }
            }
            let lossSpans: [[Int64]] = ConversationBoundaryDetector.lossSpansMs(meta).map {
                [$0.0, $0.1]
            }
            let segment = ExportedSegment(
                segmentId: meta.segmentId, streamId: meta.streamId, startWallMs: start,
                endWallMs: end, audioMs: ConversationGrouper.segmentAudioMs(meta),
                receivedAtMs: meta.receivedAtMs, state: meta.transcriptionState.rawValue,
                closeKind: meta.closeReason?.kind,
                userStop: ConversationGrouper.endsWithUserStop(meta), isOpen: meta.isOpen,
                exact: clock.isExact, timeZone: meta.recordedTimeZone,
                provider: transcript?.providerId, hasTranscript: transcript != nil,
                loss: lossSpans,
                silence: silence, turns: turns)
            lines.append(String(decoding: try encoder.encode(segment), as: UTF8.self))
        }
        let out = URL(fileURLWithPath: exportOut!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(
            to: out.appendingPathComponent("segments.jsonl"), atomically: true, encoding: .utf8)
        print("exported \(metas.count) segments, \(lines.count) lines to \(out.path)")
    }
}
