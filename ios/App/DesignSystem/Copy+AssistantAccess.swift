import CompanionRuntime
import Foundation

// Settings › AI Assistants: link this phone to the person's own Pebble Audio server, choose what
// syncs, connect assistants, and see who can read. The approved round-3 mockups' words
// (`docs/redesign/assistant-access-mockups/round3/`). Each state is a heading and at most one
// line; receivers are named by name; nothing names a mechanism. The exception is another app's
// own button labels (ChatGPT's "Add custom MCP server"), named the way that app names them so
// the person can find them there. Every list goes through `Copy.list` (Oxford comma).

extension Copy {
    enum AssistantAccess {
        static let title = "AI Assistants"
        static let rowTitle = "AI Assistants"

        // MARK: Settings root row

        static let rowNotSetUp = "Not set up"
        static let rowOff = "Off"
        static let rowNoneConnected = "None connected"
        static let rowUnlinked = "Unlinked"

        // MARK: Before linking (02)

        static let introHeading = "Let your assistants read your conversations"
        static let introLine =
            "Ask ChatGPT, Claude, or another assistant what you agreed to yesterday, and it "
            + "answers from your conversations."
        static let needServer = "A Pebble Audio server of your own"
        static let needBrowser = "Your server open in a browser"
        static let offHeading = "Off"
        static let offLine = "Nothing syncs until you tap Start Syncing."
        static let whatGoesToYourServer = "What goes to your server"
        static let introGoesText =
            "The text of your conversations: titles, summaries, transcripts, notes, follow-ups, "
            + "and recaps. No audio goes to your server unless you allow clips."
        static let introGoesAssistants =
            "Assistants you connect read it there, and it becomes part of your chats with them."
        static let linkYourServer = "Link Your Server"
        /// After an unlink the server had already refused: the phone could not ask it to delete.
        static let unlinkedAlreadyLine =
            "Your server had already stopped accepting this phone, so its copy may still be there."

        // Linked, but the person has not chosen what syncs yet.
        static func linkedHeading(_ host: String) -> String { "Linked to \(host)" }
        static let chooseWhatSyncs = "Choose What Syncs"

        // MARK: The step bar

        static let stepLink = "Link"
        static let stepChoose = "Choose"
        static let stepConnect = "Connect"
        static func stepAccessibility(_ now: Int) -> String {
            let names = [stepLink, stepChoose, stepConnect]
            return "Step \(now + 1) of 3, \(names[min(max(now, 0), 2)])"
        }

        // MARK: Link (03)

        static let linkTitle = "Link your server"
        static let linkLede = "On your server, open **Link a phone** and point this camera at its code."
        static let cameraLooking = "Looking for a code"
        static let cameraDenied = "Camera access is off. Enter the code below."
        static let cameraUnavailable = "No camera here. Enter the code below."
        static let cameraAccessibility = "Camera, looking for a code"
        static let orEnterIt = "Or enter it"
        static let serverField = "Server"
        static let codeField = "Code"
        static let codeAccessibility = "Code, 8 characters"
        static let linkThisPhone = "Link This Phone"
        static let linking = "Linking…"
        static let scanNewCode = "Scan New Code"

        static let expiredHeading = "This code has expired"
        static let expiredLine = "Codes last ten minutes. Open Link a phone on your server for a new one."
        static let refusedHeading = "This code didn't work"
        static let refusedLine = "Check it, or open Link a phone on your server for a new one."
        static let tooManyHeading = "Too many tries"
        static let tooManyLine = "Wait a few minutes, then try a new code."
        static func unreachableHeading(_ host: String) -> String { "Couldn't reach \(host)" }
        static let unreachableLine = "Check the address and your connection, then try again."
        static let badAddressHeading = "That address can't be used"
        static let badAddressLine = "Your server's address starts with https."
        static func serverErrorHeading(_ host: String) -> String { "\(host) couldn't link this phone" }
        static let serverErrorLine = "Try again in a moment."
        static let keepFailedHeading = "This phone couldn't keep the link"
        static let keepFailedLine = "Try again."

