import CompanionRuntime
import Foundation

// Settings · Pebble Audio server: the phone half of the archive sync. Each state is a heading and
// at most one line under it; what is shared, and where, is said once, in plain words; nothing
// here names a mechanism (tokens, batches, outboxes) the person never asked about.

extension Copy {
    enum ArchiveServer {
        static let title = "Pebble Audio server"
        static let rowTitle = "Pebble Audio server"

        // MARK: States (heading + one line)

        static let notLinkedHeading = "Not linked"
        static let notLinkedLine =
            "Link this phone to your Pebble Audio server so your assistants can read your "
            + "conversations."

        static func linkedHeading(_ host: String) -> String { "Linked to \(host)" }
        static let linkedLine = "Text syncs there. Audio goes only when an assistant asks for a clip."

        static let pausedHeading = "Sync is paused"
        static let pausedPreview = "Paused"
        static let pausedLine = "Changes wait on this phone until you turn sync back on."

        static let revokedHeading = "This phone was unlinked"
        static func revokedLine(_ host: String) -> String {
            "\(host) no longer accepts this phone. Link it again to resume syncing."
        }

        static let tooOldHeading = "Update Pebble Audio to sync"
        static func tooOldLine(_ host: String) -> String { "\(host) needs a newer version of this app." }

        // MARK: Linking

        static func invitationHeading(_ host: String) -> String { "Link to \(host)?" }
        static let invitationLine =
            "Your conversations' text will sync there. Audio stays on this phone unless an "
            + "assistant asks for a clip."
        static let invitationLink = "Link"
        static let invitationCancel = "Not Now"

        static let serverField = "Server"
        static let serverPlaceholder = "pebbleaudio.okgodoit.com"
        static let codeField = "Code"
        static let codePlaceholder = "8 characters"
        static let linkButton = "Link This Phone"
        static let linking = "Linking…"
        static let linkFooter =
            "On your server, open Link a phone. Scan its code with the Camera, or enter the code "
            + "here."

        static func linkError(_ error: ArchiveSyncService.LinkError?, host: String) -> String {
            switch error {
            case .codeRefused?:
                return "That code didn't work. Codes last ten minutes and work once, so get a "
                    + "new one from your server."
            case .badOrigin?:
                return "That server address can't be used. It needs to start with https."
            case .network?:
                return "Couldn't reach \(host). Check the connection and try again."
            case .server?, .malformed?:
                return "\(host) couldn't link this phone right now. Try again in a moment."
            case nil:
                return "This phone couldn't keep the link. Try again."
            }
        }

        // MARK: Linked

        static let syncToggle = "Sync"

        static let sharedSection = "What's shared"
        static func sharedText(_ host: String) -> String {
            "Titles, summaries, transcripts, notes, follow-ups, and day recaps sync to \(host)."
        }
        static let sharedAudio =
            "Audio stays on this phone. An assistant can ask for a clip, and only that clip is sent."
        static let sharedDeletes =
            "Deleting a conversation here deletes it there too. When Keep audio removes a "
            + "recording here, its text stays on the server."
        static let sharedDeleteAll = "Delete All Recordings also deletes everything on the server."

        static let statusSection = "Status"
        static let lastSynced = "Last synced"
        static let notYet = "Not yet"
        static let waiting = "Waiting to send"
        static let nothingWaiting = "Nothing"
        static let couldNotSync = "Couldn't sync"
        static let syncNow = "Sync Now"
        static let syncing = "Syncing…"

        static let aiReadSection = "What AI read"
        static let aiReadNone = "No assistant has read anything yet."
        static func aiRead(client: String, count: Int, when: String) -> String {
            let who = client.isEmpty ? "An assistant" : client
            guard count > 0 else { return "\(who) looked · \(when)" }
            return "\(who) read \(count) \(count == 1 ? "item" : "items") · \(when)"
        }

        static let unlink = "Unlink This Phone"
        static func unlinkFooter(_ host: String) -> String {
            "\(host) keeps what it already has. You can link again with a new code."
        }
    }
}

extension Copy.Settings.Storage {
    /// The delete-all confirmation, naming the server when there is one to wipe.
    static func deleteAllMessage(serverHost: String?) -> String {
        guard let serverHost else { return deleteAllMessage }
        return deleteAllMessage + " Everything on \(serverHost) is deleted too."
    }
}
