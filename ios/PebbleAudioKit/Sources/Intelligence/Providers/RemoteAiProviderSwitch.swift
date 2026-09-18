import Foundation

/// The AI router's remote slot when there is more than one thing "remote" can mean.
///
/// `AiModeRouter` is built once, at composition, and holds its two providers for the life of
/// the process; the `RemoteAiProvider` setting changes whenever the person changes it. So the
/// slot is this: a thin `AiProvider` that re-reads the setting on every call and hands the
/// request to whichever provider it names — the same shape `SelectableLocalTranscriptionProvider`
/// has on the transcription axis. The router never sees the switch; it falls back around
/// failures per mode exactly as it does for a single remote provider.
///
/// Fail-closed on the case that cannot happen but must not be wrong if it does: a setting
/// that names Private Cloud Compute on an OS without it (`applePrivateCloud: nil`) is
/// UNAVAILABLE, never quietly OpenAI. Sending transcripts to a provider the person did not
/// choose is the one thing this slot exists to make impossible.
public final class RemoteAiProviderSwitch: AiProvider, AiInputWindowReporting, @unchecked Sendable
{
    private let selected: @Sendable () -> RemoteAiProvider
    private let openAi: AiProvider
    private let applePrivateCloud: AiProvider?

    /// - Parameters:
    ///   - selected: the setting, read per call.
    ///   - applePrivateCloud: nil where the OS has no such model (iOS 26).
    public init(
        selected: @escaping @Sendable () -> RemoteAiProvider,
        openAi: AiProvider,
        applePrivateCloud: AiProvider?
    ) {
        self.selected = selected
        self.openAi = openAi
        self.applePrivateCloud = applePrivateCloud
    }

    /// The id of the provider the setting names right now, so a log line and a `RoutedAiResult`
    /// say which one actually ran. `apple-pcc` even when that provider is absent: the setting
    /// named it, and "unavailable: apple-pcc" is the honest line for that configuration.
    public var id: String {
        switch selected() {
        case .openAi: return openAi.id
        case .applePrivateCloud: return applePrivateCloud?.id ?? ApplePrivateCloudAiProvider.providerId
        }
    }

    /// The provider the setting names, or nil when it names one this OS does not have.
    private var current: AiProvider? {
        switch selected() {
        case .openAi: return openAi
        case .applePrivateCloud: return applePrivateCloud
        }
    }

    public func isAvailable() async -> Bool {
        guard let current else { return false }
        return await current.isAvailable()
    }

    public func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        guard let current else { throw AiError.providerUnavailable(providerId: id) }
        return try await current.run(request)
    }

    // MARK: AiInputWindowReporting

    public func inputChars() async -> Int? {
        guard let reporting = current as? AiInputWindowReporting else { return nil }
        return await reporting.inputChars()
    }

    public func contextTokens() async -> Int? {
        guard let reporting = current as? AiInputWindowReporting else { return nil }
        return await reporting.contextTokens()
    }
}
