import Foundation
import Testing
import Transcription

@testable import Intelligence

// What the model reads. `AppDB/TranscriptArtefacts.swift` carries the measurements; this pins
// the two properties everything downstream depends on:
//
//  1. a clean transcript comes back IDENTICAL — no reformatting, no rebuilt text, no surprise
//     diff between what the transcript screen shows and what the summariser was given;
//  2. a looped one comes back with the line said once and a note saying how many times the
//     transcriber said it again, so the model can report a quiet recording instead of
//     inventing significance for 12 000 words of stutter.

@Suite struct HCTranscriptCleanupTests {

    @Test func cleanTranscriptIsReturnedUnchanged() {
        let transcript = make([
            ("Did you get the parcel sorted?", 0),
            ("Yeah, finally. Blue, it was the only one left.", 2_400),
            ("That figures.", 6_000),
        ])

        #expect(transcript.withLoopedArtefactsCollapsed() == transcript)
        #expect(transcript.loopedArtefactWordCount == 0)
    }

    @Test func loopedTranscriptKeepsTheLineOnceAndSaysHowOftenItRepeated() {
        var turns: [(String, Int64)] = [("Right, I'll head off then.", 0)]
        for index in 0..<50 {
            turns.append(("I'm going to bring you some cookies.", Int64(2_000 + index * 500)))
        }
        turns.append(("Sorry — where were we?", 40_000))
        let transcript = make(turns)

        let collapsed = transcript.withLoopedArtefactsCollapsed()

        // The line survives exactly once, both ends of the real conversation survive, and the
        // omission is stated rather than left as an unexplained hole.
        #expect(collapsed.text.contains("Right, I'll head off then."))
        #expect(collapsed.text.contains("Sorry — where were we?"))
        #expect(
            collapsed.text.components(separatedBy: "I'm going to bring you some cookies.").count - 1
                == 1)
        #expect(collapsed.text.contains("repeated the previous line 49 more times"))
        #expect(collapsed.segments.count == 3)
        #expect(transcript.loopedArtefactWordCount == 49 * 7)
    }

    @Test func collapsingNeverTouchesTheStoredTranscript() {
        var turns: [(String, Int64)] = []
        for index in 0..<20 { turns.append(("I need to find my keys.", Int64(index * 800))) }
        let transcript = make(turns)
        let before = transcript

        _ = transcript.withLoopedArtefactsCollapsed()

        // A value type, so this is a compile-time truth as much as a runtime one — but it is
        // the whole safety story for this feature and deserves to fail loudly if it changes.
        #expect(transcript == before)
        #expect(transcript.segments.count == 20)
    }

    @Test func aTranscriptWithNoTurnTimingsIsLeftAlone() {
        // Migrated rows and some providers store text with no segment breakdown. There is
        // nothing to reason about, so it passes through rather than being guessed at.
        let transcript = SegmentTranscript(
            segmentId: "seg", text: "one two three", modeUsed: .remoteOnly,
            providerId: "test", createdAtMs: 0)

        #expect(transcript.withLoopedArtefactsCollapsed() == transcript)
        #expect(transcript.loopedArtefactWordCount == 0)
    }

    private func make(_ turns: [(String, Int64)]) -> SegmentTranscript {
        SegmentTranscript(
            segmentId: "seg",
            text: turns.map(\.0).joined(separator: " "),
            modeUsed: .remoteOnly,
            providerId: "test",
            createdAtMs: 0,
            segments: turns.map {
                TranscriptSegment(text: $0.0, startMs: $0.1, endMs: $0.1 + 400)
            })
    }
}
