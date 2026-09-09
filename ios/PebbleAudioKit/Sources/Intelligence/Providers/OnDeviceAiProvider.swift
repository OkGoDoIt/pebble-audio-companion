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

/// What the OS model hit, for the cases worth telling the user apart.
///
/// The bridge translates the platform's own error enum into this so `OnDeviceAiProvider` — which
/// cannot import FoundationModels, because the kit builds where that framework does not exist —
/// can say something specific. Before this, every one of them arrived as an opaque `Error` and
/// left as the single sentence "On-device AI generation failed", which is what the user was
/// shown for a request that had simply overflowed the context window.
public enum OnDeviceGenerationFailure: Error, Sendable, Equatable {
    /// The request did not fit the model's context window, input and output together.
    case contextWindowExceeded(String)
    /// The model's own content filter declined this material. Ordinary for an always-on
    /// microphone: it hears medication, money, arguments and swearing.
    case contentRefused
    /// The model's assets were not loadable at that moment — still downloading, or reclaimed.
    case assetsUnavailable
    /// The system throttled us, or too many generations were in flight.
    case busy
    /// The material is not in a language this model handles.
    case unsupportedLanguage
    /// Anything else the framework reported.
    case other(String)
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
    /// Still here because `AskBudget.forMode` plans a whole-archive read against it before any
    /// request exists, and because it is the ceiling a caller-supplied `maxInputChars` means.
    /// It is no longer what an ordinary request is sized by — see `OnDeviceContextBudget`, which
    /// derives that from the template's own output need and the grounding block actually in
    /// force, so a 200-token title and a 900-token long-form summary stop sharing one number.
    public static let defaultMaxInputChars = 8_000

    /// The fallback output cap, for a caller that pins one explicitly. Per-template budgets come
    /// from `OnDeviceTemplateBudget`; this is what a request outside that table would have got
    /// anyway.
    public static let defaultMaxOutputTokens = OnDeviceContextBudget.defaultOutputTokens

    public let id: String

    private let model: OnDeviceLanguageModel?
    /// A caller-supplied ceiling, or nil to let `OnDeviceContextBudget` size the request from
    /// what it actually costs. Only tests and `OnDeviceStructuredShape` pin one.
    private let maxInputChars: Int?
    /// Non-nil only where a caller pinned a cap. Otherwise the per-template budget decides, and
    /// a single constant no longer caps a long-form summary at 190 words.
    private let maxOutputTokens: Int?
    private let grounding: @Sendable () -> String?
    /// Read only on the failure path, to say whether Low Power Mode was on when the model would
    /// not run. `SystemLanguageModel.availability` has no case for it — the SDK's
    /// `UnavailableReason` is `deviceNotEligible` / `appleIntelligenceNotEnabled` /
    /// `modelNotReady` and nothing else — so a device that has paused Apple Intelligence to save
    /// power still reports `.available` and then fails at generation time. Naming it is the
    /// difference between "something went wrong" and "turn off Low Power Mode".
    private let lowPowerMode: @Sendable () -> Bool

