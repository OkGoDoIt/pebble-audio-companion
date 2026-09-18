import Foundation
import Transcription

// Apple Private Cloud Compute as the AI router's remote slot.
//
// iOS 27's `PrivateCloudComputeLanguageModel` is a remote model with three properties no other
// remote has: no key and no account to set up, Apple's verifiable no-retention guarantee, and a
// per-person daily allowance. It is an `AiProvider` like `OpenAiChatAiProvider`, chosen by the
// `RemoteAiProvider` setting, and the router falls back around it per mode exactly as it does
// for OpenAI. What is different is what can go wrong — a used-up allowance, a build without
// the managed entitlement — and each of those has its own honest outcome below.
//
// Split the same way as the on-device pair (`OnDeviceLanguageModel` / `OnDeviceAiProvider`):
// this file is the provider and the seam, pure Swift, unit-tested with fakes;
// `PrivateCloudComputeLanguageModel.swift` is the bridge over the framework, iOS 27 only.

/// Readiness of Apple's Private Cloud Compute model, from the platform's own status plus the
/// one fact the platform does not report.
public enum ApplePrivateCloudAvailability: Sendable, Equatable {
    /// Ready to take a request now.
    case available
    /// `deviceNotEligible` — this hardware will never run it.
    case deviceNotEligible
    /// `systemNotReady` — signed out, still setting up, or Apple Intelligence off.
    case systemNotReady
    /// The framework said ready and a request then failed the way a process without the
    /// `com.apple.developer.private-cloud-compute` entitlement fails. Learned from a failed
    /// request, never read from the framework — see `ApplePrivateCloudBuildStatus`.
    case notEnabledForThisBuild
    /// An OS that predates the model (iOS 26). Never a crash, never a changed behaviour there.
    case unsupported

    public var isAvailable: Bool { self == .available }
}

/// How much of the daily allowance is left, as the framework reports it.
public struct ApplePrivateCloudQuota: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case belowLimit(approaching: Bool)
        case limitReached
    }

    public var status: Status
    /// When the allowance comes back, when the framework says.
    public var resetDate: Date?
    /// Whether Apple offers a way to ask for more (`limitIncreaseSuggestion`).
    public var canRequestMore: Bool

    public init(status: Status, resetDate: Date? = nil, canRequestMore: Bool = false) {
        self.status = status
        self.resetDate = resetDate
        self.canRequestMore = canRequestMore
    }

    public var isLimitReached: Bool { status == .limitReached }
}

/// What the Private Cloud Compute model hit, in the cases worth telling apart. The bridge
/// translates the framework's enums into this so the provider can say something specific
/// without importing FoundationModels.
public enum ApplePrivateCloudFailure: Error, Sendable, Equatable {
    /// The daily allowance is used up. Comes back on its own.
    case quotaLimitReached(resetDate: Date?)
    /// The request never reached Apple.
    case networkFailure(String)
    /// Apple's service could not take the request right now.
    case serviceUnavailable(String)
    /// The shape a process without the entitlement gets: `LanguageModelError` code -1 over
    /// `ModelManagerError 1046`. Not transient, and about this binary, not this request.
    case notEnabledForThisBuild(String)
    /// The model ran and said something specific — the same vocabulary the on-device path uses.
    case generation(OnDeviceGenerationFailure)
}

/// Abstraction over Apple's Private Cloud Compute model, so the provider is unit-testable
/// without iOS 27, the entitlement, or a network.
public protocol ApplePrivateCloudLanguageModel: Sendable {
    /// Stable identifier recorded as the model used, e.g. "apple-private-cloud-compute".
    var id: String { get }

    func availability() async -> ApplePrivateCloudAvailability

    /// Nil where the platform cannot say.
    func quota() async -> ApplePrivateCloudQuota?

    /// The model's context window, input and output together.
    func contextWindowTokens() async -> Int

    /// Prose. Throws `ApplePrivateCloudFailure` for anything the framework said something
    /// specific about; `CancellationError` must propagate.
    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String

    /// The body named by `shape`, from one guided-generation call over the whole prompt. Throws
    /// like `generate`.
    func generateStructured(
        _ shape: OnDeviceStructuredShape,
        instructions: String,
        prompt: String,
        maxOutputTokens: Int?
    ) async throws -> String
}

