import Foundation
import Intelligence
import Testing

// Apple Private Cloud Compute against the REAL framework, on whatever this test is running on.
//
// Measured on the iOS 27.0 simulator: without the managed entitlement the framework's
// `availability` reads `.available`, and the first `respond` does not throw — it traps the
// process (`FoundationModels/ErrorConversion.swift:140: Fatal error: Missing entitlement`). So
// what must hold here is that the provider never gets that far: a simulator build has no
// embedded provisioning profile, the build status reads "not entitled", and a request is
// refused as `providerUnavailable` before any session exists. On iOS 26 there is no framework
// model and the provider is simply absent; that path is the "silent no-op" and is pinned too.
@Suite("Apple Private Cloud Compute · on this simulator") @MainActor
struct ApplePrivateCloudSimulatorTests {
    private final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.withLock { _lines } }
        func record(_ line: String) { lock.withLock { _lines.append(line) } }
    }

    private var request: AiRunRequest {
        AiRunRequest(
            requestId: "sim-pcc",
            prompt: SegmentAnnotationPrompt.template,
            transcripts: [
                TranscriptExcerpt(
                    segmentId: "seg-1",
                    text: "Dana: so the roadmap review moved to Thursday, can you send the deck?")
            ])
    }

    @Test func aRequestWithoutTheEntitlementIsRefusedBeforeItExists() async throws {
        // This test bundle, like the app it compiles, is not signed with a profile that grants
        // the entitlement — and on the simulator not with a profile at all.
        #expect(!ApplePrivateCloudEntitlement.isGranted(in: .main))
        #expect(ApplePrivateCloudBuildStatus.shared.isKnownNotEnabled)

        guard #available(iOS 27.0, *) else {
            // iOS 26: nothing to construct. The readiness the Settings row would show says so.
            #expect(ApplePrivateCloudReadiness.current == .unsupportedOs)
            #expect(ApplePrivateCloudReadiness.quota == .unknown)
            return
        }
        // The Settings row's own answer, read the way the screen reads it: the build fact comes
        // first, and the framework's "available" — which is what it reads here — is never asked.
        #expect(ApplePrivateCloudReadiness.current == .notEnabledForThisBuild)

        let log = LogSink()
        let provider = ApplePrivateCloudAiProvider(
            model: ApplePrivateCloudModel(),
            remoteConsent: { true },
            buildStatus: .shared,
            log: { log.record($0) })

        #expect(await provider.isAvailable() == false)
        #expect(await provider.availability() == .notEnabledForThisBuild)
        do {
            _ = try await provider.run(request)
            Issue.record("a request went out from a build without the entitlement")
        } catch AiError.providerUnavailable(let id) {
            #expect(id == "apple-pcc")
        }
        #expect(log.lines.contains { $0.contains("not enabled for this build") })
        // And the router falls back around it in a "first" mode with a calm cause.
        let router = AiModeRouter(
            local: StubLocal(), remote: provider, mode: { .remoteFirst })
        let result = try await router.run(request)
        #expect(result.providerId == "stub-local")
        #expect(router.lastFallback?.cause == .notAvailable)
    }

    private struct StubLocal: AiProvider {
        let id = "stub-local"
        func isAvailable() async -> Bool { true }
        func run(_ request: AiRunRequest) async throws -> AiProviderResult {
            AiProviderResult(text: "TITLE: x\nSUMMARY: y.", modelUsed: "stub")
        }
    }
}