        // MARK: Choose (04)

        static let chooseTitle = "Choose what syncs"
        static let allTitle = "All conversations"
        static func allLine(count: Int, oldest: String?) -> String {
            guard count > 0, let oldest else { return "Every conversation, from your first one." }
            return "All \(count.formatted()), back to \(oldest), and every new one."
        }
        static let keepAudioLine =
            "Your server keeps the text even after Keep audio clears a recording here."
        static func sinceTitle(_ day: String) -> String { "From \(day) on" }
        static func sinceLine(count: Int) -> String {
            switch count {
            case 0: return "Every new conversation, starting today."
            case 1: return "Today's conversation, and every new one."
            default: return "Today's \(count.formatted()) conversations, and every new one."
            }
        }
        static func rollingTitle(_ days: Int) -> String { "Only the last \(days) days" }
        static func rollingCountLine(count: Int, since: String) -> String {
            "\(Copy.count(count, "conversation")), back to \(since)."
        }
        static let rollingShortLine = "Older ones are removed from your server each day."
        static func rollingLine(_ days: Int) -> String {
            "Always the last \(days) days. Older conversations are removed from your server each day."
        }
        static let daysAccessibility = "Days"
        static let conversationsAccessibility = "Conversations"

        static let mayAlso = "Assistants may also"
        static let clipsTitle = "Ask for audio clips"
        static let clipsLine = "Only the moment they ask about."
        static let editsTitle = "Add follow-ups and notes"
        static let editsLine = "Marked with the assistant's name."

        static func whatGoesTo(_ host: String) -> String { "What goes to \(host)" }

        /// The Choose step's preview, which follows the choices as they change.
        static func choosePreview(_ scope: ArchiveSharingScope, count: Int, clips: Bool, edits: Bool) -> String {
            var text: String
            switch scope {
            case .all: text = "The text of all \(Copy.count(count, "conversation")), and each new one."
            case .since:
                text = count == 0
                    ? "The text of each new conversation, from today on."
                    : "The text of today's \(Copy.count(count, "conversation")), and each new one."
            case .lastDays(let days):
                text = "The text of \(Copy.count(count, "conversation")) now, then always the last \(days) days."
            }
            text += clips ? " " + clipsGoLine : " " + noAudioLine
            if edits { text += " " + editsComeBackLine }
            return text
        }
        static let noAudioLine = "No audio goes to your server."
        static let clipsGoLine = "Audio goes only as a clip an assistant asks for."
        static let editsComeBackLine = "Follow-ups and notes your assistants add come back to this phone."
        static let startSyncing = "Start Syncing"

        // MARK: Connect (05)

        static let connectTitle = "Connect your assistants"
        static let connectAnotherTitle = "Connect an assistant"
        static let connectLede = "Connect each one in its own app. It shows up here once your server sees it."
        static let serverAddress = "Your server address"
        static let copy = "Copy"
        static let copied = "Copied"
        static let done = "Done"
        static let notConnected = "Not connected"
        static func connected(_ when: String) -> String { "Connected \(when)" }
        static let connectedAccessibility = "Connected"

        static let chatGPT = "ChatGPT"
        static let chatGPTSteps = [
            "In ChatGPT, open **Plugins** and tap **Add**.",
            "Tap **Add custom MCP server** and paste your server address.",
            "Choose **OAuth**, then tap **Create as a plugin**.",
            "Sign in to your server with your passkey.",
        ]
        static let chatGPTButton = "Copy Address and Open ChatGPT"

        static let claude = "Claude"
        static let claudeSteps = [
            "Tap **Open in Claude**. Your server is already filled in.",
            "Sign in to your server with your passkey.",
        ]
        static let claudeButton = "Open in Claude"
        static let claudeAlt =
            "Or in Claude, open **Settings › Connectors**, tap **Add custom connector**, and paste "
            + "your server address."

