import Foundation

// What transcribes while the chosen cloud provider's account is refused (`CloudAccountHold`).
//
// A Soniox balance ran out on 2026-11-22 and nobody knew for three days: the on-device engine
// took over, as the mode says it should, and that was the whole story. Two things were missing.
// Being told (`CloudAccountIssue`), and being able to say "use OpenAI until it works again"
// without changing the provider for good and having to remember to change it back.
//
// So the backup is a SETTING, not a switch of provider: it names what stands in while the
// account is held, and stops applying the moment the hold lifts. Nothing is sent to a provider
// the person did not name, here or as the main one.

/// What stands in for the selected cloud transcription provider while its account is refused.
public enum TranscriptionBackup: String, CaseIterable, Codable, Sendable {
    /// Nothing named: the mode decides, as it always did (first modes use the phone, Cloud only
    /// waits).
    case none = "None"
    /// The on-device engine, in Cloud only too.
    case onDevice = "OnDevice"
    case openAi = "OpenAi"
    case soniox = "Soniox"

    /// The cloud provider this names, if it names one.
    public var provider: CloudProvider? {
        switch self {
        case .none, .onDevice: return nil
        case .openAi: return .openAi
        case .soniox: return .soniox
        }
    }

    public init(provider: CloudProvider) {
        switch provider {
        case .openAi: self = .openAi
        case .soniox: self = .soniox
        }
    }
}

/// Where transcription goes right now, given the choice, the backup, and which accounts are held.
/// Pure, so every combination is pinned in `TranscriptionBackupTests`.
public enum TranscriptionRouting {
    /// The cloud provider to send to: the selected one, or its backup while the selected one's
    /// account is held and the backup can take work (it has a key and is not held itself).
    public static func provider(
        selected: CloudProvider,
        backup: TranscriptionBackup,
        isHeld: (CloudProvider) -> Bool,
        hasKey: (CloudProvider) -> Bool
    ) -> CloudProvider {
        guard let standIn = backup.provider, standIn != selected, isHeld(selected),
            hasKey(standIn), !isHeld(standIn)
        else { return selected }
        return standIn
    }

    /// The mode to run in: the chosen one, except that Cloud only with the phone named as the
    /// backup runs as Cloud first while the account is held. No other mode changes: the first
    /// modes already use the phone, and Local only never had a cloud to lose.
    public static func mode(
        _ mode: TranscriptionMode,
        selected: CloudProvider,
        backup: TranscriptionBackup,
        isHeld: (CloudProvider) -> Bool
    ) -> TranscriptionMode {
        guard mode == .remoteOnly, backup == .onDevice, isHeld(selected) else { return mode }
        return .remoteFirst
    }
}
