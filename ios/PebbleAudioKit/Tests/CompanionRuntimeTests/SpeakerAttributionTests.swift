import AppDB
import Foundation
import Testing
import Transcription

@testable import CompanionRuntime

@Suite("speaker attribution across app consumers")
struct SpeakerAttributionTests {
    private let old = Person(id: "old", name: "Alex")
    private let current = Person(id: "current", name: "Roger")

    private func snapshot(person: Person?, range: Range<Int64> = 100..<200) -> SpeakerIdentitySnapshot {
        SpeakerIdentitySnapshot(revision: 7, currentUserPersonId: current.id, corrections: [
            SpeakerCorrection(id: "correction", segmentId: "s", startMediaMs: range.lowerBound,
                              endMediaMs: range.upperBound, person: person, createdAtMs: 1),
        ])
    }

    private var assignments: [SpeakerAssignment] {
        [SpeakerAssignment(conversationId: "c", label: SpeakerKey(segmentId: "s", label: "1").stored,
                           personId: old.id, personName: old.name)]
    }

    private func auto(_ person: Person, start: Int64, end: Int64,
                      disposition: VoiceAttributionDisposition = .recognized) -> VoiceResolvedAttribution {
        VoiceResolvedAttribution(attribution: VoiceAutomaticAttribution(personId: person.id, segmentId: "s",
            startMediaMs: start, endMediaMs: end, sourceRevision: "digest", recipeID: "recipe",
            score: 0.95, margin: 0.2, calibrationID: "test", runID: "run", disposition: disposition), person: person)
    }

