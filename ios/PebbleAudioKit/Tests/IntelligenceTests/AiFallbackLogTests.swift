import Foundation
import Testing
import Transcription

@testable import Intelligence

// A First mode's fallback that ANSWERS used to leave no trace: failures were logged, successes
// were not, and the primary's error was reduced to a four-way cause. A Remote-first user whose
// every cloud call failed got every title from the on-device model and the device said nothing.

private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func append(_ line: String) { lock.withLock { _lines.append(line) } }
}

private final class ScriptedProvider: AiProvider, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var failure: Error?
    init(_ id: String, failure: Error? = nil) {
        self.id = id
        self.failure = failure
    }
    func fail(with error: Error?) { lock.withLock { failure = error } }
    func isAvailable() async -> Bool { true }
    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        if let failure = lock.withLock({ failure }) { throw failure }
        return AiProviderResult(text: "answer from \(id)", modelUsed: "\(id)-model")
    }
}

@Suite("AI fallback — every fallback that answers is on the record")
struct AiFallbackLogTests {
    private let request = AiRunRequest(
        requestId: "r",
        prompt: AiPromptTemplate(
            id: "summary", title: "Summary", systemPrompt: "Summarize.", userPrompt: "Go."),
        transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "the private words spoken")])

    private let rejected = AiError.providerFailed(
        "OpenAI responses request failed (401): Incorrect API key provided: sk-abcdef1234567890")

    @Test func aFallbackThatAnswersIsLoggedWithThePrimarysKindAndARedactedPrefix() async throws {
        let sink = LogSink()
        let router = AiModeRouter(
            local: ScriptedProvider("apple-foundation-models"),
            remote: ScriptedProvider("openai-chat", failure: rejected),
            mode: { .remoteFirst }, log: { sink.append($0) })

        let result = try await router.run(request)

        #expect(result.providerId == "apple-foundation-models")
        #expect(result.viaFallback)
        let line = try #require(sink.lines.first { $0.hasPrefix("ai fallback:") })
        #expect(line.contains("summary mode=RemoteFirst cloud=openai-chat failed (keyRejected)"))
        #expect(line.contains("answered by onDevice=apple-foundation-models"))
        #expect(line.contains("(401)"))
        // The key the body quoted back is redacted, and no transcript text ever reaches the log.
        #expect(line.contains("sk-***"))
        #expect(!line.contains("abcdef1234567890"))
        #expect(!line.contains("private words"))
        // Still the coarse disclosure Settings reads.
        #expect(router.lastFallback?.direction == .cloudToLocal)
    }

    @Test func aRepeatingFallbackIsLoggedOnceThenCountedEveryTenMinutes() async throws {
        let sink = LogSink()
        let clock = TestWallClock(ms: 1_000_000)
        let router = AiModeRouter(
            local: ScriptedProvider("local"),
            remote: ScriptedProvider("remote", failure: rejected),
            mode: { .remoteFirst }, log: { sink.append($0) },
            fallbackLogGate: RepeatingLogGate(intervalMs: 10 * 60_000, nowMs: { clock.now }))

        for _ in 0..<4 { _ = try await router.run(request) }
        #expect(sink.lines.filter { $0.hasPrefix("ai fallback:") }.count == 1)

        clock.advance(byMs: 10 * 60_000)
        _ = try await router.run(request)
        let lines = sink.lines.filter { $0.hasPrefix("ai fallback:") }
        #expect(lines.count == 2)
        #expect(lines.last?.contains("[3 more like it since the last line]") == true)
    }

    @Test func aDifferentCauseIsLoggedAtOnce() async throws {
        let sink = LogSink()
        let remote = ScriptedProvider("remote", failure: rejected)
        let router = AiModeRouter(
            local: ScriptedProvider("local"), remote: remote,
            mode: { .remoteFirst }, log: { sink.append($0) })

        _ = try await router.run(request)
        remote.fail(with: AiError.providerFailed("OpenAI responses request failed (429): slow"))
        _ = try await router.run(request)

        let lines = sink.lines.filter { $0.hasPrefix("ai fallback:") }
        #expect(lines.count == 2)
        #expect(lines.last?.contains("(rateLimited)") == true)
    }

    @Test func aWorkingPrimaryLogsNothing() async throws {
        let sink = LogSink()
        let router = AiModeRouter(
            local: ScriptedProvider("local"), remote: ScriptedProvider("remote"),
            mode: { .remoteFirst }, log: { sink.append($0) })
        let result = try await router.run(request)
        #expect(!result.viaFallback)
        #expect(sink.lines.isEmpty)
    }

    /// Local first, the mirror image: the on-device model failed and the cloud answered.
    @Test func localFirstNamesTheOnDeviceFailure() async throws {
        let sink = LogSink()
        let router = AiModeRouter(
            local: ScriptedProvider(
                "apple-foundation-models",
                failure: AiError.providerFailed("The on-device model is busy. Try again.")),
            remote: ScriptedProvider("openai-chat"),
            mode: { .localFirst }, log: { sink.append($0) })

        _ = try await router.run(request)

        let line = try #require(sink.lines.first)
        #expect(line.contains("onDevice=apple-foundation-models failed (modelBusy)"))
        #expect(line.contains("answered by cloud=openai-chat"))
    }
}
