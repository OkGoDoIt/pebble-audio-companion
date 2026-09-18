import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    // The one implementation of "run a prompt through an Apple language model".
    //
    // Two of Apple's models serve this app — the on-device `SystemLanguageModel` (iOS 26) and
    // `PrivateCloudComputeLanguageModel` (iOS 27) — and everything about generating with them
    // is the same except how a session is opened and which error enum comes back. Both bridges
    // (`FoundationModelsLanguageModel`, `ApplePrivateCloudModel`) therefore share this file:
    // one prose path, one guided-generation path, one error translation. A fix to either lands
    // for both models, and the PCC bridge cannot drift into a second opinion about what a
    // refusal or a context overflow means.
    //
    // The error translation is where iOS 27 changed under the on-device path too. On iOS 26 a
    // session throws `LanguageModelSession.GenerationError`; on iOS 27 the same overflow arrives
    // as `LanguageModelError.contextSizeExceeded` (measured on macOS 27: "Content contains 9160
    // tokens, which exceeds the maximum allowed context size of 8192" — with a `LanguageModelError`
    // type, not a `GenerationError`). A bridge that only translated the iOS 26 enum reported
    // every one of those as "On-device AI generation failed" on iOS 27, which is exactly the
    // opaque sentence the translation was written to remove.

    /// How a session on one of Apple's models is opened. The only thing that differs between
    /// the two models, so it is the only thing a caller supplies.
    struct AppleModelSessions: Sendable {
        /// A fresh session with these instructions. Fresh per generation, deliberately: the
        /// enrichment and recap passes are one-shot and the runtime releases the model between
        /// passes (plan 4.6 model residency).
        let open: @Sendable (String) -> LanguageModelSession
        /// How hard the model may think per call. iOS 27 only; nil on iOS 26, where the option
        /// does not exist and the iOS 26 `respond` overloads are used unchanged.
        let reasoning: AppleReasoning?

        /// The on-device model, with the content filter set for the job it is doing — see
        /// `FoundationModelsLanguageModel.companionModel`.
        static func onDevice() -> AppleModelSessions {
            AppleModelSessions(
                open: { instructions in
                    LanguageModelSession(
                        model: FoundationModelsLanguageModel.companionModel,
                        instructions: instructions)
                },
                reasoning: nil)
        }

        /// Any iOS 27 model — Private Cloud Compute is the one this app uses it for.
        @available(iOS 27.0, macOS 27.0, *)
        static func model(
            _ model: any LanguageModel, reasoning: AppleReasoning?
        ) -> AppleModelSessions {
            AppleModelSessions(
                open: { instructions in
                    LanguageModelSession(model: model, instructions: instructions)
                },
                reasoning: reasoning)
        }
    }

    /// `ContextOptions.ReasoningLevel` without the availability, so a session description can
    /// be stored on a type that exists on iOS 26.
    enum AppleReasoning: Sendable, Equatable {
        case light
        case moderate
        case deep
    }

    enum AppleModelGeneration {
        /// Prose. Throws the kit's own `OnDeviceGenerationFailure` for anything the framework
        /// said something specific about, and the original error otherwise.
        static func prose(
            _ sessions: AppleModelSessions,
            instructions: String, prompt: String, maxOutputTokens: Int?
        ) async throws -> String {
            let session = sessions.open(instructions)
            let options: GenerationOptions
            if let maxOutputTokens, maxOutputTokens > 0 {
                options = GenerationOptions(maximumResponseTokens: maxOutputTokens)
            } else {
                options = GenerationOptions()
            }
            do {
                if #available(iOS 27.0, macOS 27.0, *), let reasoning = sessions.reasoning {
                    return try await session.respond(
                        to: prompt, options: options,
                        contextOptions: ContextOptions(reasoningLevel: reasoning.level)
                    ).content
                }
                return try await session.respond(to: prompt, options: options).content
            } catch {
                throw translate(error) ?? error
            }
        }

        /// Guided generation into a `@Generable` shape. The whole response, so a caller that
        /// wants the JSON the parsers read (`rawContent.jsonString`) has it as well as the
        /// typed content.
        ///
        /// Greedy, not sampled: this is extraction, not prose. Sampling only adds a way for two
        /// passes over the same recording to disagree about what somebody promised.
        static func respond<Content: Generable>(
            _ sessions: AppleModelSessions,
            to prompt: String, instructions: String, generating type: Content.Type,
            maxTokens: Int
        ) async throws -> LanguageModelSession.Response<Content> {
            let session = sessions.open(instructions)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
            do {
                if #available(iOS 27.0, macOS 27.0, *), let reasoning = sessions.reasoning {
                    return try await session.respond(
                        to: prompt, generating: type, options: options,
                        contextOptions: ContextOptions(
                            includeSchemaInPrompt: true, reasoningLevel: reasoning.level))
                }
                return try await session.respond(to: prompt, generating: type, options: options)
            } catch {
                throw translate(error) ?? error
            }
        }

        // MARK: - Turning Apple's errors into the kit's own

        /// Apple's error enums → `OnDeviceGenerationFailure`, so a provider can say which thing
        /// happened without importing FoundationModels (the kit builds where the framework does
        /// not exist). Nil for anything unrecognised, which the caller rethrows untouched — a
        /// `CancellationError`, a PCC transport error, something new.
        ///
        /// Both generations of the framework's vocabulary are handled. Measured on this machine
        /// against a real four-hour recording, the shipped build's 12,000-character input threw
        /// iOS 26's `exceededContextWindowSize` ("Content contains 4179 tokens, which exceeds
        /// the maximum allowed context size of 4096"); the same overflow on 27 is
        /// `LanguageModelError.contextSizeExceeded`.
        static func translate(_ error: Error) -> OnDeviceGenerationFailure? {
            if error is CancellationError { return nil }
            if let generation = error as? LanguageModelSession.GenerationError {
                return translate(generation)
            }
            if #available(iOS 27.0, macOS 27.0, *) {
                return translateModern(error)
            }
            return nil
        }

        /// iOS 26's enum. Deprecated on 27 in favour of the types below, and still what an
        /// iOS 26 phone throws — which is why this is matched outside any `#available(27)`
        /// scope: there the deprecation would be diagnosed, here it is the live API.
        static func translate(
            _ error: LanguageModelSession.GenerationError
        ) -> OnDeviceGenerationFailure {
            switch error {
            case .exceededContextWindowSize(let context):
                return .contextWindowExceeded(context.debugDescription)
            case .guardrailViolation, .refusal:
                return .contentRefused
            case .assetsUnavailable:
                return .assetsUnavailable
            case .rateLimited, .concurrentRequests:
                return .busy
            case .unsupportedLanguageOrLocale:
                return .unsupportedLanguage
            case .decodingFailure(let context), .unsupportedGuide(let context):
                return .other(context.debugDescription)
            @unknown default:
                return .other("\(error)")
            }
        }

        /// iOS 27's three enums, mapped onto the same cases so nothing downstream can tell which
        /// OS produced them.
        @available(iOS 27.0, macOS 27.0, *)
        static func translateModern(_ error: Error) -> OnDeviceGenerationFailure? {
            if let modelError = error as? LanguageModelError {
                switch modelError {
                case .contextSizeExceeded(let context):
                    return .contextWindowExceeded(context.debugDescription)
                case .guardrailViolation, .refusal:
                    return .contentRefused
                case .rateLimited:
                    return .busy
                case .unsupportedLanguageOrLocale:
                    return .unsupportedLanguage
                case .timeout(let context):
                    return .other(context.debugDescription)
                case .unsupportedCapability(let context):
                    return .other(context.debugDescription)
                case .unsupportedTranscriptContent(let context):
                    return .other(context.debugDescription)
                case .unsupportedGenerationGuide(let context):
                    return .other(context.debugDescription)
                @unknown default:
                    return .other("\(modelError)")
                }
            }
            if let systemError = error as? SystemLanguageModel.Error {
                switch systemError {
                case .assetsUnavailable:
                    return .assetsUnavailable
                @unknown default:
                    return .other("\(systemError)")
                }
            }
            if let sessionError = error as? LanguageModelSession.Error {
                switch sessionError {
                case .concurrentRequests:
                    return .busy
                case .transcriptMutationWhileResponding:
                    return .other("\(sessionError)")
                @unknown default:
                    return .other("\(sessionError)")
                }
            }
            return nil
        }
    }

    @available(iOS 27.0, macOS 27.0, *)
    extension AppleReasoning {
        var level: ContextOptions.ReasoningLevel {
            switch self {
            case .light: return .light
            case .moderate: return .moderate
            case .deep: return .deep
            }
        }
    }
#endif