    @Test func wordAlignmentNamesOnlyCoveredWordsAndPreservesEveryOriginalCharacter() {
        let transcript = SegmentTranscript(segmentId: "s", text: "Hello,  Alex! Bye.", modeUsed: .localOnly,
            providerId: "test", createdAtMs: 0,
            segments: [TranscriptSegment(text: "Hello,  Alex! Bye.", startMs: 0, endMs: 4_000)],
            words: [TranscriptWord(text: "Hello,", startMs: 200, endMs: 1_000),
                    TranscriptWord(text: "Alex!", startMs: 1_200, endMs: 2_000),
                    TranscriptWord(text: "Bye.", startMs: 2_200, endMs: 3_000)])
        let identity = SpeakerIdentitySnapshot(automaticAttributions: [auto(current, start: 360, end: 2_000)])
        let turns = SpeakerAttribution.attributedTurns(transcript: transcript, segmentId: "s",
            identity: identity, legacyAssignments: [])
        #expect(turns.map(\.text).joined() == transcript.text)
        #expect(turns.count == 2)
        #expect(turns.first?.person?.id == current.id)
        #expect(turns.first?.isVoiceMatch == true)
        #expect(turns.last?.person == nil)
        #expect(turns.flatMap(\.words) == transcript.words)
        let conflicted = SpeakerIdentitySnapshot(automaticAttributions: identity.automaticAttributions
            + [auto(old, start: 900, end: 950)])
        #expect(conflicted.resolvedWordIdentity(segmentId: "s", startMediaMs: 200, endMediaMs: 1_000,
            speaker: nil, legacyAssignments: []) == nil)
    }

    @Test func manualLocksAndLegacyNamesOverrideAutomaticAndSuggestionsStayUnnamed() {
        var identity = SpeakerIdentitySnapshot(automaticAttributions: [auto(current, start: 0, end: 1_000)])
        #expect(identity.resolvedWordIdentity(segmentId: "s", startMediaMs: 100, endMediaMs: 200,
            speaker: "1", legacyAssignments: assignments)?.person.id == old.id)
        identity.corrections = snapshot(person: nil).corrections
        #expect(identity.resolvedWordIdentity(segmentId: "s", startMediaMs: 100, endMediaMs: 200,
            speaker: "1", legacyAssignments: assignments) == nil)
        identity = SpeakerIdentitySnapshot(automaticAttributions: [auto(current, start: 0, end: 1_000, disposition: .suggestion)])
        #expect(identity.resolvedWordIdentity(segmentId: "s", startMediaMs: 100, endMediaMs: 200,
            speaker: nil, legacyAssignments: []) == nil)
    }

    @Test(arguments: ["1", nil] as [String?])
    func explicitCorrectionNamesBothCloudAndLocalSpeech(_ label: String?) {
        let identity = snapshot(person: current)
        let person = SpeakerAttribution.person(
            segmentId: "s", startMediaMs: 100, endMediaMs: 200, speaker: label,
            identity: identity, legacyAssignments: assignments)
        #expect(person?.id == current.id)
        #expect(person?.isCurrentUser == true)
        let name = SpeakerAttribution.name(
            segmentId: "s", startMediaMs: 100, endMediaMs: 200, speaker: label,
            identity: identity, legacyNames: [assignments[0].label: old.name])
        #expect(SpeakerAttribution.line(text: "hello", speaker: label, name: name) == "Roger: hello")
    }

    @Test func unnamedAndPartialCorrectionsBlockLegacyNames() {
        for identity in [snapshot(person: nil), snapshot(person: current, range: 125..<175)] {
            #expect(SpeakerAttribution.person(
                segmentId: "s", startMediaMs: 100, endMediaMs: 200, speaker: "1",
                identity: identity, legacyAssignments: assignments) == nil)
            let name = SpeakerAttribution.name(
                segmentId: "s", startMediaMs: 100, endMediaMs: 200, speaker: "1",
                identity: identity, legacyNames: [assignments[0].label: old.name])
            #expect(name == nil)
            #expect(SpeakerAttribution.line(text: "hello", speaker: "1", name: name) == "Speaker 1: hello")
        }
        // The same provider label elsewhere keeps its legacy name.
        #expect(SpeakerAttribution.name(
            segmentId: "s", startMediaMs: 200, endMediaMs: 300, speaker: "1",
            identity: snapshot(person: nil), legacyNames: [assignments[0].label: old.name]) == "Alex")
    }

    @Test func legacyFallbackIsScopedAndSelfIsNeverInferredFromAName() {
        let identity = SpeakerIdentitySnapshot(currentUserPersonId: "someone-else")
        let legacy = [SpeakerAssignment(conversationId: "c", label: assignments[0].label,
                                       personId: "literal-you", personName: "You")]
        #expect(SpeakerAttribution.person(
            segmentId: "s", startMediaMs: 100, endMediaMs: 200, speaker: "1",
            identity: identity, legacyAssignments: legacy)?.isCurrentUser == false)
        #expect(SpeakerAttribution.name(
            segmentId: "other-segment", startMediaMs: 100, endMediaMs: 200, speaker: "1",
            identity: identity, legacyNames: [assignments[0].label: "Alex"]) == nil)
    }

    @Test func participantsUseAudioRangesAndKeepSameNamePeopleDistinct() {
        let otherAlex = Person(id: "second-alex", name: "Alex")
        let identity = SpeakerIdentitySnapshot(corrections: [
            SpeakerCorrection(id: "a", segmentId: "s", startMediaMs: 100, endMediaMs: 200,
                              person: old, createdAtMs: 1),
            SpeakerCorrection(id: "b", segmentId: "s", startMediaMs: 300, endMediaMs: 400,
                              person: otherAlex, createdAtMs: 2),
        ])
        #expect(SpeakerAttribution.people(
            in: ConversationMember(segmentId: "s"), transcript: nil,
            identity: identity, legacyAssignments: []).map(\.id) == [old.id, otherAlex.id])
        #expect(SpeakerAttribution.people(
            in: ConversationMember(segmentId: "s", startMediaMs: 200), transcript: nil,
            identity: identity, legacyAssignments: []).map(\.id) == [otherAlex.id])
    }

    @Test func archiveTextAndStructuredTurnsUseTheSameCorrection() throws {
        var pieces = try ArchiveTranscriptExportTests.pieces()
        let first = try #require(pieces[0].transcript?.piece(pieces[0].member).segments.first)
        let segmentId = pieces[0].member.segmentId
        // Exercise local ASR: an explicit name must not be dropped for lack of a raw label.
        pieces[0].transcript?.segments = [
            TranscriptSegment(text: first.text, startMs: first.startMs, endMs: first.endMs),
        ]
        let identity = SpeakerIdentitySnapshot(currentUserPersonId: current.id, corrections: [
            SpeakerCorrection(id: "a", segmentId: segmentId, startMediaMs: first.startMs,
                              endMediaMs: first.endMs, person: current, createdAtMs: 1),
        ])
        let payload = ArchiveExport.transcript(
            conversationId: "c", pieces: [pieces[0]], gaps: [], speakerNames: [:],
            sourceHash: "h", identity: identity)
        #expect(payload.text == "Roger: \(first.text)")
        guard case .turn(_, _, let speaker, let name, _, _) = payload.items.first else {
            Issue.record("expected named turn")
            return
        }
        #expect(speaker == nil && name == "Roger")
    }
}
