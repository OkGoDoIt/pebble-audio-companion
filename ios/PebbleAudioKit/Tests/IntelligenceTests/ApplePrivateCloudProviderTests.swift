import Foundation
import Testing
import Transcription

@testable import Intelligence

// Apple Private Cloud Compute as the remote slot: what it refuses, what it names, and how the
// router falls back around it. Nothing here touches iOS 27 or the framework — the seam is
// `ApplePrivateCloudLanguageModel`, and the fake below plays every part the real model can.

private final class FakePrivateCloudModel: ApplePrivateCloudLanguageModel, @unchecked Sendable {
    let id = "fake-pcc"
    private let lock = NSLock()
    private var _availability: ApplePrivateCloudAvailability
    private var _quota: ApplePrivateCloudQuota?
    private var _window: Int
    private var _failure: Error?
    private var _lastPrompt: String?
    private var _lastInstructions: String?
    private var _lastShape: OnDeviceStructuredShape?
    private var _lastMaxOutputTokens: Int?
    private var _proseCalls = 0
    private var _structuredCalls = 0

    init(
        availability: ApplePrivateCloudAvailability = .available,
        quota: ApplePrivateCloudQuota? = ApplePrivateCloudQuota(
            status: .belowLimit(approaching: false)),
        window: Int = ApplePrivateCloudAiProvider.defaultContextTokens,
        failure: Error? = nil
    ) {
        _availability = availability
        _quota = quota
        _window = window
        _failure = failure
    }

    var lastPrompt: String? { lock.withLock { _lastPrompt } }
    var lastInstructions: String? { lock.withLock { _lastInstructions } }
    var lastShape: OnDeviceStructuredShape? { lock.withLock { _lastShape } }
    var lastMaxOutputTokens: Int? { lock.withLock { _lastMaxOutputTokens } }
    var proseCalls: Int { lock.withLock { _proseCalls } }
    var structuredCalls: Int { lock.withLock { _structuredCalls } }

    func availability() async -> ApplePrivateCloudAvailability { lock.withLock { _availability } }
    func quota() async -> ApplePrivateCloudQuota? { lock.withLock { _quota } }
    func contextWindowTokens() async -> Int { lock.withLock { _window } }

    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String
    {
        let failure: Error? = lock.withLock {
            _proseCalls += 1
            _lastInstructions = instructions
            _lastPrompt = prompt
            _lastMaxOutputTokens = maxOutputTokens
            return _failure
        }
        if let failure { throw failure }
        return "TITLE: Roadmap\nSUMMARY: Moved to Thursday."
    }

    func generateStructured(
        _ shape: OnDeviceStructuredShape, instructions: String, prompt: String,
        maxOutputTokens: Int?
    ) async throws -> String {
        let failure: Error? = lock.withLock {
            _structuredCalls += 1
            _lastShape = shape
            _lastInstructions = instructions
            _lastPrompt = prompt
            _lastMaxOutputTokens = maxOutputTokens
            return _failure
        }
        if let failure { throw failure }
        return #"{"items":[]}"#
    }
}

private final class FakeLocalProvider: AiProvider, @unchecked Sendable {
    let id = "local-fake"
    func isAvailable() async -> Bool { true }
    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        AiProviderResult(text: "local answer", modelUsed: "local-model")
    }
}

private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func record(_ line: String) { lock.withLock { _lines.append(line) } }
}

