import Foundation
import StatusUI

// Settings · Transcription & AI · On this iPhone — which engine transcribes on the phone.

extension Copy {
    enum OnThisIPhone {
        static let footer = "Bars show how much quiet conversation each one catches."
        static let get = "Get"
        static func getLabel(_ name: String) -> String { "Get \(name)" }
        static let remove = "Remove"
        static func removeTitle(_ name: String) -> String { "Remove \(name)?" }
        static let useCellular = "Use Cellular"
        static let storage = "Storage"
        static let waitingForWiFi = "Waiting for Wi-Fi"
        static let settingUp = "Setting up for this iPhone"
        static let failed = "The download stopped"
        static let cannotRunHere = "Needs a newer iPhone or iOS"
        static let noSystemModel = "Not available in your phone’s language"

        /// "265 of 632 MB".
        static func downloaded(_ progress: Double, of bytes: Int64) -> String {
            let total = Int((Double(bytes) / 1_000_000).rounded())
            return "\(Int((Double(total) * min(max(progress, 0), 1)).rounded())) of \(total) MB"
        }

        /// "Needs 1.5 GB, 210 MB free".
        static func needsSpace(_ needed: Int64, free: Int64) -> String {
            "Needs \(Formatting.storageSize(needed)), \(Formatting.storageSize(free)) free"
        }

        /// VoiceOver's reading of the bar.
        static func hearing(_ level: Int) -> String {
            "catches \(level) out of 5 of quiet conversation"
        }
    }
}
