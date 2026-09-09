import Foundation

// The structured-output half of the on-device model seam.
//
// `OnDeviceLanguageModel.generate` returns prose, which is why `OnDeviceAiProvider` used to
// refuse every request tagged `AiRunRequest.requiresStructuredOutputKey` outright: with no way
// to constrain the shape, a follow-up extraction came back as unparseable text and the failure
// looked exactly like the conversation having no follow-ups.
//
// Apple's Foundation Models framework has guided generation — `@Generable`, `@Guide`,
// `GenerationSchema` — so on a device with Apple Intelligence the shape CAN be enforced, and
// the refusal is now conditional on the model actually lacking the capability rather than
// unconditional. Everything here is additive: a model that cannot do guided generation
// (including every test double) inherits the defaults below, reports `false`, and the provider
// refuses exactly as it always did.

/// The output shapes the app's own parsers understand. A shape is not "some JSON": each case
/// names a body that an existing parser already consumes, so nothing downstream of the provider
/// seam has to know which model produced it.
public enum OnDeviceStructuredShape: String, Sendable, CaseIterable {
    /// `{"items":[{task,quote,ifForgotten,dueDate,confidence}]}` — `FollowUpExtractionParser`.
    case followUps

    /// `{"decisions":[{index,decision,reason,task,priority,dueDate}]}` — `FollowUpCurationParser`.
    case followUpCuration

    /// The shape a prompt template asks for, or nil when we have no on-device implementation
    /// for it. Fail-closed by construction: an unrecognised template refuses rather than being
    /// answered in some shape nobody agreed to.
    ///
    /// `BoundaryPromptTemplates.boundaryReview` is deliberately absent. It sets the same
    /// structured-output tag, so conversation splitting still falls back to the structural
    /// grouping in LocalOnly — a semantic boundary verdict from this model is a judgement call,
    /// and judgement is the thing it measurably cannot do.
    public static func forPromptId(_ id: String) -> OnDeviceStructuredShape? {
        switch id {
        case AiPromptTemplates.followUpExtraction.id: return .followUps
        case AiPromptTemplates.followUpCuration.id: return .followUpCuration
        default: return nil
        }
    }

    /// How much input this shape may be handed. The follow-up shape chunks and filters its own
    /// input, so it takes the conversation whole rather than the 12k-character slice the prose
    /// path uses — truncating a conversation is what makes a closed loop look open.
    public var maxInputChars: Int {
        switch self {
        case .followUps: return FollowUpWorker.maxTranscriptChars
        case .followUpCuration: return 20_000
        }
    }
}

public enum OnDeviceStructuredError: Error, Sendable {
    /// The model cannot constrain its output at all.
    case unsupported
    /// The model can, but not into this shape.
    case unsupportedShape(OnDeviceStructuredShape)
}

// The defaults for the two requirements `OnDeviceLanguageModel` declares. They are what makes
// this change additive: every conformer that predates it — and every test double — inherits
// "no, and here is a throw if you try anyway", and is refused exactly as it was before.
extension OnDeviceLanguageModel {
    /// Default `false`: a model that has not said otherwise cannot hold a shape.
    public var supportsStructuredOutput: Bool { false }

    /// The default throws, which the provider turns into `providerUnavailable`: a caller that
    /// needs a schema gets a failure it can retry rather than a confident empty answer built
    /// out of prose.
    public func generateStructured(
        _ shape: OnDeviceStructuredShape,
        instructions: String,
        prompt: String,
        maxOutputTokens: Int?
    ) async throws -> String {
        throw OnDeviceStructuredError.unsupported
    }
}

/// A synchronous, best-effort answer to "could this device produce follow-ups on its own?".
///
/// Exists because `LiveFollowUps.automaticProposalsEnabled` is a synchronous computed property
/// and its honesty depends on a real capability rather than on a constant. It used to return
/// `false` for LocalOnly on EVERY device, which was true only because the provider refused
/// structured output unconditionally; now that it does not, the question is genuinely about
/// this device.
public enum OnDeviceAiCapability {
    /// True when an on-device model is present, enabled and ready right now.
    ///
    /// Deliberately a snapshot and not cached: Apple Intelligence can be switched off, and a
    /// model can still be downloading, between one reading and the next. Callers that want a
    /// durable answer should ask again rather than remember this one.
    public static var canProposeFollowUps: Bool {
        #if canImport(FoundationModels)
            return FoundationModelsAvailability.isReadyNow
        #else
            return false
        #endif
    }
}
