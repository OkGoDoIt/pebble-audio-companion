import Foundation
import Receiver

/// How loud a question is made before it goes to Muse.
public enum MuseVoiceLevel: Hashable, Sendable {
    /// Each question is measured and brought to the level recognizers expect.
    case automatic
    /// The same boost for every question, in dB.
    case fixed(gainDB: Int)

    public static let fixedRange = 0...30
}

/// Which of Muse's chats a question from the watch goes to.
public enum MuseChatPlace: String, Equatable, Sendable, CaseIterable {
    /// A chat of their own, so the main one isn't filled with quick questions.
    case watchChat
    case mainChat
}

/// What Muse may do on the watch while answering (docs/privacy-model.md, D7b). Nothing but the
/// outcome goes back, except what is playing when asked.
public enum MuseWatchActionKind: String, Equatable, Sendable, CaseIterable {
    case timer
    case alarm
    case music
    case quietTime
    case launchApp
    case findWatch
    /// Pause or resume recording, and mark a moment.
    case recording
}

/// What Muse may read while answering, each sent to Meta only when it asks.
public enum MuseSource: String, Equatable, Sendable, CaseIterable {
    /// Transcripts, recaps, and answers from the person's own AI about their recordings (D7a).
    case conversations
    /// Steps, distance, active time, calories, sleep and heart rate from the watch.
    case health
    case calendar
    case reminders
    case followUps
}

/// Whether Muse may use a data source.
public enum MuseSourceAccess: String, Equatable, Sendable, CaseIterable {
    /// The first time Muse asks, the watch asks the wearer.
    case ask
    case allowed
    /// Muse isn't told the source exists.
    case off
}

/// The person's Muse choices. Kept in the app's own defaults: none of it is secret.
public struct MusePreferences: Equatable, Sendable {
    public var voiceLevel: MuseVoiceLevel = .automatic
    public var chatPlace: MuseChatPlace = .watchChat
    /// On once paired, each with its own switch (docs/privacy-model.md, D7b).
    public var watchActions: Set<MuseWatchActionKind> = Set(MuseWatchActionKind.allCases)
    /// Ask first until the wearer says otherwise.
    public var dataAccess: [MuseSource: MuseSourceAccess] = [:]
    /// Sources allowed on the watch while iOS hadn't given the app access yet: the next time the
    /// app comes to the foreground it asks iOS, once.
    public var pendingPhoneAccess: Set<MuseSource> = []
    /// What Muse sends by itself (a scheduled result, an update, an answer that came late) goes
    /// to the watch. On by default: Muse is an agent, and this is how it reaches the wrist.
    public var messagesOnWatch = true

    public init(
        voiceLevel: MuseVoiceLevel = .automatic, chatPlace: MuseChatPlace = .watchChat,
        watchActions: Set<MuseWatchActionKind> = Set(MuseWatchActionKind.allCases),
        dataAccess: [MuseSource: MuseSourceAccess] = [:]
    ) {
        self.voiceLevel = voiceLevel
        self.chatPlace = chatPlace
        self.watchActions = watchActions
        self.dataAccess = dataAccess
    }

    public func access(_ source: MuseSource) -> MuseSourceAccess { dataAccess[source] ?? .ask }
}

/// Reads and writes `MusePreferences`, and publishes them.
public final class MusePreferencesStore: @unchecked Sendable {
    public let current: StateSubject<MusePreferences>
    private let defaults: UserDefaults
    private let lock = NSLock()

    private enum Key {
        static let voiceLevel = "muse.voiceLevel"
        static let chatPlace = "muse.chatPlace"
        static let actionsOff = "muse.watchActionsOff"
        // ".2": the first watch chat was named by Muse from its first question ("Transcribe audio
        // file"); a new one starts with a line saying what it is for (LiveMuseVoiceConversation).
        static let watchChatID = "muse.watchChatID.2"
        static func access(_ source: MuseSource) -> String { "muse.access.\(source.rawValue)" }
        static let pendingPhoneAccess = "muse.pendingPhoneAccess"
        static let messagesOff = "muse.messagesOff"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = StateSubject(Self.load(defaults))
    }

    public func update(_ change: (inout MusePreferences) -> Void) {
        let next: MusePreferences = lock.withLock {
            var value = current.value
            change(&value)
            switch value.voiceLevel {
            case .automatic: defaults.removeObject(forKey: Key.voiceLevel)
            case .fixed(let gain): defaults.set(gain, forKey: Key.voiceLevel)
            }
            defaults.set(value.chatPlace.rawValue, forKey: Key.chatPlace)
            let off = MuseWatchActionKind.allCases.filter { !value.watchActions.contains($0) }.map(\.rawValue)
            defaults.set(off, forKey: Key.actionsOff)
            defaults.set(value.pendingPhoneAccess.map(\.rawValue).sorted(), forKey: Key.pendingPhoneAccess)
            defaults.set(!value.messagesOnWatch, forKey: Key.messagesOff)
            for source in MuseSource.allCases {
                let access = value.access(source)
                if access == .ask {
                    defaults.removeObject(forKey: Key.access(source))
                } else {
                    defaults.set(access.rawValue, forKey: Key.access(source))
                }
            }
            return value
        }
        current.value = next
    }

    /// The id of the chat questions from the watch go to, made once.
    public func watchChatID() -> String {
        lock.withLock {
            if let id = defaults.string(forKey: Key.watchChatID), !id.isEmpty { return id }
            let id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: Key.watchChatID)
            return id
        }
    }

    private static func load(_ defaults: UserDefaults) -> MusePreferences {
        var value = MusePreferences()
        if defaults.object(forKey: Key.voiceLevel) != nil {
            let gain = defaults.integer(forKey: Key.voiceLevel)
            value.voiceLevel = .fixed(gainDB: min(max(gain, MuseVoiceLevel.fixedRange.lowerBound), MuseVoiceLevel.fixedRange.upperBound))
        }
        if let raw = defaults.string(forKey: Key.chatPlace), let place = MuseChatPlace(rawValue: raw) {
            value.chatPlace = place
        }
        let off = Set((defaults.stringArray(forKey: Key.actionsOff) ?? []).compactMap(MuseWatchActionKind.init(rawValue:)))
        value.watchActions = Set(MuseWatchActionKind.allCases).subtracting(off)
        value.pendingPhoneAccess = Set((defaults.stringArray(forKey: Key.pendingPhoneAccess) ?? []).compactMap(MuseSource.init(rawValue:)))
        value.messagesOnWatch = !defaults.bool(forKey: Key.messagesOff)
        for source in MuseSource.allCases {
            if let raw = defaults.string(forKey: Key.access(source)), let access = MuseSourceAccess(rawValue: raw) {
                value.dataAccess[source] = access
            }
        }
        return value
    }
}
