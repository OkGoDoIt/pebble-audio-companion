import AppDB
import CompanionRuntime
import Foundation
import Testing
import Transcription

@Suite("speaker selection survives provider token boundaries") @MainActor
struct SpeakerNamingRoundTripTests {
    @Test func namingThenClearingASelectedRunSurvivesReloadAndExport() async throws {
        let id = "tokenized"
        let text = (0..<35).map { "word\($0)" }.joined(separator: " ") + "."
        var words: [Transcription.TranscriptWord] = []
        for index in 0..<35 {
            let start = Int64(1_000 + index * 200)
            words += [Transcription.TranscriptWord(text: "wo", startMs: start, endMs: start + 60),
                      Transcription.TranscriptWord(text: "rd\(index)", startMs: start + 60, endMs: start + 60)]
        }
        words.append(Transcription.TranscriptWord(text: ".", startMs: 7_900, endMs: 7_960))
        words.append(Transcription.TranscriptWord(text: "Neighbor.", startMs: 15_000, endMs: 16_000))
        var transcript = PieceLibrary.transcript(id, [
            PieceLibrary.turn(text, 1_000, 7_960, "1"),
            PieceLibrary.turn("Neighbor.", 15_000, 16_000, "2")])
        transcript.words = words
        let member = ConversationMember(segmentId: id, startMediaMs: 500, endMediaMs: 20_000)
        let meta = PieceLibrary.meta(id, index: 0)
        func render(_ identity: SpeakerIdentitySnapshot) async -> [TranscriptItem] {
            await LiveWorld.walkMembers([member], metas: [id: meta], transcripts: [id: transcript],
                assignments: [], identities: identity).transcript
        }
        let original = await render(.init())
        let first = try #require(original.compactMap { if case .turn(let turn) = $0 { turn } else { nil } }.first)
        let layout = TranscriptLayout(transcript: original, provenance: nil, focus: nil)
        let picked = TranscriptView.run(startingAt: first, in: layout)
        #expect(picked.count == 2) // Readability splitting must not omit the last word.
        #expect(picked.allSatisfy { $0.canIdentifyPassage })
        #expect(picked.last?.sourceEndMs == 7_860) // Letters, not the separately timed period.
        let db = try AppDatabase.inMemory()
        let person = try await PeopleStore(db: db).createPerson(name: "Dana")
        let store = SpeakerCorrectionStore(db: db)
        for turn in picked {
            try await store.set(segmentId: id, startMediaMs: try #require(turn.sourceStartMs),
                endMediaMs: try #require(turn.sourceEndMs), personId: person.id)
        }
        let saved = try await store.snapshot(segmentIds: [id])
        let renamed = await render(saved)
        let turns = renamed.compactMap { if case .turn(let turn) = $0 { turn } else { nil } }
        #expect(turns.dropLast().allSatisfy { $0.name == "Dana" && $0.personId == person.id })
        #expect(turns.last?.name == "Speaker 2")
        #expect(turns.map(\.text).joined(separator: " ") == text + " Neighbor.")
        let export = ArchiveExport.transcript(conversationId: "conversation",
            pieces: [.init(member: member, meta: meta, transcript: transcript)], gaps: [],
            speakerNames: [:], sourceHash: "test", identity: saved)
        #expect(export.text.contains("Dana: " + text))
        #expect(export.text.contains("Speaker 2: Neighbor."))

        for turn in turns.dropLast() {
            try await store.set(segmentId: id, startMediaMs: try #require(turn.sourceStartMs),
                endMediaMs: try #require(turn.sourceEndMs), personId: nil)
        }
        let cleared = await render(try await store.snapshot(segmentIds: [id]))
        #expect(cleared.compactMap { if case .turn(let turn) = $0 { turn.personId } else { nil } }.isEmpty)
    }
}
