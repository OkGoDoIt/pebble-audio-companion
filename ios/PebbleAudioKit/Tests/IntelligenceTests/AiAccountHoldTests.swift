import Foundation
import Testing
import Transcription

@testable import Intelligence

// The AI side of the account hold. The transcription side learned on 2026-09-23 what a dry
// account costs when every attempt pays in full to be told no; the AI side had no breaker at
// all — `isAvailable()` was consent + key, so a 402 was re-sent for every title in the backlog,
// every live refresh (45 s), every boundary review (every pass) and every Ask sweep part.

private final class ScriptedTransport: HttpTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [HttpTransportResponse]
    private var _bodies: [String] = []

    init(_ responses: [HttpTransportResponse]) { queue = responses }

    var requests: Int { lock.withLock { _bodies.count } }
    var bodies: [String] { lock.withLock { _bodies } }

    func push(_ response: HttpTransportResponse) { lock.withLock { queue.append(response) } }

    func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse {
        lock.withLock {
            _bodies.append(String(decoding: request.body ?? Data(), as: UTF8.self))
            return queue.isEmpty ? ok : queue.removeFirst()
        }
    }
}

private let ok = HttpTransportResponse(
    status: 200, text: #"{"output_text": "fine", "model": "gpt-5.6-luna"}"#)
private let outOfQuota = HttpTransportResponse(
    status: 429,
    text: #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","code":"insufficient_quota"}}"#)
private let badKey = HttpTransportResponse(
    status: 401, text: #"{"error":{"message":"Incorrect API key provided: sk-abc***xyz."}}"#)
private let noModelAccess = HttpTransportResponse(
    status: 403, text: #"{"error":{"message":"You are not allowed to sample from this model"}}"#)

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private struct OnDevice: AiProvider {
    let id = "apple-foundation-models"
    func isAvailable() async -> Bool { true }
    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        AiProviderResult(text: "from the phone", modelUsed: id)
    }
}

private let request = AiRunRequest(
    requestId: "r", prompt: SegmentAnnotationPrompt.template,
    transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "We talked about the trip.")])

@Suite("AI account hold — stop sending to an account that has said no")
struct AiAccountHoldTests {
    private func setup(
        _ responses: [HttpTransportResponse], clock: TestWallClock = TestWallClock(ms: 1_000_000)
    ) -> (OpenAiChatAiProvider, ScriptedTransport, CloudAccountHold, Box<String>) {
        let key = Box("sk-live-key")
        let transport = ScriptedTransport(responses)
        let hold = CloudAccountHold(
            fileURL: nil, apiKey: { _ in key.value }, nowMs: { clock.now })
        let provider = OpenAiChatAiProvider(
            transport: transport, apiKey: { key.value }, remoteConsent: { true },
            accountHold: hold, nowMs: { clock.now })
        return (provider, transport, hold, key)
    }

    @Test func anOutOfQuotaAnswerHoldsTheAccountAndNothingMoreIsSent() async throws {
        let (provider, transport, hold, _) = setup([outOfQuota])

        do {
            _ = try await provider.run(request)
            Issue.record("expected the refusal")
        } catch {
            #expect(AiFailure.classify(error).kind == .accountOutOfFunds)
        }
        #expect(hold.active(for: .openAi)?.kind == .accountOutOfFunds)
        #expect(await provider.isAvailable() == false)

        // A direct caller is told why — and nothing is sent.
        do {
            _ = try await provider.run(request)
            Issue.record("expected the held refusal")
        } catch {
            #expect(AiFailure.classify(error).kind == .accountOutOfFunds)
        }
        #expect(transport.requests == 1)
    }

    @Test func aRejectedKeyHoldsTheAccount() async throws {
        let (provider, _, hold, _) = setup([badKey])
        _ = try? await provider.run(request)
        #expect(hold.active(for: .openAi)?.kind == .keyRejected)
        #expect(await provider.isAvailable() == false)
    }

    /// A 403 on the AI side can be ONE model the key may not use. Holding the account for it
    /// would stop every other job that uses a model the key can.
    @Test func a403DoesNotHoldTheAccount() async throws {
        let (provider, _, hold, _) = setup([noModelAccess])
        _ = try? await provider.run(request)
        #expect(hold.active(for: .openAi) == nil)
        #expect(await provider.isAvailable())
    }

    @Test func aNewKeyReleasesTheHold() async throws {
        let (provider, _, _, key) = setup([outOfQuota])
        _ = try? await provider.run(request)
        #expect(await provider.isAvailable() == false)
        key.value = "sk-a-different-key"
        #expect(await provider.isAvailable())
    }

    /// Through the router: Remote first answers on the phone, Remote only says the real reason
    /// ("out of credit") instead of "no AI provider is available".
    @Test func theRouterFallsBackOrSaysWhyWhileTheAccountIsHeld() async throws {
        let (provider, transport, _, _) = setup([outOfQuota])
        _ = try? await provider.run(request)

        let remoteFirst = AiModeRouter(local: OnDevice(), remote: provider, mode: { .remoteFirst })
        let answered = try await remoteFirst.run(request)
        #expect(answered.providerId == "apple-foundation-models")
        #expect(answered.viaFallback)
        #expect(remoteFirst.lastFallback?.cause == .notAccepted)

        let remoteOnly = AiModeRouter(local: OnDevice(), remote: provider, mode: { .remoteOnly })
        do {
            _ = try await remoteOnly.run(request)
            Issue.record("expected the held refusal")
        } catch {
            #expect(AiFailure.classify(error).kind == .accountOutOfFunds)
        }
        #expect(transport.requests == 1)
    }

    // MARK: The probe

    @Test func theProbeRunsOnTheHoldsScheduleAndATopUpLiftsIt() async throws {
        let clock = TestWallClock(ms: 1_000_000)
        let (provider, transport, hold, _) = setup([outOfQuota], clock: clock)
        let lifted = Box(0)
        hold.onLifted { _ in lifted.value += 1 }
        _ = try? await provider.run(request)
        let router = AiModeRouter(local: nil, remote: provider, mode: { .remoteFirst })

        // Not yet: the first check is 15 minutes out, and nothing is sent before it.
        #expect(await router.probeHeldRemoteAccountIfDue(foreground: false) == nil)
        #expect(transport.requests == 1)

        clock.advance(byMs: CloudAccountHold.firstProbeDelayMs)
        #expect(await router.probeHeldRemoteAccountIfDue(foreground: false) == .accepted)
        #expect(transport.requests == 2)
        // The smallest request that can answer the question.
        let probe = try #require(transport.bodies.last)
        #expect(probe.contains(#""input":"ok""#))
        #expect(probe.contains(#""max_output_tokens":16"#))
        #expect(!probe.contains("We talked about the trip"))

        #expect(hold.active(for: .openAi) == nil)
        #expect(lifted.value == 1)
        #expect(await provider.isAvailable())
    }

    @Test func aStillRefusedProbeBacksOffFurther() async throws {
        let clock = TestWallClock(ms: 1_000_000)
        let (provider, transport, hold, _) = setup([outOfQuota, outOfQuota], clock: clock)
        _ = try? await provider.run(request)
        clock.advance(byMs: CloudAccountHold.firstProbeDelayMs)

        #expect(
            await provider.probeHeldAccountIfDue(foreground: false)
                == .refused(.accountOutOfFunds))
        let held = try #require(hold.active(for: .openAi))
        #expect(held.refusedProbes == 1)
        #expect(held.nextProbeAtMs == clock.now + CloudAccountHold.probeDelayMs(afterRefusedProbes: 1))
        #expect(await provider.probeHeldAccountIfDue(foreground: false) == nil)
        #expect(transport.requests == 2)
    }

    /// A Local-only user's parked OpenAI account is not worth a request.
    @Test func theProbeNeverRunsInLocalOnly() async throws {
        let clock = TestWallClock(ms: 1_000_000)
        let (provider, transport, _, _) = setup([outOfQuota], clock: clock)
        _ = try? await provider.run(request)
        clock.advance(byMs: CloudAccountHold.maxProbeDelayMs)
        let router = AiModeRouter(local: OnDevice(), remote: provider, mode: { .localOnly })
        #expect(await router.probeHeldRemoteAccountIfDue(foreground: true) == nil)
        #expect(transport.requests == 1)
    }

    // MARK: 429 — busy, not broke

    @Test func aRateLimitWaitsOutItsRetryAfterAndHoldsNothing() async throws {
        let clock = TestWallClock(ms: 1_000_000)
        let slowDown = HttpTransportResponse(
            status: 429, text: #"{"error":{"message":"Rate limit reached for requests"}}"#,
            headers: ["Retry-After": "120"])
        let (provider, transport, hold, _) = setup([slowDown], clock: clock)

        _ = try? await provider.run(request)
        #expect(hold.active(for: .openAi) == nil)
        #expect(await provider.isAvailable() == false)
        do {
            _ = try await provider.run(request)
            Issue.record("expected the wait")
        } catch {
            #expect(AiFailure.classify(error).kind == .rateLimited)
        }
        #expect(transport.requests == 1)

        clock.advance(byMs: 120_000)
        #expect(await provider.isAvailable())
        _ = try await provider.run(request)
        #expect(transport.requests == 2)
    }

    @Test func retryAfterIsReadInEveryShapeItComesIn() {
        let now: Int64 = 1_790_000_000_000
        #expect(
            OpenAiChatAiProvider.retryAfterMs(
                HttpTransportResponse(status: 429, text: "", headers: ["retry-after": "7"]),
                nowMs: now) == 7_000)
        #expect(
            OpenAiChatAiProvider.retryAfterMs(
                HttpTransportResponse(status: 429, text: "", headers: ["retry-after-ms": "250"]),
                nowMs: now) == 250)
        let date = Date(timeIntervalSince1970: Double(now) / 1_000 + 90)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let http = formatter.string(from: date)
        #expect(
            OpenAiChatAiProvider.retryAfterMs(
                HttpTransportResponse(status: 429, text: "", headers: ["Retry-After": http]),
                nowMs: now) == 90_000)
        #expect(
            OpenAiChatAiProvider.retryAfterMs(
                HttpTransportResponse(status: 429, text: ""), nowMs: now) == nil)
    }
}
