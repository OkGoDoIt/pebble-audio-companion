import AppDB
import Foundation
import Testing
import Transcription
@testable import Intelligence

@Suite struct SpeakerFollowUpIdentityTests {
    @Test func promptNamesTheExplicitCurrentUserAndKeepsUnknownSpeechSeparate() {
        let person = Person(id: "self", name: "Roger")
        let identity = SpeakerIdentitySnapshot(currentUserPersonId: person.id, corrections: [
            SpeakerCorrection(id: "human", segmentId: "s", startMediaMs: 100, endMediaMs: 200,
                              person: person, createdAtMs: 0),
        ])
        let part = FollowUpSourcePart(segmentId: "s", startedAtMs: 0,
            text: "I will call. I might go.", turns: [
                TranscriptSegment(text: "I will call.", startMs: 100, endMs: 200),
                TranscriptSegment(text: "I might go.", startMs: 200, endMs: 300),
            ], identity: identity)
        #expect(FollowUpTranscriptRenderer.speakerLines(part)
            == "Roger (current user): I will call.\nS?: I might go.")
    }
}
