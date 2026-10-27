import Foundation

/// The extension only supplies the current filter. Opt-in belongs to the app, and turning
/// a Focus off must never change that preference. Separate keys keep these writers independent.
enum FocusQuietTimeBridge {
    #if DEBUG
    static let prefix = "focusQuietTime.dev."
    #else
    static let prefix = "focusQuietTime."
    #endif
    static let notification = prefix + "changed"
    static let enabledKey = prefix + "enabled"
    static let stateKey = prefix + "state"

    struct State: Codable, Equatable {
        var quiet: Bool
        var revision = UUID()
    }

    static func state(in defaults: UserDefaults = SharedAppGroup.defaults) -> State? {
        guard let data = defaults.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    static func setFilter(_ quiet: Bool, in defaults: UserDefaults = SharedAppGroup.defaults) {
        // Refresh revision even for identical values: an in-flight system query must not
        // overwrite a more recent filter invocation.
        guard let data = try? JSONEncoder().encode(State(quiet: quiet)) else { return }
        defaults.set(data, forKey: stateKey)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notification as CFString), nil, nil, true)
    }
}

final class FocusQuietTimeObserver {
    private let handler: @Sendable () -> Void
    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<FocusQuietTimeObserver>.fromOpaque(observer).takeUnretainedValue().handler()
            }, FocusQuietTimeBridge.notification as CFString, nil, .deliverImmediately)
    }
    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(FocusQuietTimeBridge.notification as CFString), nil)
    }
}
