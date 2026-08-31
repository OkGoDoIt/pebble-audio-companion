import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import SearchKit

// Port of `app/src/commonTest/.../ui/TranscriptFormattingTest.kt` — ALL cases. These behaviors
// (timeline gap collapsing, quiet labeling, snippet behaviors) are the spec for the rebuilt
// transcript renderer and search snippets (plan 4.7); the KMP `SegmentTranscript` fixture is
// the local `TranscriptContent` slice.

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

    @Test func transcriptTimelineItemsShowSeveralReasonsWhenLossReasonsCollapseTogether() throws {
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
        #expect(pause.label == "audio interrupted for 4 sec (several reasons)")
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

    // MARK: - Library search match

    @Test func librarySearchMatchReturnsTimedTranscriptSnippet() throws {
        let transcript = testTranscript(
            text: "They discussed lunch, then Austin apartment hunting near transit.",
            segments: [
                TranscriptSegment(text: "They discussed lunch", startMs: 0, endMs: 2_000),
                TranscriptSegment(
                    text: "Austin apartment hunting near transit", startMs: 42_000, endMs: 47_000
                ),
            ]
        )

        let match = try #require(
            librarySearchMatch(
                query: "Austin",
                meta: testMeta(),
                transcript: transcript,
                annotation: nil
            ),
            "expected transcript search match"
        )

        #expect(match.kind == .transcript)
        #expect(match.startMs == 42_000)
        #expect(match.label.hasPrefix("Transcript match"))
        #expect(match.snippet.contains("Austin"))
    }

    @Test func librarySearchMatchFallsBackToPlainTranscriptSnippetWithoutTimings() throws {
        let transcript = testTranscript(
            text: "Before the errand they talked about groceries. Later Austin called back."
        )

        let match = try #require(
            librarySearchMatch(
                query: "Austin",
                meta: testMeta(),
                transcript: transcript,
                annotation: nil
            ),
            "expected plain transcript search match"
        )

        #expect(match.kind == .transcript)
        #expect(match.startMs == nil)
        #expect(match.snippet.contains("Austin"))
    }

    @Test func librarySearchMatchSupportsOutOfOrderMultiTermTranscriptQueries() throws {
        let transcript = testTranscript(
            text: "They discussed lunch, then Austin apartment hunting near transit.",
            segments: [
                TranscriptSegment(text: "They discussed lunch", startMs: 0, endMs: 2_000),
                TranscriptSegment(
                    text: "Austin apartment hunting near transit", startMs: 42_000, endMs: 47_000
                ),
            ]
        )

        let match = try #require(
            librarySearchMatch(
                query: "transit Austin",
                meta: testMeta(),
                transcript: transcript,
                annotation: nil
            ),
            "expected multi-term transcript search match"
        )

        #expect(match.kind == .transcript)
        #expect(match.startMs == 42_000)
        #expect(match.snippet.contains("Austin"))
        #expect(match.snippet.contains("transit"))
    }

    @Test func librarySearchMatchSupportsFuzzyTranscriptTerms() throws {
        let transcript = testTranscript(
            text: "They discussed lunch, then Austin apartment hunting near transit.",
            segments: [
                TranscriptSegment(text: "They discussed lunch", startMs: 0, endMs: 2_000),
                TranscriptSegment(
                    text: "Austin apartment hunting near transit", startMs: 42_000, endMs: 47_000
                ),
            ]
        )

        let match = try #require(
            librarySearchMatch(
                query: "Austn",
                meta: testMeta(),
                transcript: transcript,
                annotation: nil
            ),
            "expected fuzzy transcript search match"
        )

        #expect(match.kind == .transcript)
        #expect(match.startMs == 42_000)
        #expect(match.highlightTerm == "Austin")
        #expect(match.snippet.contains("Austin"))
    }

    @Test func librarySearchMatchPrefersTranscriptContextWhenTitleAlsoMatches() throws {
        let transcript = testTranscript(
            text: "They discussed lunch, then Austin apartment hunting near transit.",
            segments: [
                TranscriptSegment(text: "They discussed lunch", startMs: 0, endMs: 2_000),
                TranscriptSegment(
                    text: "Austin apartment hunting near transit", startMs: 42_000, endMs: 47_000
                ),
            ]
        )

        let match = try #require(
            librarySearchMatch(
                query: "Austin",
                meta: testMeta(),
                transcript: transcript,
                annotation: SegmentAnnotation(title: "Austin plans")
            ),
            "expected transcript search match"
        )

        #expect(match.kind == .transcript)
        #expect(match.startMs == 42_000)
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

    private func testTranscript(
        text: String,
        segments: [TranscriptSegment] = []
    ) -> TranscriptContent {
        TranscriptContent(text: text, segments: segments)
    }
}