        static let macSubtitle = "On your Mac"
        static func macTitle(_ names: [String]) -> String { Copy.list(names, conjunction: "or") }
        static func macSteps(_ tool: String, cursor: Bool) -> [String] {
            if cursor {
                return [
                    "Tap **Open Setup in Safari**. Your server shows a link for Cursor.",
                    "Open it on your Mac and click **Add to Cursor**, then confirm in Cursor.",
                ]
            }
            return [
                "Tap **Open Setup in Safari**. Your server shows the command for \(tool).",
                "Copy it, then paste it into Terminal on your Mac.",
            ]
        }
        static let openSetupInSafari = "Open Setup in Safari"
        static func macAlt(_ host: String) -> String { "Or, on your Mac, open \(host)/connect." }
        static let appAccessibility = "App"

        static let otherTitle = "Another assistant"
        static let otherSubtitle = "Gemini and others"
        static let otherSteps = [
            "In that assistant, find where it adds a custom connector or server.",
            "Paste your server address.",
            "Sign in to your server with your passkey.",
        ]
        static let copyAddress = "Copy Address"

        // MARK: Linked (07)

        static func syncingHeading(_ host: String) -> String { "Syncing to \(host)" }
        static func lastSyncedLine(_ when: String) -> String { "Last synced \(when)." }
        static let firstSyncLine = "Sending your conversations for the first time."
        static let retryingLine = "Couldn't reach your server. Trying again soon."
        static let wipePendingLine = "Deleting your server's copy."
        static let pausedHeading = "Sync is paused"
        static let pausedLine = "Assistants can still read what your server already has."
        static let revokedHeading = "This phone was unlinked"
        static let revokedLine = "Your server no longer accepts this phone. Link it again to sync."
        static let linkAgain = "Link Again"
        static let tooOldHeading = "Update Pebble Audio to sync"
        static func tooOldLine(_ host: String) -> String { "\(host) needs a newer version of this app." }
        static let syncToggle = "Sync"

        static let whoCanRead = "Who can read"
        static func accessLine(_ mayDo: String, lastRead: String) -> String { "\(mayDo) · \(lastRead)" }
        static let notReadYet = "Not used yet"
        static func lastRead(_ when: String) -> String { "Last read \(when)" }
        static let connectAnother = "Connect Another Assistant"
        static let noAssistantYet = "No assistant is connected yet."

        static func linkedGoesLine(count: Int, scope: ArchiveSharingScope, clips: Bool) -> String {
            let what = scope == .all
                ? "all \(Copy.count(count, "conversation"))" : Copy.count(count, "conversation")
            return "The text of \(what): titles, summaries, transcripts, notes, follow-ups, and "
                + "recaps. " + (clips ? clipsGoLine : noAudioLine)
        }
        static let deletesTooLine = "Deleting a conversation here deletes it from your server too."
        static func pausedGoesLine(count: Int) -> String {
            "Your server has the text of \(Copy.count(count, "conversation")). Nothing new goes to "
                + "it while Sync is off."
        }
        static let conversationsRow = "Conversations"

        /// The scope as a row value and in Privacy's server row: "All conversations",
        /// "From October 21", "Last 90 days".
        static func scopeLabel(_ scope: ArchiveSharingScope, zone: TimeZone = .current) -> String {
            switch scope {
            case .all: return allTitle
            case .since(let ms): return "From \(AssistantTime.longDay(ms, zone: zone))"
            case .lastDays(let days): return "Last \(days) days"
            }
        }

        static let unlinkRow = "Unlink and Delete from Server"
        static let unlinkTitle = "Unlink and delete from your server?"
        static func unlinkMessage(count: Int?, host: String, assistants: [String]) -> String {
            var text = count.map { "Deletes the text of \(Copy.count($0, "conversation")) from \(host)." }
                ?? "Deletes everything on \(host)."
            if !assistants.isEmpty { text += " \(Copy.list(assistants)) lose access." }
            text += " Nothing on this phone changes."
            if !assistants.isEmpty { text += "\n\nWhat they already read stays in your chats with them." }
            return text
        }
        static let unlinkConfirm = "Unlink and Delete"
        static let unlinkUnreachable =
            "Couldn't reach your server. Nothing was deleted, and this phone is still linked."
        static let unlinkRefused = "Your server didn't delete its copy. Try again in a moment."

