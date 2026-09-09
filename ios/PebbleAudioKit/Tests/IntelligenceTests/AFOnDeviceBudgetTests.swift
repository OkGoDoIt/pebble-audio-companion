import Foundation
import Testing

@testable import Intelligence

// AF · per-template on-device budgets.
//
// The measurements these pin were taken on this machine against Apple's real model and a real
// four-hour recording from the backup (157,639 characters of transcript once rendered):
//
//   • 12,000 input chars + grounding + the Extended summary prompt, 256 output tokens
//     → exceededContextWindowSize, "Content contains 4179 tokens, which exceeds the maximum
//       allowed context size of 4096". That is the shipped build (f4bc3e6), and the message the
//       user saw — "On-device AI generation failed" — is what this became.
//   • 12,000 input chars with grounding OFF → still fails, at 4,090 tokens, four seconds in,
//     partway through generating. The window covers input AND output.
//   • Binary search, grounding on: 256 output tokens → 10,851 chars fit; 1,600 → 5,968 chars.
//     3.63 chars per token, ±69.

private final class AFRecordingModel: OnDeviceLanguageModel, @unchecked Sendable {
    let id = "af-fake"
    private let lock = NSLock()
    private var _prompt: String?
    private var _instructions: String?
    private var _maxOutputTokens: Int?
    private let failure: Error?

    init(failure: Error? = nil) { self.failure = failure }

    var prompt: String? { lock.withLock { _prompt } }
    var instructions: String? { lock.withLock { _instructions } }
    var maxOutputTokens: Int? { lock.withLock { _maxOutputTokens } }

    func availability() async -> OnDeviceAvailability { .available }

    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String
    {
        lock.withLock {
            _instructions = instructions
            _prompt = prompt
            _maxOutputTokens = maxOutputTokens
        }
        if let failure { throw failure }
        return "an answer"
    }
}

@Suite("AF · on-device context budget")
struct AFOnDeviceBudgetTests {
    private func request(_ template: AiPromptTemplate, chars: Int) -> AiRunRequest {
        AiRunRequest(
            requestId: "r",
            prompt: template,
            transcripts: [
                TranscriptExcerpt(segmentId: "seg-1", text: String(repeating: "word ", count: chars / 5))
            ]
        )
    }

    // MARK: The window arithmetic

    /// Input and output come out of ONE window. Asking for a longer answer must buy less input,
    /// or the call dies partway through generating — which is exactly what 12,000 characters at
    /// 256 output tokens did on the real model.
    @Test func outputTokensAreTakenOutOfTheSameWindowAsInput() {
        let short = OnDeviceContextBudget.forRequest(
            outputTokens: 200, systemPromptChars: 2_823, groundingChars: 1_600)
        let long = OnDeviceContextBudget.forRequest(
            outputTokens: 1_400, systemPromptChars: 2_823, groundingChars: 1_600)

        #expect(short.inputChars > long.inputChars)
        let difference = short.inputChars - long.inputChars
        #expect(difference == (1_400 - 200) * AskBudget.charsPerToken)
    }

