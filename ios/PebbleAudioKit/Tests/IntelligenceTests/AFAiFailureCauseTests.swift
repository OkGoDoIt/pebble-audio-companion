import Foundation
import Testing

@testable import Intelligence

// AF · "the message names the wrong provider".
//
// The reported bug, reduced to its mechanism: Remote first, a four-hour conversation, and the
// dock says "Extended summary didn't finish — On-device AI generation failed" while remote AI is
// switched ON. Both halves are covered here — the router surfacing the fallback instead of the
// primary, and the guard that dropped the primary entirely when the fallback was unavailable.

private final class AFFakeProvider: AiProvider, @unchecked Sendable {
    let id: String
    private let available: Bool
    private let lock = NSLock()
    private var _failure: Error?

    init(_ id: String, available: Bool = true, failure: Error? = nil) {
        self.id = id
        self.available = available
        self._failure = failure
    }

    /// Settable so one router can be watched across a change of cause — which is the only way to
    /// test that a streak's count is carried out when the situation changes.
    var failure: Error? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    func isAvailable() async -> Bool { available }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        if let failure { throw failure }
        return AiProviderResult(text: "text-\(id)", modelUsed: "\(id)-model")
    }
}

@Suite("AF · the failure a person is shown")
struct AFAiFailureCauseTests {
    private let request = AiRunRequest(
        requestId: "run-1",
        prompt: AiPromptTemplates.extendedSummary,
        transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "hello world")]
    )

    /// A rejected key, then an on-device model that also fails. What escapes must be the 401.
    @Test func remoteFirstSurfacesTheCloudCauseNotTheFallbacks() async throws {
        let router = AiModeRouter(
            remoteFailure: AiError.providerFailed(
                "OpenAI responses request failed (401): incorrect api key"),
            localFailure: AiError.providerFailed(
                "On-device AI generation failed.", underlying: URLError(.unknown)),
            mode: .remoteFirst
        )

        do {
            _ = try await router.run(request)
            Issue.record("expected a failure")
        } catch {
            let failure = AiFailure.classify(error)
            #expect(failure.kind == .keyRejected)
            // The fallback is not lost, it is demoted.
            #expect(failure.fallback?.origin == .onDevice)
            #expect(failure.fallback?.kind == .unknown)
        }
    }

    /// The dropped-primary guard. Before: `providerUnavailable(local)`, i.e. "no AI provider is
    /// available", to a person whose remote AI is on and whose key is the actual problem.
    @Test func anUnavailableFallbackDoesNotEraseThePrimary() async throws {
        let router = AiModeRouter(
            local: AFFakeProvider("apple-foundation-models", available: false),
            remote: AFFakeProvider(
                "openai-chat",
                failure: AiError.providerFailed("OpenAI responses request failed (429): slow")),
            mode: { .remoteFirst }
        )

        do {
            _ = try await router.run(request)
            Issue.record("expected a failure")
        } catch {
            #expect(AiFailure.classify(error).kind == .rateLimited)
        }
    }

    /// The mirror image, so the rule is "the provider you chose", not "the cloud".
    @Test func localFirstSurfacesTheOnDeviceCause() async throws {
        let router = AiModeRouter(
            remoteFailure: AiError.providerFailed("OpenAI responses request failed (500): oops"),
            localFailure: AiError.providerFailed(
                "This recording is \(AiFailure.Marker.tooLongForDevice) It would fit about 4877 "
                    + "of its 157639 characters."),
            mode: .localFirst
        )

        do {
            _ = try await router.run(request)
            Issue.record("expected a failure")
        } catch {
            let failure = AiFailure.classify(error)
            #expect(failure.kind == .tooLongForDevice)
            #expect(failure.fallback?.origin == .cloud)
            #expect(failure.fallback?.kind == .providerTrouble)
        }
    }

    /// A fallback that SUCCEEDS is still just a fallback. The calm disclosure must not start
    /// reading as an error because the failure plumbing changed underneath it.
    @Test func aSuccessfulFallbackStillOnlyDisclosesAFallback() async throws {
        let router = AiModeRouter(
            local: AFFakeProvider("apple-foundation-models"),
            remote: AFFakeProvider(
                "openai-chat",
                failure: AiError.providerFailed("OpenAI responses request failed (401): denied")),
            mode: { .remoteFirst }
        )

        let result = try await router.run(request)

        #expect(result.providerId == "apple-foundation-models")
        #expect(router.lastFallback?.direction == .cloudToLocal)
        #expect(router.lastFallback?.cause == .notAccepted)
    }

    /// Consent is never swallowed, and a fallback's failure must not turn it into something else.
    @Test func consentStillNeverFallsBack() async throws {
        let router = AiModeRouter(
            remoteFailure: AiError.consentRequired(providerId: "openai-chat"),
            localFailure: AiError.providerFailed("On-device AI generation failed."),
            mode: .remoteFirst
        )

        do {
            _ = try await router.run(request)
            Issue.record("expected consentRequired")
        } catch AiError.consentRequired {
            // expected
        }
    }

    // MARK: - The log line

    /// AI failures reached no log at all before this: the device's `companion.log` carried link,
    /// session, heartbeat and cloud transcription lines, and nothing about a failed note.
    @Test func aFailureIsWrittenToTheRuntimeLogWithNoTranscriptText() async throws {
        let lines = AFLogSink()
        let router = AiModeRouter(
            local: AFFakeProvider("apple-foundation-models", available: false),
            remote: AFFakeProvider(
                "openai-chat",
                failure: AiError.providerFailed("OpenAI responses request failed (401): denied")),
            mode: { .remoteFirst },
            log: { lines.append($0) }
        )

        _ = try? await router.run(request)

        let line = try #require(lines.all.first)
        #expect(line.contains("ai failed: extended-summary"))
        #expect(line.contains("mode=RemoteFirst"))
        #expect(line.contains("cloud=openai-chat"))
        #expect(line.contains("keyRejected"))
        #expect(!line.contains("hello world"), "transcript text must never reach the log")
    }

    /// The raw provider body is kept — it is the only thing that distinguishes a wrong key from
    /// an empty account — but this log is a file the user exports and sends to somebody, and a
    /// 401 body quotes the key back at us.
    @Test func aKeyInAProvidersErrorBodyIsRedactedBeforeItReachesTheLog() {
        let line = AiFailureLog.line(
            templateId: "extended-summary", mode: .remoteOnly, providerId: "openai-chat",
            origin: .cloud,
            error: AiError.providerFailed(
                "OpenAI responses request failed (401): {\"message\":\"Incorrect API key "
                    + "provided: sk-proj-abcdef123456.\"}"))

        #expect(line.contains("sk-***"))
        #expect(!line.contains("abcdef123456"))
        // The status survives, because it is what makes the line diagnosable.
        #expect(line.contains("(401)"))
    }

    /// A broken key fails every job, not one. 145 copies of one line would push everything else
    /// out of the 400-line ring the Detailed Logs screen tails, so a streak is counted.
    @Test func repeatedIdenticalFailuresAreCountedRatherThanRepeated() async throws {
        let lines = AFLogSink()
        let remote = AFFakeProvider(
            "openai-chat",
            failure: AiError.providerFailed("OpenAI responses request failed (401): denied"))
        let router = AiModeRouter(
            local: nil, remote: remote, mode: { .remoteOnly }, log: { lines.append($0) })

        for _ in 0..<20 { _ = try? await router.run(request) }
        #expect(lines.all.count == 1, "twenty identical failures are one line, not twenty")

        // A different cause is news, and it arrives behind the count of what it replaced.
        remote.failure = AiError.providerFailed("OpenAI responses request failed (429): slow")
        _ = try? await router.run(request)
        #expect(lines.all.count == 3)
        #expect(lines.all[1].contains("and 19 more the same"))
        #expect(lines.all[2].contains("rateLimited"))

        // And a run that works closes the streak, so the next 401 is reported afresh.
        remote.failure = nil
        _ = try? await router.run(request)
        remote.failure = AiError.providerFailed("OpenAI responses request failed (429): slow")
        _ = try? await router.run(request)
        #expect(lines.all.count == 4)
    }

    /// Stopping a note is the user's own doing. It is not a failure and must not fill the ring.
    @Test func cancellationIsNotLogged() async throws {
        let lines = AFLogSink()
        let router = AiModeRouter(
            local: nil,
            remote: AFFakeProvider("openai-chat", failure: CancellationError()),
            mode: { .remoteOnly },
            log: { lines.append($0) }
        )

        _ = try? await router.run(request)

        #expect(lines.all.isEmpty)
    }
}

// MARK: - Support

private final class AFLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

extension AiModeRouter {
    /// Both providers present, both failing — the shape every case above needs.
    fileprivate convenience init(
        remoteFailure: Error, localFailure: Error, mode: AiProcessingMode
    ) {
        self.init(
            local: AFFakeProvider("apple-foundation-models", failure: localFailure),
            remote: AFFakeProvider("openai-chat", failure: remoteFailure),
            mode: { mode }
        )
    }
}