@Suite("Apple Private Cloud Compute provider")
struct ApplePrivateCloudProviderTests {
    private func request(
        _ template: AiPromptTemplate = SegmentAnnotationPrompt.template,
        text: String = "Dana: send the deck by Wednesday night.",
        structured: Bool = false
    ) -> AiRunRequest {
        AiRunRequest(
            requestId: "pcc-1",
            prompt: template,
            transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: text)],
            metadata: structured ? [AiRunRequest.requiresStructuredOutputKey: "1"] : [:]
        )
    }

    private func provider(
        _ model: FakePrivateCloudModel?,
        consent: Bool = true,
        status: ApplePrivateCloudBuildStatus = ApplePrivateCloudBuildStatus(entitled: true),
        grounding: String? = nil,
        log: LogSink = LogSink()
    ) -> ApplePrivateCloudAiProvider {
        ApplePrivateCloudAiProvider(
            model: model, remoteConsent: { consent }, grounding: { grounding },
            buildStatus: status, log: { log.record($0) })
    }

    private func kind(_ error: Error) -> AiFailureKind { AiFailure.classify(error).kind }

    // MARK: Availability

    @Test func unavailableWithoutConsentAModelOrReadiness() async {
        #expect(await provider(FakePrivateCloudModel(), consent: false).isAvailable() == false)
        #expect(await provider(nil).isAvailable() == false)
        #expect(
            await provider(FakePrivateCloudModel(availability: .systemNotReady)).isAvailable()
                == false)
        #expect(
            await provider(FakePrivateCloudModel(availability: .deviceNotEligible)).isAvailable()
                == false)
        #expect(await provider(FakePrivateCloudModel()).isAvailable() == true)
    }

    /// The one failure that never falls back, exactly as OpenAI's: consent is not a provider
    /// fault, it is the person's decision.
    @Test func consentOffThrowsConsentRequired() async throws {
        do {
            _ = try await provider(FakePrivateCloudModel(), consent: false).run(request())
            Issue.record("expected consentRequired")
        } catch AiError.consentRequired(let id) {
            #expect(id == "apple-pcc")
        }
    }

    @Test func readinessReportsWhatTheModelSaysUntilABuildFailureCorrectsIt() async {
        let status = ApplePrivateCloudBuildStatus(entitled: true)
        let ready = provider(FakePrivateCloudModel(), status: status)
        #expect(await ready.availability() == .available)
        #expect(await provider(nil).availability() == .unsupported)
        #expect(
            await provider(FakePrivateCloudModel(availability: .deviceNotEligible))
                .availability() == .deviceNotEligible)
        status.markNotEnabled()
        #expect(await ready.availability() == .notEnabledForThisBuild)
        #expect(await ready.isAvailable() == false)
    }

    /// THE guard for iOS 27, where a request without the entitlement traps the process instead
    /// of throwing: a build the signature did not entitle never reaches the model at all — not
    /// for a request, not for its quota, not for its window — and says so once in the log.
    @Test func anUnentitledBuildNeverTouchesTheModel() async throws {
        let log = LogSink()
        let model = FakePrivateCloudModel()
        let status = ApplePrivateCloudBuildStatus(entitled: false)
        let provider = provider(model, status: status, log: log)

        #expect(status.isKnownNotEnabled)
        #expect(await provider.isAvailable() == false)
        #expect(await provider.availability() == .notEnabledForThisBuild)
        #expect(await provider.quota() == nil)
        #expect(await provider.contextTokens() == ApplePrivateCloudAiProvider.defaultContextTokens)
        for _ in 0..<3 {
            do {
                _ = try await provider.run(request())
                Issue.record("expected providerUnavailable")
            } catch AiError.providerUnavailable(let id) {
                #expect(id == "apple-pcc")
            }
        }
        #expect(model.proseCalls == 0)
        #expect(model.structuredCalls == 0)
        let refusals = log.lines.filter { $0.contains("not enabled for this build") }
        #expect(refusals.count == 1)
        #expect(refusals.first?.contains("no request sent") == true)
    }

    // MARK: Naming the failures

    @Test func aUsedUpAllowanceIsAUsageLimitEverywhere() async throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let log = LogSink()
        let provider = provider(
            FakePrivateCloudModel(
                failure: ApplePrivateCloudFailure.quotaLimitReached(resetDate: reset)),
            log: log)
        do {
            _ = try await provider.run(request())
            Issue.record("expected a failure")
        } catch {
            #expect(kind(error) == .usageLimit)
            guard case AiError.providerFailed(let message, _) = error else {
                Issue.record("expected providerFailed"); return
            }
            #expect(ProcessingFallbackCause.classify(message) == .usageLimit)
            // Never read as an account out of money, which is what "quota" wording becomes.
            #expect(TranscriptionFailureKind.classify(message) != .accountOutOfFunds)
            #expect(message.contains("2027"))
        }
        #expect(log.lines.contains { $0.hasPrefix("apple pcc: usage limit reached") })
    }

    @Test func aNetworkFailureIsNoConnection() async throws {
        let provider = provider(
            FakePrivateCloudModel(failure: ApplePrivateCloudFailure.networkFailure("offline")))
        do {
            _ = try await provider.run(request())
            Issue.record("expected a failure")
        } catch {
            #expect(kind(error) == .noConnection)
        }
    }

    @Test func serviceDownIsUnavailableAndLogged() async throws {
        let log = LogSink()
        let provider = provider(
            FakePrivateCloudModel(
                failure: ApplePrivateCloudFailure.serviceUnavailable("maintenance")),
            log: log)
        do {
            _ = try await provider.run(request())
            Issue.record("expected a failure")
        } catch AiError.providerUnavailable(let id) {
            #expect(id == "apple-pcc")
        }
        #expect(log.lines.contains { $0.contains("service unavailable") && $0.contains("maintenance") })
        // Transient: the build is not marked.
        #expect(await provider.availability() == .available)
    }

    /// The path this build will actually take on an iOS 27 phone: the framework says ready, the
    /// request fails for want of the entitlement, and from then on the provider is unavailable
    /// — a First mode goes straight to its fallback instead of paying a doomed round trip per
    /// job, and Settings can say why.
    @Test func aMissingEntitlementIsRememberedForTheBuild() async throws {
        let log = LogSink()
        let status = ApplePrivateCloudBuildStatus(entitled: true)
        let model = FakePrivateCloudModel(
            failure: ApplePrivateCloudFailure.notEnabledForThisBuild(
                "LanguageModelError -1 > ModelManagerError 1046"))
        let provider = provider(model, status: status, log: log)
        #expect(await provider.isAvailable() == true)

        do {
            _ = try await provider.run(request())
            Issue.record("expected a failure")
        } catch AiError.providerUnavailable {
            // expected
        }

        #expect(status.isKnownNotEnabled)
        #expect(await provider.isAvailable() == false)
        #expect(await provider.availability() == .notEnabledForThisBuild)
        #expect(log.lines.contains { $0.contains("not enabled for this build") && $0.contains("1046") })
        // And the second request does not reach the model at all.
        do {
            _ = try await provider.run(request())
        } catch AiError.providerUnavailable {
            // expected
        }
        #expect(model.proseCalls == 1)
    }

    @Test func generationVerdictsKeepTheCloudsName() async throws {
        let cases: [(OnDeviceGenerationFailure, AiFailureKind)] = [
            (.contentRefused, .cloudContentRefused),
            (.busy, .rateLimited),
            // The framework's own detail is carried, so a timeout still reads as one.
            (.other("request timeout"), .timedOut),
            (.other("something new"), .unknown),
            (.contextWindowExceeded("9160 tokens"), .unknown),
        ]
        for (failure, expected) in cases {
            let provider = provider(
                FakePrivateCloudModel(failure: ApplePrivateCloudFailure.generation(failure)))
            do {
                _ = try await provider.run(request())
                Issue.record("expected a failure for \(failure)")
            } catch {
                #expect(kind(error) == expected, "\(failure) should classify as \(expected)")
                if case AiError.providerFailed(let message, _) = error {
                    #expect(!message.lowercased().contains("on-device"))
                }
            }
        }
    }

    // MARK: The router falls back per mode exactly as it does for OpenAI

    @Test func remoteFirstFallsBackToLocalOnAUsageLimitAndSaysSo() async throws {
        let router = AiModeRouter(
            local: FakeLocalProvider(),
            remote: provider(
                FakePrivateCloudModel(
                    failure: ApplePrivateCloudFailure.quotaLimitReached(resetDate: nil))),
            mode: { .remoteFirst })

        let result = try await router.run(request())

        #expect(result.providerId == "local-fake")
        #expect(router.lastFallback == ProcessingFallback(direction: .cloudToLocal, cause: .usageLimit))
    }

    @Test func remoteFirstFallsBackOnAMissingEntitlementAsNotAvailable() async throws {
        let router = AiModeRouter(
            local: FakeLocalProvider(),
            remote: provider(
                FakePrivateCloudModel(
                    failure: ApplePrivateCloudFailure.notEnabledForThisBuild("1046"))),
            mode: { .remoteFirst })

        let result = try await router.run(request())

        #expect(result.providerId == "local-fake")
        #expect(
            router.lastFallback == ProcessingFallback(direction: .cloudToLocal, cause: .notAvailable))
    }

    @Test func remoteOnlyNeverFallsBack() async throws {
        let router = AiModeRouter(
            local: FakeLocalProvider(),
            remote: provider(
                FakePrivateCloudModel(
                    failure: ApplePrivateCloudFailure.quotaLimitReached(resetDate: nil))),
            mode: { .remoteOnly })
        do {
            _ = try await router.run(request())
            Issue.record("expected a failure")
        } catch {
            #expect(kind(error) == .usageLimit)
        }
        #expect(router.lastFallback == nil)
    }

    // MARK: What the model is handed

    @Test func aShapedRequestGoesToGuidedGenerationAndABoundaryReviewToProse() async throws {
        let model = FakePrivateCloudModel()
        let provider = provider(model)

        _ = try await provider.run(
            request(AiPromptTemplates.followUpExtraction, structured: true))
        #expect(model.lastShape == .followUps)
        #expect(model.structuredCalls == 1)

        _ = try await provider.run(request(BoundaryPromptTemplates.boundaryReview, structured: true))
        #expect(model.proseCalls == 1)
    }

    @Test func groundingIsPrependedAndTheOutputCapIsTheCloudOne() async throws {
        let model = FakePrivateCloudModel()
        _ = try await provider(model, grounding: "Known people: Dana, Priya.")
            .run(request(AiPromptTemplates.extendedSummary))
        #expect(try #require(model.lastInstructions).hasPrefix("Known people: Dana, Priya."))
        #expect(
            model.lastMaxOutputTokens
                == CloudOutputBudget.maxOutputTokens(forTemplateId: "extended-summary"))
    }

    /// Sized to ITS window, not the on-device one: a conversation the 4,096-token budget would
    /// cut to a few thousand characters goes through at tens of thousands — and one that is
    /// genuinely too long is still cut, with the marker, rather than overflowing.
    @Test func inputIsSizedToTheCloudWindow() async throws {
        let model = FakePrivateCloudModel()
        let provider = provider(model)

        _ = try await provider.run(
            request(text: String(repeating: "word ", count: 8_000)))
        let medium = try #require(model.lastPrompt)
        #expect(!medium.contains("transcript truncated for length"))
        #expect(medium.count > 40_000)

        _ = try await provider.run(
            request(text: String(repeating: "word ", count: 60_000)))
        let long = try #require(model.lastPrompt)
        #expect(long.contains("transcript truncated for length"))
        let ceiling =
            (ApplePrivateCloudAiProvider.defaultContextTokens - OnDeviceContextBudget.safetyTokens
                - CloudOutputBudget.backstop) * AskBudget.charsPerToken
        #expect(long.count <= ceiling + 64)
    }

    @Test func reportsItsWindowForThePlanner() async throws {
        let provider = provider(FakePrivateCloudModel(window: 32_768))
        #expect(await provider.contextTokens() == 32_768)
        #expect(await provider.inputChars() == nil)
        #expect(await self.provider(nil).contextTokens() == nil)
    }

    @Test func anEmptyAnswerIsAFailureNotANote() async throws {
        final class Empty: ApplePrivateCloudLanguageModel {
            let id = "empty"
            func availability() async -> ApplePrivateCloudAvailability { .available }
            func quota() async -> ApplePrivateCloudQuota? { nil }
            func contextWindowTokens() async -> Int { 32_768 }
            func generate(instructions: String, prompt: String, maxOutputTokens: Int?)
                async throws -> String
            { "  \n" }
            func generateStructured(
                _ shape: OnDeviceStructuredShape, instructions: String, prompt: String,
                maxOutputTokens: Int?
            ) async throws -> String { "" }
        }
        let provider = ApplePrivateCloudAiProvider(
            model: Empty(), remoteConsent: { true },
            buildStatus: ApplePrivateCloudBuildStatus(entitled: true))
        do {
            _ = try await provider.run(request())
            Issue.record("expected a failure")
        } catch {
            #expect(kind(error) == .emptyAnswer)
        }
    }
}
