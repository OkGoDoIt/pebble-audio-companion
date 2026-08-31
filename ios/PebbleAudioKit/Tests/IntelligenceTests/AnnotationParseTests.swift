import Foundation
import Testing

@testable import Intelligence

// Port of the `SegmentAnnotationPromptTest` parse set from
// `core/ai/src/jvmTest/.../SegmentAnnotationStoreTest.kt` — all 7 cases, same names. (The
// file-store round-trip half of that file is superseded by the DB-backed AnnotationStore,
// exercised via EnrichmentWorkerTests.)

@Suite struct AnnotationParseTests {
    @Test func parsesWellFormedResponse() {
        let parsed = SegmentAnnotationPrompt.parse(
            "TITLE: Quarterly budget review\n"
                + "SUMMARY: The team reviewed Q3 spend. Cuts were agreed.\n"
                + "TAGS: budget, work, finance"
        )
        #expect(parsed.title == "Quarterly budget review")
        #expect(parsed.summary == "The team reviewed Q3 spend. Cuts were agreed.")
        #expect(parsed.tags == ["budget", "work", "finance"])
    }

    @Test func parsesStructuredResponseWithTags() {
        let parsed = SegmentAnnotationPrompt.parse(
            """
            {
              "title": "Quarterly budget review",
              "summary": "The team reviewed Q3 spend and agreed on cuts.",
              "tags": ["budget", "finance", "budget", "#work"]
            }
            """
        )

        #expect(parsed.title == "Quarterly budget review")
        #expect(parsed.summary == "The team reviewed Q3 spend and agreed on cuts.")
        #expect(parsed.tags == ["budget", "finance", "work"])
    }

    @Test func parsesCaseInsensitiveAndPadded() {
        let parsed = SegmentAnnotationPrompt.parse(
            "  title: Coffee chat \n\n  Summary:  Casual conversation about weekend plans. "
        )
        #expect(parsed.title == "Coffee chat")
        #expect(parsed.summary == "Casual conversation about weekend plans.")
    }

    @Test func parsesMarkdownWrappedLabelsAsPlainText() {
        let parsed = SegmentAnnotationPrompt.parse(
            "**TITLE:** Troubleshooting Microsoft account setup\n"
                + "**SUMMARY:** The user is frustrated with account setup and OneDrive loading."
        )
        #expect(parsed.title == "Troubleshooting Microsoft account setup")
        #expect(
            parsed.summary == "The user is frustrated with account setup and OneDrive loading.")
    }

    @Test func parsesMultilineSummaryWithoutMarkdown() {
        let parsed = SegmentAnnotationPrompt.parse(
            "TITLE: Downtown living\n"
                + "SUMMARY:\n"
                + "- They talked about festival crowds.\n"
                + "- They also discussed fitness routines."
        )
        #expect(parsed.title == "Downtown living")
        #expect(
            parsed.summary
                == "They talked about festival crowds. They also discussed fitness routines.")
    }

    @Test func fallsBackToFirstLineAsTitle() {
        let parsed = SegmentAnnotationPrompt.parse(
            "Planning discussion\nThey planned the sprint.")
        #expect(parsed.title == "Planning discussion")
        #expect(parsed.summary == "They planned the sprint.")
    }

    @Test func boundsOversizedFields() {
        let parsed = SegmentAnnotationPrompt.parse(
            "TITLE: \(String(repeating: "t", count: 300))\n"
                + "SUMMARY: \(String(repeating: "s", count: 2000))"
        )
        #expect(parsed.title?.count == 80)
        #expect(parsed.summary?.count == 600)
    }
}
