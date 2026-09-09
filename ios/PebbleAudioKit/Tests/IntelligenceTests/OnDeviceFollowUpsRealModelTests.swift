import Foundation
import Testing

@testable import Intelligence

// The only tests here that touch the real Apple Foundation Models model. Everything they assert
// is a CONTRACT — the body parses, the quotes are real, no dates are invented — never a recall
// or precision figure: those were measured against twenty hand-labelled conversations and are
// recorded in `LocalFollowUpSift`'s header, and pinning them in a test would only make the suite
// a hostage to a model Apple updates without asking.
//
// Every case is gated on `OnDeviceAiCapability.canProposeFollowUps`, so on a machine with no
// Apple Intelligence — CI, an older Mac, a device still downloading the model — the suite skips
// rather than fails.
@Suite struct OnDeviceFollowUpsRealModelTests {

    static var modelAvailable: Bool { OnDeviceAiCapability.canProposeFollowUps }

    /// A conversation with exactly one thing in it somebody still has to do, surrounded by the
    /// kinds of sentence the recordings are actually full of: narration of the moment, another
    /// person's plan, and a wish.
    static let conversation = """
        Recorded: Monday, 2026-09-07 at 6:14 PM

        --- Mon 6:14 PM ---
        S1: Right, I am putting the kettle on now while we talk about this.
        S2: Sure. I'm going to book the flights myself later this evening, do not worry.
        S1: Okay. I need to send the signed lease over to the letting agent tomorrow morning.
        S2: Good. It would be nice to get away somewhere warm sometime, wouldn't it.
        S1: It really would. Anyway, I am off to make the tea.
        """

    private static func request(_ body: String) -> AiRunRequest {
        AiRunRequest(
            requestId: "real-1",
            prompt: AiPromptTemplates.followUpExtraction,
            transcripts: [
                TranscriptExcerpt(
                    segmentId: AiTranscriptFormatting.prebuiltSegmentId, text: body)
            ],
            metadata: [
                AiRunRequest.modelKey: FollowUpWorker.modelId,
                AiRunRequest.requiresStructuredOutputKey: "1",
            ])
    }

    #if canImport(FoundationModels)
        @Test(.enabled(if: modelAvailable))
        func theProviderNoLongerRefusesAStructuredRunOnThisDevice() async throws {
            let provider = OnDeviceAiProvider(model: FoundationModelsLanguageModel())
            #expect(await provider.isAvailable())
            // The whole point of the change: this call used to throw before it looked at the
            // model at all.
            let result = try await provider.run(Self.request(Self.conversation))
            #expect(FollowUpExtractionParser.parse(raw: result.text) != nil)
            #expect(result.modelUsed == "apple-foundation-models")
        }

        /// Whatever it returns must be grounded, undated and honest about its confidence. This
        /// is the contract `FollowUpWorker.persist` and `FollowUpCurator` are built on, and it
        /// is what stops a local guess from arriving looking like a cloud answer.
        @Test(.enabled(if: modelAvailable))
        func everyItemItReturnsIsGroundedUndatedAndMarkedLowConfidence() async throws {
            let provider = OnDeviceAiProvider(model: FoundationModelsLanguageModel())
            let result = try await provider.run(Self.request(Self.conversation))
            let items = try #require(FollowUpExtractionParser.parse(raw: result.text))
            #expect(items.count <= 4, "a five-line conversation cannot hold more than a few")
            for item in items {
                #expect(
                    FollowUpQuoteLocator.locate(
                        quote: item.quote,
                        in: [
                            FollowUpSourcePart(
                                segmentId: "seg-1", startedAtMs: 0, text: Self.conversation)
                        ]) != nil,
                    "an item whose words are not in the recording must never be produced")
                #expect(item.dueDate.isEmpty, "the on-device path is never asked for a date")
                #expect(item.confidence == "low")
                #expect(!item.ifForgotten.isEmpty)
                #expect(LocalFollowUpSift.rejection(task: item.task, quote: item.quote) == nil)
            }
        }

        /// The one thing the local path must not do is answer a conversation that holds nothing
        /// with a list of things. Mic checks are the commonest recording in the corpus.
        @Test(.enabled(if: modelAvailable))
        func findsNothingInARecordingThatHoldsNothing() async throws {
            let provider = OnDeviceAiProvider(model: FoundationModelsLanguageModel())
            let result = try await provider.run(
                Self.request(
                    """
                    Recorded: Tuesday, 2026-06-23 at 6:08 PM

                    --- Tue 6:08 PM ---
                    S1: Testing, one, two, three. Testing, this is a test. Hello, world.
                    S1: Is this still working? Why does it keep stopping? That is very annoying.
                    S1: One, one thousand. Two, one thousand. Three, one thousand. Four.
                    """))
            let items = try #require(FollowUpExtractionParser.parse(raw: result.text))
            #expect(items.isEmpty, "returned \(items.map(\.task))")
        }

        /// Curation on-device may only subtract. Whatever it decides, it must never rewrite a
        /// task, invent a priority or attach a date — those are the fields that would make a
        /// local guess look like a cloud answer on the row.
        @Test(.enabled(if: modelAvailable))
        func curationOnlyEverSubtracts() async throws {
            let provider = OnDeviceAiProvider(model: FoundationModelsLanguageModel())
            let body = """
                Today is Tuesday, 2026-09-08.

                This person's follow-up list is currently empty.

                CANDIDATES:
                1. Send the signed lease to the letting agent
                   heard: "I need to send the signed lease over to the letting agent tomorrow."
                   if forgotten: the tenancy is not confirmed
                   recorded: Monday, 2026-09-07
                   how sure the reader was: low
                2. Put the kettle on
                   heard: "Right, I am putting the kettle on now while we talk about this."
                   if forgotten: nothing much
                   recorded: Monday, 2026-09-07
                   how sure the reader was: low
                """
            let result = try await provider.run(
                AiRunRequest(
                    requestId: "real-2",
                    prompt: AiPromptTemplates.followUpCuration,
                    transcripts: [
                        TranscriptExcerpt(
                            segmentId: AiTranscriptFormatting.prebuiltSegmentId, text: body)
                    ],
                    metadata: [AiRunRequest.requiresStructuredOutputKey: "1"]))
            let decisions = try #require(FollowUpCurationParser.parse(raw: result.text))
            #expect(decisions.count == 2, "one decision per candidate, in the order given")
            #expect(Set(decisions.map(\.index)) == [1, 2])
            for decision in decisions {
                #expect(["keep", "drop"].contains(decision.decision.lowercased()))
                #expect(decision.task.isEmpty, "curation on-device never rewrites")
                #expect(decision.dueDate.isEmpty, "and never dates")
                #expect(decision.priority == "normal")
            }
        }
    #endif
}
