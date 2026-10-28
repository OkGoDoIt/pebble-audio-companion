import AppDB
import CompanionRuntime
import Foundation
import Testing
import Transcription

/// "Who is this?": recurring unnamed voices, asked about in People & voices and in a conversation.
@Suite("who is this") @MainActor
struct WhoIsThisTests {
    typealias Library = PieceLibrary
    private final class People: PeopleDataSource {
        var registry = [Person(id: "dana", name: "Dana")]
        func people() async throws -> [Person] { registry }
        func createPerson(name: String) async throws -> Person {
            let person = Person(id: "new-\(registry.count)", name: name)
            registry.append(person)
            return person
        }
        func assignPassage(_ turn: TranscriptTurn, personId: String?, makeCurrentUser: Bool) async throws {}
        func assignCurrentUserPassage(_ turn: TranscriptTurn, displayName: String) async throws -> Person { registry[0] }
        func assignedPerson(conversationId: String, turn: TranscriptTurn) async throws -> Person? { nil }
        func setCurrentUser(personId: String?) async throws {}
        func assign(conversationId: String, label: String, personName: String) async throws {}
        func assignedPerson(conversationId: String, label: String) async throws -> Person? { nil }
        func renamePerson(id: String, to newName: String) async throws {}
        func unassign(conversationId: String, label: String) async throws {}
        func deletePerson(id: String) async throws {}
    }

    private func voice() -> UnknownVoiceDisplay {
        UnknownVoiceDisplay(id: "v", recordingCount: 3, detail: "", clips: ["a", "b", "c"].map {
            UnknownVoiceClip(id: $0, segmentId: "seg-\($0)", startMs: 0, endMs: 4_000, heardAt: nil, quote: nil)
        })
    }

    @Test func namingTheWholeVoiceOrOnlyTheRecordingsThatAreThatPerson() async {
        let voices = VoiceTestSource(), people = People()
        let model = WhoIsThisModel(voices: voices, people: people)
        await model.load()
        #expect(await model.name(voice(), personId: "dana") == "Dana")
        #expect(await model.name(voice(), personId: "dana", recordings: ["seg-a", "seg-c"]) == "Dana")
        #expect(voices.namedUnknown.map(\.2) == [nil, ["seg-a", "seg-c"]],
                "The unticked recording stays unnamed")
        #expect(await model.nameAsNewPerson(voice(), name: "  Sam ") == "Sam")
        #expect(people.registry.last?.name == "Sam" && voices.namedUnknown.last?.1 == people.registry.last?.id)
    }

    @Test func ignoringOnlyTheChosenClipDoesNotNameOrTeachAndFailureAllowsRetry() async throws {
        let voices = VoiceTestSource(), people = People()
        let model = WhoIsThisModel(voices: voices, people: people)
        let clip = try #require(voice().clips.first)
        voices.failIgnore = true
        #expect(await !model.ignore(clip))
        #expect(model.errorMessage != nil && !model.working)
        #expect(voices.ignoredClips.isEmpty)
        voices.failIgnore = false
        #expect(await model.ignore(clip))
        #expect(model.errorMessage == nil && !model.working)
        #expect(voices.ignoredClips == [clip])
        #expect(voices.namedUnknown.isEmpty && voices.dismissedUnknown.isEmpty)
        #expect(voices.enrollmentPeople.isEmpty && voices.learnedRechecks.isEmpty)
    }

    @Test func ignoringAllUsesTheWholeGroupWithoutNamingOrLearning() async {
        let voices = VoiceTestSource(), model = WhoIsThisModel(voices: voices, people: People())
        voices.failIgnore = true
        #expect(await !model.ignoreAll(voice()))
        #expect(model.errorMessage != nil && voices.dismissedUnknown.isEmpty)
        voices.failIgnore = false
        #expect(await model.ignoreAll(voice()))
        #expect(model.errorMessage == nil && voices.dismissedUnknown == ["v"])
        #expect(voices.ignoredClips.isEmpty && voices.namedUnknown.isEmpty && voices.enrollmentPeople.isEmpty)
    }

    @Test func aRecurringVoiceIsMarkedOnlyOnUnnamedParagraphsItOverlaps() async {
        let members = [ConversationMember(segmentId: "s", startMediaMs: 0, endMediaMs: 30_000)]
        let transcripts = ["s": Library.transcript("s", [
            Library.turn("First voice talking.", 1_000, 5_000, "1"),
            Library.turn("Second voice talking.", 6_000, 12_000, "2"),
        ])]
        let result = await LiveWorld.walkMembers(members, metas: ["s": Library.meta("s", index: 0)],
            transcripts: transcripts, assignments: [],
            unknownVoices: [.init(segmentId: "s", startMs: 7_000, endMs: 10_000, voiceID: "voice-1"),
                            .init(segmentId: "other", startMs: 0, endMs: 30_000, voiceID: "voice-2")])
        let marks = result.transcript.compactMap { item -> String? in
            if case .turn(let turn) = item { return turn.unknownVoiceID ?? "-" }; return nil
        }
        #expect(marks == ["-", "voice-1"], "Another recording's voice never marks this one")
    }

    @Test func summaryLineSaysWhenTheVoiceIsUsuallyHeard() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_792_000_000 - 8 * 3_600)   // 09:46 UTC
        func at(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3_600) }
        #expect(UnknownVoiceDisplay.timeOfDay([at(1), at(25), at(49)], calendar: calendar) == "mostly mornings")
        #expect(UnknownVoiceDisplay.timeOfDay([at(1), at(12)], calendar: calendar) == nil, "Two sightings say little")
        #expect(UnknownVoiceDisplay.lastHeard(at(1), now: now, calendar: calendar) == "last heard today")
        #expect(UnknownVoiceDisplay.lastHeard(at(24), now: now, calendar: calendar) == "last heard yesterday")
    }
}

