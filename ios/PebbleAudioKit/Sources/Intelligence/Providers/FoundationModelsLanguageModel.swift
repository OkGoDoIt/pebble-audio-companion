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

    /// The model this app runs, with Apple's content filter set for the job it is doing.
    ///
    /// `.permissiveContentTransformations` is Apple's documented setting for TRANSFORMING content
    /// the person supplied, rather than generating new content — which is exactly this: their own
    /// recorded words, turned into a title, a summary or a task, and shown back only to them.
    ///
    /// On `.default` the filter refuses outright, and the refusal is invisible. Measured on real
    /// recordings, one was declined mid-extraction — someone dictating a complaint to a support
    /// desk — and the person simply gets no follow-ups from it, with no error and nothing to act
    /// on. That lands hardest on the conversations most worth remembering: anything medical,
    /// legal, financial or difficult. Declining to surface "call the pharmacy back" because the
    /// surrounding talk was about medication is a worse outcome than the filter is preventing.
    ///
    /// This changes nothing about privacy: on-device either way, and no output leaves the phone.
    public static var companionModel: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }


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
            let session = LanguageModelSession(
                model: Self.companionModel, instructions: instructions)
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
