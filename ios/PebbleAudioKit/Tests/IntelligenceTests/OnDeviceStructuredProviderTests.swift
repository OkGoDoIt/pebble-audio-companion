import Foundation
import Testing

@testable import Intelligence

// The provider seam's structured-output half: who is refused, who is routed, and what the
// refusal still protects. `OnDeviceProviderTests` covers the prose path and is unchanged.

/// A model that can be told whether it supports guided generation, so both sides of the now
/// CONDITIONAL refusal can be exercised without Apple Intelligence being present.
private final class StructuredFakeModel: OnDeviceLanguageModel, @unchecked Sendable {
    let id = "fake-structured"
    let supportsStructuredOutput: Bool

    private let lock = NSLock()
    private var _structuredBody: String
    private var _lastShape: OnDeviceStructuredShape?
    private var _lastPrompt: String?
    private var _structuredError: Error?
    private var _proseCalls = 0

    init(
        supportsStructuredOutput: Bool = true,
        structuredBody: String = #"{"items":[]}"#,
        structuredError: Error? = nil
    ) {
        self.supportsStructuredOutput = supportsStructuredOutput
        self._structuredBody = structuredBody
        self._structuredError = structuredError
    }

    var lastShape: OnDeviceStructuredShape? { lock.withLock { _lastShape } }
    var lastPrompt: String? { lock.withLock { _lastPrompt } }
    var proseCalls: Int { lock.withLock { _proseCalls } }

    func availability() async -> OnDeviceAvailability { .available }

    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String
    {
        lock.withLock { _proseCalls += 1 }
        return "TITLE: x\nSUMMARY: y."
    }

    func generateStructured(
        _ shape: OnDeviceStructuredShape, instructions: String, prompt: String,
        maxOutputTokens: Int?
    ) async throws -> String {
        let error: Error? = lock.withLock {
            _lastShape = shape
            _lastPrompt = prompt
            return _structuredError
        }
        if let error { throw error }
        return lock.withLock { _structuredBody }
    }
}

/// The pre-existing double, which knows nothing about structured output and therefore inherits
/// `supportsStructuredOutput == false` from the protocol extension.
private final class ProseOnlyModel: OnDeviceLanguageModel, @unchecked Sendable {
    let id = "prose-only"
    func availability() async -> OnDeviceAvailability { .available }
    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String
    { "anything" }
}

@Suite struct OnDeviceStructuredProviderTests {

    private func followUpRequest(
        template: AiPromptTemplate = AiPromptTemplates.followUpExtraction,
        text: String = "S1: I will pick up Oliver from school today."
    ) -> AiRunRequest {
        AiRunRequest(
            requestId: "r",
            prompt: template,
            transcripts: [
                TranscriptExcerpt(
                    segmentId: AiTranscriptFormatting.prebuiltSegmentId, text: text)
            ],
            metadata: [AiRunRequest.requiresStructuredOutputKey: "1"])
    }

    // MARK: - Who is refused

    /// The behaviour the old unconditional refusal had, kept exactly for a model that genuinely
    /// cannot hold a shape. This is the fail-closed case, and it is what every existing test
    /// double lands on.
    @Test func stillRefusesAModelThatCannotHoldAShape() async {
        let provider = OnDeviceAiProvider(model: ProseOnlyModel())
        await #expect(throws: AiError.self) { try await provider.run(followUpRequest()) }
    }

    @Test func refusesWhenTheModelClaimsNoStructuredSupport() async {
        let model = StructuredFakeModel(supportsStructuredOutput: false)
        let provider = OnDeviceAiProvider(model: model)
        await #expect(throws: AiError.self) { try await provider.run(followUpRequest()) }
        #expect(model.lastShape == nil, "must not reach the model at all")
        #expect(model.proseCalls == 0, "and must never quietly answer in prose instead")
    }

