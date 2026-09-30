import Foundation
import Testing

@testable import AppDB

// The two value types the unit model is written in (`ConversationUnits.swift`): a PIECE of a
// segment and a POSITION in one. Everything else — tiling, ids, ownership queries, delete — is
// built on the small rules pinned here.

@Suite struct ConversationUnitsTests {
    typealias Member = ConversationMember

    @Test func conversationsAreTopicSized() {
        #expect(ConversationUnits.isTopicSized)
    }

    // MARK: - a piece

    @Test func aWholeSegmentIsAPieceWithNoBounds() {
        let whole = Member(segmentId: "a")
        #expect(whole.isWhole)
        #expect(whole.startMediaMs == nil && whole.endMediaMs == nil)
        // "From the first frame" has one spelling: a start of 0 (or before it) IS no start, so
        // two descriptions of the same piece compare, hash and store equal.
        #expect(Member(segmentId: "a", startMediaMs: 0) == whole)
        #expect(Member(segmentId: "a", startMediaMs: -5) == whole)
        #expect(Member(segmentId: "a", startMediaMs: 0).hashValue == whole.hashValue)
        #expect(!Member(segmentId: "a", startMediaMs: 1).isWhole)
        #expect(!Member(segmentId: "a", endMediaMs: 1_000).isWhole)
        #expect(Member(segmentId: "a") != Member(segmentId: "b"))
    }

    @Test func aPieceOwnsWhatStartsInsideItsHalfOpenRange() {
        let piece = Member(segmentId: "a", startMediaMs: 1_000, endMediaMs: 5_000)
        #expect(!piece.contains(mediaMs: 999))
        #expect(piece.contains(mediaMs: 1_000))
        #expect(piece.contains(mediaMs: 4_999))
        // The end belongs to the next piece: nothing is ever in two.
        #expect(!piece.contains(mediaMs: 5_000))

        let head = Member(segmentId: "a", endMediaMs: 1_000)
        let tail = Member(segmentId: "a", startMediaMs: 5_000)
        #expect(head.contains(mediaMs: 0) && head.contains(mediaMs: -50))
        #expect(!head.contains(mediaMs: 1_000))
        #expect(tail.contains(mediaMs: 5_000) && tail.contains(mediaMs: .max))
        #expect(Member(segmentId: "a").contains(mediaMs: 0))
        #expect(Member(segmentId: "a").contains(mediaMs: .max))

        // Three abutting pieces: every offset is in exactly one of them.
        for offset: Int64 in [0, 1, 999, 1_000, 1_001, 4_999, 5_000, 5_001, 1_000_000] {
            #expect(
                [head, piece, tail].filter { $0.contains(mediaMs: offset) }.count == 1,
                "\(offset)")
        }
    }

    @Test func aPiecesRangeIsClampedIntoTheAudioTheSegmentHolds() {
        #expect(Member(segmentId: "a").mediaRange(mediaSpanMs: 9_000) == 0..<9_000)
        #expect(
            Member(segmentId: "a", startMediaMs: 1_000, endMediaMs: 5_000)
                .mediaRange(mediaSpanMs: 9_000) == 1_000..<5_000)
        #expect(
            Member(segmentId: "a", startMediaMs: 1_000).mediaRange(mediaSpanMs: 9_000)
                == 1_000..<9_000)
        // A bound past the end of the audio (a stale cut after a retention trim) is the end.
        #expect(
            Member(segmentId: "a", startMediaMs: 1_000, endMediaMs: 50_000)
                .mediaRange(mediaSpanMs: 9_000) == 1_000..<9_000)
        #expect(
            Member(segmentId: "a", startMediaMs: 20_000, endMediaMs: 50_000)
                .mediaRange(mediaSpanMs: 9_000).isEmpty)
        // Never inverted, never negative, whatever it is given.
        #expect(
            Member(segmentId: "a", startMediaMs: 5_000, endMediaMs: 1_000)
                .mediaRange(mediaSpanMs: 9_000).isEmpty)
        #expect(Member(segmentId: "a").mediaRange(mediaSpanMs: 0).isEmpty)
        #expect(Member(segmentId: "a").mediaRange(mediaSpanMs: -10).isEmpty)
    }

    // MARK: - a position

    @Test func theIdOfAConversationIsWhereItStarts() {
        // At a segment's own start it keeps the id it always had, so nothing keyed on those
        // moved when conversations became pieces.
        #expect(ConversationCut(segmentId: "seg-1", mediaMs: 0).conversationId == "conv-seg-1")
        #expect(
            ConversationCut(segmentId: "seg-1", mediaMs: 238_500).conversationId
                == "conv-seg-1-m238500")
        #expect(ConversationCut(segmentId: "seg-1", mediaMs: 1).conversationId == "conv-seg-1-m1")
        // A position before the segment's start is its start.
        #expect(ConversationCut(segmentId: "seg-1", mediaMs: -7).mediaMs == 0)
        #expect(ConversationCut(segmentId: "seg-1", mediaMs: -7).conversationId == "conv-seg-1")
        // Different positions, different ids.
        #expect(
            ConversationCut(segmentId: "a", mediaMs: 10).conversationId
                != ConversationCut(segmentId: "a", mediaMs: 100).conversationId)
    }

    @Test func positionsOrderBySegmentThenOffset() {
        let cuts = [
            ConversationCut(segmentId: "b", mediaMs: 5), ConversationCut(segmentId: "a", mediaMs: 900),
            ConversationCut(segmentId: "a", mediaMs: 10), ConversationCut(segmentId: "b", mediaMs: 0),
        ]
        #expect(
            cuts.sorted() == [
                ConversationCut(segmentId: "a", mediaMs: 10),
                ConversationCut(segmentId: "a", mediaMs: 900),
                ConversationCut(segmentId: "b", mediaMs: 0), ConversationCut(segmentId: "b", mediaMs: 5),
            ])
        #expect(Set(cuts + cuts).count == 4)
    }

    // MARK: - a conversation's pieces

    @Test func aConversationAnswersWhichPieceOfASegmentItOwnsAndWhetherItOwnsAMoment() {
        let conversation = GroupedConversation(
            id: "conv-a-m1000", startMs: 0, endMs: 10, timeZoneID: "UTC", isLive: false,
            members: [
                Member(segmentId: "a", startMediaMs: 1_000), Member(segmentId: "b"),
                Member(segmentId: "c", endMediaMs: 2_000),
            ])
        #expect(conversation.memberSegmentIds == ["a", "b", "c"])
        #expect(conversation.member("a") == Member(segmentId: "a", startMediaMs: 1_000))
        #expect(conversation.member("c")?.endMediaMs == 2_000)
        #expect(conversation.member("nope") == nil)

        #expect(!conversation.contains(segmentId: "a", mediaMs: 999))
        #expect(conversation.contains(segmentId: "a", mediaMs: 1_000))
        #expect(conversation.contains(segmentId: "b", mediaMs: 123_456))
        #expect(conversation.contains(segmentId: "c", mediaMs: 1_999))
        #expect(!conversation.contains(segmentId: "c", mediaMs: 2_000))
        #expect(!conversation.contains(segmentId: "nope", mediaMs: 0))

        // The whole-segment initialiser is the same thing with no bounds, and is not provisional.
        let whole = GroupedConversation(
            id: "conv-a", startMs: 0, endMs: 10, timeZoneID: "UTC", isLive: false,
            memberSegmentIds: ["a", "b"])
        #expect(whole.members == [Member(segmentId: "a"), Member(segmentId: "b")])
        #expect(!whole.isProvisional)
    }
}
