import Foundation
import SegmentStore
import Testing

@testable import AppDB

// Characterisation gate for the QUIET layer, run over a READ-ONLY copy of Roger's real library
// (segment metas + the durable transcripts beside them). Skips cleanly where the backup is
// absent so CI elsewhere stays green — same contract as `RealSegmentGroupingTests`.
//
// What the data said, measured on the 2026-09-08 backup (765 metas, 591 transcripts,
// 2026-06-12 → 2026-09-08), and why the thresholds are what they are:
//
//  * v1 rules alone: 210 conversations. The 163 that contain speech have a median of 16 m 44 s
//    but a p90 of 3 h 40 m and a longest of 17 h 31 m.
//  * The 5-minute chain window cannot see any of that. Of the 555 joins INSIDE those 210
//    conversations, 370 abut to the second and NOT ONE exceeds 5 minutes: rotations hand
//    straight over, and the watch counts through quiet, so the silence is inside the segments.
//  * With this layer at its 15-minute bar plus the flanking-flow guard and the honest extent:
//    263 conversations, 163 with speech, p90 2 h 03 m, longest 7 h 38 m, >4 h down from 16 to 4.
//    (At the 25-minute bar it was 237 / 151 / p90 2 h 54 m / longest 16 h 29 m / >4 h 9.)
//  * Scored against 95 hand-labelled `certain` boundaries at ±3 minutes it finds 67, up from 62,
//    and lands on 34 of the 149 hand-labelled traps, up from 30 — see
//    `RealSegmentSplitDistributionTests` for the full table and both failure classes.
//  * The 8–15 minute band stays a candidate band and waits for the semantic reviewer: in the
//    labels, silences of 5–10 minutes run about 7:1 AGAINST being a boundary.
//
// This suite pins the invariants rather than the exact counts, so a library that grows does not
// fail it — but the direction (fewer monsters, no split without settled evidence) is enforced.

private let segmentsPath =
    ProcessInfo.processInfo.environment["PEBBLE_SEGMENT_BACKUP"]
    ?? NSHomeDirectory()
        + "/Desktop/PebbleAudioBackup/audio-companion-20260831-110954/segments"

private var transcriptsPath: String {
    URL(fileURLWithPath: segmentsPath)
        .deletingLastPathComponent()
        .appendingPathComponent("transcription/transcripts").path
}

private var backupAvailable: Bool {
    FileManager.default.fileExists(atPath: segmentsPath, isDirectory: nil)
        && FileManager.default.fileExists(atPath: transcriptsPath, isDirectory: nil)
}

/// Just enough of the durable transcript sidecar to build evidence — AppDB cannot see
/// `Transcription.SegmentTranscript` (the dependency runs the other way), and the boundary
/// layer only ever needs the speech timings.
private struct BackupTranscript: Decodable {
    struct Turn: Decodable {
        var startMs: Int64
        var endMs: Int64
        /// Carried so the evidence here matches what the app builds: the flanking-flow guard
        /// needs word counts and is inert without them, so a fixture that omitted the text
        /// would be exercising a configuration nothing ships.
        var text: String?
    }
    var segments: [Turn]?
}

private func loadMetas() throws -> [SegmentMeta] {
    let decoder = JSONDecoder()
    return try FileManager.default
        .contentsOfDirectory(at: URL(fileURLWithPath: segmentsPath), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix(".meta.json") }
        .map { try decoder.decode(SegmentMeta.self, from: Data(contentsOf: $0)) }
}

private func loadEvidence(_ metas: [SegmentMeta]) -> [String: SegmentSpeechEvidence] {
    let decoder = JSONDecoder()
    var out: [String: SegmentSpeechEvidence] = [:]
    for meta in metas {
        let url = URL(fileURLWithPath: transcriptsPath)
            .appendingPathComponent("\(meta.segmentId).transcript.json")
        let speech: [SpeechSpan]? = (try? Data(contentsOf: url))
            .flatMap { try? decoder.decode(BackupTranscript.self, from: $0) }
            .map {
                ($0.segments ?? []).map { turn in
                    SpeechSpan(
                        startMs: turn.startMs, endMs: turn.endMs,
                        wordCount: (turn.text ?? "").split(whereSeparator: \.isWhitespace).count)
                }
            }
        out[meta.segmentId] = SegmentSpeechEvidence.of(meta, transcriptSpeech: speech)
    }
    return out
}

@Suite struct RealSegmentBoundaryTests {

