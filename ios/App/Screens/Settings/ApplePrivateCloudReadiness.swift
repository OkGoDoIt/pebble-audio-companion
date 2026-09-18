import Foundation
import Intelligence

#if canImport(FoundationModels)
    import FoundationModels
#endif

// Can this phone, in this build, send text to Apple Private Cloud Compute right now — and how
// much of today's allowance is left? The iOS 27 twin of `OnDeviceAiReadiness`, read fresh on
// every draw for the same reason: the framework's model is `Observable`, so a Settings body that
// touches `availability` and `quotaUsage` redraws by itself when either changes.

/// The states the Settings row tells apart. Each is a different situation with a different
/// thing (or nothing) to do about it; "not available" would collapse them into a shrug.
enum ApplePrivateCloudReadiness: Equatable, CaseIterable {
    /// Signed in, eligible, and answering.
    case ready
    /// `deviceNotEligible` — this hardware will never use it.
    case notSupported
    /// `systemNotReady` — signed out, still setting up, or Apple Intelligence off.
    case notReady
    /// This binary was not signed with the entitlement, so it may not send a request at all.
    /// About this build, not this phone; read from `ApplePrivateCloudBuildStatus`.
    case notEnabledForThisBuild
    /// iOS 26: the model does not exist here.
    case unsupportedOs

    var isReady: Bool { self == .ready }
}

/// Today's allowance, as the row and the footer describe it.
enum ApplePrivateCloudQuotaState: Equatable {
    case fine
    case nearlyUsedUp
    case usedUp(resetsAt: Date?)
    /// Nothing to read — an OS without the model, or the framework did not say.
    case unknown
}

extension ApplePrivateCloudReadiness {
    /// A snapshot, never cached. Readiness can change between draws (sign-in, Apple
    /// Intelligence toggled). The build fact is checked FIRST, and when it says no the
    /// framework is not asked: its `availability` reads "available" in exactly the build whose
    /// first request would trap the process (see `ApplePrivateCloudEntitlement`).
    ///
    /// The OS comes before the build: on iOS 26 the model does not exist whatever the signature
    /// says, and "needs iOS 27" is the only true sentence — the same order the provider's own
    /// `availability()` uses (no model → `.unsupported`).
    static var current: ApplePrivateCloudReadiness {
        guard #available(iOS 27.0, *) else { return .unsupportedOs }
        if ApplePrivateCloudBuildStatus.shared.isKnownNotEnabled { return .notEnabledForThisBuild }
        #if canImport(FoundationModels)
            switch ApplePrivateCloudFrameworkModel.shared.availability {
            case .available:
                return .ready
            case .unavailable(.deviceNotEligible):
                return .notSupported
            case .unavailable(.systemNotReady):
                return .notReady
            case .unavailable:
                // A reason Apple adds later: not ready, and no claim about why.
                return .notReady
            }
        #else
            return .unsupportedOs
        #endif
    }

    /// Today's allowance. `.unknown` on iOS 26, where there is nothing to read — and in a build
    /// that may not use the model, where the framework is not asked anything at all.
    static var quota: ApplePrivateCloudQuotaState {
        if ApplePrivateCloudBuildStatus.shared.isKnownNotEnabled { return .unknown }
        #if canImport(FoundationModels)
            if #available(iOS 27.0, *) {
                let usage = ApplePrivateCloudFrameworkModel.shared.quotaUsage
                switch usage.status {
                case .belowLimit(let below):
                    return below.isApproachingLimit ? .nearlyUsedUp : .fine
                case .limitReached:
                    return .usedUp(resetsAt: usage.resetDate)
                @unknown default:
                    return .fine
                }
            }
        #endif
        return .unknown
    }

    /// Whether Apple offers a way to ask for a higher limit right now.
    static var canRequestMore: Bool {
        if ApplePrivateCloudBuildStatus.shared.isKnownNotEnabled { return false }
        #if canImport(FoundationModels)
            if #available(iOS 27.0, *) {
                return ApplePrivateCloudFrameworkModel.shared.quotaUsage.limitIncreaseSuggestion
                    != nil
            }
        #endif
        return false
    }

    /// Presents Apple's own limit-increase flow. A no-op when there is nothing to show.
    static func requestMore() {
        if ApplePrivateCloudBuildStatus.shared.isKnownNotEnabled { return }
        #if canImport(FoundationModels)
            if #available(iOS 27.0, *) {
                ApplePrivateCloudFrameworkModel.shared.quotaUsage.limitIncreaseSuggestion?.show()
            }
        #endif
    }
}

#if canImport(FoundationModels)
    /// One framework model instance for the Settings reads. The provider in `AppComposition`
    /// holds its own; both read the same system state, and neither is expensive to create,
    /// but a body that made a new one on every draw would subscribe to a fresh object each time.
    @available(iOS 27.0, *)
    enum ApplePrivateCloudFrameworkModel {
        static let shared = PrivateCloudComputeLanguageModel()
    }
#endif