    /// Fail-closed on the shape, not just on the model. Boundary review sets the same tag and
    /// has no on-device implementation, so LocalOnly keeps the structural grouping rather than
    /// being handed a semantic verdict nothing agreed the format of.
    @Test func refusesAShapeNothingOnDeviceKnowsHowToProduce() async {
        let model = StructuredFakeModel()
        let provider = OnDeviceAiProvider(model: model)
        await #expect(throws: AiError.self) {
            try await provider.run(followUpRequest(template: BoundaryPromptTemplates.boundaryReview))
        }
        #expect(model.lastShape == nil)
    }

    @Test func refusesWhenTheModelIsNotAvailableEvenIfItCouldHoldAShape() async {
        // Availability is checked before the shape, so a downloading model is unavailable
        // rather than unsupported — the caller retries instead of giving up on the feature.
        let provider = OnDeviceAiProvider(model: DownloadingModel())
        await #expect(throws: AiError.self) { try await provider.run(followUpRequest()) }
    }

    private final class DownloadingModel: OnDeviceLanguageModel, @unchecked Sendable {
        let id = "downloading"
        var supportsStructuredOutput: Bool { true }
        func availability() async -> OnDeviceAvailability { .downloading }
        func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
            -> String
        { "" }
        func generateStructured(
            _ shape: OnDeviceStructuredShape, instructions: String, prompt: String,
            maxOutputTokens: Int?
        ) async throws -> String {
            Issue.record("must not run an unavailable model")
            return ""
        }
    }

    // MARK: - Who is routed

    @Test func routesFollowUpExtractionToTheStructuredPath() async throws {
        let body = LocalFollowUpSift.extractionJSON([
            LocalFollowUpSift.Item(
                task: "Pick up Oliver from school",
                quote: "I will pick up Oliver from school today.",
                ifForgotten: "nobody collects him")
        ])
        let model = StructuredFakeModel(structuredBody: body)
        let provider = OnDeviceAiProvider(model: model)

        let result = try await provider.run(followUpRequest())

        #expect(model.lastShape == .followUps)
        #expect(model.proseCalls == 0)
        let parsed = try #require(FollowUpExtractionParser.parse(raw: result.text))
        #expect(parsed.count == 1)
        #expect(result.modelUsed == "fake-structured")
    }

    @Test func routesCurationToTheStructuredPath() async throws {
        let model = StructuredFakeModel(
            structuredBody: LocalFollowUpSift.curationJSON(decisions: [
                (index: 1, keep: true, reason: "")
            ]))
        let provider = OnDeviceAiProvider(model: model)
        let result = try await provider.run(
            followUpRequest(
                template: AiPromptTemplates.followUpCuration,
                text: "CANDIDATES:\n1. Pick up Oliver from school\n   heard: \"I will.\""))
        #expect(model.lastShape == .followUpCuration)
        #expect(FollowUpCurationParser.parse(raw: result.text)?.count == 1)
    }

    /// A structured run gets the conversation whole. The 12k-character prose cap is what made a
    /// loop that closes in the last ten minutes of a recording come back looking open.
    @Test func doesNotTruncateAStructuredRunToTheProseBudget() async throws {
        let long = String(repeating: "S1: I will send the paperwork over tomorrow morning.\n",
            count: 600)
        let model = StructuredFakeModel()
        let provider = OnDeviceAiProvider(model: model, maxInputChars: 1_000)

        _ = try await provider.run(followUpRequest(text: long))

        let prompt = try #require(model.lastPrompt)
        #expect(prompt.count > 10_000)
        #expect(!prompt.contains("transcript truncated for length"))
    }

    /// The prose path is untouched: no tag, no shape, no structured call.
    @Test func leavesTheProsePathExactlyAsItWas() async throws {
        let model = StructuredFakeModel()
        let provider = OnDeviceAiProvider(model: model)
        _ = try await provider.run(
            AiRunRequest(
                requestId: "r",
                prompt: SegmentAnnotationPrompt.template,
                transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "Words.")]))
        #expect(model.proseCalls == 1)
        #expect(model.lastShape == nil)
    }

    /// A model that advertises the capability and then throws is UNAVAILABLE, not failed, so a
    /// First mode falls through to the cloud instead of spending one of the caller's two
    /// attempts on a device that will never manage it.
    @Test func aBrokenStructuredModelIsUnavailableRatherThanFailed() async {
        let provider = OnDeviceAiProvider(
            model: StructuredFakeModel(structuredError: OnDeviceStructuredError.unsupported))
        do {
            _ = try await provider.run(followUpRequest())
            Issue.record("expected providerUnavailable")
        } catch AiError.providerUnavailable {
            // expected
        } catch {
            Issue.record("expected providerUnavailable, got \(error)")
        }
    }

    // MARK: - The shape table

    @Test func mapsOnlyThePromptsWithAnOnDeviceImplementation() {
        #expect(
            OnDeviceStructuredShape.forPromptId(AiPromptTemplates.followUpExtraction.id)
                == .followUps)
        #expect(
            OnDeviceStructuredShape.forPromptId(AiPromptTemplates.followUpCuration.id)
                == .followUpCuration)
        #expect(OnDeviceStructuredShape.forPromptId(BoundaryPromptTemplates.boundaryReview.id) == nil)
        #expect(OnDeviceStructuredShape.forPromptId("something-invented") == nil)
    }
}