    @Test(.enabled(if: backupAvailable))
    func theQuietLayerBreaksUpTheMonstersWithoutFragmentingTheRest() throws {
        let metas = try loadMetas()
        let evidence = loadEvidence(metas)
        let before = ConversationGrouper.group(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            policy: .structuralOnly)
        let after = ConversationGrouper.group(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence)

        // It splits, and it splits conservatively: a rule that DOUBLED the conversation count
        // would be fragmenting real conversations, not finding boundaries.
        //
        // The bound was 3/2 while `quietSplitMs` was 25 minutes. At 15 it is 1.25× on the full
        // 2026-09-08 library (210 → 263) and 1.57× on this smaller, partial snapshot, so the
        // ratio is too coarse to be the real gate — that is now
        // `RealSegmentSplitDistributionTests`, which scores the same grouping against 149
        // hand-labelled NON-boundaries and holds the false-split rate at 34/149.
        #expect(after.count > before.count)
        #expect(after.count < before.count * 2)

        // Nothing is lost or duplicated: every segment still belongs to exactly one
        // conversation, in the same order.
        #expect(after.flatMap(\.memberSegmentIds) == before.flatMap(\.memberSegmentIds))

        // The longest thing in the library gets shorter.
        let longestBefore = before.map { $0.endMs - $0.startMs }.max() ?? 0
        let longestAfter = after.map { $0.endMs - $0.startMs }.max() ?? 0
        #expect(longestAfter < longestBefore)
    }

    /// Every automatic split must be explainable, and only by a reason this layer can defend.
    @Test(.enabled(if: backupAvailable))
    func everyNewSplitCarriesAReasonAndNoneIsAGuess() throws {
        let metas = try loadMetas()
        let evidence = loadEvidence(metas)
        let byId = Dictionary(uniqueKeysWithValues: metas.map { ($0.segmentId, $0) })
        let after = ConversationGrouper.group(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence)

        for conversation in after.dropFirst() {
            #expect(conversation.startReason != nil)
            guard conversation.startReason == .quiet || conversation.startReason == .interrupted
            else { continue }
            // A quiet split only ever happens where the evidence was settled on both sides.
            for id in conversation.memberSegmentIds.prefix(1) {
                #expect(evidence[id]?.isSettled == true)
                #expect(byId[id]?.closeReason != nil)
            }
        }
    }

    /// Determinism over the real library, including the two-pass rebuild shape: same input,
    /// same conversations, same ids, same reasons.
    @Test(.enabled(if: backupAvailable))
    func groupingTheRealLibraryTwiceGivesTheSameAnswer() throws {
        let metas = try loadMetas()
        let evidence = loadEvidence(metas)
        let first = ConversationGrouper.group(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence)
        let second = ConversationGrouper.group(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence)
        #expect(first == second)
    }

    /// The delay trap, on real data: pretending nothing has been transcribed yet must produce
    /// exactly the v1 grouping — not a library shredded by "silence" that is really a queue.
    @Test(.enabled(if: backupAvailable))
    func anUntranscribedLibraryGroupsExactlyAsItDidBefore() throws {
        let metas = try loadMetas()
        let unsettled = Dictionary(
            uniqueKeysWithValues: metas.map {
                ($0.segmentId, SegmentSpeechEvidence(segmentId: $0.segmentId, isSettled: false, speech: []))
            })
        let baseline = ConversationGrouper.group(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            policy: .structuralOnly)
        let withPendingEverything = ConversationGrouper.group(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: unsettled)
        #expect(withPendingEverything.map(\.memberSegmentIds) == baseline.map(\.memberSegmentIds))
    }

    /// The candidate band is small enough to be reviewed by one batched AI call every few days,
    /// and is never so large that the reviewer becomes load-bearing.
    @Test(.enabled(if: backupAvailable))
    func theSemanticLayersWorkListIsSmall() throws {
        let metas = try loadMetas()
        let evidence = loadEvidence(metas)
        let result = ConversationGrouper.groupWithCandidates(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence)
        // At most one open question per conversation: the reviewer is a tie-breaker on a short
        // list, not a second grouping engine. (Measured: 68 candidates over 237 conversations
        // on the 2026-09-08 backup, 36 over 68 on the smaller 2026-08-31 one.)
        #expect(result.candidates.count <= result.conversations.count)
        for candidate in result.candidates {
            #expect(candidate.quietMs >= BoundaryPolicy.default.quietCandidateMs)
            #expect(candidate.newStartSegmentId != candidate.previousEndSegmentId)
        }
    }
}
