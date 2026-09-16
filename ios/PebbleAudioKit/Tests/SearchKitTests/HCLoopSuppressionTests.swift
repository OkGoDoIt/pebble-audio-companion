import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import SearchKit

// Looped-ASR-artefact suppression on the render path. The cases below are the shapes actually
// found in Roger's library (591 transcripts, 74 125 turns) — see
// `AppDB/TranscriptArtefacts.swift` for the measurements and the thresholds they set.
//
// The two that matter most are the NEGATIVE ones. A background-microphone product that hides a
// sentence someone really said has done something worse than showing junk, so
// `realSpeechBetweenLoopBurstsSurvives` and `wordPerTurnTranscriptsAreLeftAlone` are the tests
// that stop a future tuning pass from trading precision for recall by accident.

@Suite struct HCLoopSuppressionTests {

    // MARK: - The catastrophic case

    @Test func repeatedLineCollapsesToOneVisibleOccurrence() {
        var segments = [
            TranscriptSegment(text: "So where do you want to eat tonight?", startMs: 0, endMs: 2_000)
        ]
        for index in 0..<40 {
            let start = Int64(3_000 + index * 500)
            segments.append(
                TranscriptSegment(
                    text: "I'm going to bring you some cookies.",
                    startMs: start, endMs: start + 400))
        }

        let filtered = filteringLoopedArtefacts(segments: segments)

        // The first occurrence is never suppressed: the reader still sees what was said, once.
        #expect(filtered.segments.count == 2)
        #expect(filtered.segments[1].text == "I'm going to bring you some cookies.")
        #expect(filtered.loops.count == 1)
        #expect(filtered.loops[0].turnCount == 39)
    }

    @Test func suppressedLoopReadsAsQuietAndSaysWhatItStandsFor() throws {
        var segments = [TranscriptSegment(text: "Right, I'll head off then.", startMs: 0, endMs: 2_000)]
        for index in 0..<120 {
            let start = Int64(5_000 + index * 1_000)
            segments.append(
                TranscriptSegment(
                    text: "I'm going to bring you some cookies.",
                    startMs: start, endMs: start + 800))
        }
        segments.append(
            TranscriptSegment(text: "Sorry, I'm back — where were we?", startMs: 130_000, endMs: 132_000))

        let filtered = filteringLoopedArtefacts(segments: segments)
        let items = transcriptTimelineItems(
            meta: testMeta(), segments: filtered.segments, words: filtered.words,
            suppressedLoops: filtered.loops)

        let pauses = items.compactMap(\.asPause)
        let quiet = try #require(pauses.first { $0.suppressedRepeats > 0 })
        #expect(quiet.missing == false)  // never conflated with lost audio
        #expect(quiet.label.contains("quiet for"))
        #expect(quiet.label.contains("repeated lines hidden"))
        // And nothing anywhere claims audio went missing.
        #expect(!pauses.contains { $0.missing })
    }

    @Test func aRecordingThatIsEntirelyLoopStillExplainsItself() {
        var segments: [TranscriptSegment] = []
        for index in 0..<80 {
            let start = Int64(index * 1_000)
            segments.append(
                TranscriptSegment(text: "I need to find my keys.", startMs: start, endMs: start + 900))
        }

        let filtered = filteringLoopedArtefacts(segments: segments)
        let items = transcriptTimelineItems(
            meta: testMeta(), segments: filtered.segments, suppressedLoops: filtered.loops)

        // One surviving line, and a quiet row for the stretch it looped over — not a blank
        // screen, which is what "return [] when there is no speech" would have produced.
        #expect(items.compactMap(\.asSpeech).count == 1)
        #expect(items.compactMap(\.asPause).contains { $0.suppressedRepeats > 0 })
    }

    @Test func aBurstOfLinesInSecondsIsReportedWithoutClaimingQuietTime() {
        // The loop fires at machine speed: seg-1787241118189-41cb9579-30 emits 126 lines in
        // 13 seconds. "quiet for 13 sec" would bury what happened, so the short form reports
        // only the lines.
        let burst = TranscriptTimelineItem.Pause(
            startMs: 0, durationMs: 2_400, missing: false, suppressedRepeats: 126)
        #expect(burst.label == "126 repeated lines hidden")

        let stretch = TranscriptTimelineItem.Pause(
            startMs: 0, durationMs: 62_000, missing: false, suppressedRepeats: 231)
        #expect(stretch.label == "quiet for 1 min · 231 repeated lines hidden")

        // A handful stays unlabelled — the line is still on screen and a row per burst would
        // cost more than it explains.
        let handful = TranscriptTimelineItem.Pause(
            startMs: 0, durationMs: 62_000, missing: false, suppressedRepeats: 4)
        #expect(handful.label == "quiet for 1 min")
    }

    // MARK: - Precision: what must NEVER be suppressed

