import CompanionRuntime
import Foundation
import Intelligence
import Transcription

// A cloud account that has stopped taking work: what is wrong, what is doing its work meanwhile,
// and the two things to do about it. Register: the status card's — a heading, one line, buttons
// that say what they do.

extension Copy {
    enum CloudAccount {
        static let addFunds = "Add Funds"
        static let raiseLimit = "Raise Limit"
        static let checkKey = "Check Key"
        static let chooseBackup = "Choose Backup"
        static let transcriptionSection = "Transcription"
        static let aiSection = "Summaries and answers"
        static let thisIPhone = "This iPhone"
        static let addAKey = "Add a key"
        static let notSetUp = "Not set up on this iPhone"

        static func headline(_ kind: TranscriptionFailureKind, provider: String) -> String {
            switch kind {
            case .spendingLimitReached: return "\(provider) reached its spending limit"
            case .keyRejected: return "\(provider) didn’t accept your key"
            case .keyNotPermitted: return "Your \(provider) key can’t transcribe"
            default: return "\(provider) is out of credit"
            }
        }

        static func fixAction(_ kind: TranscriptionFailureKind) -> String {
            switch kind {
            case .spendingLimitReached: return raiseLimit
            case .keyRejected, .keyNotPermitted: return checkKey
            default: return addFunds
            }
        }

        /// The Settings row: "Soniox · out of credit".
        static func settingsValue(_ issue: CloudAccountIssue) -> String {
            "\(issue.provider.displayName) · \(issue.kind.shortReason)"
        }

        static func checking(_ provider: String) -> String { "Checking \(provider)…" }

        /// The one line: what is doing the account's work.
        static func line(_ issue: CloudAccountIssue) -> String {
            switch (issue.transcription, issue.ai) {
            case (.onDevice?, .onDevice?) where !issue.transcriptionIsFallbackOnly:
                return "This iPhone is transcribing and writing summaries meanwhile."
            case (.waiting?, .waiting?) where !issue.transcriptionIsFallbackOnly:
                return "New transcripts, summaries, and answers are waiting."
            default:
                return [
                    issue.transcription.map {
                        transcription($0, fallbackOnly: issue.transcriptionIsFallbackOnly)
                    },
                    issue.ai.map(ai),
                ].compactMap { $0 }.joined(separator: " ")
            }
        }

        private static func transcription(
            _ standIn: CloudAccountIssue.StandIn, fallbackOnly: Bool
        ) -> String {
            switch standIn {
            case .provider(let provider) where fallbackOnly:
                return "\(provider.displayName) is taking the recordings this iPhone can’t finish."
            case .onDevice where fallbackOnly, .waiting where fallbackOnly:
                return "Recordings this iPhone can’t finish are waiting."
            case .provider(let provider):
                return "\(provider.displayName) is transcribing new recordings."
            case .onDevice: return "This iPhone is transcribing new recordings."
            case .waiting, .applePrivateCloud:
                return "New recordings are waiting to be transcribed."
            }
        }

        private static func ai(_ standIn: CloudAccountIssue.StandIn) -> String {
            switch standIn {
            case .onDevice: return "This iPhone is writing summaries and answers."
            case .applePrivateCloud:
                return "\(Copy.Privacy.remoteAiName(for: .applePrivateCloud)) is writing summaries "
                    + "and answers."
            case .waiting, .provider: return "New summaries and answers are waiting."
            }
        }

        // MARK: Backup

        static func backupTitle(_ provider: String) -> String { "Until \(provider) Works Again" }
        static func backupFooter(_ provider: String) -> String {
            "\(provider) takes over again as soon as it accepts your account."
        }
        static func waitFor(_ provider: String) -> String { "Wait for \(provider)" }
        static let waitDetail = "Nothing is lost. It’s done later."
        /// The Settings row, where a backup can be chosen before it is needed.
        static func backupRow(_ provider: String) -> String { "If \(provider) stops" }

        // MARK: After coming back from the billing page

        static func worksAgain(_ provider: String) -> String { "\(provider) is working again." }
        static func stillRefused(_ kind: TranscriptionFailureKind, provider: String) -> String {
            switch kind {
            case .spendingLimitReached: return "\(provider) still reports its spending limit."
            case .keyRejected, .keyNotPermitted: return "\(provider) still doesn’t accept the key."
            default: return "\(provider) still reports no credit."
            }
        }
        static func couldNotCheck(_ provider: String) -> String {
            "Couldn’t check \(provider) right now."
        }

        /// "since 7:05 AM", "since Sunday", "since November 22".
        static func since(_ sinceMs: Int64, nowMs: Int64, timeZone: TimeZone = .current) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let start = Date(timeIntervalSince1970: Double(sinceMs) / 1000)
            let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
            let days =
                calendar.dateComponents(
                    [.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: now)
                ).day ?? 0
            let style: Date.FormatStyle
            if days <= 0 {
                style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
            } else if days < 7 {
                style = Date.FormatStyle(timeZone: timeZone).weekday(.wide)
            } else {
                style = Date.FormatStyle(timeZone: timeZone).month(.wide).day()
            }
            return "since \(start.formatted(style))"
        }
    }
}

extension CloudProvider {
    /// The page where this account's money or limit is. Soniox's are the ones its own error
    /// reference names (checked 2026-11-25); OpenAI's are its billing and limits settings.
    func accountPage(for kind: TranscriptionFailureKind) -> URL {
        switch (self, kind) {
        case (.soniox, .spendingLimitReached): return URL(string: "https://console.soniox.com/org/limits/")!
        case (.soniox, _): return URL(string: "https://console.soniox.com/org/billing/overview/")!
        case (.openAi, .spendingLimitReached):
            return URL(string: "https://platform.openai.com/settings/organization/limits")!
        case (.openAi, _):
            return URL(string: "https://platform.openai.com/settings/organization/billing/overview")!
        }
    }
}

extension CloudAccountIssue {
    /// The key is the fix, and it is changed in this app; everything else is fixed on the
    /// provider's own site.
    var isAboutTheKey: Bool { kind == .keyRejected || kind == .keyNotPermitted }
}
