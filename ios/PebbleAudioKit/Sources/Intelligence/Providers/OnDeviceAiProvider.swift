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
    public static let defaultMaxInputChars = 12_000

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
        guard let activeModel = model else {
            throw AiError.providerUnavailable(providerId: id)
        }
        guard await activeModel.availability() == .available else {
            throw AiError.providerUnavailable(providerId: id)
        }
        let userContent = AiTranscriptFormatting.buildUserContent(
            request, maxInputChars: maxInputChars)
        let instructions = buildInstructions(request.prompt.systemPrompt)
        let text: String
        do {
            text = try await activeModel.generate(
                instructions: instructions,
                prompt: userContent,
                maxOutputTokens: maxOutputTokens
            )
        } catch let error where error is CancellationError || error is AiError {
            throw error
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
