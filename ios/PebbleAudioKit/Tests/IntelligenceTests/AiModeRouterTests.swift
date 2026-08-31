import Foundation
import Testing

@testable import Intelligence

// Port of `core/ai/src/commonTest/.../AiModeRouterTest.kt` — all 3 cases, same names.

private final class FakeAiProvider: AiProvider, @unchecked Sendable {
    let id: String
    private let available: Bool
    private let text: String
    private let failure: Error?

    init(_ id: String, available: Bool = true, text: String = "ok", failure: Error? = nil) {
        self.id = id
        self.available = available
        self.text = text
        self.failure = failure
    }

    func isAvailable() async -> Bool { available }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        if let failure { throw failure }
        return AiProviderResult(text: text, modelUsed: "\(id)-model")
    }
}

private struct LocalBoom: LocalizedError {
    var errorDescription: String? { "local failed" }
}

@Suite struct AiModeRouterTests {
    private let request = AiRunRequest(
        requestId: "run-1",
        prompt: AiPromptTemplate(
            id: "summary",
            title: "Summary",
            systemPrompt: "Summarize.",
            userPrompt: "Use the transcript."
        ),
        transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "hello world")]
    )

    @Test func localFirstFallsBackToRemoteOnProviderFailure() async throws {
        let router = AiModeRouter(
            local: FakeAiProvider("local", failure: LocalBoom()),
            remote: FakeAiProvider("remote", text: "remote summary"),
            mode: { .localFirst }
        )

        let result = try await router.run(request)

        #expect(result.text == "remote summary")
        #expect(result.modeUsed == .remoteOnly)
        #expect(result.providerId == "remote")
        #expect(router.lastSuccessfulMode == .remoteOnly)
    }

    @Test func consentFailureDoesNotFallBack() async throws {
        let router = AiModeRouter(
            local: FakeAiProvider(
                "local", failure: AiError.consentRequired(providerId: "local")),
            remote: FakeAiProvider("remote", text: "remote summary"),
            mode: { .localFirst }
        )

        do {
            _ = try await router.run(request)
            Issue.record("expected ConsentRequired")
        } catch AiError.consentRequired {
            // expected: ConsentRequired never falls back
        }
    }

    @Test func remoteOnlyDoesNotUseLocalFallback() async throws {
        let router = AiModeRouter(
            local: FakeAiProvider("local", text: "local summary"),
            remote: FakeAiProvider("remote", available: false),
            mode: { .remoteOnly }
        )

        do {
            _ = try await router.run(request)
            Issue.record("expected ProviderUnavailable")
        } catch AiError.providerUnavailable {
            // expected
        }
    }
}
