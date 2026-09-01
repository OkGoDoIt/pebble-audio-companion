import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import SearchKit

// Port of `app/src/commonTest/.../ui/TranscriptFormattingTest.kt`. Timeline gap collapsing and
// quiet labelling are the spec for the rebuilt transcript renderer. The KMP fuzzy search-match
// cases went with the engine they pinned (plan 4.7): the product searches through SearchKit's
// FTS5 index, so a second in-memory scorer had no surface to reach.

@Suite struct TranscriptFormattingTests {
    // MARK: - Speaker presentation

    @Test func speakerLabelFormatsNumericAndNamedSpeakers() {
        #expect(speakerLabel("1") == "Speaker 1")
        #expect(speakerLabel("12") == "Speaker 12")
        #expect(speakerLabel("agent") == "Agent")
        #expect(speakerLabel("Customer") == "Customer")
    }

    @Test func speakerColorIndexKeepsNumericSpeakersStableAndDistinct() {
        #expect(speakerColorIndex("Speaker 1") == 0)
        #expect(speakerColorIndex("Speaker 2") == 1)
        #expect(speakerColorIndex("Speaker 1") == speakerColorIndex("Speaker 7"))
    }

    // MARK: - Paragraphs

    @Test func transcriptParagraphsSplitsOnReadableSentenceBoundaries() {
        let text = "First sentence. Second sentence! third fragment continues. 42 starts here?"

        let paragraphs = transcriptParagraphs(text, maxChars: 42)

        #expect(
            paragraphs == [
                "First sentence.",
                "Second sentence! third fragment continues.",
                "42 starts here?",
            ]
        )
    }

    @Test func transcriptParagraphsSplitsPunctuationFreeLiveTextByWords() {
        let text =
            "testing one two three testing one two three testing one two three "
            + "where did you go austin austin where are you little guy hey austin where "
            + "are you what is that in your hand what do you got can i see"

        let paragraphs = transcriptParagraphs(text, maxChars: 90, maxWords: 12)

        #expect(paragraphs.count > 3)
        #expect(
            paragraphs.allSatisfy {
                $0.split(whereSeparator: { $0.isWhitespace }).count <= 12
            }
        )
    }

    @Test func transcriptParagraphsKeepsExplicitBlankLineBreaks() {
        let text = "Before a quiet stretch.\n\nAfter the quiet stretch."

        let paragraphs = transcriptParagraphs(text)

        #expect(paragraphs == ["Before a quiet stretch.", "After the quiet stretch."])
    }

    @Test func transcriptParagraphsReturnsEmptyForBlankText() {
        #expect(transcriptParagraphs(" \n\t ").isEmpty)
    }

    // MARK: - Timeline

    @Test func transcriptTimelineItemsUseUnlabeledBreaksBeforeQuietMarkers() throws {
        let items = transcriptTimelineItems(
            meta: testMeta(),
            segments: [
                TranscriptSegment(text: "first thought", startMs: 0, endMs: 1_000),
                TranscriptSegment(text: "same paragraph", startMs: 4_000, endMs: 5_000),
                TranscriptSegment(text: "new paragraph", startMs: 11_000, endMs: 12_000),
                TranscriptSegment(text: "long pause", startMs: 43_000, endMs: 44_000),
            ]
        )

        #expect(items.count == 5)
        let first = try #require(items[0].asSpeech)
        #expect(first.text == "first thought same paragraph")
        let breakItem = try #require(items[1].asBreak)
        #expect(breakItem.startMs == 5_000)
        #expect(breakItem.durationMs == 6_000)
        #expect(items[2].asSpeech != nil)
        let pause = try #require(items[3].asPause)
        #expect(pause.startMs == 12_000)
        #expect(pause.durationMs == 31_000)
        #expect(pause.missing == false)
        #expect(items[4].asSpeech != nil)
    }

    @Test func transcriptTimelineItemsCollapseStoredGapsIntoInlineRows() throws {
        let items = transcriptTimelineItems(
            meta: testMeta(
                gaps: (0..<4).map { index in
                    GapMeta(
                        firstMissingSequence: UInt32(index),
                        missingFrameCount: 81_000,
                        firstMissingSampleIndex: UInt64(index * 16_000),
                        origin: GapMeta.originSequenceSkip
                    )
                }
            ),
            segments: [
                TranscriptSegment(text: "oh what's going on here", startMs: 2_000, endMs: 4_000)
            ]
        )

        #expect(items.count == 2)
        let gap = try #require(items[0].asPause)
        #expect(gap.missing == true)
        #expect(gap.label == "audio interrupted for 10 sec (phone briefly missed audio)")
        #expect(items[1].asSpeech != nil)
    }

    @Test func transcriptTimelineItemsCountReasonsWhenLossReasonsCollapseTogether() throws {
        let items = transcriptTimelineItems(
            meta: testMeta(
                gaps: [
                    GapMeta(
                        firstMissingSequence: 0,
                        missingFrameCount: 100,
                        firstMissingSampleIndex: 0,
                        origin: GapMeta.originWatch,
                        reasonRaw: Int(GapReason.micConflict.rawValue)
                    ),
                    GapMeta(
                        firstMissingSequence: 100,
                        missingFrameCount: 100,
                        firstMissingSampleIndex: 32_000,
                        origin: GapMeta.originWatch,
                        reasonRaw: Int(GapReason.transportReset.rawValue)
                    ),
                ]
            ),
            segments: [
                TranscriptSegment(text: "back after interruptions", startMs: 6_000, endMs: 8_000)
            ]
        )

        let pause = try #require(items.first?.asPause)
        #expect(pause.missing == true)
        // The count, not "several": it says how much is behind the tap that opens the row.
        #expect(pause.label == "audio interrupted for 4 sec (2 reasons)")
        #expect(pause.hasReasonBreakdown)
        // …but four seconds never reaches the transcript at all.
        #expect(pause.isShownInTranscript == false)
    }

    @Test func transcriptTimelineItemsCompressRepeatsOfOneReasonIntoThatReason() throws {
        let items = transcriptTimelineItems(
            meta: testMeta(
                gaps: (0..<3).map { index in
                    GapMeta(
                        firstMissingSequence: UInt32(index * 300),
                        missingFrameCount: 300,  // 6 s at 20 ms/frame
                        firstMissingSampleIndex: UInt64(index * 96_000),
                        origin: GapMeta.originWatch,
                        reasonRaw: Int(GapReason.micConflict.rawValue)
                    )
                },
                lastSampleIndexExclusive: 1_920_000  // 120 s
            ),
            segments: [
                TranscriptSegment(text: "back after the dictation", startMs: 20_000, endMs: 22_000)
            ]
        )

        let pause = try #require(items.first?.asPause)
        // Three interruptions, one cause: name the cause rather than saying "3 reasons", and
        // leave nothing to expand.
        #expect(pause.label == "audio interrupted for 18 sec (watch dictation used the mic)")
        #expect(pause.hasReasonBreakdown == false)
        #expect(pause.reasons.count == 1)
        #expect(pause.reasons[0].count == 3)
        #expect(pause.reasons[0].durationMs == 18_000)
    }

    @Test func transcriptTimelineItemsBreakDownMixedLossByCause() throws {
        let items = transcriptTimelineItems(
            meta: testMeta(
                gaps: [
                    GapMeta(
                        firstMissingSequence: 0,
                        missingFrameCount: 300,  // 6 s
                        firstMissingSampleIndex: 0,
                        origin: GapMeta.originWatch,
                        reasonRaw: Int(GapReason.transportReset.rawValue)
                    ),
                    GapMeta(
                        firstMissingSequence: 300,
                        missingFrameCount: 900,  // 18 s
                        firstMissingSampleIndex: 96_000,
                        origin: GapMeta.originWatch,
                        reasonRaw: Int(GapReason.spoolOverflow.rawValue)
                    ),
                ],
                lastSampleIndexExclusive: 1_920_000  // 120 s
            ),
            segments: [
                TranscriptSegment(text: "back after the outage", startMs: 30_000, endMs: 32_000)
            ]
        )

        let pause = try #require(items.first?.asPause)
        #expect(pause.durationMs == 24_000)
        #expect(pause.label == "audio interrupted for 24 sec (2 reasons)")
        #expect(pause.isShownInTranscript)
        // Biggest cause first — the one that explains most of the gap leads the breakdown.
        #expect(pause.reasons.map(\.text) == [
            "watch buffer filled while disconnected", "connection was interrupted",
        ])
        #expect(pause.reasons.map(\.durationMs) == [18_000, 6_000])
        #expect(pause.reasons.allSatisfy { $0.count == 1 })
    }

    @Test func transcriptTimelineItemsKeepBriefInterruptionsOutOfTheTranscript() throws {
        let items = transcriptTimelineItems(
            meta: testMeta(
                gaps: [
                    GapMeta(
                        firstMissingSequence: 0,
                        missingFrameCount: 450,  // 9 s — under the floor
                        firstMissingSampleIndex: 0,
                        origin: GapMeta.originWatch,
                        reasonRaw: Int(GapReason.codecError.rawValue)
                    ),
                    GapMeta(
                        firstMissingSequence: 3_000,
                        missingFrameCount: 550,  // 11 s — over it
                        firstMissingSampleIndex: 960_000,
                        origin: GapMeta.originWatch,
                        reasonRaw: Int(GapReason.codecError.rawValue)
                    ),
                ],
                lastSampleIndexExclusive: 1_920_000  // 120 s
            ),
            segments: [
                TranscriptSegment(text: "first half", startMs: 20_000, endMs: 22_000),
                TranscriptSegment(text: "second half", startMs: 80_000, endMs: 82_000),
            ]
        )

        // The timeline itself stays complete — loss is never dropped from the model; only the
        // transcript declines to give the brief one a row.
        let pauses = items.compactMap { $0.asPause }
        #expect(pauses.count == 2)
        #expect(pauses.map(\.durationMs) == [9_000, 11_000])
        #expect(pauses.map(\.isShownInTranscript) == [false, true])
    }

    @Test func transcriptTimelineItemsHideShortSuppressedSilence() {
        // A skipped-silence span under 30 s earns no label (same rule as natural quiet pauses).
        let items = transcriptTimelineItems(
            meta: testMeta(
                gaps: [
                    GapMeta(
                        firstMissingSequence: 0,
                        missingFrameCount: 500,  // 10 s at 20 ms/frame
                        firstMissingSampleIndex: 0,
                        origin: GapMeta.originWatch,
                        reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
                    )
                ]
            ),
            segments: [
                TranscriptSegment(
                    text: "back after a short quiet stretch", startMs: 2_000, endMs: 4_000
                )
            ]
        )

        #expect(items.compactMap { $0.asPause }.isEmpty)
        #expect(items.contains { $0.asSpeech != nil })
    }

    @Test func transcriptTimelineItemsCollapseConsecutiveQuietSpans() throws {
        // Three separate skipped-silence spans with no transcribed speech between them collapse
        // into one quiet period of their combined length, not three "quiet for…" rows.
        func silence(_ sampleIndex: UInt64, _ seq: UInt32) -> GapMeta {
            GapMeta(
                firstMissingSequence: seq,
                missingFrameCount: 1_500,  // 30 s at 20 ms/frame
                firstMissingSampleIndex: sampleIndex,
                origin: GapMeta.originWatch,
                reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
            )
        }
        // 200 s segment with quiet spans at ~0 s, ~50 s, ~100 s (too far apart to merge as gaps).
        let items = transcriptTimelineItems(
            meta: testMeta(
                gaps: [silence(0, 0), silence(800_000, 100), silence(1_600_000, 200)],
                lastSampleIndexExclusive: 3_200_000
            ),
            segments: [
                TranscriptSegment(
                    text: "after a long quiet block", startMs: 150_000, endMs: 152_000
                )
            ]
        )

        let pauses = items.compactMap { $0.asPause }
        #expect(pauses.count == 1)
        let pause = try #require(pauses.first)
        #expect(pause.missing == false)
        #expect(pause.durationMs >= 85_000, "combined ~90 s: \(pause.durationMs)")
    }

    @Test func transcriptTimelineItemsLabelLongSuppressedSilenceAsQuiet() throws {
        // 30 s or longer reads as a calm "quiet for…" pause, never "audio interrupted…".
        let items = transcriptTimelineItems(
            // 60 s segment so the 40 s skipped-silence span is not clamped below the 30 s cutoff.
            meta: testMeta(
                gaps: [
                    GapMeta(
                        firstMissingSequence: 0,
                        missingFrameCount: 2_000,  // 40 s at 20 ms/frame
                        firstMissingSampleIndex: 0,
                        origin: GapMeta.originWatch,
                        reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
                    )
                ],
                lastSampleIndexExclusive: 960_000
            ),
            segments: [
                TranscriptSegment(
                    text: "back after a long quiet stretch", startMs: 45_000, endMs: 47_000
                )
            ]
        )

        let pauses = items.compactMap { $0.asPause }
        #expect(pauses.count == 1)
        let pause = try #require(pauses.first)
        #expect(pause.missing == false)
        #expect(pause.label.hasPrefix("quiet for"), "\(pause.label)")
    }

    @Test func transcriptTimelineItemsSplitLongFinalSegmentsIntoReadableBlocks() throws {
        let longText = (1...90).map { "word\($0)" }.joined(separator: " ")
        let items = transcriptTimelineItems(
            meta: testMeta(),
            segments: [TranscriptSegment(text: longText, startMs: 0, endMs: 90_000)]
        )

        let speech = items.compactMap { $0.asSpeech }
        #expect(speech.count >= 3)
        #expect(
            speech.allSatisfy {
                $0.text.split(whereSeparator: { $0.isWhitespace }).count <= 34
            }
        )
        #expect(speech.first?.startMs == 0)
        #expect(speech.last?.endMs == 90_000)
    }

    // MARK: - Fixtures

    private func testMeta(
        gaps: [GapMeta] = [],
        lastSampleIndexExclusive: UInt64 = 160_000
    ) -> SegmentMeta {
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
            lastSampleIndexExclusive: lastSampleIndexExclusive,
            frameCount: 500,
            gaps: gaps
        )
    }
}
