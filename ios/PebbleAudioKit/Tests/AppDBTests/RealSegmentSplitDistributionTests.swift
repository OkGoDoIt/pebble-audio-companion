import Foundation
import SegmentStore
import Testing

@testable import AppDB

// The honest-extent gate over a READ-ONLY copy of the 2026-09-08 library: no conversation the
// user can open is a phantom. `RealSegmentBoundaryTests` pins the invariants of the long-quiet
// rule; this file pins what a conversation DISPLAYS, so a later change that quietly
// reintroduces a sixteen-hour "conversation" holding thirty-two seconds of audio fails loudly
// instead of shipping.
//
// PORTED 2026-09-30. This suite used to pin a measured distribution (longest < 8 h, at most
// five over four hours, p90 under 2 h 30 m) and two properties of the flanking-flow guard. Those
// numbers were measured on this corpus UNDER THE RULES THAT HAVE BEEN REPLACED — whole-segment
// conversations cut at joins — and the guard no longer affects grouping, so both are gone. The
// numbers that matter now (median, p90 and longest of topic-sized conversations, scored against
// hand-marked starts) are measured in `RealConversationSegmentationTests`. What is kept is every
// invariant that still makes sense: the extent is honest, it sits inside its own pieces and
// covers every word said in them, it changes no membership, and the long-quiet rule reads
// timings only.

/// Deliberately its own variable rather than `PEBBLE_SEGMENT_BACKUP`, as it always was: this
/// suite names its corpus.
private let splitBackupPath =
    ProcessInfo.processInfo.environment["PEBBLE_SPLIT_BACKUP"]
    ?? NSHomeDirectory()
        + "/Desktop/PebbleAudioBackup/audio-companion-20260908-164136/segments"

private var splitBackupAvailable: Bool { RealLibrary.isAvailable(segmentsPath: splitBackupPath) }

/// One piece with the run member it is cut from — for the piece's place on the wall clock.
private struct PlacedTestPiece {
    var piece: ConversationMember
    var member: ConversationRunPlanner.Member

    var wallStartMs: Int64 {
        piece.startMediaMs.map { member.wall(ofMedia: $0) } ?? member.startWallMs
    }
    var wallEndMs: Int64 {
        piece.endMediaMs.map { member.wall(ofMedia: $0) } ?? member.endWallMs
    }
    /// The turns that start in the piece, on the wall clock.
    func turns(_ evidence: SegmentSpeechEvidence?) -> [(startMs: Int64, endMs: Int64)] {
        (evidence?.speech ?? []).filter { piece.contains(mediaMs: max($0.startMs, 0)) }.map {
            let start = member.wall(ofMedia: $0.startMs)
            return (start, max(member.wall(ofMedia: $0.endMs), start))
        }
    }
    var audioMs: Int64 {
        let range = piece.mediaRange(mediaSpanMs: member.mediaSpanMs)
        return range.upperBound - range.lowerBound
    }
}

private func placed(_ conversation: GroupedConversation, in library: RealLibrary)
    -> [PlacedTestPiece]
{
    let metas = library.metasById
    return conversation.members.compactMap { piece in
        guard let meta = metas[piece.segmentId] else { return nil }
        let member = ConversationRunPlanner.members([meta], evidence: library.evidence)[0]
        return PlacedTestPiece(piece: piece, member: member)
    }
}

@Suite struct RealSegmentSplitDistributionTests {

    /// THE headline that survives: a row with nothing said in it can never be long, because its
    /// extent is the audio actually received. The worst case in this library was a single
    /// segment displaying 16 h 29 m for 1,634 frames of audio.
    ///
    /// "Nothing said" means no speech RUNS in the conversation's pieces, which is not the same
    /// as no words: 1.2% of the library's turns carry timings and empty text (the recogniser
    /// heard voice and produced no transcript for it). Those are evidence of when someone spoke,
    /// so they anchor the extent like any other run — this is for the pieces that produced no
    /// timing at all, where the only honest length left is the audio we hold.
    @Test(.enabled(if: splitBackupAvailable), arguments: [BoundaryPolicy.quietOnly, .default])
    func aConversationNobodySpokeInIsNeverLongerThanItsAudio(policy: BoundaryPolicy) throws {
        let library = try RealLibrary.load(segmentsPath: splitBackupPath)
        let conversations = library.group(policy)
        var checked = 0
        for conversation in conversations {
            let pieces = placed(conversation, in: library)
            guard pieces.allSatisfy(\.member.isSettled),
                pieces.allSatisfy({ $0.turns(library.evidence[$0.piece.segmentId]).isEmpty })
            else { continue }
            checked += 1
            let audio = pieces.reduce(Int64(0)) { $0 + $1.audioMs }
            #expect(conversation.endMs - conversation.startMs <= audio, "\(conversation.id)")
        }
        #expect(checked > 0, "the corpus holds silent conversations; none was examined")
    }

