import Foundation
import Receiver

/// How loud a question is made before it goes to Muse.
public enum MuseVoiceLevel: Equatable, Sendable {
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

/// What Muse may do on the watch while answering.
public enum MuseWatchActionKind: String, Equatable, Sendable, CaseIterable {
    case timer
    case alarm
    case choice
}

/// The person's Muse choices. Kept in the app's own defaults: none of it is secret.
public struct MusePreferences: Equatable, Sendable {
    public var voiceLevel: MuseVoiceLevel = .automatic
    public var chatPlace: MuseChatPlace = .watchChat
    /// On once paired, each with its own switch (docs/privacy-model.md, D7b).
    public var watchActions: Set<MuseWatchActionKind> = Set(MuseWatchActionKind.allCases)

    public init(
        voiceLevel: MuseVoiceLevel = .automatic, chatPlace: MuseChatPlace = .watchChat,
        watchActions: Set<MuseWatchActionKind> = Set(MuseWatchActionKind.allCases)
    ) {
        self.voiceLevel = voiceLevel
        self.chatPlace = chatPlace
        self.watchActions = watchActions
    }
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
        static let watchChatID = "muse.watchChatID"
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
        return value
    }
}
