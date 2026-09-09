import Foundation
import Testing

@testable import Intelligence

// The "Extended summary" template exists because the conversation header's automatic summary is
// two or three sentences and the user wanted the long version — and because "Meeting notes" is
// not that: it sorts a recording into topic / discussion / decisions / open questions, which
// throws away the sequence and everything that did not fit a category.
//
// Both of those are properties of the PROMPT, not of any screen, so they are pinned here. Each
// expectation below is a way the template could quietly stop being what was asked for:
//
//   • dropped from `builtIn` — `LiveWorld.prompt(for:)` looks the id up there and falls back to
//     `meetingNotes`, so the user would tap Extended summary and get meeting notes, with nothing
//     anywhere saying so;
//   • folded back onto `commonSystemRules` by a later tidy-up — that block ends "Be concise and
//     factual", which is the one instruction this template exists to countermand;
//   • re-grown an action-items or takeaways section, which is the thing the request was explicit
//     about not wanting.

@Suite("extended summary prompt")
struct ExtendedSummaryPromptTests {

    private var template: AiPromptTemplate { AiPromptTemplates.extendedSummary }

    // MARK: - It is reachable

    /// The id the app's `NoteTemplate.builtIns` row carries. A mismatch is silent: the lookup
    /// falls through to `meetingNotes` and the user gets the wrong note with the right title.
    @Test func idAndTitleAreTheOnesTheAppLooksUp() {
        #expect(template.id == "extended-summary")
        #expect(template.title == "Extended summary")
        #expect(AiPromptTemplates.builtIn.contains { $0.id == "extended-summary" })
    }

    @Test func builtInIdsAreUnique() {
        let ids = AiPromptTemplates.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: - It is read beside the recording, so it cites

    /// Every template whose output is rendered next to the transcript carries the `[n]`
    /// convention, and a long account needs it more than a short one: the chips are the only way
    /// to check a paragraph against what was actually said.
    @Test func itCitesItsSourcesWithTheSharedRules() {
        #expect(template.citesSources)
        #expect(template.systemPrompt.contains(AiPromptTemplates.citationRules))
    }

    // MARK: - It is not the short summary, and not meeting notes

    /// `commonSystemRules` ends "Be concise and factual." Inheriting it here would ask for
    /// brevity in the one template whose entire purpose is length.
    @Test func itDoesNotInheritTheConcisenessRule() {
        #expect(!template.systemPrompt.contains(AiPromptTemplates.commonSystemRules))
        #expect(!template.systemPrompt.lowercased().contains("be concise"))
        #expect(template.systemPrompt != AiPromptTemplates.meetingNotes.systemPrompt)
    }

    /// The distinction the request turned on: a summary, not a work product. The prompt has to
    /// name the sections it refuses, because a model asked for a long summary of a meeting will
    /// produce action items unprompted.
    @Test func itRefusesTheMeetingNotesSections() {
        let prompt = template.systemPrompt.lowercased()
        #expect(prompt.contains("it is not meeting notes"))
        for banned in ["action items", "next steps", "decisions", "takeaways"] {
            #expect(prompt.contains(banned), "the prompt must name \(banned) to forbid it")
        }
        // Named only inside the refusal — never as something to produce.
        #expect(prompt.contains("do not extract"))
    }

    /// This used to assert the opposite — "brevity is not a virtue", "do not stop", "in the
    /// order it happened" — and the prompt obliged: measured against a real 1 h 23 m recording
    /// it wrote **7,089 tokens, 5,797 words, in 70.4 seconds**, which is past the transport's
    /// 60-second idle timeout, so the note never arrived at all. The shape asked for is a
    /// longer SUMMARY, not a retelling, and these are the phrases that keep it one.
    @Test func itAsksForALongerSummaryAndNotARetelling() {
        let prompt = template.systemPrompt.lowercased()
        // A bound, stated as a number the model can act on.
        #expect(prompt.contains("300 to 500 words"))
        #expect(prompt.contains("nothing gets more"))
        // The failure mode named, so a model that drifts into it has been told not to.
        #expect(prompt.contains("turn by turn"))
        #expect(prompt.contains("step back and summarise"))
        // And none of the licence that produced the runaway.
        for gone in ["brevity is not a virtue", "do not stop", "in the order it happened"] {
            #expect(!prompt.contains(gone), "\(gone) is what made it write an essay")
        }
    }

    /// A prompt is a request; the ceiling is what makes it a guarantee. The runaway happened
    /// because the Responses payload carried no `max_output_tokens` at all.
    @Test func itIsCappedWithHeadroom() {
        let ceiling = CloudOutputBudget.maxOutputTokens(forTemplateId: template.id)
        #expect(ceiling < 7_089, "the cap must be well under the runaway it exists to stop")
        #expect(ceiling > 873, "... and clear of what the rewritten prompt was measured to write")
    }

    /// It is prose the user reads, not a document. The note screen renders inline Markdown only,
    /// so a model reaching for headings emits them as literal `##` on screen.
    @Test func itForbidsMarkdownFurniture() {
        let prompt = template.systemPrompt.lowercased()
        #expect(prompt.contains("no headings"))
        #expect(prompt.contains("no bullet or numbered lists"))
    }

    /// The honesty rules every prompt in this app carries: transcription is wrong a lot, and gaps
    /// are never papered over.
    @Test func itKeepsTheTranscriptQualityCaveats() {
        let prompt = template.systemPrompt.lowercased()
        #expect(prompt.contains("never invent"))
        #expect(prompt.contains("gap"))
    }

    /// Placed next to `dailySummary` rather than at the end: it is the plain one, and the sheet
    /// shows it first.
    @Test func itSitsWithTheOtherSummary() throws {
        let ids = AiPromptTemplates.builtIn.map(\.id)
        let summary = try #require(ids.firstIndex(of: "extended-summary"))
        let meeting = try #require(ids.firstIndex(of: "meeting-notes"))
        #expect(summary < meeting)
    }
}
