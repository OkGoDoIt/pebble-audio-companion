import Foundation

/// Which remote model the AI router's "remote" slot is. The four `AiProcessingMode`s stay as
/// they are — local/remote first/only — and this picks what "remote" means, the way
/// `CloudProvider` picks what cloud transcription means.
///
/// `openAi` is the historical remote (the user's own key). `applePrivateCloud` is Apple's
/// Private Cloud Compute model (iOS 27): no key, no account, Apple's verifiable no-retention
/// guarantee, a per-user daily quota. The raw values are persisted.
public enum RemoteAiProvider: String, CaseIterable, Sendable, Codable {
    case openAi = "OpenAI"
    case applePrivateCloud = "ApplePrivateCloud"

    public static let `default`: RemoteAiProvider = .openAi
}
