import Foundation
import Testing
import Transcription

@testable import Intelligence

// AI calls that could hang, and what happens when they do.
//
// An Apple model session has no timer: a generation that never returned held the pipeline pass
// until the loop watchdog restarted the whole loop. A cloud call had `URLSession.shared`'s 60 s
// idle timer, which killed every non-streaming call that thought for longer than a minute. And a
// whole-input request the cloud timed out on was handed to the on-device model, which could only
// refuse it after building it.

private struct Stuck: Error {}

private final class HangingModel: OnDeviceLanguageModel, @unchecked Sendable {
    let id = "hanging"
    func availability() async -> OnDeviceAvailability { .available }
    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String
    {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return "too late"
    }
}

private final class CountingProvider: AiProvider, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var _calls = 0
    private let failure: Error?
    init(_ id: String, failure: Error? = nil) {
        self.id = id
        self.failure = failure
    }
    var calls: Int { lock.withLock { _calls } }
    func isAvailable() async -> Bool { true }
    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        lock.withLock { _calls += 1 }
        if let failure { throw failure }
        return AiProviderResult(text: "answer", modelUsed: id)
    }
}

private func request(_ template: AiPromptTemplate) -> AiRunRequest {
    AiRunRequest(
        requestId: "r", prompt: template,
        transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "We planned the launch.")])
}

@Suite("AI deadlines — nothing waits forever, and a timed-out whole input is not re-handed")
struct AiDeadlineTests {
    @Test func aDeadlineThatPassesThrowsWithoutWaitingForTheWork() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await AiTimeout.run(milliseconds: 50, timeout: { Stuck() }) {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return 1
            }
            Issue.record("expected the deadline")
        } catch is Stuck {}
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func workThatFinishesInTimeIsReturned() async throws {
        let value = try await AiTimeout.run(milliseconds: 5_000, timeout: { Stuck() }) { 42 }
        #expect(value == 42)
    }

    @Test func theCallersCancellationReachesTheWork() async throws {
        let task = Task {
            try await AiTimeout.run(milliseconds: 60_000, timeout: { Stuck() }) {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return 1
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("expected cancellation")
            return
        }
        #expect(error is CancellationError)
    }

    /// A hung on-device generation is an ordinary, classified failure — not a wedged pass.
    @Test func aHungOnDeviceGenerationTimesOutAsTimedOut() async throws {
        let provider = OnDeviceAiProvider(model: HangingModel(), generationTimeoutMs: 50)
        let started = ContinuousClock.now
        do {
            _ = try await provider.run(request(SegmentAnnotationPrompt.template))
            Issue.record("expected the deadline")
        } catch {
            #expect(AiFailure.classify(error).kind == .timedOut)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// Local first: a hung on-device model falls back to the cloud like any other failure.
    @Test func localFirstFallsBackFromAHungModel() async throws {
        let cloud = CountingProvider("cloud")
        let router = AiModeRouter(
            local: OnDeviceAiProvider(model: HangingModel(), generationTimeoutMs: 50),
            remote: cloud, mode: { .localFirst })
        let result = try await router.run(request(SegmentAnnotationPrompt.template))
        #expect(result.providerId == "cloud")
        #expect(cloud.calls == 1)
    }

    // MARK: No fallback for a whole input the cloud dropped

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost])
    func aWholeInputRequestTheCloudDroppedIsNotHandedToThePhone(_ code: URLError.Code)
        async throws
    {
        let phone = CountingProvider("phone")
        let router = AiModeRouter(
            local: phone, remote: CountingProvider("cloud", failure: URLError(code)),
            mode: { .remoteFirst })
        do {
            _ = try await router.run(request(AiPromptTemplates.ask))
            Issue.record("expected the cloud's failure")
        } catch {
            #expect((error as? URLError)?.code == code)
        }
        #expect(phone.calls == 0)
    }

    /// Anything else still falls back as before — a title is fine from the phone.
    @Test func aGistRequestTheCloudDroppedStillFallsBack() async throws {
        let phone = CountingProvider("phone")
        let router = AiModeRouter(
            local: phone, remote: CountingProvider("cloud", failure: URLError(.timedOut)),
            mode: { .remoteFirst })
        let result = try await router.run(request(SegmentAnnotationPrompt.template))
        #expect(result.providerId == "phone")
    }

    /// A cloud call that failed for another reason is still the fallback's to try, whatever
    /// the template.
    @Test func aWholeInputRequestTheCloudRefusedStillFallsBack() async throws {
        let phone = CountingProvider("phone")
        let router = AiModeRouter(
            local: phone,
            remote: CountingProvider(
                "cloud",
                failure: AiError.providerFailed("OpenAI responses request failed (503): busy")),
            mode: { .remoteFirst })
        _ = try await router.run(request(AiPromptTemplates.ask))
        #expect(phone.calls == 1)
    }

    // MARK: The transport

    @Test func aiRequestsWaitLongerThanTheSharedSessionsMinute() {
        let configuration = AiHttpTransport.sessionConfiguration()
        #expect(configuration.timeoutIntervalForRequest == 240)
        #expect(configuration.timeoutIntervalForResource == 300)
        #expect(configuration.timeoutIntervalForRequest > URLSessionConfiguration.default.timeoutIntervalForRequest)
        #expect(configuration.waitsForConnectivity == false)
    }
}
