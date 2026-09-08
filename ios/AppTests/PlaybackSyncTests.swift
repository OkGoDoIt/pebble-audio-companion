import CoreGraphics
import Foundation
import SearchKit
import SegmentStore
import Testing
import WireProtocol

// Following along is arithmetic, and arithmetic on this screen is invisible when it is wrong:
// a highlight two seconds out of step with the voice still looks like a highlight, and a
// "play from here" that lands a minute late still plays audio. So the mappings are pinned here.
//
// Three things are under test, in the order data flows through them:
//
//  1. `SegmentMediaClock` — wall time ↔ media time through the segment's own gap records. This
//     replaced a proportional guess (a point 40% through the wall span is 40% through the
//     stored audio) that is only ever right when the gaps happen to be spread evenly.
//  2. `TranscriptItems.member` — provider timings onto the scrubber, on whichever clock the
//     provider was actually using, plus the alignment of word timings to the rendered text.
//  3. `TranscriptPlayheadIndex` / `TranscriptTapGeometry` — "which word is playing at t", and
//     its reverse, "which word did that tap land on".

@Suite("playback sync") @MainActor
struct PlaybackSyncTests {

    // MARK: - Fixtures

    /// A minute of wall time at 16 kHz / 20 ms frames, holding `storedMs` of audio.
    private func meta(
        wallMs: Int64 = 60_000,
        storedMs: Int64 = 60_000,
        gaps: [GapMeta] = [],
        startTimeMs: UInt64 = 1_700_000_000_000
    ) -> SegmentMeta {
        SegmentMeta(
            segmentId: "seg-1",
            streamId: 1,
            protocolVersion: 1,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 16_000,
            frameDurationMs: 20,
            startTimeMs: startTimeMs,
            startMonotonicMs: 0,
            // The phone received this after the watch recorded it. That ordering is not a detail
            // here: `segmentStartMs` clamps the sample-derived start to `receivedAtMs`, because
            // the watch's counter free-runs across reattach and can otherwise place a segment
            // hours in the future. A fixture claiming 0 is claiming the audio arrived in 1970,
            // which pins every stamp in the suite to the epoch and would have "proved" the
            // unclamped anchor correct.
            receivedAtMs: Int64(startTimeMs) + wallMs,
            firstSampleIndex: 0,
            lastSampleIndexExclusive: UInt64(wallMs) * 16,
            frameCount: storedMs / 20,
            gaps: gaps
        )
    }

