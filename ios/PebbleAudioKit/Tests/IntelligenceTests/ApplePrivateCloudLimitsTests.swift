import Foundation
import Testing
import Transcription

@testable import Intelligence

// Apple Private Cloud Compute: the signature, not only the profile, decides whether a request
// may be sent (iOS 27 traps on the first request from a binary without the entitlement); a used-up
// daily allowance makes the provider unavailable until it resets instead of being re-asked on
// every job; and its per-call log lines are gated.

// MARK: - A synthetic Mach-O with an embedded code signature

private func be32(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

private func le32(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func plist(_ entitlements: String) -> Data {
    Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>application-identifier</key><string>TEAM.dev.audiocompanion.app</string>
        \(entitlements)
        </dict></plist>
        """.utf8)
}

/// A thin arm64 Mach-O: a header, an LC_UUID, an LC_CODE_SIGNATURE, and a super blob with a
/// CodeDirectory stand-in (slot 0) and, when given, an entitlements blob (slot 5).
private func machO(signedEntitlements: String?) -> Data {
    var blobs: [(type: UInt32, data: Data)] = [(0, be32(0xfade_0c02) + be32(12) + be32(0))]
    if let signedEntitlements {
        let body = plist(signedEntitlements)
        blobs.append((5, be32(0xfade_7171) + be32(UInt32(8 + body.count)) + body))
    }
    var index = Data()
    var payload = Data()
    var offset = 12 + blobs.count * 8
    for blob in blobs {
        index += be32(blob.type) + be32(UInt32(offset))
        payload += blob.data
        offset += blob.data.count
    }
    let superBlob = be32(0xfade_0cc0) + be32(UInt32(offset)) + be32(UInt32(blobs.count)) + index
        + payload

    let uuid = le32(0x1b) + le32(24) + Data(repeating: 0xab, count: 16)
    let commandsSize = uuid.count + 16
    let signatureOffset = 32 + commandsSize + 64
    let signature =
        le32(0x1d) + le32(16) + le32(UInt32(signatureOffset)) + le32(UInt32(superBlob.count))
    var file =
        le32(0xfeed_facf) + le32(0x0100_000c) + le32(0) + le32(2) + le32(2)
        + le32(UInt32(commandsSize)) + le32(0) + le32(0)
    file += uuid + signature
    file += Data(repeating: 0, count: 64)
    file += superBlob
    return file
}

/// The same slice inside a fat wrapper, after an x86_64 slice.
private func fat(_ slice: Data) -> Data {
    let sliceOffset: UInt32 = 4096
    var file = be32(0xcafe_babe) + be32(2)
    file += be32(0x0100_0007) + be32(3) + be32(1024) + be32(64) + be32(12)
    file += be32(0x0100_000c) + be32(0) + be32(sliceOffset) + be32(UInt32(slice.count))
        + be32(14)
    file += Data(repeating: 0, count: Int(sliceOffset) - file.count)
    return file + slice
}

private func profile(granting: Bool) -> Data {
    Data([0x30, 0x82]) + Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Entitlements</key><dict>
        \(granting ? "<key>com.apple.developer.private-cloud-compute</key><true/>" : "")
        </dict></dict></plist>
        """.utf8) + Data([0x00])
}

private let pccKey = "<key>com.apple.developer.private-cloud-compute</key><true/>"

// MARK: - Fakes

private final class LimitedModel: ApplePrivateCloudLanguageModel, @unchecked Sendable {
    let id = "apple-private-cloud-compute"
    private let lock = NSLock()
    private var _calls = 0
    private var failure: Error?
    init(failure: Error?) { self.failure = failure }
    var calls: Int { lock.withLock { _calls } }
    func stopFailing() { lock.withLock { failure = nil } }
    func availability() async -> ApplePrivateCloudAvailability { .available }
    func quota() async -> ApplePrivateCloudQuota? { nil }
    func contextWindowTokens() async -> Int { ApplePrivateCloudAiProvider.defaultContextTokens }
    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String
    {
        let failure: Error? = lock.withLock {
            _calls += 1
            return self.failure
        }
        if let failure { throw failure }
        return "an answer"
    }
    func generateStructured(
        _ shape: OnDeviceStructuredShape, instructions: String, prompt: String,
        maxOutputTokens: Int?
    ) async throws -> String { "{}" }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func add(_ line: String) { lock.withLock { _lines.append(line) } }
}

private struct Phone: AiProvider {
    let id = "apple-foundation-models"
    func isAvailable() async -> Bool { true }
    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        AiProviderResult(text: "from the phone", modelUsed: id)
    }
}

private let request = AiRunRequest(
    requestId: "r", prompt: SegmentAnnotationPrompt.template,
    transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "We planned the launch.")])

@Suite("Apple Private Cloud Compute — signature, allowance, and log discipline")
struct ApplePrivateCloudLimitsTests {
    // MARK: The signature

    @Test func theSignaturesEntitlementsAreReadOutOfTheMachO() {
        let signed = ApplePrivateCloudEntitlement.signedEntitlements(
            inMachO: machO(signedEntitlements: pccKey))
        #expect(ApplePrivateCloudEntitlement.granted(signed?[ApplePrivateCloudEntitlement.key]))
        #expect(signed?["application-identifier"] as? String == "TEAM.dev.audiocompanion.app")

        let fatSigned = ApplePrivateCloudEntitlement.signedEntitlements(
            inMachO: fat(machO(signedEntitlements: pccKey)))
        #expect(ApplePrivateCloudEntitlement.granted(fatSigned?[ApplePrivateCloudEntitlement.key]))
    }