    public init(
        model: OnDeviceLanguageModel?,
        maxInputChars: Int? = nil,
        maxOutputTokens: Int? = nil,
        grounding: @escaping @Sendable () -> String? = { nil },
        lowPowerMode: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    ) {
        self.model = model
        self.maxInputChars = maxInputChars
        self.maxOutputTokens = maxOutputTokens
        self.grounding = grounding
        self.lowPowerMode = lowPowerMode
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
        let instructions = buildInstructions(request.prompt.systemPrompt)
        let outputTokens =
            maxOutputTokens ?? OnDeviceTemplateBudget.outputTokens(forTemplateId: request.prompt.id)
        let userContent: String
        if let shape {
            // A structured shape does its own chunking and filtering, so it is handed the
            // conversation whole. Truncating one is how a loop that closes in the last ten
            // minutes of a recording comes back looking open. It never sends this body to the
            // model in one piece, so the window budget below does not apply to it.
            userContent = AiTranscriptFormatting.buildUserContent(
                request, maxInputChars: shape.maxInputChars)
        } else {
            userContent = try fitProseInput(
                request, instructions: instructions, outputTokens: outputTokens)
        }
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
                    maxOutputTokens: outputTokens
                )
            }
        } catch let error where error is CancellationError || error is AiError {
            throw error
        } catch is OnDeviceStructuredError {
            // The model said it could and then could not: unavailable, not failed, so a First
            // mode falls back to the cloud instead of burning one of the caller's attempts.
            throw AiError.providerUnavailable(providerId: id)
        } catch let failure as OnDeviceGenerationFailure {
            throw named(failure)
        } catch {
            throw AiError.providerFailed(
                "\(Self.deviceFailedSentence)\(lowPowerNote())", underlying: error)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AiError.providerFailed("On-device AI returned an empty completion")
        }
        return AiProviderResult(text: trimmed, modelUsed: activeModel.id)
    }

    // MARK: - Sizing one prose request

    /// The transcript body for a prose call, sized to what is genuinely left of the 4,096-token
    /// window once this template's instructions, this launch's grounding block and this
    /// template's answer are paid for.
    ///
    /// Throws rather than truncating in the two cases where truncating would produce something
    /// worse than nothing:
    ///
    ///  • the fixed costs alone leave less room than `minimumInputChars`, so whatever we sent
    ///    would be a note about the first two minutes of a recording; and
    ///  • the template `readsWholeConversation` (Extended summary) and the conversation does not
    ///    fit — a "full account" of the first 3% of a four-hour day, written confidently and
    ///    with citations, is the most convincing wrong thing this app could produce.
    ///
    /// Both say so in the message, because "this recording is longer than the on-device model
    /// can hold, use cloud AI" is actionable and "On-device AI generation failed" is not.
    private func fitProseInput(
        _ request: AiRunRequest, instructions: String, outputTokens: Int
    ) throws -> String {
        let budget = OnDeviceContextBudget.forRequest(
            outputTokens: outputTokens,
            systemPromptChars: instructions.count,
            // `instructions` already carries the grounding block, so it is not counted twice.
            groundingChars: 0
        )
        guard budget.fits else {
            throw AiError.providerFailed(
                "\"\(request.prompt.title)\" is \(Self.tooLongSentence)"
                    + " Its instructions and answer alone need more than the 4,096-token window."
            )
        }
        let ceiling = min(maxInputChars ?? budget.inputChars, budget.inputChars)
        // Built once at full length so the decision below is made on the real size. This is a
        // string concatenation over transcript text the caller already holds in memory — no
        // decode, no read, no second pass over the database.
        let full = AiTranscriptFormatting.buildUserContent(request, maxInputChars: Int.max)
        guard full.count > ceiling else { return full }
        guard !OnDeviceTemplateBudget.readsWholeConversation(templateId: request.prompt.id) else {
            throw AiError.providerFailed(
                "This recording is \(Self.tooLongSentence)"
                    + " It would fit about \(ceiling) of its \(full.count) characters,"
                    + " and \"\(request.prompt.title)\" has to read all of it."
            )
        }
        return AiTranscriptFormatting.buildUserContent(request, maxInputChars: ceiling)
    }

    // MARK: - Saying what actually happened

    /// The literals `AiFailure.classify` matches. Kept as one copy so a reworded message cannot
    /// silently stop being classifiable — which is exactly how a specific cause turns back into
    /// "Something went wrong".
    static let tooLongSentence = "\(AiFailure.Marker.tooLongForDevice)."
    static let deviceFailedSentence = "On-device AI generation failed."

    /// Maps the bridge's verdict onto a message that names the cause.
    private func named(_ failure: OnDeviceGenerationFailure) -> AiError {
        switch failure {
        case .contextWindowExceeded(let detail):
            // Reaching here means the budget above was wrong, not that the user did anything —
            // so it is worth the detail in the log.
            return .providerFailed(
                "This request was \(Self.tooLongSentence) \(detail)")
        case .contentRefused:
            return .providerFailed(
                "On-device AI \(AiFailure.Marker.contentRefused). Cloud AI has different rules.")
        case .assetsUnavailable:
            return .providerFailed(
                "The \(AiFailure.Marker.modelUnavailable) right now.\(lowPowerNote())")
        case .busy:
            return .providerFailed("The \(AiFailure.Marker.modelBusy). Try again in a moment.")
        case .unsupportedLanguage:
            return .providerFailed(
                "The \(AiFailure.Marker.modelUnavailable) for this language.")
        case .other(let detail):
            return .providerFailed("\(Self.deviceFailedSentence)\(lowPowerNote()) \(detail)")
        }
    }

    /// Appended to an on-device failure while Low Power Mode is on.
    ///
    /// Not a claim of causation — Apple documents no link, and `SystemLanguageModel.availability`
    /// has no case for it — but it is the one condition a person can change, and a device that
    /// reported `lowPower=true` minutes before an unexplained model failure should say so rather
    /// than leave them guessing.
    private func lowPowerNote() -> String {
        lowPowerMode() ? " \(AiFailure.Marker.lowPower), which can pause Apple Intelligence." : ""
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