    /// A gap starting `atMs` into the segment's wall span and lasting `durationMs`.
    private func gap(atMs: Int64, durationMs: Int64) -> GapMeta {
        GapMeta(
            firstMissingSequence: UInt32(atMs / 20),
            missingFrameCount: UInt32(durationMs / 20),
            firstMissingSampleIndex: UInt64(atMs) * 16,
            origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.spoolOverflow.rawValue)
        )
    }

    private func firstTurn(_ items: [TranscriptItem]) -> TranscriptTurn? {
        for item in items {
            if case .turn(let turn) = item { return turn }
        }
        return nil
    }

    private func turn(
        id: String, startMs: Int64, endMs: Int64, text: String = "",
        words: [TranscriptWordSpan] = []
    ) -> TranscriptTurn {
        TranscriptTurn(
            id: id, speakerLabel: "1", name: "Speaker 1", role: .unresolved, text: text,
            segmentId: "seg-1", mediaOffsetMs: startMs, mediaEndMs: endMs, words: words)
    }

    // MARK: - 1. The two clocks

    @Test("media time is wall time minus the gaps before it, not a proportion of it")
    func clockUsesGapRecords() {
        // 60 s of wall time with one 20 s hole from 10 s: 40 s of stored audio.
        let clock = SegmentMediaClock(
            meta(storedMs: 40_000, gaps: [gap(atMs: 10_000, durationMs: 20_000)]))

        #expect(clock.wallSpanMs == 60_000)
        #expect(clock.mediaSpanMs == 40_000)
        #expect(clock.media(fromWall: 5_000) == 5_000)
        #expect(clock.media(fromWall: 10_000) == 10_000)
        // Inside the hole nothing was stored, so media time stands still.
        #expect(clock.media(fromWall: 20_000) == 10_000)
        #expect(clock.media(fromWall: 30_000) == 10_000)
        #expect(clock.media(fromWall: 45_000) == 25_000)
        // The proportional mapping this replaced would have said 40_000 × 45/60 = 30_000.
        #expect(clock.media(fromWall: 45_000) != 30_000)
    }

    @Test("wall time maps back, landing after the gap rather than inside it")
    func clockRoundTrips() {
        let clock = SegmentMediaClock(
            meta(storedMs: 40_000, gaps: [gap(atMs: 10_000, durationMs: 20_000)]))

        #expect(clock.wall(fromMedia: 5_000) == 5_000)
        // The first stored sample after the hole is at 30 s of wall time, not 10 s.
        #expect(clock.wall(fromMedia: 10_000) == 30_000)
        #expect(clock.wall(fromMedia: 25_000) == 45_000)
        for mediaMs in stride(from: Int64(0), to: 40_000, by: 3_100) {
            #expect(clock.media(fromWall: clock.wall(fromMedia: mediaMs)) == mediaMs)
        }
    }

    @Test("overlapping gap records are unioned, never counted twice")
    func clockUnionsOverlappingGaps() {
        // A sequence-skip recorded inside a silence-suppressed span is the routine case: the
        // same lost audio, described twice. Summing them would push media time negative.
        let clock = SegmentMediaClock(
            meta(
                storedMs: 40_000,
                gaps: [
                    gap(atMs: 10_000, durationMs: 20_000),
                    gap(atMs: 12_000, durationMs: 4_000),
                ]))
        #expect(clock.media(fromWall: 45_000) == 25_000)
    }

    @Test("gap records that do not explain the difference fall back to proportional")
    func clockFallsBackWhenRecordsAreIncomplete() {
        // Metadata says a third of the audio is stored but records no gaps at all. There is no
        // honest exact answer, so the old proportional mapping is still the best guess.
        let clock = SegmentMediaClock(meta(storedMs: 20_000, gaps: []))
        #expect(clock.media(fromWall: 30_000) == 10_000)
        #expect(clock.wall(fromMedia: 10_000) == 30_000)
    }

    // MARK: - 2. Provider timings onto the scrubber

    @Test("durable transcripts are read on the media clock, so positions pass straight through")
    func durableTimingsAreMediaOffsets() throws {
        // The processor decodes the frame log and hands THAT to the provider, so a word at 25 s
        // of provider time is at 25 s on the scrubber — even though 25 s of stored audio is
        // 45 s into the recording. Reading it as wall time (what this did before the two clocks
        // were told apart) would have placed it at 16.6 s.
        let built = TranscriptItems.member(
            segmentId: "seg-1",
            meta: meta(storedMs: 40_000, gaps: [gap(atMs: 10_000, durationMs: 20_000)]),
            segments: [
                SearchKit.TranscriptSegment(
                    text: "after the gap", startMs: 25_000, endMs: 27_000, speaker: "1")
            ],
            assignments: [],
            timebase: .media)

        let turn = try #require(firstTurn(built.items))
        #expect(turn.mediaOffsetMs == 25_000)
        #expect(turn.mediaEndMs == 27_000)
        // …and the stamp beside the speaker reads the WALL time it was said at.
        #expect(turn.startedAt?.timeIntervalSince1970 == 1_700_000_045)
    }

    @Test("live-preview timings are read on the wall clock and mapped onto the scrubber")
    func previewTimingsAreWallOffsets() throws {
        let built = TranscriptItems.member(
            segmentId: "seg-1",
            meta: meta(storedMs: 40_000, gaps: [gap(atMs: 10_000, durationMs: 20_000)]),
            segments: [
                SearchKit.TranscriptSegment(
                    text: "after the gap", startMs: 45_000, endMs: 47_000, speaker: "1")
            ],
            assignments: [],
            timebase: .wall)

        let turn = try #require(firstTurn(built.items))
        #expect(turn.mediaOffsetMs == 25_000)
        #expect(turn.startedAt?.timeIntervalSince1970 == 1_700_000_045)
    }

    @Test("the scrubber's missing tick sits where the gap actually is")
    func missingTickUsesTheGapPosition() {
        let built = TranscriptItems.member(
            segmentId: "seg-1",
            meta: meta(storedMs: 40_000, gaps: [gap(atMs: 10_000, durationMs: 20_000)]),
            segments: [
                SearchKit.TranscriptSegment(
                    text: "after the gap", startMs: 25_000, endMs: 27_000, speaker: "1")
            ],
            assignments: [],
            timebase: .media)

        #expect(built.mediaMs == 40_000)
        #expect(built.missingMediaOffsets == [10_000])
    }

    @Test("word timings land on the right characters of the rendered paragraph")
    func wordsAlignToRenderedText() throws {
        let built = TranscriptItems.member(
            segmentId: "seg-1",
            meta: meta(),
            segments: [
                SearchKit.TranscriptSegment(
                    text: "Hello there, friend.", startMs: 0, endMs: 3_000, speaker: "1")
            ],
            words: [
                SearchKit.TranscriptWord(text: "Hello", startMs: 0, endMs: 500),
                SearchKit.TranscriptWord(text: "there,", startMs: 700, endMs: 1_200),
                SearchKit.TranscriptWord(text: "friend.", startMs: 1_500, endMs: 2_400),
            ],
            assignments: [],
            timebase: .media)

        let turn = try #require(firstTurn(built.items))
        #expect(turn.text == "Hello there, friend.")
        // Character ranges index the RENDERED text, punctuation included, so the highlight can
        // be applied straight to the paragraph's `AttributedString`.
        #expect(
            turn.words == [
                TranscriptWordSpan(start: 0, end: 5, mediaStartMs: 0, mediaEndMs: 500),
                TranscriptWordSpan(start: 6, end: 12, mediaStartMs: 700, mediaEndMs: 1_200),
                TranscriptWordSpan(start: 13, end: 20, mediaStartMs: 1_500, mediaEndMs: 2_400),
            ])
        // Diarization is what keeps the paragraph on the segment timeline rather than the word
        // one, so this is the case that matters: speakers AND word timings, both kept.
        #expect(turn.name == "Speaker 1")
    }

    @Test("words that do not describe the text produce no spans at all")
    func mismatchedWordsDegradeToNoSpans() throws {
        // A transcript whose stored words came from a different pass. Sliding a marker along
        // text it cannot place would be a lie about precision; no spans means the screen
        // highlights whole turns instead, which is what it can honestly claim.
        let built = TranscriptItems.member(
            segmentId: "seg-1",
            meta: meta(),
            segments: [
                SearchKit.TranscriptSegment(
                    text: "Hello there, friend.", startMs: 0, endMs: 3_000, speaker: "1")
            ],
            words: [
                SearchKit.TranscriptWord(
                    text: "an entirely different sentence about something else entirely",
                    startMs: 0, endMs: 3_000)
            ],
            assignments: [],
            timebase: .media)

        let turn = try #require(firstTurn(built.items))
        #expect(turn.words.isEmpty)
        #expect(turn.mediaOffsetMs == 0)
    }

    @Test("a transcript with no word timings still carries turn extents")
    func noWordsStillGivesTurnSpans() throws {
        let built = TranscriptItems.member(
            segmentId: "seg-1",
            meta: meta(),
            segments: [
                SearchKit.TranscriptSegment(
                    text: "Hello there.", startMs: 1_000, endMs: 3_000, speaker: "1")
            ],
            assignments: [],
            timebase: .media)

        let turn = try #require(firstTurn(built.items))
        #expect(turn.words.isEmpty)
        #expect(turn.mediaOffsetMs == 1_000)
        #expect(turn.mediaEndMs == 3_000)
    }

    // MARK: - 3. Which word is playing at t

    private var sampleTranscript: [TranscriptItem] {
        [
            .turn(
                turn(
                    id: "a", startMs: 0, endMs: 3_000, text: "Hello there, friend.",
                    words: timedWords)),
            .turn(turn(id: "b", startMs: 5_000, endMs: 8_000, text: "No word timings here.")),
        ]
    }

    private var timedWords: [TranscriptWordSpan] {
        [
            TranscriptWordSpan(start: 0, end: 5, mediaStartMs: 0, mediaEndMs: 500),
            TranscriptWordSpan(start: 6, end: 12, mediaStartMs: 700, mediaEndMs: 1_200),
            TranscriptWordSpan(start: 13, end: 20, mediaStartMs: 1_500, mediaEndMs: 2_400),
        ]
    }

    @Test("the last word that started keeps the highlight until the next one does")
    func wordLookupDoesNotBlink() {
        let index = TranscriptPlayheadIndex(sampleTranscript)
        #expect(index.hasWordTimings)
        #expect(index.position(atMediaMs: 0) == TranscriptPlayheadPosition(turnId: "a", wordIndex: 0))
        // Between "Hello" ending and "there," starting: still on "Hello", not nothing. A
        // highlight that blinks off in every inter-word pause is unreadable at speed.
        #expect(index.position(atMediaMs: 600) == TranscriptPlayheadPosition(turnId: "a", wordIndex: 0))
        #expect(index.position(atMediaMs: 800) == TranscriptPlayheadPosition(turnId: "a", wordIndex: 1))
        #expect(index.position(atMediaMs: 2_900) == TranscriptPlayheadPosition(turnId: "a", wordIndex: 2))
    }

    @Test("a turn with no word timings lights up whole, and nothing lights up in a hole")
    func turnLevelAndEmptyLookups() {
        let index = TranscriptPlayheadIndex(sampleTranscript)
        #expect(index.position(atMediaMs: 6_000) == TranscriptPlayheadPosition(turnId: "b", wordIndex: nil))
        // Past the end of "a" and its hold, before "b" starts: honestly nothing.
        #expect(index.position(atMediaMs: 4_500) == nil)
        // Past the whole transcript.
        #expect(index.position(atMediaMs: 60_000) == nil)
    }

    @Test("a turn cannot hold the highlight into its successor")
    func turnsAreClippedToTheNextOne() {
        let index = TranscriptPlayheadIndex([
            .turn(turn(id: "a", startMs: 0, endMs: 30_000, text: "long")),
            .turn(turn(id: "b", startMs: 4_000, endMs: 8_000, text: "next")),
        ])
        #expect(index.position(atMediaMs: 5_000) == TranscriptPlayheadPosition(turnId: "b", wordIndex: nil))
    }

    @Test("an empty transcript resolves to nothing rather than trapping")
    func emptyIndex() {
        let index = TranscriptPlayheadIndex([])
        #expect(index.isEmpty)
        #expect(!index.hasWordTimings)
        #expect(index.position(atMediaMs: 0) == nil)
    }

    // MARK: - 3b. Which word did that tap land on

    @Test("a tap resolves to a character offset through the paragraph's own line count")
    func tapMapsToCharacters() {
        // 300 × 60 at an 18 pt line + 4 pt spacing is three rendered lines.
        let size = CGSize(width: 300, height: 60)
        func offset(_ x: CGFloat, _ y: CGFloat) -> Int {
            TranscriptTapGeometry.characterOffset(
                at: CGPoint(x: x, y: y), in: size, lineHeight: 18, lineSpacing: 4,
                characterCount: 90)
        }
        #expect(offset(0, 0) == 0)
        #expect(offset(150, 4) == 15)  // halfway across line 1 of 3
        #expect(offset(150, 30) == 45)  // halfway across line 2 of 3
        #expect(offset(300, 55) == 89)  // the end of the last line, clamped
        // Out-of-bounds taps clamp rather than run off the end.
        #expect(offset(-40, -20) == 0)
        #expect(offset(9_000, 9_000) == 89)
    }

    @Test("a character offset snaps to the word containing it")
    func characterOffsetSnapsToWord() {
        let spans = timedWords
        #expect(TranscriptTapGeometry.wordIndex(forCharacterOffset: 0, in: spans) == 0)
        // The space between two words belongs to the word before it.
        #expect(TranscriptTapGeometry.wordIndex(forCharacterOffset: 5, in: spans) == 0)
        #expect(TranscriptTapGeometry.wordIndex(forCharacterOffset: 6, in: spans) == 1)
        #expect(TranscriptTapGeometry.wordIndex(forCharacterOffset: 19, in: spans) == 2)
        #expect(TranscriptTapGeometry.wordIndex(forCharacterOffset: 900, in: spans) == 2)
        #expect(TranscriptTapGeometry.wordIndex(forCharacterOffset: 0, in: []) == nil)
    }

    @Test("a tap on a turn with no word timings seeks to the turn, not to nothing")
    func tapDegradesToTurnStart() {
        let plain = turn(id: "b", startMs: 5_000, endMs: 8_000, text: "plain")
        let target = TranscriptTapGeometry.seekTarget(
            at: CGPoint(x: 200, y: 10), in: CGSize(width: 300, height: 22),
            lineHeight: 18, lineSpacing: 4, turn: plain)
        #expect(target == 5_000)
    }

    @Test("a tap on a timed turn seeks to the word under it")
    func tapSeeksToTheWord() {
        let timed = turn(
            id: "a", startMs: 0, endMs: 3_000, text: "Hello there, friend.", words: timedWords)
        // One rendered line of 20 characters: a tap 80% across lands in "friend.".
        #expect(
            TranscriptTapGeometry.seekTarget(
                at: CGPoint(x: 240, y: 8), in: CGSize(width: 300, height: 22),
                lineHeight: 18, lineSpacing: 4, turn: timed) == 1_500)
        // …and one at the very start lands on the first word.
        #expect(
            TranscriptTapGeometry.seekTarget(
                at: CGPoint(x: 2, y: 8), in: CGSize(width: 300, height: 22),
                lineHeight: 18, lineSpacing: 4, turn: timed) == 0)
    }

    // MARK: - 3c. Tap cadence

    @Test("a second tap inside the window is a double; a later one starts over")
    func tapCadence() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var cadence = TapCadence()
        #expect(cadence.register(now: start) == false)
        #expect(cadence.register(now: start.addingTimeInterval(0.12)) == true)
        #expect(cadence.register(now: start.addingTimeInterval(1.5)) == false)
        #expect(cadence.register(now: start.addingTimeInterval(1.7)) == true)
    }
}
