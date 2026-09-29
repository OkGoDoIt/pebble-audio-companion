import Foundation
import Testing

@testable import Intelligence

// A question asked about ONE conversation was sent to the model as "TRANSCRIPT RANGE:
// Everything" and stored in Recent as "Everything · 29 conversations read" — the database had
// exactly that row, for one conversation of 29 recordings. Two faults: the conversation scope was
// mapped to Everything on the way in, and the coverage counted SEGMENTS and called them
// conversations.

private func stretch(_ number: Int, segment: String, chars: Int = 500) -> CitableExcerpt {
    CitableExcerpt(
        number: number, segmentId: segment, startMs: Int64(number) * 60_000,
        endMs: Int64(number) * 60_000 + 30_000, text: String(repeating: "w", count: chars))
}

@Suite("Ask scope and coverage — say what was asked about, count what was read")
struct AskScopeCoverageTests {
    @Test func aConversationScopeIsNamedAsItselfInThePromptAndInRecent() {
        let scope = AskScope.conversation(id: "conv-seg-1", title: "Planning the trip")
        #expect(scope.displayName == "\u{201C}Planning the trip\u{201D}")
        #expect(scope.promptDescription.hasPrefix("one conversation"))
        #expect(!scope.promptDescription.contains("Everything"))
        #expect(
            askNowContext(nowMs: 0, timeZoneID: "UTC", scopeDescription: scope.promptDescription)
                .contains("TRANSCRIPT RANGE: one conversation"))
        // No date window: the caller narrows to the conversation's members.
        #expect(askScopeDateKeyRange(scope, nowMs: 0, timeZoneID: "UTC") == nil)
        #expect(AskScope.conversation(id: "c", title: nil).displayName == "This conversation")
        #expect(AskScope.conversation(id: "c", title: "  ").displayName == "This conversation")
    }

    /// The reported row, rebuilt: 29 recordings of one conversation.
    @Test func twentyNineRecordingsOfOneConversationAreOneConversation() {
        let stretches = (1...29).map { stretch($0, segment: "seg-\($0)") }
        let plan = AskCorpusPlanner.plan(
            stretches: stretches, budget: AskBudget(transcriptChars: 1_000_000),
            relevance: { _ in .none }, conversationOf: { _ in "conv-seg-1" })

        #expect(plan.coverage.conversationsInScope == 1)
        #expect(plan.coverage.conversationsRead == 1)
        #expect(plan.coverage.isComplete)
        #expect(plan.coverage.promptLine.contains("ALL 1 conversation in this range"))
        let stored = askScopeDescription(
            .conversation(id: "conv-seg-1", title: "Planning the trip"), coverage: plan.coverage)
        #expect(stored == "\u{201C}Planning the trip\u{201D} · 1 conversation read")
    }

    /// Without a mapping the planner can only see recordings — and now says so.
    @Test func withoutAMappingTheCountIsRecordingsAndSaysSo() {
        let stretches = (1...3).map { stretch($0, segment: "seg-\($0)") }
        let plan = AskCorpusPlanner.plan(
            stretches: stretches, budget: AskBudget(transcriptChars: 1_000_000))
        #expect(plan.coverage.unit == .recording)
        #expect(plan.coverage.promptLine.contains("ALL 3 recordings"))
        #expect(plan.coverage.scopeSuffix == "3 recordings read")
    }

    /// A conversation a dropped batch cut through is not "read" — and the answer is not
    /// "complete" just because every conversation had SOME of it read.
    @Test func aConversationADroppedBatchCutThroughIsNotReadInFull() {
        // Two conversations, each spanning several batches' worth of stretches.
        let stretches = (1...12).map { index in
            stretch(index, segment: "seg-\(index)", chars: 900)
        }
        let conversationOf: (String) -> String? = { segment in
            let index = Int(segment.dropFirst(4)) ?? 0
            return index <= 6 ? "conv-a" : "conv-b"
        }
        let plan = AskCorpusPlanner.plan(
            stretches: stretches, budget: AskBudget(transcriptChars: 2_000, maxBatches: 3),
            relevance: { _ in .none }, conversationOf: conversationOf)

        #expect(plan.packedBatches > plan.batches.count)
        #expect(plan.coverage.conversationsInScope == 2)
        #expect(!plan.coverage.isComplete)
        #expect(plan.coverage.conversationsRead < 2)
        #expect(plan.coverage.promptLine.contains("could not be included whole"))
    }
}
