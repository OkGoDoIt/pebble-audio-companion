import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    // The bridge over Apple's `PrivateCloudComputeLanguageModel` (iOS 27). Named
    // `ApplePrivateCloudModel` so it cannot be confused with the framework's own type, which is
    // what it wraps. Everything about generating is `AppleModelGeneration`, shared with the
    // on-device bridge; this file is availability, quota, the window, the two guided shapes,
    // and the translation of the errors only this model throws.

    /// `ApplePrivateCloudLanguageModel` over the framework.
    @available(iOS 27.0, macOS 27.0, *)
    public final class ApplePrivateCloudModel: ApplePrivateCloudLanguageModel {
        public let id = "apple-private-cloud-compute"

        private let model: PrivateCloudComputeLanguageModel

        public init() {
            model = PrivateCloudComputeLanguageModel()
        }

        /// Light reasoning on every call. Recap, summaries and Ask answers are extraction
        /// over supplied text, where thinking longer buys latency and quota, not accuracy;
        /// the one-shot follow-up shapes below run on the same setting for the same reason.
        private var sessions: AppleModelSessions {
            .model(model, reasoning: .light)
        }

        // MARK: Readiness

        public func availability() async -> ApplePrivateCloudAvailability {
            switch model.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.systemNotReady):
                return .systemNotReady
            case .unavailable:
                // A reason Apple adds later. `systemNotReady` is the honest floor: it says the
                // model is not going to answer now, and claims nothing permanent.
                return .systemNotReady
            }
        }

        public func quota() async -> ApplePrivateCloudQuota? {
            let usage = model.quotaUsage
            let status: ApplePrivateCloudQuota.Status
            switch usage.status {
            case .belowLimit(let below):
                status = .belowLimit(approaching: below.isApproachingLimit)
            case .limitReached:
                status = .limitReached
            @unknown default:
                status = .belowLimit(approaching: false)
            }
            return ApplePrivateCloudQuota(
                status: status,
                resetDate: usage.resetDate,
                canRequestMore: usage.limitIncreaseSuggestion != nil)
        }

        /// `contextSize` is `async throws` on this model (it can involve the service), so it is
        /// read once per process and falls back to the measured constant if the read fails.
        public func contextWindowTokens() async -> Int {
            if let cached = Self.windowCache.value { return cached }
            let window = (try? await model.contextSize) ?? ApplePrivateCloudAiProvider.defaultContextTokens
            let clamped = max(OnDeviceContextBudget.windowTokens, window)
            Self.windowCache.value = clamped
            return clamped
        }

        // MARK: Generation

        public func generate(
            instructions: String, prompt: String, maxOutputTokens: Int?
        ) async throws -> String {
            do {
                return try await AppleModelGeneration.prose(
                    sessions, instructions: instructions, prompt: prompt,
                    maxOutputTokens: maxOutputTokens)
            } catch {
                throw Self.translate(error)
            }
        }

        /// One guided-generation call over the whole conversation, into a mirror of the JSON
        /// schema OpenAI is held to, so `rawContent.jsonString` IS the body the existing
        /// parsers read. Not the on-device sift: that is one closed question per sentence,
        /// designed around a 3B model's limits, and against a per-person daily allowance it
        /// would spend forty round trips on one conversation.
        public func generateStructured(
            _ shape: OnDeviceStructuredShape,
            instructions: String,
            prompt: String,
            maxOutputTokens: Int?
        ) async throws -> String {
            let maxTokens = maxOutputTokens ?? CloudOutputBudget.backstop
            do {
                switch shape {
                case .followUps:
                    return try await AppleModelGeneration.respond(
                        sessions, to: prompt, instructions: instructions,
                        generating: CloudFollowUpExtraction.self, maxTokens: maxTokens
                    ).rawContent.jsonString
                case .followUpCuration:
                    return try await AppleModelGeneration.respond(
                        sessions, to: prompt, instructions: instructions,
                        generating: CloudCurationDecisions.self, maxTokens: maxTokens
                    ).rawContent.jsonString
                }
            } catch {
                throw Self.translate(error)
            }
        }

        // MARK: Errors only this model throws

        /// The shared translation has already turned the framework's generation errors into
        /// `OnDeviceGenerationFailure`; this adds the three cases only Private Cloud Compute has,
        /// and the one the framework does not type at all.
        ///
        /// That last one is what a process without the managed entitlement sees: not a
        /// `PrivateCloudComputeLanguageModel.Error`, but a bare `NSError` in domain
        /// `FoundationModels.LanguageModelError`, code -1, with `ModelManagerError 1046`
        /// underneath (measured on macOS 27, where `availability` reads `.available` all the
        /// same). It is recognised by that shape and reported as "not enabled for this build",
        /// which is both what it is and the only thing a person could do about it.
        static func translate(_ error: Error) -> Error {
            if error is CancellationError { return error }
            if let generation = error as? OnDeviceGenerationFailure {
                return ApplePrivateCloudFailure.generation(generation)
            }
            if let own = error as? PrivateCloudComputeLanguageModel.Error {
                switch own {
                case .networkFailure(let failure):
                    return ApplePrivateCloudFailure.networkFailure(failure.debugDescription)
                case .quotaLimitReached(let quota):
                    return ApplePrivateCloudFailure.quotaLimitReached(resetDate: quota.resetDate)
                case .serviceUnavailable(let service):
                    return ApplePrivateCloudFailure.serviceUnavailable(service.debugDescription)
                @unknown default:
                    return ApplePrivateCloudFailure.serviceUnavailable("\(own)")
                }
            }
            if let untyped = Self.untypedFrameworkFailure(error) {
                return untyped
            }
            return error
        }

        /// The entitlement shape, matched on domain and code so a future typed error is never
        /// mistaken for it. The underlying codes are collected for the log line — that 1046 is
        /// the one fact that distinguishes "no entitlement" from "something else with code -1".
        static func untypedFrameworkFailure(_ error: Error) -> ApplePrivateCloudFailure? {
            let nsError = error as NSError
            guard nsError.domain == "FoundationModels.LanguageModelError", nsError.code == -1
            else { return nil }
            let chain = underlyingChain(of: nsError)
            let detail = chain.isEmpty ? "no underlying error" : chain.joined(separator: " > ")
            if chain.contains(where: { $0.hasSuffix("ModelManagerError 1046") }) {
                return .notEnabledForThisBuild(detail)
            }
            return .serviceUnavailable("LanguageModelError -1: \(detail)")
        }

        /// "domain code" for every error under `error`, depth first, through both the single and
        /// the multiple underlying-error keys.
        static func underlyingChain(of error: NSError) -> [String] {
            var out: [String] = []
            var pending: [NSError] = []
            if let single = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(single)
            }
            if let multiple = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                pending.append(contentsOf: multiple)
            }
            for underlying in pending {
                let domain = underlying.domain.split(separator: ".").last.map(String.init)
                    ?? underlying.domain
                out.append("\(domain) \(underlying.code)")
                out.append(contentsOf: underlyingChain(of: underlying))
            }
            return out
        }

        private final class WindowCache: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Int?
            var value: Int? {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
        private static let windowCache = WindowCache()
    }

    // MARK: - The shapes, mirroring the cloud schema

    // Property names are the parsers' keys (`ExtractedFollowUp`, `CurationDecision`), so the
    // generated content's JSON needs no mapping. Descriptions are the OpenAI schema's, which
    // were earned against real output.

    @available(iOS 27.0, macOS 27.0, *)
    @Generable
    struct CloudFollowUpExtraction {
        @Guide(description: "Every concrete commitment the wearer made. Empty when there is none.")
        var items: [CloudFollowUpItem]
    }

    @available(iOS 27.0, macOS 27.0, *)
    @Generable
    struct CloudFollowUpItem {
        @Guide(description: "One plain imperative sentence naming the concrete thing to do.")
        var task: String

        @Guide(
            description:
                "One contiguous verbatim run from a single speaker turn that contains the "
                + "commitment.")
        var quote: String

        @Guide(
            description: "One short clause naming what concretely goes wrong if this never happens.")
        var ifForgotten: String

        @Guide(
            description:
                "Real calendar date as YYYY-MM-DD, or empty string when the transcript states none.")
        var dueDate: String

        @Guide(
            description:
                "How certain the action is unambiguous, owned by this person, and cleanly "
                + "transcribed.",
            .anyOf(["high", "medium", "low"]))
        var confidence: String
    }

    @available(iOS 27.0, macOS 27.0, *)
    @Generable
    struct CloudCurationDecisions {
        @Guide(description: "One decision per numbered candidate, in order.")
        var decisions: [CloudCurationDecision]
    }

    @available(iOS 27.0, macOS 27.0, *)
    @Generable
    struct CloudCurationDecision {
        @Guide(description: "The candidate's 1-based number in the list.")
        var index: Int

        @Guide(
            description: "Whether this belongs on the person's follow-up list.",
            .anyOf(["keep", "drop", "duplicate"]))
        var decision: String

        @Guide(description: "The reason, in one short clause.")
        var reason: String

        @Guide(description: "Rewritten task text, or empty string to keep what was written.")
        var task: String

        @Guide(description: "Priority.", .anyOf(["high", "normal", "low"]))
        var priority: String

        @Guide(description: "YYYY-MM-DD, or empty string.")
        var dueDate: String
    }
#endif
