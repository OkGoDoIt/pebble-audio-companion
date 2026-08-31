import Foundation
import Testing

@testable import Intelligence

// Port of `core/ai/src/jvmTest/.../AiEvalHarnessTest.kt` — all 6 cases, same names. The eval
// harness (2C) pins fixture-parsing regressions for AI annotation and action-item outputs;
// the parsers under test live in Prompts.swift (SegmentAnnotationPrompt) and FollowUps.swift
// (ActionItemParser).

@Suite struct PromptsTests {
    @Test func segmentAnnotationParsesTagsLine() {
        let parsed = SegmentAnnotationPrompt.parse(
            "TITLE: Budget review\nSUMMARY: Discussed Q3.\nTAGS: work, budget")
        #expect(parsed.title == "Budget review")
        #expect(parsed.tags == ["work", "budget"])
    }

    @Test func actionItemParserExtractsChecklistLines() {
        let items = ActionItemParser.parse(
            raw: "- Follow up with Sarah\n* Send deck\n[ ] Book room",
            sourceSegmentId: "seg-1",
            nowMs: 1000
        )
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.sourceSegmentId == "seg-1" })
        #expect(items.first?.text == "Follow up with Sarah")
    }

    /// DELIBERATE divergence from the KMP case of the same name: the KMP parser CLEANED these
    /// markdown-wrapped lines into items, which is exactly how `**Owner:**` fragments and
    /// numbered scraps reached the UI (bug B4). Plan 4.5 requires the lenient parser to
    /// REJECT residual markdown/list structure instead, so the same fixture now yields no
    /// items (clean-line acceptance is pinned by `actionItemParserExtractsChecklistLines` and
    /// FollowUpsTests).
    @Test func actionItemParserCleansMarkdownAndSkipsPreamble() {
        let items = ActionItemParser.parse(
            raw: """
                Here are the action items I found:

                - [ ] **Improve transcription UI formatting** — **Owner:** Roger/team
                  - Show transcribed segments in **blue**.
                2. **Research timestamp support** - **Owner:** Roger
                """,
            sourceSegmentId: "seg-178",
            nowMs: 1000
        )

        #expect(items.isEmpty, "residual markdown must be rejected, never cleaned (B4)")
        #expect(ActionItemParser.displayText(items) == "No action items found.")
    }

    @Test func actionItemParserPrefersStructuredJson() throws {
        let items = ActionItemParser.parse(
            raw: """
                {
                  "items": [
                    {
                      "task": "Ship the display fix",
                      "owner": "Roger/team",
                      "due": "Friday",
                      "sourceSegmentId": "seg-2"
                    }
                  ]
                }
                """,
            sourceSegmentId: "seg-1",
            nowMs: 1000
        )

        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.text == "Ship the display fix. Owner: Roger/team. Due: Friday")
        #expect(item.sourceSegmentId == "seg-2")
        #expect(
            ActionItemParser.displayText(items)
                == "- [ ] Ship the display fix. Owner: Roger/team. Due: Friday")
    }

    @Test func actionItemParserAcceptsEmptyStructuredJson() {
        let items = ActionItemParser.parse(
            raw: #"{"items": []}"#,
            sourceSegmentId: "seg-1",
            nowMs: 1000
        )

        #expect(items.isEmpty)
        #expect(ActionItemParser.displayText(items) == "No action items found.")
    }

    @Test func actionItemParserReturnsEmptyForNoActionItems() {
        #expect(
            ActionItemParser.parse(
                raw: "No action items found.", sourceSegmentId: "seg-1", nowMs: 1000
            ).isEmpty)
    }
}
