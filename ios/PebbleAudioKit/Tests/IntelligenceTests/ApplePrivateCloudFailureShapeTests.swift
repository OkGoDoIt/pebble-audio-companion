import Foundation
import Testing
import Transcription

@testable import Intelligence

// The two literals the Private Cloud Compute provider writes, read back by both classifiers —
// and the one untyped error the framework throws for a build without the entitlement, matched
// on its shape.

@Suite("Apple Private Cloud Compute · failure shapes")
struct ApplePrivateCloudFailureShapeTests {
    @Test func theUsageLimitMarkerIsOneLiteralReadByBothClassifiers() {
        #expect(AiFailure.Marker.usageLimit == ProcessingFallbackCause.usageLimitMarker)
        let message = "Apple Private Cloud Compute has reached its daily usage limit."
        #expect(ProcessingFallbackCause.classify(message) == .usageLimit)
        #expect(AiFailure.kind(of: AiError.providerFailed(message)) == .usageLimit)
        // Case does not matter, and neither does what surrounds it.
        #expect(ProcessingFallbackCause.classify("DAILY USAGE LIMIT hit (429)") == .usageLimit)
    }

    /// Before this, the nearest words — "quota exceeded" — classified as an account out of
    /// money, whose sentence tells the person to add funds to an account that does not exist.
    @Test func theMarkerIsNotMistakenForOutOfFundsOrRateLimiting() {
        let message = "Apple Private Cloud Compute has reached its daily usage limit (429)."
        #expect(AiFailure.kind(of: AiError.providerFailed(message)) == .usageLimit)
        #expect(ProcessingFallbackCause.classify(message) == .usageLimit)
    }

    @Test func aCloudRefusalIsNotTheOnDeviceOne() {
        let cloud = "Apple Private Cloud Compute \(AiFailure.Marker.cloudContentRefused)."
        #expect(AiFailure.kind(of: AiError.providerFailed(cloud)) == .cloudContentRefused)
        let device = "On-device AI \(AiFailure.Marker.contentRefused). Cloud AI has different rules."
        #expect(AiFailure.kind(of: AiError.providerFailed(device)) == .contentRefused)
        // Neither marker contains the other, so order of checking can never confuse them.
        #expect(!AiFailure.Marker.cloudContentRefused.contains(AiFailure.Marker.contentRefused))
        #expect(!AiFailure.Marker.contentRefused.contains(AiFailure.Marker.cloudContentRefused))
    }

    @Test func everyCauseIsStillClassifiedAsBefore() {
        #expect(ProcessingFallbackCause.classify("provider unavailable: apple-pcc") == .notAvailable)
        #expect(ProcessingFallbackCause.classify("network request failed (-1009)") == .noConnection)
        #expect(ProcessingFallbackCause.classify("OpenAI said (429): slow down") == .notAccepted)
        #expect(ProcessingFallbackCause.classify(nil) == .failed)
    }

    #if canImport(FoundationModels)
        /// Measured on macOS 27 without the entitlement: `availability` reads `.available`, and
        /// the request fails with an UNTYPED `LanguageModelError` -1 carrying
        /// `ModelManagerError 1046` under `NSMultipleUnderlyingErrorsKey`. Rebuilt here from
        /// those parts so the recognition is pinned to the shape rather than to a live failure.
        @Test func theEntitlementFailureIsRecognisedByItsShape() throws {
            guard #available(iOS 27.0, macOS 27.0, *) else { return }
            let manager = NSError(
                domain: "ModelManagerServices.ModelManagerError", code: 1046, userInfo: [:])
            let inner = NSError(
                domain: "FoundationModels.LanguageModelError", code: -1,
                userInfo: [NSMultipleUnderlyingErrorsKey: [manager]])
            let outer = NSError(
                domain: "FoundationModels.LanguageModelError", code: -1,
                userInfo: [NSMultipleUnderlyingErrorsKey: [inner]])

            let failure = try #require(ApplePrivateCloudModel.untypedFrameworkFailure(outer))
            guard case .notEnabledForThisBuild(let detail) = failure else {
                Issue.record("expected notEnabledForThisBuild, got \(failure)"); return
            }
            #expect(detail == "LanguageModelError -1 > ModelManagerError 1046")

            // The same code without 1046 underneath is the service, not the build.
            let bare = NSError(domain: "FoundationModels.LanguageModelError", code: -1)
            guard case .serviceUnavailable = try #require(
                ApplePrivateCloudModel.untypedFrameworkFailure(bare))
            else { Issue.record("expected serviceUnavailable"); return }

            // Anything else is left for the caller.
            #expect(
                ApplePrivateCloudModel.untypedFrameworkFailure(
                    NSError(domain: "NSURLErrorDomain", code: -1009)) == nil)
            #expect(ApplePrivateCloudModel.untypedFrameworkFailure(CancellationError()) == nil)
        }
    #endif
}
