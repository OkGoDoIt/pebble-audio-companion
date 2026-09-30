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
            segments: day.segments, pauses: [], openSegmentId: day.open, fallbackTimeZoneID: "UTC",
            evidence: day.evidence, policy: policy, cutInputs: held)
        expectPiecesTile(grouping.conversations, segments: day.segments)
        return grouping
    }

    /// Every conversation of `before` that is not provisional is, in `after`, still described by
    /// the key of the pieces it had — `after` being the same library a little later, grouped
    /// the way the app regroups it: with everything `before` offered for committing held, and
    /// ids adopted from `before`.
    private func expectFinishedConversationsKeepTheirKeys(
        before: Day, after: Day, policy: BoundaryPolicy, somethingMustBeFinished: Bool = true,
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
        if somethingMustBeFinished {
            #expect(!finished.isEmpty, "nothing to check", sourceLocation: sourceLocation)
        }
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

    @Test func aFinishedConversationKeepsItsKeyWhileTheDayIsStillBeingRecorded() {
        // Two people, dictation, two people again — and the watch still recording. The first
        // conversation is finished (the cut that ends it is an hour old and held); an hour later
        // there is another hour of talk, and it is exactly what it was.
        let before = day(
            minutes: 120, talk: [.dialogue(0, 30), .dictation(34, 90), .dialogue(94, 120)],
            recording: true)
        let after = day(
            minutes: 180,
            talk: [.dialogue(0, 30), .dictation(34, 90), .dialogue(94, 150), .dictation(154, 180)],
            recording: true)
        for policy in [BoundaryPolicy.default, frozenPolicy] {
            #expect(group(before, policy: policy).conversations.first?.isProvisional == false)
            expectFinishedConversationsKeepTheirKeys(before: before, after: after, policy: policy)
        }
    }

    @Test func aFinishedConversationKeepsItsKeyWhenALaterRunStarts() {
        // Nothing open: the library is finished, every conversation in it final. The next
        // morning's recording is a new run and touches none of them.
        let before = day(minutes: 90, talk: [.dialogue(0, 30), .dictation(34, 90)])
        let later = day(
            minutes: 30, prefix: "t", startTimeMs: t0 + minutesMs(400), stream: 9,
            talk: [.dialogue(0, 30)], recording: true)
        for policy in [BoundaryPolicy.quietOnly, .default, frozenPolicy] {
            #expect(group(before, policy: policy).conversations.allSatisfy { !$0.isProvisional })
            expectFinishedConversationsKeepTheirKeys(
                before: before, after: before + later, policy: policy)
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
    /// Here three and a half hours of even talk, still being recorded, is cut at the joins at
    /// minutes 75 and 150; half an hour more arrives, the search re-balances, and the
    /// "finished" first conversation loses its last eleven minutes. (On the 2026-09-08 library
    /// 9 of 167 segmenter cuts sit on a segment's start.)
    @Test func aFinishedConversationKeepsItsKeyWhenItsSettledCutSitsOnASegmentStart() {
        let before = day(minutes: 210, talk: [.dialogue(0, 210)], recording: true)
        let after = day(minutes: 240, talk: [.dialogue(0, 240)], recording: true)
        let first = group(before, policy: frozenPolicy)
        #expect(first.conversations.map(\.id) == ["conv-s0", "conv-s5", "conv-s10"])
        #expect(first.conversations.map(\.isProvisional) == [false, true, true])
        // Old enough to be written down, and nowhere to write it.
        #expect(first.cutsToCommit.isEmpty)
        expectFinishedConversationsKeepTheirKeys(before: before, after: after, policy: frozenPolicy)

        // The same talk half an hour shorter puts the cuts INSIDE segments, where they are
        // held — and nothing moves.
        let inside = day(minutes: 180, talk: [.dialogue(0, 180)], recording: true)
        let insideAfter = day(minutes: 240, talk: [.dialogue(0, 240)], recording: true)
        #expect(group(inside, policy: frozenPolicy).cutsToCommit.count == 1)
        expectFinishedConversationsKeepTheirKeys(
            before: inside, after: insideAfter, policy: frozenPolicy)
    }

    /// With nothing open, nothing is provisional: the library's last conversation is final and
    /// gets its title. But "nothing is open at this instant" is not "the run is over" — a run
    /// goes on whenever the next recording starts inside the chain window
    /// (`ConversationGrouper.chainWindowMs`, five minutes), which is what happens every time
    /// the link to the watch drops and comes back.
    ///
    /// REPORTED 2026-09-30 and FAILING. In the gap between one recording closing and the next
    /// opening, a regroup finds a finished library: the tail conversation is final (and every
    /// recent cut is committed at once, however young). The recording resumes a moment later in
    /// the SAME run, and the conversation that was just declared finished grows.
    @Test func aFinishedConversationKeepsItsKeyWhenTheRecordingResumesInTheSameRun() {
        // An hour of talk; the link drops; the next recording starts straight on.
        let before = day(minutes: 60, talk: [.dialogue(0, 60)])
        let after = day(minutes: 60, talk: [.dialogue(0, 60)], recording: true)
        // (Either answer would do: the conversation is not called finished while its run can
        // still go on, or it is and then does not change.)
        for policy in [BoundaryPolicy.quietOnly, frozenPolicy] {
            expectFinishedConversationsKeepTheirKeys(
                before: before, after: after, policy: policy, somethingMustBeFinished: false)
        }
    }

    /// The same gap, after a long silence. With nothing open the silent tail of the run is its
    /// own unit "so the conversation can finish", and it does. When the recording resumes, the
    /// silence is no longer settled to its end (the open recording overlaps it), the quiet cut
    /// is deferred again, and the finished conversation takes the whole silence back:
    /// `[s0, s1[..300000)]` becomes `[s0 … s4]` and the tail conversation is gone. When somebody
    /// then speaks, it is cut again at the first word — a third set of pieces.
    ///
    /// REPORTED 2026-09-30 and FAILING (the same cause as the case above).
    @Test func aFinishedConversationKeepsItsKeyWhenTheRecordingResumesAfterItsSilentTail() {
        let before = day(minutes: 60, talk: [.dialogue(0, 20)])
        #expect(
            group(before, policy: .quietOnly).conversations.map(\.brief)
                == [["s0", "s1[..300000)"], ["s1[300000..)", "s2", "s3"]])
        let resumed = day(minutes: 60, talk: [.dialogue(0, 20)], recording: true)
        for policy in [BoundaryPolicy.quietOnly, frozenPolicy] {
            expectFinishedConversationsKeepTheirKeys(
                before: before, after: resumed, policy: policy, somethingMustBeFinished: false)
        }
    }
}