    /// THE trap: a profile that grants the capability, a binary signed from an entitlements file
    /// that never listed it. The first request from that binary kills the process on iOS 27.
    @Test func aProfileThatGrantsItIsNotEnoughWhenTheSignatureDoesNotClaimIt() {
        let unclaimed = ApplePrivateCloudEntitlement.signedEntitlements(
            inMachO: machO(signedEntitlements: ""))
        #expect(unclaimed != nil)
        #expect(
            !ApplePrivateCloudEntitlement.isGranted(
                profile: profile(granting: true), signedEntitlements: unclaimed))
        // Both halves: granted AND claimed.
        #expect(
            ApplePrivateCloudEntitlement.isGranted(
                profile: profile(granting: true),
                signedEntitlements: ApplePrivateCloudEntitlement.signedEntitlements(
                    inMachO: machO(signedEntitlements: pccKey))))
        #expect(
            !ApplePrivateCloudEntitlement.isGranted(
                profile: profile(granting: false),
                signedEntitlements: ApplePrivateCloudEntitlement.signedEntitlements(
                    inMachO: machO(signedEntitlements: pccKey))))
    }

    /// Every failure to read is "not signed with it".
    @Test func anythingUnreadableIsNotSignedWithIt() {
        #expect(ApplePrivateCloudEntitlement.signedEntitlements(inMachO: Data()) == nil)
        #expect(
            ApplePrivateCloudEntitlement.signedEntitlements(inMachO: Data(repeating: 7, count: 64))
                == nil)
        let noBlob = machO(signedEntitlements: nil)
        #expect(ApplePrivateCloudEntitlement.signedEntitlements(inMachO: noBlob) == nil)
        let truncated = machO(signedEntitlements: pccKey).prefix(120)
        #expect(ApplePrivateCloudEntitlement.signedEntitlements(inMachO: Data(truncated)) == nil)
        #expect(
            !ApplePrivateCloudEntitlement.isGranted(
                profile: profile(granting: true), signedEntitlements: nil))
    }

    /// Opportunistic: the test runner itself is a real Mach-O. Whatever its signature holds,
    /// walking it must neither crash nor claim the entitlement.
    @Test func aRealExecutableIsWalkedSafely() {
        guard let url = Bundle.main.executableURL else { return }
        let signed = ApplePrivateCloudEntitlement.signedEntitlements(ofExecutableAt: url)
        #expect(!ApplePrivateCloudEntitlement.granted(signed?[ApplePrivateCloudEntitlement.key]))
    }

    // MARK: The daily allowance

    @Test func aUsedUpAllowanceMakesTheProviderUnavailableUntilItResets() async throws {
        let clock = TestWallClock(ms: 1_790_000_000_000)
        let reset = Date(timeIntervalSince1970: Double(clock.now) / 1_000 + 7_200)
        let model = LimitedModel(failure: ApplePrivateCloudFailure.quotaLimitReached(resetDate: reset))
        let provider = ApplePrivateCloudAiProvider(
            model: model, remoteConsent: { true },
            buildStatus: ApplePrivateCloudBuildStatus(entitled: true), nowMs: { clock.now })

        do {
            _ = try await provider.run(request)
            Issue.record("expected the limit")
        } catch {
            #expect(AiFailure.classify(error).kind == .usageLimit)
        }
        #expect(await provider.isAvailable() == false)
        #expect(await provider.unavailabilityReason()?.contains("daily usage limit") == true)

        // Nothing is asked of the model while the allowance is used up.
        _ = try? await provider.run(request)
        #expect(model.calls == 1)

        // Remote first answers on the phone meanwhile, and says why.
        let router = AiModeRouter(local: Phone(), remote: provider, mode: { .remoteFirst })
        let answered = try await router.run(request)
        #expect(answered.providerId == "apple-foundation-models")
        #expect(router.lastFallback?.cause == .usageLimit)

        // Back when it resets.
        model.stopFailing()
        clock.advance(byMs: 7_200_000)
        #expect(await provider.isAvailable())
        _ = try await provider.run(request)
        #expect(model.calls == 2)
    }

    @Test func anAllowanceWithNoResetDateIsLookedAtAgainInAnHour() async throws {
        let clock = TestWallClock(ms: 1_790_000_000_000)
        let model = LimitedModel(failure: ApplePrivateCloudFailure.quotaLimitReached(resetDate: nil))
        let provider = ApplePrivateCloudAiProvider(
            model: model, remoteConsent: { true },
            buildStatus: ApplePrivateCloudBuildStatus(entitled: true), nowMs: { clock.now })
        _ = try? await provider.run(request)
        #expect(await provider.isAvailable() == false)
        clock.advance(byMs: ApplePrivateCloudAiProvider.unknownResetRecheckMs)
        #expect(await provider.isAvailable())
    }

    // MARK: Log discipline

    @Test func aServiceThatKeepsBeingUnavailableIsLoggedOnceThenCounted() async throws {
        let clock = TestWallClock(ms: 1_790_000_000_000)
        let lines = Lines()
        let provider = ApplePrivateCloudAiProvider(
            model: LimitedModel(failure: ApplePrivateCloudFailure.serviceUnavailable("down")),
            remoteConsent: { true }, buildStatus: ApplePrivateCloudBuildStatus(entitled: true),
            log: { lines.add($0) }, nowMs: { clock.now })
        for _ in 0..<5 { _ = try? await provider.run(request) }
        #expect(lines.lines.filter { $0.contains("service unavailable") }.count == 1)
        clock.advance(byMs: 10 * 60_000)
        _ = try? await provider.run(request)
        let logged = lines.lines.filter { $0.contains("service unavailable") }
        #expect(logged.count == 2)
        #expect(logged.last?.contains("[4 more like it since the last line]") == true)
    }
}
