import Foundation
import SegmentStore
import Testing

@testable import AppDB

// Characterisation gate for the conversation grouping, run over a READ-ONLY copy of Roger's
// real segment metas (438 of them, 2026-06-12 → 2026-08-31). Skips cleanly where the backup
// is absent so CI elsewhere stays green.
//
// What it caught, and why the rules changed:
//  - The watch's sample counter free-runs across reattach, so `startTimeMs + firstSampleIndex`
//    anchored 197 of 435 segments INTO THE FUTURE — by up to 14.8 h. Durations, day sections
//    and the inter-segment gaps were all computed off that.
//  - "Same streamId chains" was unbounded, and a Pebble stream id survives a long silent
//    disconnect: 34 of the 52 genuine breaks ≥ 5 min (up to 10.5 h) were glued back together.
//    438 segments collapsed into 17 conversations spanning up to 53 h — the "38 hr 38 min"
//    rows Roger saw.
private let backupPath =
    ProcessInfo.processInfo.environment["PEBBLE_SEGMENT_BACKUP"]
    ?? NSHomeDirectory()
        + "/Desktop/PebbleAudioBackup/audio-companion-20260831-110954/segments"

private var backupAvailable: Bool {
    FileManager.default.fileExists(atPath: backupPath, isDirectory: nil)
}

private func loadBackupMetas() throws -> [SegmentMeta] {
    let decoder = JSONDecoder()
    return try FileManager.default
        .contentsOfDirectory(at: URL(fileURLWithPath: backupPath), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix(".meta.json") }
        .map { try decoder.decode(SegmentMeta.self, from: Data(contentsOf: $0)) }
}

@Suite struct RealSegmentGroupingTests {

    /// No segment may be placed after the phone first received it: audio cannot be recorded
    /// in the future. This is the anchoring invariant the free-running sample counter broke.
    @Test(.enabled(if: backupAvailable))
    func noSegmentIsAnchoredAfterThePhoneReceivedIt() throws {
        for meta in try loadBackupMetas() {
            #expect(ConversationGrouper.segmentStartMs(meta) <= meta.receivedAtMs)
            #expect(ConversationGrouper.segmentEndMs(meta) >= ConversationGrouper.segmentStartMs(meta))
            if let closed = meta.closedAtMs {
                #expect(ConversationGrouper.segmentEndMs(meta) <= closed)
            }
        }
    }

    /// A break of 5 minutes or more always ends a conversation — including one where the
    /// watch kept the same stream id across the gap.
    @Test(.enabled(if: backupAvailable))
    func realMetasNeverChainAcrossABreakOfFiveMinutesOrMore() throws {
        let grouped = ConversationGrouper.group(
            segments: try loadBackupMetas(), pauses: [], openSegmentId: nil,
            fallbackTimeZoneID: "UTC")
        let byId = Dictionary(
            uniqueKeysWithValues: try loadBackupMetas().map { ($0.segmentId, $0) })
        for convo in grouped {
            let members = convo.memberSegmentIds.compactMap { byId[$0] }
            for (prev, next) in zip(members, members.dropFirst()) {
                let gap =
                    ConversationGrouper.segmentStartMs(next)
                    - ConversationGrouper.segmentEndMs(prev)
                #expect(gap < ConversationGrouper.chainWindowMs)
            }
        }
    }

    /// Continuous background capture legitimately runs for hours (rotations hand straight
    /// over, and the watch counts through VAD-suppressed quiet), but a conversation spanning
    /// more than a day is not something a person can use. The old rules produced four.
    @Test(.enabled(if: backupAvailable))
    func noConversationSpansMoreThanADay() throws {
        let grouped = ConversationGrouper.group(
            segments: try loadBackupMetas(), pauses: [], openSegmentId: nil,
            fallbackTimeZoneID: "UTC")
        #expect(grouped.count > 40)  // was 17 before the rule fix
        for convo in grouped {
            #expect(convo.endMs - convo.startMs < 24 * 60 * 60 * 1000)
        }
    }
}
