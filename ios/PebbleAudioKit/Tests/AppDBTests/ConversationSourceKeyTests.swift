import Foundation
import SegmentStore
import Testing

@testable import AppDB

// `ConversationSourceKey` says WHICH PIECES something derived from a conversation was derived
// from, so a title can tell whether it still describes the conversation that carries its id.
// The first half pins the key itself. The second half pins what the key is FOR, at the point
// where the grouper meets it: a conversation that is finished — not provisional, so its title
// has been written once — must still be described by the key it was titled under when the day
// carries on, or every such conversation costs a second model call and may change its title
// under the person who has already read it.

private typealias Member = ConversationMember

@Suite struct ConversationSourceKeyTests {
    let t0 = testEpochMs

    // MARK: - the key

    @Test func theKeyIsThePieceListWrittenOut() {
        #expect(ConversationSourceKey.key(of: []) == "")
        #expect(ConversationSourceKey.key(of: [Member(segmentId: "seg-1")]) == "seg-1@0-")
        #expect(
            ConversationSourceKey.key(of: [
                Member(segmentId: "seg-1", startMediaMs: 238_500), Member(segmentId: "seg-2"),
                Member(segmentId: "seg-3", endMediaMs: 9_000),
            ]) == "seg-1@238500-;seg-2@0-;seg-3@0-9000")
        // One spelling per piece: "from the first frame" is 0 however it was written.
        #expect(
            ConversationSourceKey.key(of: [Member(segmentId: "a", startMediaMs: 0)])
                == ConversationSourceKey.key(of: [Member(segmentId: "a")]))
    }

    @Test func theKeyChangesWhenAPieceIsAddedRemovedReorderedOrMoved() {
        let pieces = [
            Member(segmentId: "a", startMediaMs: 1_000), Member(segmentId: "b"),
            Member(segmentId: "c", endMediaMs: 9_000),
        ]
        let key = ConversationSourceKey.key(of: pieces)
        #expect(ConversationSourceKey.key(of: pieces) == key)
        var moved = pieces
        moved[0].startMediaMs = 1_001
        #expect(ConversationSourceKey.key(of: moved) != key)
        moved = pieces
        moved[2].endMediaMs = 9_001
        #expect(ConversationSourceKey.key(of: moved) != key)
        moved[2].endMediaMs = nil
        #expect(ConversationSourceKey.key(of: moved) != key)
        #expect(ConversationSourceKey.key(of: Array(pieces.dropLast())) != key)
        #expect(ConversationSourceKey.key(of: pieces + [Member(segmentId: "d")]) != key)
        #expect(ConversationSourceKey.key(of: pieces.reversed()) != key)
    }

    @Test func aStoredKeyDescribesTheSamePiecesAndWhatIsLeftAfterLeadingOnesAreRemoved() {
        let pieces = [
            Member(segmentId: "a", startMediaMs: 1_000), Member(segmentId: "b"),
            Member(segmentId: "c", endMediaMs: 9_000),
        ]
        let stored = ConversationSourceKey.key(of: pieces)
        func describes(_ current: [Member]) -> Bool {
            ConversationSourceKey.describes(
                stored: stored, current: ConversationSourceKey.key(of: current))
        }
        #expect(describes(pieces))
        // Retention deletes the oldest audio a segment at a time: what is left is exactly what
        // it was, and is not worth a model call.
        #expect(describes(Array(pieces.dropFirst())))
        #expect(describes(Array(pieces.dropFirst(2))))

        // Anything else is a different conversation.
        #expect(!describes(Array(pieces.dropLast())))
        #expect(!describes([pieces[0], pieces[2]]))
        #expect(!describes(pieces + [Member(segmentId: "d")]))
        #expect(!describes([Member(segmentId: "c")]))
        #expect(!describes([Member(segmentId: "b", startMediaMs: 5), pieces[2]]))
        #expect(!describes([]))
        // A suffix of the TEXT that is not a suffix of the PIECES does not count: "b" is not
        // what is left of "ab".
        #expect(
            !ConversationSourceKey.describes(
                stored: ConversationSourceKey.key(of: [Member(segmentId: "ab")]),
                current: ConversationSourceKey.key(of: [Member(segmentId: "b")])))
        // A row written before the key existed describes nothing.
        #expect(!ConversationSourceKey.describes(stored: nil, current: stored))
        #expect(!ConversationSourceKey.describes(stored: "", current: stored))
        #expect(!ConversationSourceKey.describes(stored: "", current: ""))
    }

    // MARK: - what a finished conversation was titled from, as the day carries on

    private func group(_ day: Day, policy: BoundaryPolicy, held: ConversationCutInputs = .none)
        -> ConversationGrouper.Grouping
    {
        let grouping = ConversationGrouper.groupDetailed(
            segments: day.segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: day.evidence, policy: policy, cutInputs: held)
        expectPiecesTile(grouping.conversations, segments: day.segments)
        return grouping
    }

    /// Every conversation of `before` that is not provisional is, in `after`, still described by
    /// the key of the pieces it had — `after` being the same library a little later, grouped
    /// with everything `before` offered for committing held.
    private func expectFinishedConversationsKeepTheirKeys(
        before: Day, after: Day, policy: BoundaryPolicy,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let first = group(before, policy: policy)
        var held = ConversationCutInputs()
        for (cut, reason) in first.cutsToCommit {
            held.committed[cut.segmentId, default: [:]][cut.mediaMs] = reason
        }
        let second = ConversationGrouper.adoptStableIds(
            group(after, policy: policy, held: held).conversations, previous: first.conversations)
        let finished = first.conversations.filter { !$0.isProvisional }
        #expect(!finished.isEmpty, "nothing to check", sourceLocation: sourceLocation)
        for conversation in finished {
            let now = second.first { $0.id == conversation.id }
            #expect(
                ConversationSourceKey.describes(
                    stored: ConversationSourceKey.key(of: conversation.members),
                    current: ConversationSourceKey.key(of: now?.members ?? [])),
                "\(conversation.id) was \(conversation.brief), is \(now?.brief ?? [])",
                sourceLocation: sourceLocation)
        }
    }

    @Test func aFinishedConversationKeepsItsKeyWhenMoreOfTheSameTalkArrives() {
        // A change of mode with an hour of talk after it, then another half hour of the same.
        let before = day(minutes: 90, talk: [.dialogue(0, 30), .dictation(34, 90)])
        let after = day(minutes: 120, talk: [.dialogue(0, 30), .dictation(34, 120)])
        for policy in [BoundaryPolicy.default, frozenPolicy] {
            expectFinishedConversationsKeepTheirKeys(before: before, after: after, policy: policy)
        }
    }

    @Test func aFinishedConversationKeepsItsKeyWhenALaterRunStarts() {
        let before = day(minutes: 90, talk: [.dialogue(0, 30), .dictation(34, 90)])
        let later = day(
            minutes: 30, prefix: "t", startTimeMs: t0 + minutesMs(400), stream: 9,
            talk: [.dialogue(0, 30)])
        for policy in [BoundaryPolicy.default, frozenPolicy] {
            expectFinishedConversationsKeepTheirKeys(
                before: before, after: before + later, policy: policy)
        }
    }

    /// Talk, then a silence long enough to end the conversation. The silent tail becomes its own
    /// unit "so the conversation can finish" — and it does: it is not provisional, and its title
    /// is written. Two hours later somebody speaks again in the same run.
    ///
    /// REPORTED 2026-09-30 and FAILING: the silence is then no longer the tail of the run but
    /// an interior silence, which "stays with what came before". The finished conversation's
    /// last piece grows from `s1[..302000)` to the whole of `s1`, and it gains every silent
    /// segment up to the first word after. Nothing it was titled from has changed — only
    /// silence was appended — but its key has, so it is titled a second time.
    @Test func aFinishedConversationKeepsItsKeyWhenTalkResumesAfterItsSilentTail() {
        let before = day(minutes: 60, talk: [.dialogue(0, 20)])
        let after = day(minutes: 180, talk: [.dialogue(0, 20), .dialogue(140, 180)])
        for policy in [BoundaryPolicy.quietOnly, .default, frozenPolicy] {
            expectFinishedConversationsKeepTheirKeys(before: before, after: after, policy: policy)
        }
    }

    /// A conversation is finished when both its boundaries are fixed, and a segmenter cut with
    /// 45 minutes of settled talk after it counts as fixed. When that cut happens to fall on a
    /// segment's own start (the first word of the new conversation is the first word of a
    /// recording), it must be held like any other.
    ///
    /// REPORTED 2026-09-30 and FAILING: `conversation_cuts` only holds positions INSIDE
    /// segments (`mediaMs > 0`), so a settled cut at a segment's start is reported as fixed —
    /// the conversation before it is not provisional — and then is not forced on the next pass.
    /// Here a hundred minutes of even talk in ten-minute recordings is cut at the join at
    /// minute 50; sixty more minutes arrive, the search re-balances into two units of eighty,
    /// and the "finished" first conversation grows from fifty minutes to eighty.
    @Test func aFinishedConversationKeepsItsKeyWhenItsSettledCutSitsOnASegmentStart() {
        let before = day(minutes: 100, rotation: 10, talk: [.dialogue(0, 100)])
        let after = day(minutes: 160, rotation: 10, talk: [.dialogue(0, 160)])
        let first = group(before, policy: frozenPolicy)
        #expect(first.conversations.map(\.id) == ["conv-s0", "conv-s5"])
        #expect(first.conversations.map(\.isProvisional) == [false, true])
        expectFinishedConversationsKeepTheirKeys(before: before, after: after, policy: frozenPolicy)

        // The same day in fifteen-minute recordings puts the cut INSIDE a segment, where it is
        // held — and nothing moves.
        let inside = day(minutes: 100, talk: [.dialogue(0, 100)])
        let insideAfter = day(minutes: 160, talk: [.dialogue(0, 160)])
        #expect(group(inside, policy: frozenPolicy).cutsToCommit.count == 1)
        expectFinishedConversationsKeepTheirKeys(
            before: inside, after: insideAfter, policy: frozenPolicy)
    }
}
