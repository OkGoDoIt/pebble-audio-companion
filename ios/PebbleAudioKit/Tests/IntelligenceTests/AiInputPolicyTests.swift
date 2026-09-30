import Foundation
import Testing
import Transcription

@testable import Intelligence

// One rule for every provider: a template whose answer claims its whole input is REFUSED when
// the input does not fit, and anything else that is cut says it was cut.
//
// The incident these pin: the recaps for 2026-09-22 and 09-23 were written by the on-device
// model and saved as covering 51 and 45 recordings (~232,000 and ~285,000 characters). It had
// been handed about 8,000 characters of each by a Remote-first fallback and cut the rest
// without a word.

private final class PolicyOnDeviceModel: OnDeviceLanguageModel, @unchecked Sendable {
    let id = "policy-on-device"
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    func availability() async -> OnDeviceAvailability { .available }

    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String
    {
        lock.withLock { _calls += 1 }
        return "a recap"
    }
}

private final class PolicyPrivateCloudModel: ApplePrivateCloudLanguageModel, @unchecked Sendable {
    let id = "apple-private-cloud-compute"
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    func availability() async -> ApplePrivateCloudAvailability { .available }
    func quota() async -> ApplePrivateCloudQuota? { nil }
    func contextWindowTokens() async -> Int { ApplePrivateCloudAiProvider.defaultContextTokens }

    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String
    {
        lock.withLock { _calls += 1 }
        return "an answer"
    }

    func generateStructured(
        _ shape: OnDeviceStructuredShape, instructions: String, prompt: String,
        maxOutputTokens: Int?
    ) async throws -> String {
        lock.withLock { _calls += 1 }
        return "{}"
    }
}

private final class PolicyTransport: HttpTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests = 0
    var requests: Int { lock.withLock { _requests } }

    func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse {
        lock.withLock { _requests += 1 }
        return HttpTransportResponse(
            status: 200, text: #"{"output_text": "ok", "model": "gpt-5.6-luna"}"#)
    }
}

private final class FailingProvider: AiProvider, @unchecked Sendable {
    let id = "cloud"
    func isAvailable() async -> Bool { true }
    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        throw AiError.providerFailed("OpenAI responses request failed (503): overloaded")
    }
}

private final class StubProvider: AiProvider, @unchecked Sendable {
    let id: String
    let truncated: Bool
    init(_ id: String, truncated: Bool) {
        self.id = id
        self.truncated = truncated
    }
    func isAvailable() async -> Bool { true }
    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        AiProviderResult(text: "done", modelUsed: "\(id)-model", inputTruncated: truncated)
    }
}

/// A whole day of transcript: many recordings, far past any on-device window.
private func wholeDay(_ template: AiPromptTemplate, chars: Int) -> AiRunRequest {
    let perSegment = 5_000
    let count = max(1, chars / perSegment)
    return AiRunRequest(
        requestId: "day",
        prompt: template,
        transcripts: (0..<count).map {
            TranscriptExcerpt(
                segmentId: "seg-\($0)", text: String(repeating: "word ", count: perSegment / 5))
        })
}

