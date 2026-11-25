import Foundation
import Intelligence
import Transcription

// A cloud account that has stopped taking work, as something to tell the person: which account,
// what is wrong with it, since when, and what is doing its work meanwhile. `CloudAccountHold`
// is the mechanism; this is the news. One issue per account, even when one account (OpenAI)
// does both jobs, because it is one thing to fix.

public struct CloudAccountIssue: Equatable, Sendable, Identifiable {
    /// What is doing the account's work while it is refused.
    public enum StandIn: Equatable, Sendable {
        case waiting
        case onDevice
        case provider(CloudProvider)
        case applePrivateCloud
    }

    public var provider: CloudProvider
    public var kind: TranscriptionFailureKind
    public var sinceMs: Int64
    /// Nil when this account does not transcribe in the current settings.
    public var transcription: StandIn?
    /// True when the account is only ever asked for recordings the phone could not finish
    /// (Local first), so it has nothing to stand in for most of the time.
    public var transcriptionIsFallbackOnly: Bool
    /// Nil when this account does no AI work in the current settings.
    public var ai: StandIn?

    public var id: String { "\(provider.rawValue)|\(sinceMs)" }

    public init(
        provider: CloudProvider, kind: TranscriptionFailureKind, sinceMs: Int64,
        transcription: StandIn? = nil, transcriptionIsFallbackOnly: Bool = false,
        ai: StandIn? = nil
    ) {
        self.provider = provider
        self.kind = kind
        self.sinceMs = sinceMs
        self.transcription = transcription
        self.transcriptionIsFallbackOnly = transcriptionIsFallbackOnly
        self.ai = ai
    }

    /// Every account in use that is being refused, in the order the jobs run: transcription's
    /// first.
    public static func resolve(
        settings: some RuntimeSettings,
        hold: (CloudProvider) -> CloudAccountHold.Hold?,
        hasKey: (CloudProvider) -> Bool,
        onDeviceTranscriptionReady: Bool,
        onDeviceAiReady: Bool,
        applePrivateCloudReady: Bool
    ) -> [CloudAccountIssue] {
        var issues: [CloudAccountIssue] = []

        let main = settings.cloudTranscriptionProvider
        if settings.transcriptsConfigured, settings.cloudTranscriptionEnabled, let held = hold(main) {
            let sending = TranscriptionRouting.provider(
                selected: main, backup: settings.transcriptionBackup,
                isHeld: { hold($0) != nil }, hasKey: hasKey)
            let mode = TranscriptionRouting.mode(
                settings.transcriptionMode, selected: main, backup: settings.transcriptionBackup,
                isHeld: { hold($0) != nil })
            let standIn: StandIn
            if sending != main {
                standIn = .provider(sending)
            } else if mode != .remoteOnly, onDeviceTranscriptionReady {
                standIn = .onDevice
            } else {
                standIn = .waiting
            }
            issues.append(
                CloudAccountIssue(
                    provider: main, kind: held.kind, sinceMs: held.sinceMs, transcription: standIn,
                    transcriptionIsFallbackOnly: settings.transcriptionMode == .localFirst))
        }

        if settings.remoteAiEnabled, settings.remoteAiProvider == .openAi, let held = hold(.openAi),
            OpenAiChatAiProvider.aiHoldingKinds.contains(held.kind)
        {
            let mode = AiRouting.mode(
                settings.aiMode, selected: .openAi, backup: settings.aiBackup, openAiHeld: true)
            let standIn: StandIn
            if settings.aiBackup == .applePrivateCloud, applePrivateCloudReady {
                standIn = .applePrivateCloud
            } else if mode != .remoteOnly, onDeviceAiReady {
                standIn = .onDevice
            } else {
                standIn = .waiting
            }
            if let index = issues.firstIndex(where: { $0.provider == .openAi }) {
                issues[index].ai = standIn
            } else {
                issues.append(
                    CloudAccountIssue(
                        provider: .openAi, kind: held.kind, sinceMs: held.sinceMs, ai: standIn))
            }
        }
        return issues
    }
}
