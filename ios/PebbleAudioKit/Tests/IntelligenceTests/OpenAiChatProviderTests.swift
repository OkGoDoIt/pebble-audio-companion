import Foundation
import Testing
import Transcription

@testable import Intelligence

// Port of `core/ai/src/jvmTest/.../OpenAiChatAiProviderTest.kt` — all 8 cases, same names.
// The KMP tests faked HTTP with ktor's MockEngine; here the injected `HttpTransport` plays
// that role, so no test touches the network.

/// Hermetic `HttpTransport` fake (the MockEngine analogue): runs the handler, records every
/// request for assertions.
private final class RecordingTransport: HttpTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HttpTransportRequest] = []
    private let handler: @Sendable (HttpTransportRequest) async throws -> HttpTransportResponse

    init(
        handler: @escaping @Sendable (HttpTransportRequest) async throws -> HttpTransportResponse
    ) {
        self.handler = handler
    }

    var requests: [HttpTransportRequest] { lock.withLock { recorded } }
    var last: HttpTransportRequest? { lock.withLock { recorded.last } }

    func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse {
        lock.withLock { recorded.append(request) }
        return try await handler(request)
    }
}

private struct UnexpectedRequest: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Mutable settings box (the KMP tests' captured `var selectedModel`).
private final class ModelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String
    init(_ value: String) { _value = value }
    var value: String {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private func bodyText(_ request: HttpTransportRequest?) -> String {
    String(decoding: request?.body ?? Data(), as: UTF8.self)
}

@Suite struct OpenAiChatProviderTests {

    private func request(
        prompt: AiPromptTemplate = AiPromptTemplates.actionItems
    ) -> AiRunRequest {
        AiRunRequest(
            requestId: "ai-1",
            prompt: prompt,
            transcripts: [
                TranscriptExcerpt(
                    segmentId: "seg-1", text: "We agreed Bob ships the fix Friday.")
            ]
        )
    }

    @Test func unavailableWithoutConsentOrKey() async throws {
        let transport = RecordingTransport { _ in
            throw UnexpectedRequest(message: "no requests without consent and key")
        }
        let provider = OpenAiChatAiProvider(
            transport: transport,
            apiKey: { "" },
            remoteConsent: { false }
        )

        #expect(await provider.isAvailable() == false)
        do {
            _ = try await provider.run(request())
            Issue.record("expected ConsentRequired")
        } catch AiError.consentRequired {
            // expected
        }
    }

    @Test func consentWithoutKeyIsUnavailable() async throws {
        let transport = RecordingTransport { _ in
            throw UnexpectedRequest(message: "no requests without a key")
        }
        let provider = OpenAiChatAiProvider(
            transport: transport,
            apiKey: { nil },
            remoteConsent: { true }
        )

        #expect(await provider.isAvailable() == false)
        do {
            _ = try await provider.run(request())
            Issue.record("expected ProviderUnavailable")
        } catch AiError.providerUnavailable {
            // expected
        }
    }

    @Test func postsPromptAndTranscriptAndParsesCompletion() async throws {
        let transport = RecordingTransport { _ in
            HttpTransportResponse(
                status: 200,
                text: """
                    {
                      "model": "gpt-4o-mini-2024",
                      "output_text": "{\\"items\\":[{\\"task\\":\\"Ship the fix\\",\\"owner\\":\\"Bob\\",\\"due\\":\\"Friday\\",\\"sourceSegmentId\\":\\"seg-1\\"}]}",
                      "usage": {"input_tokens": 42, "output_tokens": 12}
                    }
                    """
            )
        }
        let provider = OpenAiChatAiProvider(
            transport: transport,
            apiKey: { "test-key" },
            remoteConsent: { true }
        )

        let result = try await provider.run(request())

        #expect(result.text.contains("\"items\""))
        #expect(result.text.contains("\"Ship the fix\""))
        #expect(result.modelUsed == "gpt-4o-mini-2024")
        #expect(result.inputTokens == 42)
        #expect(result.outputTokens == 12)
        let captured = try #require(transport.last)
        #expect(captured.headers["Authorization"] == "Bearer test-key")
        let body = bodyText(captured)
        #expect(body.contains("seg-1"), "request body should reference the segment id")
        #expect(
            body.contains("We agreed Bob ships the fix Friday."),
            "request body should contain the transcript text")
        let compactBody = body.filter { !$0.isWhitespace }
        #expect(compactBody.contains("\"text\""))
        #expect(compactBody.contains("\"format\""))
        #expect(compactBody.contains("\"type\":\"json_schema\""))
        #expect(compactBody.contains("\"name\":\"action_items\""))
        #expect(compactBody.contains("\"strict\":true"))
        #expect(compactBody.contains("\"sourceSegmentId\""))
    }

    @Test func nonActionTemplatesDoNotRequestJsonSchema() async throws {
        let transport = RecordingTransport { _ in
            HttpTransportResponse(
                status: 200,
                text: #"{"output_text": "Plain summary", "model": "gpt-5.6-luna"}"#)
        }
        let provider = OpenAiChatAiProvider(
            transport: transport,
            apiKey: { "test-key" },
            remoteConsent: { true }
        )

        _ = try await provider.run(request(prompt: AiPromptTemplates.dailySummary))

        let body = bodyText(transport.last)
        #expect(
            !body.contains("\"json_schema\""),
            "free-form outputs should not request JSON schema")
    }

    @Test func segmentAnnotationRequestsStructuredTags() async throws {
        let transport = RecordingTransport { _ in
            HttpTransportResponse(
                status: 200,
                text: """
                    {
                      "model": "gpt-5.6-luna",
                      "output_text": "{\\"title\\":\\"Budget review\\",\\"summary\\":\\"They discussed Q3 spend.\\",\\"tags\\":[\\"budget\\",\\"finance\\"]}"
                    }
                    """
            )
        }
        let provider = OpenAiChatAiProvider(
            transport: transport,
            apiKey: { "test-key" },
            remoteConsent: { true }
        )

        let result = try await provider.run(request(prompt: SegmentAnnotationPrompt.template))

        #expect(result.text.contains("\"tags\""))
        let body = bodyText(transport.last).filter { !$0.isWhitespace }
        #expect(body.contains("\"type\":\"json_schema\""))
        #expect(body.contains("\"name\":\"segment_annotation\""))
        #expect(body.contains("\"title\""))
        #expect(body.contains("\"summary\""))
        #expect(body.contains("\"tags\""))
        #expect(body.contains("\"strict\":true"))
    }

    @Test func sendsConfiguredModelInRequestBody() async throws {
        let selectedModel = ModelBox("gpt-5.6-luna")
        let transport = RecordingTransport { _ in
            HttpTransportResponse(
                status: 200, text: #"{"output_text": "ok", "model": "gpt-5.6-luna"}"#)
        }
        let provider = OpenAiChatAiProvider(
            transport: transport,
            apiKey: { "test-key" },
            remoteConsent: { true },
            model: { selectedModel.value }
        )

        _ = try await provider.run(request())
        #expect(
            bodyText(transport.last).contains("\"model\":\"gpt-5.6-luna\""),
            "request should carry the configured model")

        // The closure is read per request, so a settings change takes effect on the next call.
        selectedModel.value = "gpt-5.6-sol"
        _ = try await provider.run(request())
        #expect(
            bodyText(transport.last).contains("\"model\":\"gpt-5.6-sol\""),
            "model change should apply to the next request")
    }

    @Test func nonOkResponseFailsWithProviderFailed() async throws {
        let transport = RecordingTransport { _ in
            HttpTransportResponse(status: 429, text: #"{"error": {"message": "rate limited"}}"#)
        }
        let provider = OpenAiChatAiProvider(
            transport: transport,
            apiKey: { "test-key" },
            remoteConsent: { true }
        )

        do {
            _ = try await provider.run(request())
            Issue.record("expected ProviderFailed")
        } catch AiError.providerFailed {
            // expected
        }
    }

    @Test func oversizedTranscriptIsTruncatedNotRejected() async throws {
        let transport = RecordingTransport { _ in
            HttpTransportResponse(
                status: 200, text: #"{"output_text": "ok", "model": "gpt-5.6-luna"}"#)
        }
        let provider = OpenAiChatAiProvider(
            transport: transport,
            apiKey: { "test-key" },
            remoteConsent: { true },
            maxInputChars: { 500 }
        )

        let bigRequest = AiRunRequest(
            requestId: "ai-2",
            prompt: AiPromptTemplates.dailySummary,
            transcripts: [
                TranscriptExcerpt(
                    segmentId: "seg-1", text: String(repeating: "word ", count: 1_000))
            ]
        )
        let result = try await provider.run(bigRequest)

        #expect(result.text == "ok")
        #expect(bodyText(transport.last).contains("transcript truncated for length"))
    }
}