@Suite("AI input policy — refuse, never silently cut, a whole-input template")
struct AiInputPolicyTests {
    @Test func theTemplatesThatClaimTheirWholeInputAreExactlyTheseEight() {
        // The five that summarise transcripts, and History's three briefs, each stored against a
        // fingerprint of its whole input.
        #expect(
            AiInputPolicy.wholeInputTemplateIds
                == ["extended-summary", "daily-summary", "ask", "ask-sweep-findings",
                    "ask-sweep-answer", "day-brief", "week-brief", "month-brief"])
        for template in [
            AiPromptTemplates.extendedSummary, AiPromptTemplates.dailySummary,
            AiPromptTemplates.ask, AiPromptTemplates.askSweepFindings,
            AiPromptTemplates.askSweepAnswer,
        ] {
            #expect(AiInputPolicy.requiresWholeInput(templateId: template.id))
        }
        #expect(!AiInputPolicy.requiresWholeInput(templateId: SegmentAnnotationPrompt.templateId))
        #expect(!AiInputPolicy.requiresWholeInput(templateId: AiPromptTemplates.meetingNotes.id))
        // The on-device budget's own question now has the same answer.
        #expect(OnDeviceTemplateBudget.readsWholeConversation(templateId: "daily-summary"))
    }

    /// The reported recap, on the on-device model: refused, and the model is never asked.
    @Test func theOnDeviceModelRefusesAWholeDayInsteadOfRecappingItsFirstHour() async throws {
        let model = PolicyOnDeviceModel()
        do {
            _ = try await OnDeviceAiProvider(model: model)
                .run(wholeDay(AiPromptTemplates.dailySummary, chars: 232_000))
            Issue.record("expected a refusal")
        } catch {
            #expect(AiFailure.classify(error).kind == .tooLongForDevice)
        }
        #expect(model.calls == 0)
    }

    @Test(arguments: ["ask", "ask-sweep-findings", "ask-sweep-answer", "extended-summary"])
    func theOnDeviceModelRefusesEveryWholeInputTemplate(_ id: String) async throws {
        let template = AiPromptTemplate(id: id, title: id, systemPrompt: "Read.", userPrompt: "Go.")
        let model = PolicyOnDeviceModel()
        await #expect(throws: AiError.self) {
            _ = try await OnDeviceAiProvider(model: model).run(wholeDay(template, chars: 60_000))
        }
        #expect(model.calls == 0)
    }

    /// A title is still allowed to be the gist of the first hour — and now it says so.
    @Test func aGistTemplateIsCutAndTheResultSaysSo() async throws {
        let provider = OnDeviceAiProvider(model: PolicyOnDeviceModel())
        let cut = try await provider.run(wholeDay(SegmentAnnotationPrompt.template, chars: 60_000))
        #expect(cut.inputTruncated)
        let whole = try await provider.run(
            wholeDay(SegmentAnnotationPrompt.template, chars: 1_000))
        #expect(!whole.inputTruncated)
    }

    @Test func privateCloudComputeRefusesARecapItsWindowCannotHold() async throws {
        let model = PolicyPrivateCloudModel()
        let provider = ApplePrivateCloudAiProvider(
            model: model, remoteConsent: { true },
            buildStatus: ApplePrivateCloudBuildStatus(entitled: true))
        do {
            _ = try await provider.run(wholeDay(AiPromptTemplates.dailySummary, chars: 285_000))
            Issue.record("expected a refusal")
        } catch {
            #expect(AiFailure.classify(error).kind == .tooLongForModel)
        }
        #expect(model.calls == 0)

        let cut = try await provider.run(
            wholeDay(SegmentAnnotationPrompt.template, chars: 285_000))
        #expect(cut.inputTruncated)
        #expect(model.calls == 1)
    }

    @Test func openAiRefusesAWholeInputTemplateItsCeilingCannotHoldAndSendsNothing() async throws {
        let transport = PolicyTransport()
        let provider = OpenAiChatAiProvider(
            transport: transport, apiKey: { "sk-test" }, remoteConsent: { true },
            maxInputChars: { 2_000 })
        do {
            _ = try await provider.run(wholeDay(AiPromptTemplates.ask, chars: 20_000))
            Issue.record("expected a refusal")
        } catch AiError.providerFailed(let message, _) {
            #expect(message.contains(AiInputPolicy.tooLongForModelMarker))
            #expect(message.contains("\"Ask\" has to read all of it"))
        }
        #expect(transport.requests == 0)

        let cut = try await provider.run(wholeDay(AiPromptTemplates.meetingNotes, chars: 20_000))
        #expect(cut.inputTruncated)
        #expect(transport.requests == 1)
    }

    // MARK: The router marks what a fallback produced

    @Test func aResultAFallbackProducedFromACutInputIsProvisional() async throws {
        let router = AiModeRouter(
            local: StubProvider("local", truncated: true),
            remote: FailingProvider(),
            mode: { .remoteFirst })
        let result = try await router.run(wholeDay(SegmentAnnotationPrompt.template, chars: 900))
        #expect(result.viaFallback)
        #expect(result.inputTruncated)
        #expect(result.isProvisional)
    }

    /// The primary's own cut is the best there will ever be: marked cut, not provisional.
    @Test func thePrimarysOwnCutIsNotProvisional() async throws {
        let router = AiModeRouter(
            local: StubProvider("local", truncated: true),
            remote: FailingProvider(),
            mode: { .localOnly })
        let result = try await router.run(wholeDay(SegmentAnnotationPrompt.template, chars: 900))
        #expect(!result.viaFallback)
        #expect(result.inputTruncated)
        #expect(!result.isProvisional)
    }

    /// End to end, the reported shape: Remote first, the cloud is down, and the whole day goes
    /// to the on-device fallback — which now refuses. What escapes is the CLOUD failure, with
    /// the refusal as the trailing detail, and nothing is written.
    @Test func remoteFirstFallbackNoLongerRecapsADayFromItsFirstHour() async throws {
        let model = PolicyOnDeviceModel()
        let router = AiModeRouter(
            local: OnDeviceAiProvider(model: model),
            remote: FailingProvider(),
            mode: { .remoteFirst })
        do {
            _ = try await router.run(wholeDay(AiPromptTemplates.dailySummary, chars: 232_000))
            Issue.record("expected the day to be refused")
        } catch {
            let failure = AiFailure.classify(error)
            #expect(failure.kind == .providerTrouble)
            #expect(failure.fallback?.kind == .tooLongForDevice)
        }
        #expect(model.calls == 0)
    }
}
