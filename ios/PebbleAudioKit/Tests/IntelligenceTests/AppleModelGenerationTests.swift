import Foundation
import Testing

@testable import Intelligence

#if canImport(FoundationModels)
    import FoundationModels

    // The translation of Apple's error enums into the kit's own — for BOTH generations of the
    // framework's vocabulary. iOS 26 throws `LanguageModelSession.GenerationError`; iOS 27 throws
    // `LanguageModelError` for the same situations, and a bridge that only knew the first turned
    // every iOS 27 overflow back into "On-device AI generation failed". These run on the host
    // (macOS 27, where both enums exist) and construct the errors directly.

    @Suite("Apple model generation · error translation")
    struct AppleModelGenerationTests {
        @Test func theIOS26EnumStillTranslates() {
            let context = LanguageModelSession.GenerationError.Context(
                debugDescription: "Content contains 4179 tokens")
            #expect(
                AppleModelGeneration.translate(
                    LanguageModelSession.GenerationError.exceededContextWindowSize(context))
                    == .contextWindowExceeded("Content contains 4179 tokens"))
            #expect(
                AppleModelGeneration.translate(
                    LanguageModelSession.GenerationError.guardrailViolation(context))
                    == .contentRefused)
            #expect(
                AppleModelGeneration.translate(
                    LanguageModelSession.GenerationError.assetsUnavailable(context))
                    == .assetsUnavailable)
            #expect(
                AppleModelGeneration.translate(
                    LanguageModelSession.GenerationError.rateLimited(context)) == .busy)
            #expect(
                AppleModelGeneration.translate(
                    LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(context))
                    == .unsupportedLanguage)
        }

        /// The iOS 27 regression: the same overflow, in the new type, must land on the same
        /// case — the one `AiFailure.classify` reads as `tooLongForDevice`.
        @Test func theIOS27EnumTranslatesToTheSameCases() throws {
            guard #available(iOS 27.0, macOS 27.0, *) else { return }
            let overflow = LanguageModelError.contextSizeExceeded(
                LanguageModelError.ContextSizeExceeded(
                    contextSize: 8_192, tokenCount: 9_160,
                    debugDescription: "Content contains 9160 tokens"))
            #expect(
                AppleModelGeneration.translate(overflow)
                    == .contextWindowExceeded("Content contains 9160 tokens"))
            #expect(
                AppleModelGeneration.translate(
                    LanguageModelError.rateLimited(
                        LanguageModelError.RateLimited(resetDate: nil, debugDescription: "slow")))
                    == .busy)
            #expect(
                AppleModelGeneration.translate(LanguageModelSession.Error.concurrentRequests)
                    == .busy)
        }

        /// Cancellation is never a generation failure, and an error nobody recognises comes back
        /// nil so the caller rethrows it untouched rather than dressing it up.
        @Test func unknownErrorsAreLeftAlone() {
            struct Boom: Error {}
            #expect(AppleModelGeneration.translate(CancellationError()) == nil)
            #expect(AppleModelGeneration.translate(Boom()) == nil)
        }
    }
#endif