        // MARK: Narrowing the scope (07b, 07d)

        static let scopeScreenTitle = "Conversations"
        static func removeTitle(_ count: Int) -> String {
            "Remove \(Copy.count(count, "conversation")) from your server?"
        }
        static func removeMessage(before day: String, host: String) -> String {
            "Conversations from before \(day) are removed from \(host) now, and assistants can no "
                + "longer read them. They stay on this phone."
        }
        static func removeConfirm(_ count: Int) -> String {
            "Remove \(count.formatted()) \(count == 1 ? "Conversation" : "Conversations")"
        }

        // MARK: One assistant (08)

        static let detailHeading = "Can read your conversations"
        static func detailLine(connected: String?, clips: Bool, add: Bool) -> String {
            let lead = connected.map { "Connected \($0). " } ?? ""
            switch (clips, add) {
            case (false, false): return lead + "It can't ask for clips or add anything."
            case (true, false): return lead + "It can also ask for clips. It can't add anything."
            case (false, true): return lead + "It can also add follow-ups and notes. It can't ask for clips."
            case (true, true): return lead + "It can also ask for clips and add follow-ups and notes."
            }
        }
        static let today = "Today"
        static let yesterday = "Yesterday"
        static let readPrefix = "Read"
        static let nothingReadYet = "Nothing read yet."
        static let searched = "Searched your conversations"
        static let listedConversations = "Looked through your conversations"
        static let listedDays = "Looked through your days"
        static let listedFollowUps = "Looked through your follow-ups"
        static let lookedUpPeople = "Looked up people"
        static let lookedUpTags = "Looked up tags"
        static let addedFollowUp = "Added a follow-up"
        static let changedFollowUp = "Changed a follow-up"
        static let addedNote = "Added a note"
        static let untitledConversation = "A conversation"
        static func clipOf(_ title: String) -> String { "Listened to a clip of \(title)" }
        static func recapOf(_ day: String) -> String { "\(day) recap" }
        static func weekdayRecap(_ weekday: String) -> String { "\(weekday)'s recap" }
        static func weekBrief(_ day: String) -> String { "Week of \(day)" }
        static func monthBrief(_ month: String) -> String { "\(month) brief" }
        static func disconnect(_ name: String) -> String { "Disconnect \(name)" }
        static func disconnectTitle(_ name: String) -> String { "Disconnect \(name)?" }
        static func disconnectFooter(_ name: String) -> String {
            "\(name) can't read your server after this. What it already read stays in your chats with it."
        }
        static let disconnectFailed = "Couldn't reach your server. Try again in a moment."

        // MARK: Shared

        /// What an assistant may do: the same words on Linked, Privacy, and in the diagram.
        static func mayDo(clips: Bool, add: Bool) -> String {
            switch (clips, add) {
            case (true, true): return "Can read, ask for clips, and add"
            case (true, false): return "Can read and ask for clips"
            case (false, true): return "Can read and add"
            case (false, false): return "Can read"
            }
        }
        static let whatTheyReadLine = "What they read becomes part of your chats with them."
        static func asOf(_ ms: Int64, zone: TimeZone) -> String { "As of \(AssistantTime.clock(ms, zone: zone))." }
    }
}

// MARK: - Privacy screen headings

extension Copy.Settings.Privacy {
    static let whereItGoes = "Where it goes"
    static let whoCanRead = "Who can read your archive"
    static let manage = "Manage AI Assistants"
    static let connect = "Connect an Assistant"
    static let noAssistant = "No assistant is connected yet."
    static let thisIPhone = "This iPhone"
    static let audioAndText = "Audio and text"
    static let assistants = "Assistants"
    static let noneYet = "None yet"
    static let commitmentsSection = "Privacy"
    static let flowAccessibility = "Where your data goes"
}

// MARK: - Delete All