    @Test func realSpeechBetweenLoopBurstsSurvives() {
        // Verbatim shape from seg-1788011545455-f4c48ea5-6: a backchannel loop with genuine
        // sentences interleaved. An earlier rule that marked the whole degenerate WINDOW
        // deleted these sentences; requiring the turn itself to add no new phrase keeps them.
        var segments: [TranscriptSegment] = []
        var clock: Int64 = 0
        func add(_ text: String) {
            segments.append(TranscriptSegment(text: text, startMs: clock, endMs: clock + 300))
            clock += 400
        }
        add("You know, people especially students live in these dorms.")
        for _ in 0..<30 { add("Yeah.") }
        add("And three libraries.")
        for _ in 0..<30 { add("Yeah.") }
        add("I honestly don't have to leave the campus grounds.")
        for _ in 0..<30 { add("Yeah.") }

        let filtered = filteringLoopedArtefacts(segments: segments)
        let kept = filtered.segments.map(\.text)

        #expect(kept.contains("You know, people especially students live in these dorms."))
        #expect(kept.contains("And three libraries."))
        #expect(kept.contains("I honestly don't have to leave the campus grounds."))
        #expect(kept.filter { $0 == "Yeah." }.count == 1)
    }

    @Test func normalConversationIsUntouched() {
        let segments = [
            TranscriptSegment(text: "Did you get the parcel sorted?", startMs: 0, endMs: 2_000),
            TranscriptSegment(text: "Yeah, finally.", startMs: 2_400, endMs: 3_200),
            TranscriptSegment(text: "Which color in the end?", startMs: 3_600, endMs: 5_000),
            TranscriptSegment(text: "Blue, it was the only one left.", startMs: 5_400, endMs: 7_000),
            TranscriptSegment(text: "Yeah, that figures.", startMs: 7_400, endMs: 8_400),
        ]

        let filtered = filteringLoopedArtefacts(segments: segments)

        #expect(filtered.isUnchanged)
        #expect(filtered.segments.count == segments.count)
    }

    @Test func repeatingYourselfTwiceIsNotALoop() {
        // People do say the same thing twice. Three identical turns is the floor for a
        // multi-word line, and even then the first one always survives.
        let segments = [
            TranscriptSegment(text: "Are you coming or not?", startMs: 0, endMs: 1_500),
            TranscriptSegment(text: "Are you coming or not?", startMs: 3_000, endMs: 4_500),
            TranscriptSegment(text: "Fine, I'll drive myself.", startMs: 6_000, endMs: 7_500),
        ]

        #expect(filteringLoopedArtefacts(segments: segments).isUnchanged)
    }

    @Test func wordPerTurnTranscriptsAreLeftAlone() {
        // seg-1781314029539-0ad71257-4: no diarization, so the provider emits ONE WORD per
        // turn. Every common word is trivially "already said", and a candidate-density rule
        // shredded the real sentence "Let's go get some green apples." into fragments. The
        // diversity gate is what stops that, and this test is why it is the gate.
        let words = """
            A red that apple is the way to go Okay let's go get apples A green or I think green \
            is a good color Let's go get some green apples I think the puppy wants some apples \
            too We need some hats and gloves though Oliver Where's your hats and gloves Not yet
            """
            .split(separator: " ").map(String.init)
        let segments = words.enumerated().map { index, word in
            TranscriptSegment(
                text: word, startMs: Int64(index) * 400, endMs: Int64(index) * 400 + 250)
        }

        #expect(filteringLoopedArtefacts(segments: segments).isUnchanged)
    }

    // MARK: - The word stream has to move with the turns

    @Test func suppressionKeepsWordsLetterAlignedWithTurns() {
        // The karaoke highlight walks the two streams POSITIONALLY. Dropping turns without
        // dropping their words slides every later highlight by the removed characters.
        var segments: [TranscriptSegment] = []
        var words: [TranscriptWord] = []
        var clock: Int64 = 0
        func add(_ text: String) {
            segments.append(TranscriptSegment(text: text, startMs: clock, endMs: clock + 400))
            for token in text.split(separator: " ") {
                words.append(TranscriptWord(text: String(token), startMs: clock, endMs: clock + 60))
                clock += 80
            }
            clock += 320
        }
        add("Let me find the tickets.")
        for _ in 0..<12 { add("I'm going to bring you some cookies.") }
        add("Here they are, gate twenty two.")

        let filtered = filteringLoopedArtefacts(segments: segments, words: words)

        func letters(_ text: String) -> Int {
            text.reduce(0) { $0 + (($1.isLetter || $1.isNumber) ? 1 : 0) }
        }
        let inTurns = filtered.segments.reduce(0) { $0 + letters($1.text) }
        let inWords = filtered.words.reduce(0) { $0 + letters($1.text) }
        #expect(inTurns == inWords)
        #expect(filtered.words.count < words.count)
    }

    // MARK: - Compatibility

    @Test func timelineWithoutSuppressedLoopsIsUnchanged() {
        // Every caller that does not opt in must see exactly the old behavior, including the
        // 30-second threshold for a labelled quiet row.
        let segments = [
            TranscriptSegment(text: "before the quiet", startMs: 0, endMs: 1_000),
            TranscriptSegment(text: "after the quiet", startMs: 61_000, endMs: 62_000),
        ]

        let items = transcriptTimelineItems(meta: testMeta(), segments: segments)

        let pause = items.compactMap(\.asPause).first
        #expect(pause?.suppressedRepeats == 0)
        #expect(pause?.label == "quiet for 1 min")
    }

    private func testMeta() -> SegmentMeta {
        SegmentMeta(
            segmentId: "seg",
            streamId: 1,
            protocolVersion: 1,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 16_000,
            frameDurationMs: 20,
            startTimeMs: 0,
            startMonotonicMs: 0,
            receivedAtMs: 0,
            firstSampleIndex: 0,
            lastSampleIndexExclusive: 16_000 * 300,
            frameCount: 15_000,
            gaps: []
        )
    }
}
