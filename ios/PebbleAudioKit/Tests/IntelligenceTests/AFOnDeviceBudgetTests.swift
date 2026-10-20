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
//       allowed context size of 4096". That is the shipped build (0ea7871), and the message the
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
    private var _countCalls = 0
    private let failure: Error?
    /// The window this fake reports; the default is the protocol's default (the iOS 26 floor).
    private let window: Int?
    /// Characters per token the fake's counter charges, or nil for a model that cannot count.
    private let charsPerToken: Int?

    init(failure: Error? = nil, window: Int? = nil, charsPerToken: Int? = nil) {
        self.failure = failure
        self.window = window
        self.charsPerToken = charsPerToken
    }

    var prompt: String? { lock.withLock { _prompt } }
    var instructions: String? { lock.withLock { _instructions } }
    var maxOutputTokens: Int? { lock.withLock { _maxOutputTokens } }
    var countCalls: Int { lock.withLock { _countCalls } }

    func availability() async -> OnDeviceAvailability { .available }

    func contextWindowTokens() async -> Int { window ?? OnDeviceContextBudget.windowTokens }

    func tokenCount(for text: String) async -> Int? {
        lock.withLock { _countCalls += 1 }
        guard let charsPerToken else { return nil }
        return max(1, text.count / charsPerToken)
    }

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

    // MARK: The window comes from the model

    /// The arithmetic scales with the window and nothing else changes: the same request against
    /// iOS 27's 8,192 gets exactly the extra tokens' worth of characters.
    @Test func aWiderWindowBuysExactlyItsExtraTokensOfInput() {
        let floor = OnDeviceContextBudget.forRequest(
            outputTokens: 512, systemPromptChars: 1_000, groundingChars: 700)
        let wide = OnDeviceContextBudget.forRequest(
            outputTokens: 512, systemPromptChars: 1_000, groundingChars: 700, windowTokens: 8_192)

        #expect(wide.inputChars - floor.inputChars == 4_096 * AskBudget.charsPerToken)
        // The default is the floor, so every caller that did not say gets the iOS 26 budget.
        #expect(
            floor
                == OnDeviceContextBudget.forRequest(
                    outputTokens: 512, systemPromptChars: 1_000, groundingChars: 700,
                    windowTokens: OnDeviceContextBudget.windowTokens))
    }

    /// THE point of the change: an Extended summary that the 4,096-token model refuses is
    /// accepted whole — no truncation marker — by the 8,192-token one.
    @Test func an8192TokenModelAdmitsWhatThe4096OneRejects() async throws {
        // Under the wider budget, over the narrower one: about 7,600 characters of transcript
        // against a ceiling of ~5,900 at the floor and ~18,200 at 8,192.
        let chars = 7_600
        let floorModel = AFRecordingModel(window: 4_096)
        do {
            _ = try await OnDeviceAiProvider(model: floorModel)
                .run(request(AiPromptTemplates.extendedSummary, chars: chars))
            Issue.record("expected the 4,096-token model to refuse")
        } catch {
            #expect(AiFailure.classify(error).kind == .tooLongForDevice)
        }

        let wideModel = AFRecordingModel(window: 8_192)
        _ = try await OnDeviceAiProvider(model: wideModel)
            .run(request(AiPromptTemplates.extendedSummary, chars: chars))
        let prompt = try #require(wideModel.prompt)
        #expect(!prompt.contains("transcript truncated for length"))
    }

    /// A conformer that predates the requirement — every existing test double — is budgeted
    /// exactly as before: the protocol default IS the floor.
    @Test func aModelThatDoesNotSayGetsTheFloor() async throws {
        struct Silent: OnDeviceLanguageModel {
            let id = "silent"
            func availability() async -> OnDeviceAvailability { .available }
            func generate(instructions: String, prompt: String, maxOutputTokens: Int?)
                async throws -> String
            { "ok" }
        }
        let model = Silent()
        #expect(await model.contextWindowTokens() == OnDeviceContextBudget.windowTokens)
        #expect(await model.tokenCount(for: "anything") == nil)
        #expect(
            await OnDeviceAiProvider(model: model).onDeviceInputChars()
                == OnDeviceAiProvider.defaultMaxInputChars)
    }

    /// The failure message names the window it was measured against, not a number that stopped
    /// being true on iOS 27.
    @Test func theRefusalNamesTheModelsOwnWindow() async throws {
        let enormous = AiPromptTemplate(
            id: "af-enormous", title: "Enormous",
            systemPrompt: String(repeating: "instruction ", count: 2_400),
            userPrompt: "Go.")
        let provider = OnDeviceAiProvider(model: AFRecordingModel(window: 8_192))
        do {
            _ = try await provider.run(request(enormous, chars: 2_000))
            Issue.record("expected a failure")
        } catch AiError.providerFailed(let message, _) {
            #expect(message.contains("8,192-token window"))
            #expect(!message.contains("4,096"))
        }
    }

    @Test func theWindowIsWrittenWithItsGroupingComma() {
        #expect(OnDeviceAiProvider.formatted(4_096) == "4,096")
        #expect(OnDeviceAiProvider.formatted(8_192) == "8,192")
        #expect(OnDeviceAiProvider.formatted(32_768) == "32,768")
        #expect(OnDeviceAiProvider.formatted(999) == "999")
        #expect(OnDeviceAiProvider.formatted(1_000_000) == "1,000,000")
    }

    // MARK: A real count beats the estimate

    /// The estimate charges three characters a token; a model that counts five admits a body
    /// the estimate would have truncated — whole, with no marker.
    @Test func aRealTokenCountAdmitsWhatTheEstimateWouldHaveCut() async throws {
        // ~12,000 characters: past the estimate's ceiling for this template (~10,400 with no
        // grounding), well inside the window at five characters a token (2,400 tokens).
        let estimating = AFRecordingModel()
        _ = try await OnDeviceAiProvider(model: estimating)
            .run(request(SegmentAnnotationPrompt.template, chars: 12_000))
        #expect(try #require(estimating.prompt).contains("transcript truncated for length"))

        let counting = AFRecordingModel(charsPerToken: 5)
        _ = try await OnDeviceAiProvider(model: counting)
            .run(request(SegmentAnnotationPrompt.template, chars: 12_000))
        #expect(!(try #require(counting.prompt).contains("transcript truncated for length")))
        // Instructions once, body once. Not per-candidate, not per-retry.
        #expect(counting.countCalls == 2)
    }

    /// When the count agrees it does not fit, the cut is proportional to the count — and never
    /// deeper than the estimate already guaranteed.
    @Test func aRealTokenCountTruncatesProportionally() async throws {
        let counting = AFRecordingModel(charsPerToken: 5)
        _ = try await OnDeviceAiProvider(model: counting)
            .run(request(SegmentAnnotationPrompt.template, chars: 60_000))
        let prompt = try #require(counting.prompt)
        #expect(prompt.contains("transcript truncated for length"))
        // Room ≈ (4096 − 96 − 200 − instructions) tokens × 5 chars × 0.95 — comfortably more
        // than the estimate's ~10,400, and comfortably under the 60,000 offered.
        #expect(prompt.count > 12_000)
        #expect(prompt.count < 20_000)
    }

    /// A count that says "fits" is still not allowed past a caller's pinned ceiling.
    @Test func aPinnedInputCapStillWinsOverACount() async throws {
        let counting = AFRecordingModel(charsPerToken: 5)
        _ = try await OnDeviceAiProvider(model: counting, maxInputChars: 3_000)
            .run(request(SegmentAnnotationPrompt.template, chars: 12_000))
        let prompt = try #require(counting.prompt)
        #expect(prompt.contains("transcript truncated for length"))
        #expect(prompt.count < 3_400)
    }

    /// The whole point of counting is admitting more, never less: a count can only ever
    /// ENLARGE the estimate's ceiling. A body the estimate admits is sent without counting.
    @Test func aBodyTheEstimateAdmitsIsNotCounted() async throws {
        let counting = AFRecordingModel(charsPerToken: 5)
        _ = try await OnDeviceAiProvider(model: counting)
            .run(request(SegmentAnnotationPrompt.template, chars: 2_000))
        #expect(counting.countCalls == 0)
    }

    /// The Ask planner's ceiling follows the window: the measured 8,000 at the floor, double at
    /// iOS 27's window, and a pinned cap still wins.
    @Test func thePlannerCeilingScalesWithTheWindow() async throws {
        #expect(await OnDeviceAiProvider(model: AFRecordingModel()).onDeviceInputChars() == 8_000)
        #expect(
            await OnDeviceAiProvider(model: AFRecordingModel(window: 8_192)).onDeviceInputChars()
                == 16_000)
        #expect(
            await OnDeviceAiProvider(model: AFRecordingModel(window: 8_192), maxInputChars: 5_000)
                .onDeviceInputChars() == 5_000)
        // No model at all: the constant, so a planner never divides by a missing window.
        #expect(await OnDeviceAiProvider(model: nil).onDeviceInputChars() == 8_000)
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