extension Copy.Settings.Storage {
    /// The delete-all confirmation, naming the server only when the phone can actually reach it
    /// (linked, and the server still accepts this phone): the wipe is sent whether or not sync is
    /// on, and retried until the server confirms it.
    static func deleteAllMessage(serverHost: String?) -> String {
        guard let serverHost else { return deleteAllMessage }
        return deleteAllMessage + " Everything on \(serverHost) is deleted too."
    }
}

// MARK: - Times

/// The relative times these screens print, against a `now` the caller passes (so a demo, a
/// test, and the live app read the same).
enum AssistantTime {
    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// "just now", "2 min ago", "1 hr ago", "yesterday", "Oct 18".
    static func ago(_ ms: Int64, nowMs: Int64, zone: TimeZone = .current) -> String {
        let since = max(0, nowMs - ms)
        if since < 60_000 { return "just now" }
        if since < 3_600_000 { return "\(since / 60_000) min ago" }
        let cal = calendar(zone)
        let then = date(ms)
        let now = date(nowMs)
        if cal.isDate(then, inSameDayAs: now) { return "\(since / 3_600_000) hr ago" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(then, inSameDayAs: yesterday) {
            return "yesterday"
        }
        return shortDay(ms, zone: zone)
    }

    /// "just now", "2 minutes ago", "3 hours ago", "yesterday", "on Oct 18".
    static func synced(_ ms: Int64, nowMs: Int64, zone: TimeZone = .current) -> String {
        let since = max(0, nowMs - ms)
        if since < 60_000 { return "just now" }
        if since < 3_600_000 {
            let minutes = since / 60_000
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes") ago"
        }
        let cal = calendar(zone)
        if cal.isDate(date(ms), inSameDayAs: date(nowMs)) {
            let hours = since / 3_600_000
            return "\(hours) \(hours == 1 ? "hour" : "hours") ago"
        }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: date(nowMs)),
            cal.isDate(date(ms), inSameDayAs: yesterday)
        {
            return "yesterday"
        }
        return "on \(shortDay(ms, zone: zone))"
    }

    /// "just now", "2 min ago", or "Oct 12": when an assistant connected.
    static func connected(_ ms: Int64, nowMs: Int64, zone: TimeZone = .current) -> String {
        let since = max(0, nowMs - ms)
        if since < 60_000 { return "just now" }
        if since < 3_600_000 { return "\(since / 60_000) min ago" }
        return shortDay(ms, zone: zone)
    }

    /// "Oct 18".
    static func shortDay(_ ms: Int64, zone: TimeZone = .current) -> String {
        var style = Date.FormatStyle().month(.abbreviated).day()
        style.timeZone = zone
        return date(ms).formatted(style)
    }

    /// "October 21".
    static func longDay(_ ms: Int64, zone: TimeZone = .current) -> String {
        var style = Date.FormatStyle().month(.wide).day()
        style.timeZone = zone
        return date(ms).formatted(style)
    }

    /// "9:42 AM".
    static func clock(_ ms: Int64, zone: TimeZone = .current) -> String {
        var style = Date.FormatStyle().hour().minute()
        style.timeZone = zone
        return date(ms).formatted(style)
    }

    /// "Monday".
    static func weekday(_ ms: Int64, zone: TimeZone = .current) -> String {
        var style = Date.FormatStyle().weekday(.wide)
        style.timeZone = zone
        return date(ms).formatted(style)
    }

    /// "Today", "Yesterday", or "Monday, October 19": a section of what an assistant read.
    static func dayHeader(_ ms: Int64, nowMs: Int64, zone: TimeZone = .current) -> String {
        let cal = calendar(zone)
        if cal.isDate(date(ms), inSameDayAs: date(nowMs)) { return Copy.AssistantAccess.today }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: date(nowMs)),
            cal.isDate(date(ms), inSameDayAs: yesterday)
        {
            return Copy.AssistantAccess.yesterday
        }
        return "\(weekday(ms, zone: zone)), \(longDay(ms, zone: zone))"
    }
}
