import AppDB
import Foundation
import SearchKit
import Testing

// A provider labels ONE segment at a time, so "1" in one segment is not "1" in the next — and a
// conversation spans several. Names used to be filed under the bare label, so naming the second
// segment's "Speaker 1" also renamed whoever held label 1 in the first. These pin the scoping on
// the shared library of `ConversationPiecesTests`, whose second conversation holds a piece of
// each segment and label "1" in both.

@Suite("speaker names are per segment") @MainActor
struct SpeakerNamesPerSegmentTests {
    typealias Library = PieceLibrary

    private func rows(_ assignments: [SpeakerAssignment]) async throws -> [TranscriptTurn] {
        let db = try await Library.sharedLibrary()
        let pieces = try await Library.pieces(of: Library.second, in: db)
        let walked = await LiveWorld.walkMembers(
            pieces, metas: Library.metas, transcripts: Library.transcripts,
            assignments: assignments)
        return Library.turnRows(walked)
    }

    private func named(_ label: String, _ name: String) -> SpeakerAssignment {
        SpeakerAssignment(
            conversationId: Library.second, label: label, personId: "p-\(name)", personName: name)
    }

    /// The turns are seg-a "1", seg-a "2", seg-b "1".
    @Test func namingOneSegmentsSpeakerLeavesTheOtherSegmentsSameLabelUnnamed() async throws {
        let sam = SpeakerKey(segmentId: "seg-b", label: "1").stored
        let turns = try await rows([named(sam, "Sam")])

        #expect(turns.map(\.text) == [
            "So about the holiday plans.", "We could fly on the ninth.",
            "Flights are cheaper midweek.",
        ])
        #expect(turns.map(\.name) == ["Speaker 1", "Speaker 2", "Sam"])
        #expect(turns.map(\.role) == [.unresolved, .unresolved, .other])
        // What the rename sheet files a name under: each turn's own segment and label.
        #expect(turns.map(\.speakerLabel) == ["seg-a#1", "seg-a#2", "seg-b#1"])
    }

    /// A name given before names were scoped named the label in every segment, and that is
    /// what the person saw when they gave it, so it still does — except where a segment has a
    /// name of its own. Both forms such rows exist in: the one the sheet filed ("Speaker 1",
    /// what a turn carried) and the bare label the archive export reads.
    @Test func legacyNamesStillCoverTheConversationUnlessASegmentHasItsOwn() async throws {
        for legacy in ["Speaker 1", "1"] {
            let everywhere = try await rows([named(legacy, "Alex")])
            #expect(everywhere.map(\.name) == ["Alex", "Speaker 2", "Alex"], "\(legacy)")

            let overridden = try await rows([
                named(legacy, "Alex"), named(SpeakerKey(segmentId: "seg-b", label: "1").stored, "Sam"),
            ])
            #expect(overridden.map(\.name) == ["Alex", "Speaker 2", "Sam"], "\(legacy)")
        }
    }

    /// The header logic follows the same identity: two unnamed "Speaker 1"s either side of a
    /// segment boundary may be two people and get a header each; one named person talking
    /// across it is one run.
    @Test func aRunCrossesASegmentBoundaryOnlyForTheSamePerson() async throws {
        let unnamed = try await rows([])
        #expect(!TranscriptLayout.continuesRun(unnamed[0], with: unnamed[2]))

        let alex = try await rows([
            named(SpeakerKey(segmentId: "seg-a", label: "1").stored, "Alex"),
            named(SpeakerKey(segmentId: "seg-b", label: "1").stored, "Alex"),
        ])
        #expect(TranscriptLayout.continuesRun(alex[0], with: alex[2]))
        #expect(!TranscriptLayout.continuesRun(alex[0], with: alex[1]))
    }
}
