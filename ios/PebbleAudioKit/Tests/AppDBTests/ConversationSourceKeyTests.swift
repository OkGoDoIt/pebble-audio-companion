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

    private func group(
        _ day: Day, policy: BoundaryPolicy, held: ConversationCutInputs = .none,
        nowMs: Int64 = .max
    ) -> ConversationGrouper.Grouping {
        let grouping = ConversationGrouper.groupDetailed(
            segments: day.segments, pauses: [], openSegmentId: day.open, fallbackTimeZoneID: "UTC",
            evidence: day.evidence, policy: policy, cutInputs: held, nowMs: nowMs)
        expectPiecesTile(grouping.conversations, segments: day.segments)
        return grouping
    }

    /// Every conversation of `before` that is not provisional is, in `after`, still described by
    /// the key of the pieces it had — `after` being the same library a little later, grouped
    /// the way the app regroups it: with everything `before` offered for committing held, and
    /// ids adopted from `before`. `nowMs` is the clock both passes run at (`.max`: no clock).
    private func expectFinishedConversationsKeepTheirKeys(
        before: Day, after: Day, policy: BoundaryPolicy, somethingMustBeFinished: Bool = true,
        nowMs: Int64 = .max, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let first = group(before, policy: policy, nowMs: nowMs)
        var held = ConversationCutInputs()
        for (cut, reason) in first.cutsToCommit {
            held.committed[cut.segmentId, default: [:]][cut.mediaMs] = reason
        }
        let second = ConversationGrouper.adoptStableIds(
            group(after, policy: policy, held: held, nowMs: nowMs).conversations,
            previous: first.conversations)
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
    /// Reported 2026-09-30 and fixed since: `conversation_cuts` used to hold only positions
    /// INSIDE segments (`mediaMs > 0`), so a settled cut at a segment's start was reported as
    /// fixed — the conversation before it not provisional — and then not forced on the next
    /// pass: three and a half hours of even talk, still being recorded, cut at the joins at
    /// minutes 75 and 150, re-balanced when half an hour more arrived, and the "finished" first
    /// conversation lost its last eleven minutes. A cut at a segment's start is now offered for
    /// committing and held like any other. (On the 2026-09-08 library 9 of 167 segmenter cuts
    /// sit on a segment's start.)
    @Test func aFinishedConversationKeepsItsKeyWhenItsSettledCutSitsOnASegmentStart() {
        let before = day(minutes: 210, talk: [.dialogue(0, 210)], recording: true)
        let after = day(minutes: 240, talk: [.dialogue(0, 240)], recording: true)
        let first = group(before, policy: frozenPolicy)
        #expect(first.conversations.map(\.id) == ["conv-s0", "conv-s5", "conv-s10"])
        #expect(first.conversations.map(\.isProvisional) == [false, true, true])
        // Old enough to be written down, and written down at the segment's start.
        #expect(first.cutsToCommit == [ConversationCut(segmentId: "s5", mediaMs: 0): .topicChange])
        expectFinishedConversationsKeepTheirKeys(before: before, after: after, policy: frozenPolicy)

        // The same talk half an hour shorter puts the cuts INSIDE segments, where they are
        // held — and nothing moves.
        let inside = day(minutes: 180, talk: [.dialogue(0, 180)], recording: true)
        let insideAfter = day(minutes: 240, talk: [.dialogue(0, 240)], recording: true)
        #expect(group(inside, policy: frozenPolicy).cutsToCommit.count == 1)
        expectFinishedConversationsKeepTheirKeys(
            before: inside, after: insideAfter, policy: frozenPolicy)
    }

    /// With nothing open and no clock, nothing is provisional: the library's last conversation
    /// is final and gets its title. But "nothing is open at this instant" is not "the run is
    /// over" — a run goes on whenever the next recording starts inside the chain window
    /// (`ConversationGrouper.chainWindowMs`, five minutes), which is what happens every time
    /// the link to the watch drops and comes back.
    ///
    /// Reported 2026-09-30 and fixed since: in the gap between one recording closing and the
    /// next opening, a regroup found a finished library — the tail conversation final, every
    /// recent cut committed at once however young — and a moment later the recording resumed
    /// in the SAME run and the "finished" conversation grew. A regroup that knows the time
    /// (`nowMs`) now treats a run whose last recording closed less than a chain window ago as
    /// still open-ended: its tail stays provisional through the gap, and after it.
    @Test func aFinishedConversationKeepsItsKeyWhenTheRecordingResumesInTheSameRun() {
        // An hour of talk; the link drops; the next recording starts straight on. The regroup
        // in the gap runs ten seconds after the recording closed.
        let before = day(minutes: 60, talk: [.dialogue(0, 60)])
        let after = day(minutes: 60, talk: [.dialogue(0, 60)], recording: true)
        let inTheGap = t0 + minutesMs(60) + 10_000
        func tailIsProvisional(_ day: Day, _ policy: BoundaryPolicy, nowMs: Int64) -> Bool? {
            group(day, policy: policy, nowMs: nowMs).conversations.last?.isProvisional
        }
        for policy in [BoundaryPolicy.quietOnly, frozenPolicy] {
            #expect(tailIsProvisional(before, policy, nowMs: inTheGap) == true)
            expectFinishedConversationsKeepTheirKeys(
                before: before, after: after, policy: policy, somethingMustBeFinished: false,
                nowMs: inTheGap)
            #expect(tailIsProvisional(after, policy, nowMs: inTheGap) == true)
            // A whole chain window after it closed, nothing can continue the run any more: the
            // tail is final.
            let later = t0 + minutesMs(60) + ConversationGrouper.chainWindowMs
            #expect(tailIsProvisional(before, policy, nowMs: later) == false)
        }
    }

    /// The same gap, after a long silence. The silent tail of the run is its own unit, and the
    /// conversation before it is finished: the forty minutes of settled silence after its last
    /// word end it there. When the recording resumes, the open recording overlaps the silence —
    /// and that used to defer the quiet cut again, so the finished conversation took the whole
    /// silence back (`[s0, s1[..300000)]` became `[s0 … s4]`). The end after the last word is
    /// now decided on the settled silence that follows it, whatever is recorded later, so the
    /// conversation keeps its pieces; the tail is what grows, and it is provisional both in the
    /// gap and once the recording has resumed.
    @Test func aFinishedConversationKeepsItsKeyWhenTheRecordingResumesAfterItsSilentTail() {
        let before = day(minutes: 60, talk: [.dialogue(0, 20)])
        let talk = [["s0", "s1[..300000)"]]
        #expect(
            group(before, policy: .quietOnly).conversations.map(\.brief)
                == talk + [["s1[300000..)", "s2", "s3"]])
        let resumed = day(minutes: 60, talk: [.dialogue(0, 20)], recording: true)
        let inTheGap = t0 + minutesMs(60) + 10_000
        for policy in [BoundaryPolicy.quietOnly, frozenPolicy] {
            let gap = group(before, policy: policy, nowMs: inTheGap).conversations
            #expect(gap.map(\.isProvisional) == [false, true])
            expectFinishedConversationsKeepTheirKeys(
                before: before, after: resumed, policy: policy, nowMs: inTheGap)
            let now = group(resumed, policy: policy, nowMs: inTheGap).conversations
            #expect(now.map(\.brief) == talk + [["s1[300000..)", "s2", "s3", "s4"]])
            #expect(now.map(\.isProvisional) == [false, true])

            // And whatever the recording goes on to hold — more silence, or somebody talking
            // again — the conversation that ended keeps exactly the pieces it had.
            for (name, later) in [
                ("more silence", day(minutes: 90, talk: [.dialogue(0, 20)], recording: true)),
                (
                    "talk again",
                    day(minutes: 90, talk: [.dialogue(0, 20), .dialogue(80, 90)], recording: true)
                ),
            ] {
                expectFinishedConversationsKeepTheirKeys(
                    before: before, after: later, policy: policy, nowMs: inTheGap)
                #expect(
                    group(later, policy: policy, nowMs: inTheGap).conversations.first?.brief
                        == talk[0], "\(name)")
            }
        }
    }
}
