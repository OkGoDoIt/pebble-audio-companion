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

    private func rows(_ assignments: [SpeakerAssignment], identities: SpeakerIdentitySnapshot = .init()) async throws -> [TranscriptTurn] {
        let db = try await Library.sharedLibrary()
        let pieces = try await Library.pieces(of: Library.second, in: db)
        let walked = await LiveWorld.walkMembers(
            pieces, metas: Library.metas, transcripts: Library.transcripts,
            assignments: assignments, identities: identities)
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
    @Test func correctionUsesSegmentAudioAndOverridesChangedProviderLabels() async throws {
        let original = try await rows([])
        let selected = try #require(original.last)
        let start = try #require(selected.sourceStartMs)
        let end = try #require(selected.sourceEndMs)
        #expect(selected.canIdentifyPassage)
        let person = Person(id: "me", name: "Roger")
        let identity = SpeakerIdentitySnapshot(currentUserPersonId: "me", corrections: [
            SpeakerCorrection(id: "x", segmentId: "seg-b", startMediaMs: start,
                              endMediaMs: end, person: person, createdAtMs: 0)
        ])
        let corrected = try await rows([named("seg-b#1", "Wrong")], identities: identity)
        #expect(corrected.last?.name == "You")
        #expect(corrected.last?.role == .you)
        #expect(corrected.last?.personId == "me")
        #expect(corrected.first?.personId == nil)
    }

    @Test func unnamedLockWinsAndLiteralYouIsNotTheCurrentUser() async throws {
        let original = try await rows([named("seg-b#1", "You")])
        let selected = try #require(original.last)
        #expect(selected.role == .other)
        let identity = SpeakerIdentitySnapshot(corrections: [
            SpeakerCorrection(id: "x", segmentId: "seg-b",
                              startMediaMs: try #require(selected.sourceStartMs),
                              endMediaMs: try #require(selected.sourceEndMs),
                              person: nil, createdAtMs: 0)
        ])
        let corrected = try await rows([named("seg-b#1", "You")], identities: identity)
        #expect(corrected.last?.name == "Speaker 1")
        #expect(corrected.last?.personId == nil)
    }

    @Test func equalNamesWithDifferentIdsNeverJoinARun() async throws {
        let turns = try await rows([
            SpeakerAssignment(conversationId: Library.second, label: "seg-a#1", personId: "a", personName: "Sam"),
            SpeakerAssignment(conversationId: Library.second, label: "seg-b#1", personId: "b", personName: "Sam")
        ])
        #expect(!TranscriptLayout.continuesRun(turns[0], with: turns[2]))
    }

    @Test func unlabeledAsrWordsSplitAtRecognizedIdentityBoundaries() throws {
        func match(_ id: String, _ name: String, start: Int64, end: Int64) -> VoiceResolvedAttribution {
            VoiceResolvedAttribution(attribution: VoiceAutomaticAttribution(personId: id, segmentId: "s",
                startMediaMs: start, endMediaMs: end, sourceRevision: "audio", recipeID: "test",
                score: 0.9, margin: 0.2, calibrationID: "test", runID: "run"), person: Person(id: id, name: name))
        }
        let identities = SpeakerIdentitySnapshot(currentUserPersonId: "me", automaticAttributions: [
            match("me", "Roger", start: 0, end: 1_900), match("sam", "Sam", start: 2_100, end: 4_000)
        ])
        let built = TranscriptItems.member(segmentId: "s", meta: Library.meta("s", index: 0),
            segments: [SearchKit.TranscriptSegment(text: "Hello there. Good morning.", startMs: 0, endMs: 4_000)],
            words: [SearchKit.TranscriptWord(text: "Hello", startMs: 0, endMs: 900),
                    SearchKit.TranscriptWord(text: "there.", startMs: 1_000, endMs: 1_900),
                    SearchKit.TranscriptWord(text: "Good", startMs: 2_100, endMs: 3_000),
                    SearchKit.TranscriptWord(text: "morning.", startMs: 3_100, endMs: 4_000)],
            assignments: [], identities: identities, timebase: .media)
        let turns = built.items.compactMap { if case .turn(let turn) = $0 { turn } else { nil } }
        #expect(turns.count == 2)
        #expect(turns.map(\.name) == ["You", "Sam"])
        #expect(turns.map(\.personId) == ["me", "sam"])
        #expect(turns.allSatisfy { $0.isVoiceMatch })
        #expect(turns.map(\.text).joined(separator: " ") == "Hello there. Good morning.")
        #expect(turns[0].sourceEndMs == 1_900)
        #expect(turns[1].sourceStartMs == 2_100)
    }

    @Test func noWordTimingsOfferAnExplicitWholePassageWithoutInventingParagraphAudio() {
        let text = (0..<80).map { "word\($0)" }.joined(separator: " ")
        let built = TranscriptItems.member(segmentId: "s", meta: Library.meta("s", index: 0),
            segments: [SearchKit.TranscriptSegment(text: text, startMs: 0, endMs: 50_000)],
            assignments: [], timebase: .media)
        let turns = built.items.compactMap { if case .turn(let turn) = $0 { turn } else { nil } }
        #expect(turns.count > 1)
        #expect(turns.allSatisfy { $0.canIdentifyPassage })
        #expect(turns.allSatisfy { $0.sourceStartMs == 0 && $0.sourceEndMs == 50_000 })
        #expect(turns.allSatisfy { $0.identificationText == text })
        #expect(turns.allSatisfy { !$0.canRememberVoice }) // Too long; guided setup remains available.
    }

    @Test func equalLengthDifferentWordsNeverNarrowAnIdentityRange() {
        let aligner = TranscriptWordAligner(
            words: [SearchKit.TranscriptWord(text: "sells", startMs: 1_000, endMs: 2_000)],
            speechTexts: ["hello"])
        #expect(!aligner.hasExactTextMatch)
        let text = (0..<80).map { "hello\($0)" }.joined(separator: " ")
        let words = (0..<80).map { index in
            SearchKit.TranscriptWord(text: "sells\(index)", startMs: Int64(index) * 500, endMs: Int64(index + 1) * 500)
        }
        let built = TranscriptItems.member(segmentId: "s", meta: Library.meta("s", index: 0),
            segments: [SearchKit.TranscriptSegment(text: text, startMs: 0, endMs: 50_000, speaker: "1")],
            words: words, assignments: [], timebase: .media)
        let turns = built.items.compactMap { if case .turn(let turn) = $0 { turn } else { nil } }
        #expect(turns.count > 1)
        #expect(turns.allSatisfy { $0.identificationText == text && $0.sourceEndMs == 50_000 })
    }

    @Test func punctuationMismatchUsesWholePassageAsAttributionRequires() {
        let text = (0..<40).map { "word\($0)," }.joined(separator: " ")
        let words = (0..<40).map { index in
            SearchKit.TranscriptWord(text: "word\(index)", startMs: Int64(index) * 500,
                                     endMs: Int64(index + 1) * 500)
        }
        let built = TranscriptItems.member(segmentId: "s", meta: Library.meta("s", index: 0),
            segments: [SearchKit.TranscriptSegment(text: text, startMs: 0, endMs: 20_000, speaker: "1")],
            words: words, assignments: [], timebase: .media)
        let turns = built.items.compactMap { if case .turn(let turn) = $0 { turn } else { nil } }
        #expect(turns.count > 1)
        #expect(turns.allSatisfy { $0.identificationText == text && $0.sourceStartMs == 0 && $0.sourceEndMs == 20_000 })
        #expect(turns.allSatisfy { !$0.words.isEmpty }) // Highlighting remains usable.
    }

    @Test func aPointTimedFinalWordBelongsToItsSavedCorrection() throws {
        let segments = [SearchKit.TranscriptSegment(text: "First Paris.", startMs: 0, endMs: 220, speaker: "1"),
                        SearchKit.TranscriptSegment(text: "Next.", startMs: 240, endMs: 500, speaker: "2")]
        let words = [SearchKit.TranscriptWord(text: "First", startMs: 0, endMs: 100),
                     SearchKit.TranscriptWord(text: "Paris", startMs: 200, endMs: 200),
                     SearchKit.TranscriptWord(text: ".", startMs: 210, endMs: 220),
                     SearchKit.TranscriptWord(text: "Next.", startMs: 240, endMs: 500)]
        func render(_ identity: SpeakerIdentitySnapshot) -> [TranscriptTurn] {
            TranscriptItems.member(segmentId: "s", meta: Library.meta("s", index: 0),
                segments: segments, words: words, assignments: [], identities: identity, timebase: .media)
                .items.compactMap { if case .turn(let turn) = $0 { turn } else { nil } }
        }
        let selected = try #require(render(.init()).first)
        #expect(selected.sourceEndMs == 201)
        let named = render(SpeakerIdentitySnapshot(corrections: [SpeakerCorrection(id: "c", segmentId: "s",
            startMediaMs: try #require(selected.sourceStartMs), endMediaMs: try #require(selected.sourceEndMs),
            person: Person(id: "dana", name: "Dana"), createdAtMs: 0)]))
        #expect(named.map(\.name) == ["Dana", "Speaker 2"])
        #expect(named.map(\.text) == ["First Paris.", "Next."])
        #expect(named.first?.sourceEndMs == selected.sourceEndMs)
    }

    @Test func aTimedTurnCrossingAPieceCannotNameTheNeighborsAudio() {
        let built = TranscriptItems.member(segmentId: "s", meta: Library.meta("s", index: 0),
            segments: [SearchKit.TranscriptSegment(text: "Hello there.", startMs: 5_000, endMs: 15_000)],
            assignments: [], timebase: .media,
            piece: ConversationMember(segmentId: "s", startMediaMs: 0, endMediaMs: 10_000))
        let turns = built.items.compactMap { if case .turn(let turn) = $0 { turn } else { nil } }
        #expect(turns.count == 1)
        #expect(turns.allSatisfy { !$0.canIdentifyPassage })
    }

    @Test func coarseAsrStillOffersExactAudioMatchesInsideItsOwnPiece() async throws {
        let person = Person(id: "me", name: "Roger", isCurrentUser: true)
        let identity = SpeakerIdentitySnapshot(currentUserPersonId: "me", automaticAttributions: [
            VoiceResolvedAttribution(attribution: VoiceAutomaticAttribution(personId: "me", segmentId: "s",
                startMediaMs: 12_000, endMediaMs: 16_000, sourceRevision: "r", recipeID: "r",
                score: 0.8, margin: 0.2, calibrationID: "test", runID: "run"), person: person)])
        let result = await LiveWorld.walkMembers(
            [ConversationMember(segmentId: "s", startMediaMs: 10_000, endMediaMs: 30_000)],
            metas: ["s": Library.meta("s", index: 0)],
            transcripts: ["s": Library.transcript("s", [Library.turn("A whole sentence with coarse timing.", 10_000, 29_000, "")])],
            assignments: [], identities: identity)
        #expect(result.voiceMatches.count == 1)
        let match = try #require(result.voiceMatches.first)
        #expect(match.playbackStartMs == 2_000 && match.playbackEndMs == 6_000)
        #expect(match.correction.sourceStartMs == 12_000 && match.correction.isAudioOnly)
        #expect(match.correction.canRememberVoice)
        #expect(result.transcript.compactMap { if case .turn(let turn) = $0 { turn.personId } else { nil } }.isEmpty)
    }

    @Test(arguments: [false, true])
    func correctingAudioOnlyMatchRemainsEditableIncludingLeaveUnnamed(coarseTranscript: Bool) async throws {
        let database = try AppDatabase.inMemory()
        let person = try await PeopleStore(db: database).createPerson(name: "Alice")
        let corrections = SpeakerCorrectionStore(db: database)
        let members = [ConversationMember(segmentId: "s", startMediaMs: 10_000, endMediaMs: 30_000)]
        let transcripts = coarseTranscript ? ["s": Library.transcript("s", [
            Library.turn("A whole sentence with coarse timing.", 10_000, 29_000, "")])] : [:]
        try await corrections.set(segmentId: "s", startMediaMs: 12_000, endMediaMs: 16_000, personId: person.id)
        var identity = try await corrections.snapshot(segmentIds: ["s"])
        var result = await LiveWorld.walkMembers(members, metas: ["s": Library.meta("s", index: 0)],
            transcripts: transcripts, assignments: [], identities: identity)
        let named = try #require(result.voiceMatches.first)
        #expect(result.voiceMatches.count == 1)
        #expect(named.person?.id == person.id && !named.isAutomatic)
        #expect(named.correction.canIdentifyPassage && !named.correction.isVoiceMatch)
        #expect(named.playbackStartMs == 2_000 && named.playbackEndMs == 6_000)

        try await corrections.set(segmentId: "s", startMediaMs: 12_000, endMediaMs: 16_000, personId: nil)
        identity = try await corrections.snapshot(segmentIds: ["s"])
        result = await LiveWorld.walkMembers(members, metas: ["s": Library.meta("s", index: 0)],
            transcripts: transcripts, assignments: [], identities: identity)
        let unnamed = try #require(result.voiceMatches.first)
        #expect(result.voiceMatches.count == 1)
        #expect(unnamed.person == nil && !unnamed.isAutomatic)
        #expect(unnamed.name == "Unnamed voice")
        #expect(unnamed.correction.canIdentifyPassage)
        #expect(unnamed.correction.sourceStartMs == 12_000 && unnamed.correction.sourceEndMs == 16_000)
    }

}
