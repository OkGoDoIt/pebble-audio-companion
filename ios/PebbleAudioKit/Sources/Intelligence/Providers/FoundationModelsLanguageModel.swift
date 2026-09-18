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

        // MARK: What the model says about its own size

        /// The window, read once per process.
        ///
        /// `SystemLanguageModel.contextSize` is `@backDeployed` to iOS 26 and answers 4,096 there
        /// by construction; the real property behind it is iOS 27's, where it reports 8,192.
        /// The read is gated on 27 anyway so the iOS 26 path is visibly the constant it always
        /// was, not a framework call that happens to return it. Cached because the provider
        /// asks on every request and the answer cannot change while the process lives.
        public func contextWindowTokens() async -> Int {
            if let cached = Self.windowCache.value { return cached }
            let window: Int
            if #available(iOS 27.0, macOS 27.0, *) {
                window = max(
                    OnDeviceContextBudget.windowTokens, SystemLanguageModel.default.contextSize)
            } else {
                window = OnDeviceContextBudget.windowTokens
            }
            Self.windowCache.value = window
            return window
        }

        /// The model's own count, or nil where the OS predates `tokenCount(for:)` (iOS 26.4) or
        /// the count itself fails — either way the provider falls back to its estimate, which
        /// is what it used before the count existed. Never cached: the text is different every
        /// time.
        public func tokenCount(for text: String) async -> Int? {
            guard #available(iOS 26.4, macOS 26.4, *) else { return nil }
            return try? await SystemLanguageModel.default.tokenCount(for: text)
        }

        /// One process-wide slot under a lock — the same idiom as `AskFormatterCache`.
        private final class WindowCache: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Int?
            var value: Int? {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
        private static let windowCache = WindowCache()

        /// One shared implementation with the Private Cloud Compute bridge — session, options,
        /// and the translation of Apple's error enums into the kit's own, so `OnDeviceAiProvider`
        /// can say which thing happened without importing FoundationModels. See
        /// `AppleModelGeneration` for why that translation covers two generations of the
        /// framework's vocabulary.
        public func generate(
            instructions: String, prompt: String, maxOutputTokens: Int?
        ) async throws -> String {
            try await AppleModelGeneration.prose(
                .onDevice(), instructions: instructions, prompt: prompt,
                maxOutputTokens: maxOutputTokens)
        }
    }
#endif