    /// Every budget must stay under 4,096 tokens at the ratio actually measured (3.63 chars per
    /// token), with the answer counted. This is the whole point of the file, so it is checked
    /// for every built-in template at the widest grounding block a user can produce.
    @Test func everyTemplateFitsTheMeasuredWindow() {
        let templates =
            AiPromptTemplates.builtIn + [
                SegmentAnnotationPrompt.template, AiPromptTemplates.ask,
                AiPromptTemplates.askSweepFindings, AiPromptTemplates.askSweepAnswer,
                AiPromptTemplates.custom("anything at all"),
            ]
        for template in templates {
            let output = OnDeviceTemplateBudget.outputTokens(forTemplateId: template.id)
            let grounding = PersonalContextBudget.aiGroundingBudgetChars
            let budget = OnDeviceContextBudget.forRequest(
                outputTokens: output,
                systemPromptChars: template.systemPrompt.count,
                groundingChars: grounding)
            guard budget.fits else { continue }
            let chars = budget.inputChars + template.systemPrompt.count + grounding
            // 363/100 rather than 3.63: integer arithmetic, no rounding to argue about.
            let tokens = chars * 100 / 363 + output
            #expect(
                tokens < OnDeviceContextBudget.windowTokens,
                "\(template.id) plans \(tokens) tokens against a 4096-token window")
        }
    }

    /// The 256-token cap is gone as a single number: a title and a long-form account cannot
    /// share one, and the one they shared was sized for the title.
    @Test func aLongFormSummaryGetsMoreOutputThanATitle() {
        let title = OnDeviceTemplateBudget.outputTokens(
            forTemplateId: SegmentAnnotationPrompt.templateId)
        let extended = OnDeviceTemplateBudget.outputTokens(forTemplateId: "extended-summary")
        #expect(extended > title * 3)
        // And more than the old constant, which is the specific complaint: Extended summary
        // exists to be longer than the header's 1-3 sentences and was capped at ~190 words.
        #expect(extended > 256)
    }

    // MARK: What the provider does with it

    @Test func theProviderPassesTheTemplatesOwnOutputBudget() async throws {
        let model = AFRecordingModel()
        let provider = OnDeviceAiProvider(model: model)

        _ = try await provider.run(request(AiPromptTemplates.extendedSummary, chars: 400))

        #expect(
            model.maxOutputTokens
                == OnDeviceTemplateBudget.outputTokens(forTemplateId: "extended-summary"))
    }

    @Test func aPinnedOutputCapStillWins() async throws {
        let model = AFRecordingModel()
        let provider = OnDeviceAiProvider(model: model, maxOutputTokens: 77)

        _ = try await provider.run(request(AiPromptTemplates.extendedSummary, chars: 400))

        #expect(model.maxOutputTokens == 77)
    }

    /// A four-hour conversation asked for as an Extended summary. It cannot fit, and the honest
    /// answer is to say so — not a confident "full account" of the first 3% of the day.
    @Test func anOversizedExtendedSummaryFailsSayingWhy() async throws {
        let provider = OnDeviceAiProvider(model: AFRecordingModel())
        do {
            _ = try await provider.run(
                request(AiPromptTemplates.extendedSummary, chars: 157_000))
            Issue.record("expected a failure")
        } catch {
            #expect(AiFailure.classify(error).kind == .tooLongForDevice)
        }
    }

    /// …but a template that summarizes what it was given still truncates, as it always has.
    /// Nothing is claimed about the part it did not see, and `buildUserContent` marks the cut.
    @Test func aGistTemplateStillTruncatesRatherThanFailing() async throws {
        let model = AFRecordingModel()
        let provider = OnDeviceAiProvider(model: model)

        _ = try await provider.run(request(SegmentAnnotationPrompt.template, chars: 157_000))

        let prompt = try #require(model.prompt)
        #expect(prompt.contains("transcript truncated for length"))
    }

    /// Grounding is paid for out of the same window, so a person with a long About You block
    /// gets less transcript — measured at call time rather than assumed.
    @Test func groundingCostsInputRoom() async throws {
        let bare = AFRecordingModel()
        _ = try await OnDeviceAiProvider(model: bare)
            .run(request(SegmentAnnotationPrompt.template, chars: 157_000))

        let grounded = AFRecordingModel()
        let block = String(repeating: "a", count: 1_600)
        _ = try await OnDeviceAiProvider(model: grounded, grounding: { block })
            .run(request(SegmentAnnotationPrompt.template, chars: 157_000))

        let bareLength = try #require(bare.prompt).count
        let groundedLength = try #require(grounded.prompt).count
        #expect(groundedLength < bareLength)
        // Within a marker's length of the grounding block it paid for.
        #expect(bareLength - groundedLength >= 1_500)
    }

    /// A template whose instructions alone eat the window fails saying THAT, rather than sending
    /// the model 200 characters and printing whatever comes back.
    @Test func aTemplateThatCannotFitAtAllSaysSo() async throws {
        let enormous = AiPromptTemplate(
            id: "af-enormous", title: "Enormous",
            systemPrompt: String(repeating: "instruction ", count: 1_200),
            userPrompt: "Go.")
        let provider = OnDeviceAiProvider(model: AFRecordingModel())
        do {
            _ = try await provider.run(request(enormous, chars: 2_000))
            Issue.record("expected a failure")
        } catch {
            #expect(AiFailure.classify(error).kind == .tooLongForDevice)
        }
    }

    // MARK: Naming what the model hit

    @Test func lowPowerModeIsNamedOnAnUnexplainedOnDeviceFailure() async throws {
        struct Boom: Error {}
        let provider = OnDeviceAiProvider(
            model: AFRecordingModel(failure: Boom()), lowPowerMode: { true })
        do {
            _ = try await provider.run(request(AiPromptTemplates.dailySummary, chars: 400))
            Issue.record("expected a failure")
        } catch AiError.providerFailed(let message, _) {
            #expect(message.contains("Low Power Mode"))
            // …and it survives classification, so the person is told the one thing they can
            // change rather than "Something went wrong."
            #expect(AiFailure.kind(of: AiError.providerFailed(message)) == .modelUnavailable)
        }
    }

    @Test func theBridgesVerdictsBecomeDistinctCauses() async throws {
        let cases: [(OnDeviceGenerationFailure, AiFailureKind)] = [
            (.contextWindowExceeded("4179 tokens"), .tooLongForDevice),
            (.contentRefused, .contentRefused),
            (.assetsUnavailable, .modelUnavailable),
            (.unsupportedLanguage, .modelUnavailable),
            (.busy, .modelBusy),
            (.other("something new"), .unknown),
        ]
        for (failure, expected) in cases {
            let provider = OnDeviceAiProvider(
                model: AFRecordingModel(failure: failure), lowPowerMode: { false })
            do {
                _ = try await provider.run(request(AiPromptTemplates.dailySummary, chars: 400))
                Issue.record("expected a failure for \(failure)")
            } catch {
                #expect(
                    AiFailure.classify(error).kind == expected,
                    "\(failure) should classify as \(expected)")
            }
        }
    }
}