/// What a failed request taught this process about the binary it is running in.
///
/// `PrivateCloudComputeLanguageModel.availability` reads `.available` whether or not the process
/// carries the managed entitlement; the missing entitlement only shows up when a request fails
/// (measured on macOS 27: `LanguageModelError -1` over `ModelManagerError 1046`). The fact is
/// about the build, so it is remembered for the life of the process: `isAvailable()` answers
/// false from then on and a "first" mode goes straight to its fallback instead of paying a
/// doomed round trip per job, and the Settings row can say "not available for this build"
/// rather than "ready". One shared instance by default; tests inject their own.
public final class ApplePrivateCloudBuildStatus: @unchecked Sendable {
    public static let shared = ApplePrivateCloudBuildStatus()

    private let lock = NSLock()
    private var _notEnabled = false

    public init() {}

    public var isKnownNotEnabled: Bool { lock.withLock { _notEnabled } }

    public func markNotEnabled() { lock.withLock { _notEnabled = true } }
}

/// `AiProvider` over Apple Private Cloud Compute.
///
/// Fail-closed: transcripts leave the phone only when the user has enabled remote AI consent
/// (`remoteAiEnabled`, the same gate as OpenAI's) and the model reports itself available; on an
/// OS without the model, or in a build without the entitlement, the provider is unavailable
/// and the router treats it exactly as it treats a missing key.
public final class ApplePrivateCloudAiProvider: AiProvider, AiInputWindowReporting,
    @unchecked Sendable
{
    public static let providerId = "apple-pcc"

    /// The window the framework reports for the model (`contextSize`, measured on macOS 27),
    /// and what the bridge falls back to when the read itself fails.
    public static let defaultContextTokens = 32_768

    public let id = ApplePrivateCloudAiProvider.providerId

    private let model: ApplePrivateCloudLanguageModel?
    private let remoteConsent: @Sendable () -> Bool
    private let grounding: @Sendable () -> String?
    private let buildStatus: ApplePrivateCloudBuildStatus
    private let log: @Sendable (String) -> Void

    /// - Parameters:
    ///   - model: nil on an OS without the model; the provider is then simply unavailable.
    ///   - remoteConsent: `RuntimeSettings.remoteAiEnabled` — the same consent OpenAI needs.
    ///   - buildStatus: process-wide by default; tests pass their own.
    public init(
        model: ApplePrivateCloudLanguageModel?,
        remoteConsent: @escaping @Sendable () -> Bool,
        grounding: @escaping @Sendable () -> String? = { nil },
        buildStatus: ApplePrivateCloudBuildStatus = .shared,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.model = model
        self.remoteConsent = remoteConsent
        self.grounding = grounding
        self.buildStatus = buildStatus
        self.log = log
    }

    public func isAvailable() async -> Bool {
        guard remoteConsent(), let model, !buildStatus.isKnownNotEnabled else { return false }
        return await model.availability() == .available
    }

    /// The readiness the Settings row shows: the framework's answer, corrected by what a failed
    /// request has taught us about this build.
    public func availability() async -> ApplePrivateCloudAvailability {
        guard let model else { return .unsupported }
        if buildStatus.isKnownNotEnabled { return .notEnabledForThisBuild }
        return await model.availability()
    }

    public func quota() async -> ApplePrivateCloudQuota? {
        await model?.quota()
    }

    // MARK: AiInputWindowReporting

    public func inputChars() async -> Int? { nil }

    public func contextTokens() async -> Int? {
        guard let model else { return nil }
        return await model.contextWindowTokens()
    }

    // MARK: Running one request

    public func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        guard remoteConsent() else {
            throw AiError.consentRequired(providerId: id)
        }
        guard let model, !buildStatus.isKnownNotEnabled else {
            throw AiError.providerUnavailable(providerId: id)
        }
        guard await model.availability() == .available else {
            throw AiError.providerUnavailable(providerId: id)
        }

        let instructions = buildInstructions(request.prompt.systemPrompt)
        let outputTokens = CloudOutputBudget.maxOutputTokens(forTemplateId: request.prompt.id)
        let window = await model.contextWindowTokens()
        // Sized like the on-device path — the answer, the safety margin and the instructions
        // come out of the same window — but against this model's window, which is eight times
        // the on-device one. This model cannot count tokens for us, so the estimate is what
        // there is; it is pessimistic, and truncation marks the cut.
        let budget = OnDeviceContextBudget.forRequest(
            outputTokens: outputTokens, systemPromptChars: instructions.count,
            groundingChars: 0, windowTokens: window)
        let userContent = AiTranscriptFormatting.buildUserContent(
            request, maxInputChars: budget.inputChars)

        // A shape this model has a guided-generation form for is held to it, in one call over
        // the whole conversation — what OpenAI is asked for with a JSON schema. A structured
        // request with no form (the boundary review) is answered as the prompt asks, as
        // OpenAI answers it; this is a large model, not the 3B one that had to be refused.
        let shape =
            request.metadata[AiRunRequest.requiresStructuredOutputKey] != nil
            ? OnDeviceStructuredShape.forPromptId(request.prompt.id) : nil

        let text: String
        do {
            if let shape {
                text = try await model.generateStructured(
                    shape, instructions: instructions, prompt: userContent,
                    maxOutputTokens: outputTokens)
            } else {
                text = try await model.generate(
                    instructions: instructions, prompt: userContent,
                    maxOutputTokens: outputTokens)
            }
        } catch let error where error is CancellationError || error is AiError {
            throw error
        } catch let failure as ApplePrivateCloudFailure {
            throw named(failure)
        } catch {
            throw AiError.providerFailed(
                "\(Self.failedSentence) \(error)", underlying: error)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AiError.providerFailed("\(Self.name) returned an \(AiFailure.Marker.emptyAnswer)")
        }
        return AiProviderResult(text: trimmed, modelUsed: model.id)
    }

    // MARK: - Saying what actually happened

    static let name = "Apple Private Cloud Compute"
    static let failedSentence = "\(name) could not finish this request."

    /// Maps the bridge's verdict onto the outcome the router and the copy can act on.
    ///
    ///  • a used-up allowance → `providerFailed` carrying `usageLimitMarker`, which
    ///    `ProcessingFallbackCause` reads as `.usageLimit` and `AiFailure` as `.usageLimit`;
    ///  • no network → `providerFailed` chaining a `URLError`, the same shape a transport
    ///    failure has, so both classifiers read `.noConnection`;
    ///  • the service down, or a build without the entitlement → `providerUnavailable`, which
    ///    is `.notAvailable` / `.notConfigured`: a First mode falls back silently, and the
    ///    Settings row is where the reason lives. The entitlement case is also remembered.
    private func named(_ failure: ApplePrivateCloudFailure) -> AiError {
        switch failure {
        case .quotaLimitReached(let resetDate):
            var message = "\(Self.name) has reached its \(AiFailure.Marker.usageLimit)."
            if let resetDate {
                message += " It resets at \(Self.iso(resetDate))."
            }
            log("apple pcc: usage limit reached reset=\(resetDate.map(Self.iso) ?? "unknown")")
            return .providerFailed(message)
        case .networkFailure(let detail):
            return .providerFailed(
                "\(Self.name) could not be reached. \(detail)",
                underlying: URLError(.notConnectedToInternet))
        case .serviceUnavailable(let detail):
            log("apple pcc: service unavailable — \(String(detail.prefix(200)))")
            return .providerUnavailable(providerId: id)
        case .notEnabledForThisBuild(let detail):
            buildStatus.markNotEnabled()
            log(
                "apple pcc: not enabled for this build (missing entitlement) — "
                    + "\(String(detail.prefix(200)))")
            return .providerUnavailable(providerId: id)
        case .generation(let generation):
            return namedGeneration(generation)
        }
    }

    /// The on-device vocabulary, in this provider's own words. The on-device markers are not
    /// reused: their sentences name the on-device model, and "On-device AI declined this
    /// recording" about a request that went to Apple's cloud would be the wrong-provider
    /// headline this app already had once.
    private func namedGeneration(_ failure: OnDeviceGenerationFailure) -> AiError {
        switch failure {
        case .contextWindowExceeded(let detail):
            // The request was sized to the window above, so reaching here means that sizing
            // was wrong — worth the detail in the log.
            return .providerFailed("\(Self.failedSentence) It did not fit its window. \(detail)")
        case .contentRefused:
            return .providerFailed("\(Self.name) \(AiFailure.Marker.cloudContentRefused).")
        case .busy:
            // A parenthesised 429 is what the shared taxonomy reads as rate limiting — busy,
            // not broke, try again later.
            return .providerFailed("\(Self.name) is rate limiting this request (429).")
        case .assetsUnavailable, .unsupportedLanguage:
            log("apple pcc: unavailable for this request — \(failure)")
            return .providerUnavailable(providerId: id)
        case .other(let detail):
            return .providerFailed("\(Self.failedSentence) \(detail)")
        }
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
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
