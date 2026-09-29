import Foundation
import Testing
import Transcription

@testable import Intelligence

// The ways a successful call is not an answer, each named rather than kept.
//
// OpenAI returns 200 for an answer its filter stopped partway (`incomplete`, `content_filter`),
// for a refusal part instead of text, and for a response that `failed` on its side — all three
// reached the caller as finished text, or as "an empty completion". The on-device model returns
// an answer cut at its output budget without saying so, and it was kept as finished.

private struct OneResponse: HttpTransport {
    let text: String
    func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse {
        HttpTransportResponse(status: 200, text: text)
    }
}

private func openAi(_ body: String) -> OpenAiChatAiProvider {
    OpenAiChatAiProvider(
        transport: OneResponse(text: body), apiKey: { "sk-test" }, remoteConsent: { true })
}

private let request = AiRunRequest(
    requestId: "r", prompt: AiPromptTemplates.meetingNotes,
    transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "We planned the launch.")])

private final class CountingModel: OnDeviceLanguageModel, @unchecked Sendable {
    let id = "counting"
    let reply: String
    let charsPerToken: Int?
    init(reply: String, charsPerToken: Int?) {
        self.reply = reply
        self.charsPerToken = charsPerToken
    }
    func availability() async -> OnDeviceAvailability { .available }
    func tokenCount(for text: String) async -> Int? { charsPerToken.map { text.count / $0 } }
    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String
    { reply }
}

@Suite("AI answers — a 200 that is not an answer is named, not kept")
struct AiAnswerShapeTests {
    @Test func anAnswerTheFilterStoppedPartwayIsARefusalNotAFinishedNote() async throws {
        let provider = openAi(
            #"{"status":"incomplete","incomplete_details":{"reason":"content_filter"},"output_text":"The first half of a"}"#)
        do {
            _ = try await provider.run(request)
            Issue.record("expected the refusal")
        } catch {
            #expect(AiFailure.classify(error).kind == .answerRefused)
        }
    }

    @Test func aRefusalPartIsARefusalNotAnEmptyAnswer() async throws {
        let provider = openAi(
            #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"I can't help with that."}]}]}"#)
        do {
            _ = try await provider.run(request)
            Issue.record("expected the refusal")
        } catch {
            #expect(AiFailure.classify(error).kind == .answerRefused)
        }
    }

    @Test func aResponseThatFailedOnOpenAisSideIsTheProvidersTrouble() async throws {
        let provider = openAi(
            #"{"status":"failed","error":{"code":"server_error","message":"The server had an error"}}"#)
        do {
            _ = try await provider.run(request)
            Issue.record("expected the failure")
        } catch {
            #expect(AiFailure.classify(error).kind == .providerTrouble)
            #expect(!AiRetryPolicy.spendsAttempt(error))
        }
    }

    @Test func theOutputCeilingIsNamedAsSuch() async throws {
        let provider = openAi(
            #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output_text":"Half"}"#)
        do {
            _ = try await provider.run(request)
            Issue.record("expected the cut")
        } catch {
            #expect(AiFailure.classify(error).kind == .outputLimit)
        }
    }

    // MARK: On device

    /// A reply that filled the model's whole output budget was cut there.
    @Test func anOnDeviceAnswerThatFilledItsBudgetIsNotKept() async throws {
        let cap = OnDeviceTemplateBudget.outputTokens(forTemplateId: "meeting-notes")
        let full = String(repeating: "word ", count: cap)  // cap × 5 chars = cap tokens at 5/token
        let provider = OnDeviceAiProvider(model: CountingModel(reply: full, charsPerToken: 5))
        do {
            _ = try await provider.run(request)
            Issue.record("expected the cut")
        } catch {
            #expect(AiFailure.classify(error).kind == .outputLimit)
        }

        let short = OnDeviceAiProvider(
            model: CountingModel(reply: "Launch planned for Friday.", charsPerToken: 5))
        #expect(try await short.run(request).text == "Launch planned for Friday.")
    }

    /// A model that cannot count is judged conservatively: only a reply long enough to be at
    /// the cap AND ending mid-sentence is refused.
    @Test func withoutACountOnlyALongReplyEndingMidSentenceIsRefused() async throws {
        let cap = OnDeviceTemplateBudget.outputTokens(forTemplateId: "meeting-notes")
        let cut = String(repeating: "the plan went on and ", count: cap / 4)
        await #expect(throws: AiError.self) {
            _ = try await OnDeviceAiProvider(
                model: CountingModel(reply: cut, charsPerToken: nil)
            ).run(request)
        }
        let finished = String(repeating: "The plan went on. ", count: cap / 4)
        _ = try await OnDeviceAiProvider(model: CountingModel(reply: finished, charsPerToken: nil))
            .run(request)
    }
}
