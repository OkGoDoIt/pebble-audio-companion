import Foundation
import Testing

@testable import Intelligence

// Port of `core/ai/src/commonTest/.../OnDeviceAiProviderTest.kt` — all 7 cases, same names.

private final class FakeOnDeviceModel: OnDeviceLanguageModel, @unchecked Sendable {
    let id: String

    private let lock = NSLock()
    private var _availability: OnDeviceAvailability
    private var _response: String
    private var _error: Error?
    private var _lastInstructions: String?
    private var _lastPrompt: String?
    private var _lastMaxOutputTokens: Int?
    private var _runCount = 0

    init(
        availability: OnDeviceAvailability = .available,
        response: String = "TITLE: Team sync\nSUMMARY: Discussed the plan.",
        error: Error? = nil,
        id: String = "fake-on-device"
    ) {
        self._availability = availability
        self._response = response
        self._error = error
        self.id = id
    }

    var response: String {
        get { lock.withLock { _response } }
        set { lock.withLock { _response = newValue } }
    }
    var lastInstructions: String? { lock.withLock { _lastInstructions } }
    var lastPrompt: String? { lock.withLock { _lastPrompt } }
    var lastMaxOutputTokens: Int? { lock.withLock { _lastMaxOutputTokens } }
    var runCount: Int { lock.withLock { _runCount } }

    func availability() async -> OnDeviceAvailability { lock.withLock { _availability } }

    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String
    {
        let error: Error? = lock.withLock {
            _runCount += 1
            _lastInstructions = instructions
            _lastPrompt = prompt
            _lastMaxOutputTokens = maxOutputTokens
            return _error
        }
        if let error { throw error }
        return response
    }
}

private struct NanoBoom: LocalizedError {
    var errorDescription: String? { "nano boom" }
}

@Suite struct OnDeviceProviderTests {
    private func request(text: String = "We agreed Bob ships the fix Friday.") -> AiRunRequest {
        AiRunRequest(
            requestId: "ai-1",
            prompt: SegmentAnnotationPrompt.template,
            transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: text)]
        )
    }

    @Test func unavailableWhenNoModelInjected() async throws {
        let provider = OnDeviceAiProvider(model: nil)
        #expect(await provider.isAvailable() == false)
        do {
            _ = try await provider.run(request())
            Issue.record("expected ProviderUnavailable")
        } catch AiError.providerUnavailable {
            // expected
        }
    }

    @Test func unavailableForEveryNonAvailableStatus() async throws {
        for status in
            [OnDeviceAvailability.downloadable, .downloading, .unavailable]
        {
            let model = FakeOnDeviceModel(availability: status)
            let provider = OnDeviceAiProvider(model: model)
            #expect(await provider.isAvailable() == false, "status \(status) must be unavailable")
            do {
                _ = try await provider.run(request())
                Issue.record("expected ProviderUnavailable for status \(status)")
            } catch AiError.providerUnavailable {
                // expected
            }
            #expect(model.runCount == 0, "must not generate when unavailable")
        }
    }

    @Test func generatesWithInstructionsPromptAndModelId() async throws {
        let model = FakeOnDeviceModel()
        let provider = OnDeviceAiProvider(model: model)

        let result = try await provider.run(request())

        #expect(result.text == "TITLE: Team sync\nSUMMARY: Discussed the plan.")
        #expect(result.modelUsed == "fake-on-device")
        #expect(model.lastInstructions == SegmentAnnotationPrompt.template.systemPrompt)
        let prompt = try #require(model.lastPrompt)
        #expect(prompt.contains("seg-1"), "prompt should carry the segment id")
        #expect(
            prompt.contains("We agreed Bob ships the fix Friday."),
            "prompt should carry the transcript text")
        #expect((model.lastMaxOutputTokens ?? 0) > 0, "should pass an output cap")
    }

    @Test func emptyCompletionFails() async throws {
        let provider = OnDeviceAiProvider(model: FakeOnDeviceModel(response: "   "))
        do {
            _ = try await provider.run(request())
            Issue.record("expected ProviderFailed")
        } catch AiError.providerFailed {
            // expected
        }
    }

    @Test func generationErrorBecomesProviderFailed() async throws {
        let provider = OnDeviceAiProvider(model: FakeOnDeviceModel(error: NanoBoom()))
        do {
            _ = try await provider.run(request())
            Issue.record("expected ProviderFailed")
        } catch AiError.providerFailed(let message, _) {
            #expect(message.contains("On-device"))
        }
    }

    @Test func oversizedTranscriptIsTruncated() async throws {
        let model = FakeOnDeviceModel()
        let provider = OnDeviceAiProvider(model: model, maxInputChars: 500)

        _ = try await provider.run(request(text: String(repeating: "word ", count: 1_000)))

        let prompt = try #require(model.lastPrompt)
        #expect(prompt.contains("transcript truncated for length"))
        #expect(prompt.count <= 600)
    }

    @Test func routesAsLocalProviderWithFallback() async throws {
        // On-device is the router's local provider; LocalOnly uses it directly.
        let onDevice = OnDeviceAiProvider(
            model: FakeOnDeviceModel(response: "TITLE: Local\nSUMMARY: x."))
        let router = AiModeRouter(local: onDevice, remote: nil, mode: { .localOnly })

        let result = try await router.run(request())
        #expect(result.text == "TITLE: Local\nSUMMARY: x.")
        #expect(result.modeUsed == .localOnly)
        #expect(result.providerId == "fake-on-device")
    }
}
