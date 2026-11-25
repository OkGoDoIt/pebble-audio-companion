import Foundation

// Settings · Transcription & AI · On this iPhone — which engine transcribes on the phone.

extension Copy {
    enum OnThisIPhone {
        static let mostAccurate = "Most accurate"
        static let lessAccurate = "Less accurate"
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
            "Needs \(size(needed)), \(size(free)) free"
        }

        /// Decimal units, the same ones the model's own size is written in.
        private static func size(_ bytes: Int64) -> String {
            let megabytes = Double(bytes) / 1_000_000
            return megabytes >= 1_000
                ? String(format: "%.1f GB", megabytes / 1_000) : "\(Int(megabytes.rounded())) MB"
        }
    }
}
