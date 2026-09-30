import Foundation
import SegmentStore
import Testing

@testable import AppDB

// Characterisation gate for the LONG-QUIET rule, run over a READ-ONLY copy of Roger's real
// library (segment metas + the durable transcripts beside them). Skips cleanly where the backup
// is absent so CI elsewhere stays green — same contract as `RealSegmentGroupingTests`.
//
// PORTED 2026-09-30. This suite used to pin the quiet layer as it shipped before conversations
// became pieces of segments (cuts snapped to segment joins, an 8–15 minute candidate band for a
// semantic reviewer, a flanking-flow guard). What it pins now:
//  - against `.quietOnly`, the invariants that survived: the rule only ever ADDS cuts to the
//    structural grouping, every one of them is explainable and decided from settled evidence,
//    nothing is lost or duplicated (the pieces tile the library), and an untranscribed library
//    groups exactly as it did under v1;
//  - against `.default`, only what no tuning of the segmenter can change: the pieces tile, the
//    answer is deterministic, and an untranscribed library is divided by length alone.
// Gone: the ratio bound on the conversation count (a number measured under the old rules) and
// the reviewer's work-list test (there is no reviewer). The measured numbers for topic-sized
// conversations live in `RealConversationSegmentationTests`.

private let segmentsPath =
    ProcessInfo.processInfo.environment["PEBBLE_SEGMENT_BACKUP"]
    ?? NSHomeDirectory()
        + "/Desktop/PebbleAudioBackup/audio-companion-20260831-110954/segments"

private var backupAvailable: Bool { RealLibrary.isAvailable(segmentsPath: segmentsPath) }

@Suite struct RealSegmentBoundaryTests {

    @Test(.enabled(if: backupAvailable))
    func theQuietRuleBreaksUpTheMonstersAndOnlyEverAddsCuts() throws {
        let library = try RealLibrary.load(segmentsPath: segmentsPath)
        let before = library.group(.structuralOnly)
        let after = library.group(.quietOnly)

        // Nothing is lost or duplicated: every sample still belongs to exactly one
        // conversation, in the same order.
        expectPiecesTile(before, segments: library.metas)
        expectPiecesTile(after, segments: library.metas)
        #expect(before.allSatisfy { $0.members.allSatisfy(\.isWhole) })

        // It splits …
        #expect(after.count > before.count)
        // … and it only splits: every conversation the structural rules start is still the
        // start of one. The quiet rule divides runs; it never merges across what ended one.
        let startsAfter = Set(
            after.compactMap { convo in
                convo.members.first.flatMap { $0.startMediaMs == nil ? $0.segmentId : nil }
            })
        for convo in before {
            #expect(startsAfter.contains(convo.memberSegmentIds[0]), "\(convo.id)")
        }

        // The longest thing in the library gets shorter.
        let longestBefore = before.map { $0.endMs - $0.startMs }.max() ?? 0
        let longestAfter = after.map { $0.endMs - $0.startMs }.max() ?? 0
        #expect(longestAfter < longestBefore)
    }

