import Foundation

// Port of `core/ai/.../OnDeviceAiProvider.kt`.

/// Readiness of an OS on-device language model, mapped from the platform's own status.
public enum OnDeviceAvailability: Sendable, Equatable {
    /// The model is present and ready to run now.
    case available

    /// Supported, but the model must be downloaded first.
    case downloadable

    /// Supported and currently downloading/initializing; try again later.
    case downloading

    /// Not supported on this device/OS, or disabled by the user.
    case unavailable
}

/// Abstraction over an OS-provided on-device LLM (Apple Foundation Models). Platform code
/// implements this; `OnDeviceAiProvider` adapts it to `AiProvider`. Kept as a protocol so the
/// provider logic is unit-testable with a fake implementation (exactly like the KMP
/// `OnDeviceLanguageModel` interface).
public protocol OnDeviceLanguageModel: Sendable {
    /// Stable identifier recorded as the model used, e.g. "apple-foundation-models".
    var id: String { get }

    func availability() async -> OnDeviceAvailability

    /// Runs the model with system-style `instructions` and a user `prompt`, returning the
    /// completion text. `maxOutputTokens` is a hint (nil = provider default). Implementations
    /// should throw on failure; `CancellationError` must propagate.
    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String

    // The two members below are REQUIREMENTS with defaults in `OnDeviceStructuredOutput.swift`,
    // not extension-only members. That distinction is load-bearing and cost a debugging round:
    // `OnDeviceAiProvider` holds an existential, and a member that lives only in a protocol
    // extension is dispatched statically — the Foundation Models bridge would have gone on
    // reporting `false` from the extension's default and every structured request would have
    // been refused on every device, silently, exactly as before. Declared here, they dispatch
    // to the conformer; defaulted there, every existing conformer and test double still
    // compiles untouched and still says "no".

    /// Whether this model can be held to a named output shape.
    var supportsStructuredOutput: Bool { get }

    /// Produces the body named by `shape`. Implementations should throw on failure;
    /// `CancellationError` must propagate.
    func generateStructured(
        _ shape: OnDeviceStructuredShape,
        instructions: String,
        prompt: String,
        maxOutputTokens: Int?
    ) async throws -> String
}

/// `AiProvider` backed by an on-device OS model. This is a fully local, private provider: it
/// requires no remote consent and no API key because no data leaves the device. It is wired
/// into the `AiModeRouter`'s local slot, so LocalOnly runs on-device and LocalFirst/
/// RemoteFirst fall back to/from the cloud as configured.
///
/// Fail-closed: when no model is injected (platform unsupported / bridge not registered) or
/// the model reports anything other than `.available`, the provider is unavailable and rows
/// fall back to transcript snippets — it never blocks devices that lack on-device AI.
public final class OnDeviceAiProvider: AiProvider, @unchecked Sendable {
    /// On-device context windows are small; keep input well under the budget. Titles/
    /// summaries care about the gist, so a generous-but-bounded slice of a long transcript
    /// is fine.
    ///
    /// 12,000 was over the cliff, not near it. Apple Foundation Models reports a **4,096-token**
    /// window, and the ceiling was binary-searched against the real model: 11,047 characters
    /// bare, and 9,946 once the personal-context grounding block is prepended — which it always
    /// is. So a 12,000-character transcript threw `exceededContextWindowSize` and failed EVERY
    /// on-device annotation, with or without grounding, on every device. 8,000 leaves room for
    /// the grounding block, the instructions and the reply.
    public static let defaultMaxInputChars = 8_000

    /// Title + 1-3 sentence summary is short; cap output so generation stays fast.
    public static let defaultMaxOutputTokens = 256

    public let id: String

    private let model: OnDeviceLanguageModel?
    private let maxInputChars: Int
    private let maxOutputTokens: Int?
    private let grounding: @Sendable () -> String?

    public init(
        model: OnDeviceLanguageModel?,
        maxInputChars: Int = OnDeviceAiProvider.defaultMaxInputChars,
        maxOutputTokens: Int? = OnDeviceAiProvider.defaultMaxOutputTokens,
        grounding: @escaping @Sendable () -> String? = { nil }
    ) {
        self.model = model
        self.maxInputChars = maxInputChars
        self.maxOutputTokens = maxOutputTokens
        self.grounding = grounding
        self.id = model?.id ?? "on-device"
    }

    public func isAvailable() async -> Bool {
        await model?.availability() == .available
    }

    public func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        let needsSchema = request.metadata[AiRunRequest.requiresStructuredOutputKey] != nil
        guard let activeModel = model else {
            throw AiError.providerUnavailable(providerId: id)
        }
        guard await activeModel.availability() == .available else {
            throw AiError.providerUnavailable(providerId: id)
        }
        // Some answers are only meaningful in the shape the prompt names. This provider used to
        // refuse ALL of them, because a text-only model cannot be held to one; it now refuses
        // only when the model in front of it genuinely cannot, or when nothing on-device knows
        // how to produce that particular shape. Refusing is still the honest outcome in those
        // cases: the caller records a failure it can retry, rather than a confident empty answer
        // built out of unparseable prose.
        var shape: OnDeviceStructuredShape?
        if needsSchema {
            guard activeModel.supportsStructuredOutput,
                let matched = OnDeviceStructuredShape.forPromptId(request.prompt.id)
            else { throw AiError.providerUnavailable(providerId: id) }
            shape = matched
        }
        let userContent = AiTranscriptFormatting.buildUserContent(
            request,
            // A structured shape does its own chunking and filtering, so it is handed the
            // conversation whole. Truncating one to 12k characters is how a loop that closes in
            // the last ten minutes of a recording comes back looking open.
            maxInputChars: shape?.maxInputChars ?? maxInputChars)
        let instructions = buildInstructions(request.prompt.systemPrompt)
        let text: String
        do {
            if let shape {
                text = try await activeModel.generateStructured(
                    shape,
                    instructions: instructions,
                    prompt: userContent,
                    maxOutputTokens: maxOutputTokens
                )
            } else {
                text = try await activeModel.generate(
                    instructions: instructions,
                    prompt: userContent,
                    maxOutputTokens: maxOutputTokens
                )
            }
        } catch let error where error is CancellationError || error is AiError {
            throw error
        } catch is OnDeviceStructuredError {
            // The model said it could and then could not: unavailable, not failed, so a First
            // mode falls back to the cloud instead of burning one of the caller's attempts.
            throw AiError.providerUnavailable(providerId: id)
        } catch {
            throw AiError.providerFailed("On-device AI generation failed", underlying: error)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AiError.providerFailed("On-device AI returned an empty completion")
        }
        return AiProviderResult(text: trimmed, modelUsed: activeModel.id)
    }

    private func buildInstructions(_ systemPrompt: String) -> String {
        guard
            let groundingBlock = grounding()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !groundingBlock.isEmpty
        else { return systemPrompt }
        return "\(groundingBlock)\n\n\(systemPrompt)"
    }
}
