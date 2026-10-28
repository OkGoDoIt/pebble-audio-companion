import Foundation

// Settings › Watch › Pebble App Plugin: putting the Pebble Audio plugin into the official Pebble
// app, and connecting it to the person's server with a one-time code shown here.
//
// Rules this copy follows:
//
// - **What it gives, whether it is set up, what to do next**, in that order, each answered once.
//   A state is a heading and at most one line.
// - **Named the way the Pebble app names things.** "Plugins", "Apps › Plugins › Pebble Audio ›
//   Settings", and "Dashboard" are that app's own words, so the person can find them there.
//   Nothing names a file type, a token, or an identifier.
// - **The plugin switch is mentioned once, where it helps:** under the install button. Plugins
//   are a preview in the Pebble app behind a setting this app cannot turn on, and an install
//   with it off does nothing visible.
extension Copy {
    enum PluginInstall {
        static let header = "Pebble App Plugin"
        /// The section's first line: what the plugin is for.
        static let lede = "Shows your recording status on watch faces and in Dashboard."

        // ─── Is it set up ────────────────────────────────────────────────────

        static let checking = "Checking…"
        static let notConnected = "Not connected"
        static let connected = "Connected"
        /// "Last read 2 min ago", from the server's note of the plugin's last read.
        static func lastRead(_ ms: Int64?, nowMs: Int64) -> String {
            guard let ms else { return "Not read yet" }
            return Copy.AssistantAccess.lastRead(AssistantTime.ago(ms, nowMs: nowMs))
        }

        static let notSetUp = "Not set up"
        static let notSetUpLine = "Link this phone to your Pebble Audio server first."
        static let linkServer = Copy.AssistantAccess.linkYourServer

        static let unreachable = "Couldn’t reach your server"
        static let unreachableLine = "Check your connection, then try again."

        // ─── What to do next ─────────────────────────────────────────────────

        static let install = "Install in Pebble App"
        static let connectAgain = "Connect Again"
        /// Under the install button.
        static let turnOnPlugins = "Turn on plugins in the Pebble app’s settings first."
        /// The menu sent it to something other than Pebble.
        static let sentElsewhere = "It went to another app. Choose Pebble to install it."
        /// Nothing on this phone can open the plugin: the menu never appeared.
        static let needsPebbleApp = "Install the Pebble app on this phone first."

        static let enterCode =
            "In the Pebble app, open Apps › Plugins › Pebble Audio › Settings and enter this code."
        /// "Works once, until 3:40 PM."
        static func worksUntil(_ ms: Int64) -> String {
            let time = Date(timeIntervalSince1970: Double(ms) / 1000)
                .formatted(date: .omitted, time: .shortened)
            return "Works once, until \(time)."
        }
        static let expired = "This code has expired."
        static let newCode = "New Code"
        static let gettingCode = "Getting a code…"
        static let codeFailed = "Couldn’t get a code."
        static let copy = Copy.AssistantAccess.copy
        static let copied = Copy.AssistantAccess.copied
        /// Read character by character.
        static func codeAccessibility(_ code: String) -> String { "Code \(code)" }
    }
}