    /// Every automatic split must be explainable, and only by a reason this rule can defend.
    @Test(.enabled(if: backupAvailable))
    func everyNewSplitCarriesAReasonAndNoneIsAGuess() throws {
        let library = try RealLibrary.load(segmentsPath: segmentsPath)
        let byId = library.metasById
        let after = library.group(.quietOnly)
        let structural: Set<ConversationStartReason> = [.gap, .userStop, .pause]

        #expect(after.first?.startReason == nil)
        for conversation in after.dropFirst() {
            let reason = try #require(conversation.startReason, "\(conversation.id)")
            let first = try #require(conversation.members.first)
            if structural.contains(reason) {
                // A structural start is a segment's own start.
                #expect(first.startMediaMs == nil, "\(conversation.id)")
                continue
            }
            // With the segmenter off, nothing else but a long silence starts a conversation.
            #expect(reason == .quiet || reason == .interrupted, "\(conversation.id): \(reason)")
            // A quiet split only ever happens where the evidence was settled.
            #expect(library.evidence[first.segmentId]?.isSettled == true)
            #expect(byId[first.segmentId]?.closeReason != nil)
            // Where it starts inside a segment, it starts in one of exactly two places: just
            // ahead of the first word after the silence (less the pre-roll), or — the silent
            // tail of a run, which is its own conversation — just after the last word before it
            // (plus the post-roll), with nothing said from there to the end of the segment.
            if let startMediaMs = first.startMediaMs {
                let turns = library.evidence[first.segmentId]?.speech ?? []
                if let next = turns.map(\.startMs).filter({ $0 >= startMediaMs }).min() {
                    #expect(
                        next - startMediaMs <= ConversationRunPlanner.preRollMs,
                        "\(conversation.id)")
                } else {
                    let lastWord = turns.map(\.endMs).max()
                    #expect(
                        lastWord == startMediaMs - ConversationRunPlanner.postRollMs,
                        "\(conversation.id) starts on nothing, and not after the last word")
                }
            }
        }
    }

    /// Determinism over the real library: same input, same conversations, same ids, same
    /// reasons — with the segmenter off and on.
    @Test(.enabled(if: backupAvailable))
    func groupingTheRealLibraryTwiceGivesTheSameAnswer() throws {
        let library = try RealLibrary.load(segmentsPath: segmentsPath)
        for policy in [BoundaryPolicy.quietOnly, .default] {
            let first = library.group(policy)
            #expect(library.group(policy) == first)
            // The order the metas are read in is not part of the input.
            let shuffled = ConversationGrouper.group(
                segments: library.metas.reversed(), pauses: [], openSegmentId: nil,
                fallbackTimeZoneID: "UTC", evidence: library.evidence, policy: policy)
            #expect(shuffled == first)
        }
    }

    /// The delay trap, on real data: pretending nothing has been transcribed yet must produce
    /// exactly the v1 grouping — not a library shredded by "silence" that is really a queue.
    @Test(.enabled(if: backupAvailable))
    func anUntranscribedLibraryGroupsExactlyAsItDidBefore() throws {
        let library = try RealLibrary.load(segmentsPath: segmentsPath)
        let unsettled = Dictionary(
            uniqueKeysWithValues: library.metas.map {
                ($0.segmentId, unsettledEvidence($0.segmentId))
            })
        let baseline = library.group(.structuralOnly, evidence: [:])
        #expect(library.group(.quietOnly, evidence: unsettled) == baseline)
        #expect(library.group(.quietOnly, evidence: [:]) == baseline)
    }

    /// With the segmenter on, an untranscribed library is divided by LENGTH alone: at segment
    /// joins, labelled as such, and with nothing written down — so waiting audio is never one
    /// day-long block, and nothing decided from ignorance is ever held.
    @Test(.enabled(if: backupAvailable))
    func anUntranscribedLibraryIsOnlyEverDividedByLength() throws {
        let library = try RealLibrary.load(segmentsPath: segmentsPath)
        let grouping = ConversationGrouper.groupDetailed(
            segments: library.metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: [:], policy: .default)
        expectPiecesTile(grouping.conversations, segments: library.metas)
        #expect(grouping.cutsToCommit.isEmpty)
        let allowed: Set<ConversationStartReason> = [.gap, .userStop, .pause, .length]
        for conversation in grouping.conversations.dropFirst() {
            #expect(conversation.startReason.map(allowed.contains) == true, "\(conversation.id)")
        }
        #expect(grouping.conversations.allSatisfy { $0.members.allSatisfy(\.isWhole) })
        // It only adds to the structural grouping.
        let baseline = library.group(.structuralOnly, evidence: [:])
        let starts = Set(grouping.conversations.map { $0.memberSegmentIds[0] })
        #expect(baseline.allSatisfy { starts.contains($0.memberSegmentIds[0]) })
        #expect(grouping.conversations.count >= baseline.count)
    }

    /// Whatever the segmenter's numbers are, the shipped policy keeps the model's invariants on
    /// a real library: the pieces tile, every start has a reason, and what is offered for
    /// committing is a segmenter cut inside a segment that starts one of the conversations.
    @Test(.enabled(if: backupAvailable))
    func theShippedPolicyKeepsTheInvariantsOnTheRealLibrary() throws {
        let library = try RealLibrary.load(segmentsPath: segmentsPath)
        let grouping = ConversationGrouper.groupDetailed(
            segments: library.metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: library.evidence, policy: .default)
        expectPiecesTile(grouping.conversations, segments: library.metas)
        #expect(grouping.conversations.dropFirst().allSatisfy { $0.startReason != nil })
        for conversation in grouping.conversations {
            #expect(conversation.endMs >= conversation.startMs, "\(conversation.id)")
        }

        let starts = Dictionary(
            grouping.conversations.compactMap { convo in
                convo.members.first.map {
                    (ConversationCut(segmentId: $0.segmentId, mediaMs: $0.startMediaMs ?? 0), convo)
                }
            }, uniquingKeysWith: { first, _ in first })
        for (cut, reason) in grouping.cutsToCommit {
            #expect(cut.mediaMs > 0)
            #expect(reason == .topicChange || reason == .lull, "\(cut): \(reason)")
            #expect(starts[cut]?.startReason == reason, "\(cut)")
            #expect(library.evidence[cut.segmentId]?.isSettled == true, "\(cut)")
        }
    }
}
