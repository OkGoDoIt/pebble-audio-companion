import Foundation
import Transcription

/// What writes titles, recaps, and answers while the OpenAI account is refused — the AI twin of
/// `TranscriptionBackup`, and a setting for the same reason: it stops applying by itself the
/// moment the account works again.
public enum AiBackup: String, CaseIterable, Codable, Sendable {
    /// Nothing named: the mode decides, as it always did (first modes use the phone, Cloud only
    /// waits).
    case none = "None"
    /// Apple's on-device model, in Cloud only too.
    case onDevice = "OnDevice"
    case applePrivateCloud = "ApplePrivateCloud"
}

public enum AiRouting {
    /// The remote provider to send to.
    public static func provider(
        selected: RemoteAiProvider, backup: AiBackup, openAiHeld: Bool
    ) -> RemoteAiProvider {
        guard selected == .openAi, openAiHeld, backup == .applePrivateCloud else { return selected }
        return .applePrivateCloud
    }

    /// The mode to run in. Same rule as `TranscriptionRouting.mode`.
    public static func mode(
        _ mode: AiProcessingMode, selected: RemoteAiProvider, backup: AiBackup, openAiHeld: Bool
    ) -> AiProcessingMode {
        guard mode == .remoteOnly, selected == .openAi, backup == .onDevice, openAiHeld
        else { return mode }
        return .remoteFirst
    }

    /// Whether the OpenAI account is held for a reason the AI side honours (see
    /// `OpenAiChatAiProvider.aiHoldingKinds`: a 403 about audio is not one).
    public static func openAiHold(in holds: CloudAccountHold) -> CloudAccountHold.Hold? {
        guard let hold = holds.active(for: .openAi),
            OpenAiChatAiProvider.aiHoldingKinds.contains(hold.kind)
        else { return nil }
        return hold
    }
}