extension WhoIsThisTests {
    @Test func namingAClipNamesTheParagraphItSitsIn() {
        let paragraphs = [Library.turn("First.", 0, 8_000, "1"), Library.turn("Second, a longer one.", 8_000, 30_000, "2")]
        #expect(LiveVoiceSource.paragraph(around: 12_000..<16_000, in: paragraphs) == 8_000..<30_000)
        #expect(LiveVoiceSource.paragraph(around: 5_000..<9_000, in: paragraphs) == 0..<8_000,
                "Straddling two paragraphs, the one holding at least half the clip")
        #expect(LiveVoiceSource.paragraph(around: 40_000..<44_000, in: paragraphs) == nil, "Outside every paragraph")
    }

    /// Word timings are subword tokens without spacing ("c", "li", "ent"), as G17's transcripts
    /// have them; joined with spaces they read "a c li ent". The quote is the paragraph's own
    /// words around the clip.
    @Test func aClipsQuoteIsTheParagraphsWordsNotItsTokens() {
        let text = "Like when a client goes to a different store? You went to a different store."
        let tokens = ["L", "ike", "when", "a", "c", "li", "ent", "go", "es", "to", "a", "different", "store", "?",
                      "You", "w", "ent", "to", "a", "different", "stor", "e."]
        let words = tokens.enumerated().map { TranscriptWord(text: $1, startMs: Int64($0) * 100, endMs: Int64($0) * 100 + 90) }
        let transcript = SegmentTranscript(segmentId: "s", text: text, modeUsed: .localOnly, providerId: "parakeet",
            createdAtMs: 0, segments: [TranscriptSegment(text: text, startMs: 0, endMs: 2_200)], words: words)
        // The clip starts inside "client" (token "li") and ends inside "goes".
        #expect(UnknownVoiceDisplay.quote(transcript, from: 500, to: 800) == "“…client goes…”")
        #expect(UnknownVoiceDisplay.quote(transcript, from: 0, to: 2_200) == "“\(text)”")
        // Tokens that don't spell the text fall back to the whole paragraph, never fragments.
        let other = SegmentTranscript(segmentId: "s", text: text, modeUsed: .localOnly, providerId: "cloud", createdAtMs: 0,
            segments: [TranscriptSegment(text: text, startMs: 0, endMs: 2_200)],
            words: [TranscriptWord(text: "Something", startMs: 0, endMs: 2_000)])
        #expect(UnknownVoiceDisplay.quote(other, from: 500, to: 800) == "“\(text)”")
    }
}
