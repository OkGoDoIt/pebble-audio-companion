import Foundation
import Testing
import Transcription

@testable import Intelligence

// `AiModeRouter.lastFallback` — the AI half of the disclosure. Same contract as the
// transcription router's (they share `ProcessingFallback`, so the sentence on screen cannot
// mean two things depending on which axis produced it); these pin the AI-specific mapping,
// which is the part that could drift: `AiError` has no `LocalizedError` conformance, so the
// router spells its cases out rather than letting `localizedDescription` print "The operation
// couldn't be completed".

private final class CUFakeAiProvider: AiProvider, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var _available: Bool
    private var _failure: Error?

    var available: Bool {
        get { lock.withLock { _available } }
        set { lock.withLock { _available = newValue } }
    }

    init(_ id: String, available: Bool = true, failure: Error? = nil) {
        self.id = id
        self._available = available
        self._failure = failure
    }

    func isAvailable() async -> Bool { available }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        if let failure = lock.withLock({ _failure }) { throw failure }
        return AiProviderResult(text: "text-\(id)", modelUsed: "\(id)-model")
    }
}

@Suite("CU · AI fallback disclosure")
struct CUAiFallbackDisclosureTests {
    private let request = AiRunRequest(
        requestId: "run-1",
        prompt: AiPromptTemplate(
            id: "summary", title: "Summary", systemPrompt: "Summarize.",
            userPrompt: "Use the transcript."),
        transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "hello world")]
    )

    @Test func localFirstSucceedingOnDeviceDisclosesNothing() async throws {
        let router = AiModeRouter(
            local: CUFakeAiProvider("local"), remote: CUFakeAiProvider("remote"),
            mode: { .localFirst })
        _ = try await router.run(request)
        #expect(router.lastFallback == nil)
    }

    /// The measured real case: no Apple Intelligence, so `providerUnavailable`, so every AI job
    /// — and with it the About You context and the transcript text — goes to the cloud.
    @Test func localFirstWithNoOnDeviceModelRecordsNotAvailable() async throws {
        let router = AiModeRouter(
            local: CUFakeAiProvider("local", available: false),
            remote: CUFakeAiProvider("remote"),
            mode: { .localFirst })
        _ = try await router.run(request)
        #expect(
            router.lastFallback
                == ProcessingFallback(direction: .localToCloud, cause: .notAvailable))
    }

    @Test func localFirstAfterAnOnDeviceFailureRecordsFailed() async throws {
        let router = AiModeRouter(
            local: CUFakeAiProvider(
                "local", failure: AiError.providerFailed("on-device model refused")),
            remote: CUFakeAiProvider("remote"),
            mode: { .localFirst })
        _ = try await router.run(request)
        #expect(router.lastFallback?.direction == .localToCloud)
        #expect(router.lastFallback?.cause == .failed)
    }

    @Test func remoteFirstFallingBackOnNoConnectionRecordsNoConnection() async throws {
        let router = AiModeRouter(
            local: CUFakeAiProvider("local"),
            remote: CUFakeAiProvider(
                "remote",
                failure: AiError.providerFailed(
                    "OpenAI request failed", underlying: URLError(.notConnectedToInternet))),
            mode: { .remoteFirst })
        _ = try await router.run(request)
        #expect(
            router.lastFallback
                == ProcessingFallback(direction: .cloudToLocal, cause: .noConnection))
    }

    @Test func remoteFirstFallingBackOnARejectedKeyRecordsNotAccepted() async throws {
        let router = AiModeRouter(
            local: CUFakeAiProvider("local"),
            remote: CUFakeAiProvider(
                "remote", failure: AiError.providerFailed("OpenAI chat failed (401): denied")),
            mode: { .remoteFirst })
        _ = try await router.run(request)
        #expect(
            router.lastFallback
                == ProcessingFallback(direction: .cloudToLocal, cause: .notAccepted))
    }

    /// Recovery clears it — the same property the transcription router has, and the reason the
    /// disclosure never has to be dismissed.
    @Test func recoveryOnThePreferredProviderClearsTheDisclosure() async throws {
        let local = CUFakeAiProvider("local", available: false)
        let router = AiModeRouter(
            local: local, remote: CUFakeAiProvider("remote"), mode: { .localFirst })
        _ = try await router.run(request)
        #expect(router.lastFallback != nil)

        local.available = true
        _ = try await router.run(request)
        #expect(router.lastFallback == nil)
    }

    /// `consentRequired` is re-thrown, never swallowed (plan Part 4.5), so it can never produce
    /// a fallback to disclose.
    @Test func consentRequiredNeverRecordsAFallback() async throws {
        let router = AiModeRouter(
            local: CUFakeAiProvider(
                "local", failure: AiError.consentRequired(providerId: "local")),
            remote: CUFakeAiProvider("remote"),
            mode: { .localFirst })
        await #expect(throws: (any Error).self) { _ = try await router.run(self.request) }
        #expect(router.lastFallback == nil)
    }
}