    /// The extent may only ever SHRINK the container, and only onto real speech. This is what
    /// stops a "fix" that shortens a conversation past the words it contains.
    @Test(.enabled(if: splitBackupAvailable), arguments: [BoundaryPolicy.quietOnly, .default])
    func everyExtentSitsInsideItsPiecesAndCoversEverySpokenWord(policy: BoundaryPolicy) throws {
        let library = try RealLibrary.load(segmentsPath: splitBackupPath)
        let conversations = library.group(policy)
        expectPiecesTile(conversations, segments: library.metas)
        for conversation in conversations {
            let pieces = placed(conversation, in: library)
            guard let first = pieces.first else { continue }
            let containerStart = first.wallStartMs
            let containerEnd = max(pieces.map(\.wallEndMs).max() ?? containerStart, containerStart)
            #expect(conversation.startMs >= containerStart, "\(conversation.id)")
            #expect(conversation.endMs <= containerEnd, "\(conversation.id)")
            #expect(conversation.endMs >= conversation.startMs, "\(conversation.id)")

            // Every word said in the conversation's pieces is inside the extent — the trim only
            // ever eats silence. (A turn that runs past the end of its piece is held to the
            // piece: the extent never leaves the audio the conversation owns.)
            guard pieces.allSatisfy(\.member.isSettled) else { continue }
            for piece in pieces {
                for turn in piece.turns(library.evidence[piece.piece.segmentId]) {
                    #expect(turn.startMs >= conversation.startMs, "\(conversation.id)")
                    #expect(
                        min(turn.endMs, piece.wallEndMs) <= conversation.endMs,
                        "\(conversation.id)")
                }
            }
        }
    }

    /// The extent is a display correction, not a semantic one: it must not move a single
    /// boundary. This is why it could ship on its own, and why it is tested on its own.
    @Test(.enabled(if: splitBackupAvailable))
    func theHonestExtentChangesNoMembership() throws {
        let library = try RealLibrary.load(segmentsPath: splitBackupPath)
        let withEvidence = library.group(.structuralOnly)
        let withoutEvidence = library.group(.structuralOnly, evidence: [:])
        #expect(withEvidence.map(\.members) == withoutEvidence.map(\.members))
        #expect(withEvidence.map(\.id) == withoutEvidence.map(\.id))
        #expect(withEvidence.allSatisfy { $0.members.allSatisfy(\.isWhole) })
        // …and it really does shorten things: without evidence there is nothing to anchor on,
        // so those extents are the old container edges.
        let anchored = withEvidence.reduce(Int64(0)) { $0 + ($1.endMs - $1.startMs) }
        let containers = withoutEvidence.reduce(Int64(0)) { $0 + ($1.endMs - $1.startMs) }
        #expect(anchored < containers)
        // And never moves one outside its members. (Not "never past the evidence-free end":
        // that end is the LAST member's, and members overlap in wall time, so a word in an
        // earlier member can legitimately sit after it.)
        let metas = library.metasById
        for (a, b) in zip(withEvidence, withoutEvidence) {
            let ends = a.memberSegmentIds.compactMap { metas[$0] }.map(ConversationGrouper.segmentEndMs)
            #expect(a.startMs >= b.startMs, "\(a.id)")
            #expect(a.endMs <= max(ends.max() ?? a.endMs, b.startMs), "\(a.id)")
        }
    }

    /// The long-quiet rule reads WHERE speech is and nothing else. Word counts fed the retired
    /// flanking-flow guard; a caller that cannot supply them — or any setting of the guard's
    /// leftover knobs — must get exactly the same grouping.
    @Test(.enabled(if: splitBackupAvailable))
    func theQuietRuleReadsTimingsOnly() throws {
        let library = try RealLibrary.load(segmentsPath: splitBackupPath)
        let countless = library.evidence.mapValues { known in
            SegmentSpeechEvidence(
                segmentId: known.segmentId, isSettled: known.isSettled,
                speech: known.speech.map { SpeechSpan(startMs: $0.startMs, endMs: $0.endMs) })
        }
        let shipped = library.group(.quietOnly)
        #expect(library.group(.quietOnly, evidence: countless) == shipped)
        var unguarded = BoundaryPolicy.quietOnly
        unguarded.flankFlowWordsPerMinute = 0
        unguarded.quietCandidateMs = 1
        #expect(library.group(unguarded) == shipped)
    }

    /// The long-quiet rule on the corpus it was tuned on still does what it was tuned to do, in
    /// direction if no longer in the old numbers: more conversations than the structural rules
    /// give, a shorter longest one, and no quiet split without a reason.
    @Test(.enabled(if: splitBackupAvailable))
    func theQuietRuleStillShortensTheLongestConversation() throws {
        let library = try RealLibrary.load(segmentsPath: splitBackupPath)
        let structural = library.group(.structuralOnly)
        let quiet = library.group(.quietOnly)
        #expect(quiet.count > structural.count)
        let longest: ([GroupedConversation]) -> Int64 = { $0.map { $0.endMs - $0.startMs }.max() ?? 0 }
        #expect(longest(quiet) < longest(structural))
        #expect(quiet.dropFirst().allSatisfy { $0.startReason != nil })
    }
}
