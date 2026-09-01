import Foundation
import Testing

@testable import Intelligence

// Port of `core/ai/src/jvmTest/.../AiEvalHarnessTest.kt`. The eval harness (2C) pins
// fixture-parsing regressions for AI annotation output; the parser under test lives in
// Prompts.swift (SegmentAnnotationPrompt).
//
// The action-item half of the original harness is gone with the extractor it belonged to —
// the follow-up parser is a different contract (verbatim quotes, no owner field, JSON or
// nothing) and is pinned in FollowUpsTests instead.

@Suite struct PromptsTests {
    @Test func segmentAnnotationParsesTagsLine() {
        let parsed = SegmentAnnotationPrompt.parse(
            "TITLE: Budget review\nSUMMARY: Discussed Q3.\nTAGS: work, budget")
        #expect(parsed.title == "Budget review")
        #expect(parsed.tags == ["work", "budget"])
    }

    /// Over-long titles used to be cut with a bare `prefix(80)`, mid-word and mid-clause.
    @Test func longTitleEndsOnAClauseBoundary() {
        let parsed = SegmentAnnotationPrompt.parse(
            "TITLE: Issues with Apple's AI-powered transcription service, Soniox, and a "
                + "request for a missing API key\nSUMMARY: Nothing worked.")
        #expect(parsed.title == "Issues with Apple's AI-powered transcription service, Soniox")
    }

    @Test func longTitleWithoutAClauseBoundaryCutsOnAWordAndSaysSo() {
        let parsed = SegmentAnnotationPrompt.parse(
            "TITLE: A very long uninterrupted discussion about the replacement hallway light "
                + "fixture and the weekend grocery run")
        let title = try! #require(parsed.title)
        #expect(title.hasSuffix("…"))
        #expect(title.count <= SegmentAnnotationPrompt.maxTitleChars)
        // Never a dangling connective before the ellipsis.
        #expect(!title.hasSuffix("and…"))
        #expect(!title.hasSuffix("the…"))
    }

    @Test func shortTitlesAreUntouched() {
        #expect(SegmentAnnotationPrompt.shortenTitle("Budget review") == "Budget review")
        #expect(SegmentAnnotationPrompt.shortenTitle("   ") == nil)
    }

}
