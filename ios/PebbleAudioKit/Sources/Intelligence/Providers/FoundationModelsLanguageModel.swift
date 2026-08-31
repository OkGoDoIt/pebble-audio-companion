import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    // Swift-native successor of the old app's `FoundationModelsBridge` (iosApp/AppDelegate.swift)
    // + `IosFoundationModelsLanguageModel` (app/src/iosMain/.../IosFoundationModels.kt). The KMP
    // app needed a callback bridge because Kotlin/Native cannot call Swift-only frameworks; here
    // the provider seam is Swift, so this implements `OnDeviceLanguageModel` directly.
    //
    // Availability mapping preserves the KMP bridge's AVAILABILITY_* semantics (0/2/3):
    // `.available` → available, `.unavailable(.modelNotReady)` → downloading (model still
    // downloading / initializing), any other `.unavailable` → unavailable (deviceNotEligible /
    // appleIntelligenceNotEnabled / unknown). Apple's API never reports a distinct
    // "downloadable" state, so that case (1) is unused here, exactly as in the old bridge.

    /// `OnDeviceLanguageModel` over Apple's Foundation Models framework (iOS/macOS 26+).
    public final class FoundationModelsLanguageModel: OnDeviceLanguageModel {
        public let id = "apple-foundation-models"

        public init() {}

        public func availability() async -> OnDeviceAvailability {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.modelNotReady):
                return .downloading
            case .unavailable:
                return .unavailable
            @unknown default:
                return .unavailable
            }
        }

        public func generate(
            instructions: String, prompt: String, maxOutputTokens: Int?
        ) async throws -> String {
            // A fresh session per generation: the enrichment/recap passes are one-shot and the
            // runtime releases the model between passes (plan 4.6 model residency).
            let session = LanguageModelSession(instructions: instructions)
            let options: GenerationOptions
            if let maxOutputTokens, maxOutputTokens > 0 {
                options = GenerationOptions(maximumResponseTokens: maxOutputTokens)
            } else {
                options = GenerationOptions()
            }
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        }
    }
#endif
