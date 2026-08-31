import Foundation

// Plan 6.8: "the intent writes the desired tri-state intent to the App Group and notifies the
// main app (Darwin notification); the app (alive in the background via bluetooth-central)
// applies it through the normal ReceiverService path."
//
// So this file is a MAILBOX, not a control path. An App Intent or the Control Center toggle
// posts a REQUEST here; the app is still the only thing that talks to the receiver, and
// `AppSettings` remains the only writer of the applied `capture_intent` preference. Nothing in
// the extension flips capture state on its own — that would be exactly the B3 side-effect the
// plan forbids.

/// The plan-6.1 capture tri-state, in the spelling `AppSettings` persists.
enum SharedCaptureIntent: String, Codable, Sendable, CaseIterable {
    case active
    case paused
    case off

    var isActive: Bool { self == .active }

    /// Toggling never reaches `off`: `off` is a deliberate, consent-bearing choice made in the
    /// app, so a Control Center toggle only moves between active and paused.
    var toggled: SharedCaptureIntent { self == .active ? .paused : .active }
}

/// One pending hand-off from an intent to the app.
struct CaptureIntentRequest: Equatable, Sendable {
    var intent: SharedCaptureIntent
    var requestedAtMs: Int64
}

/// Reads and writes the capture tri-state in the App Group defaults, and rings the doorbell.
enum CaptureIntentBridge {
    // Key names: `capture_intent` is AppSettings' existing applied value (never written here);
    // the `_requested_*` pair is this mailbox.
    enum Keys {
        static let applied = "capture_intent"
        static let requested = "capture_intent_requested"
        static let requestedAtMs = "capture_intent_requested_at_ms"
    }

    // MARK: - Reading

    /// The intent the app has actually applied (AppSettings' persisted value).
    static func appliedIntent(in defaults: UserDefaults = SharedAppGroup.defaults)
        -> SharedCaptureIntent
    {
        (defaults.string(forKey: Keys.applied)).flatMap(SharedCaptureIntent.init(rawValue:)) ?? .off
    }

    /// A request the app has not consumed yet, if any.
    static func pendingRequest(in defaults: UserDefaults = SharedAppGroup.defaults)
        -> CaptureIntentRequest?
    {
        guard let raw = defaults.string(forKey: Keys.requested),
            let intent = SharedCaptureIntent(rawValue: raw)
        else { return nil }
        let at = defaults.object(forKey: Keys.requestedAtMs) as? NSNumber
        return CaptureIntentRequest(intent: intent, requestedAtMs: at?.int64Value ?? 0)
    }

    /// What the user last asked for — the pending request if there is one, else the applied
    /// value. This is what Control Center and the widget must show, so a toggle looks answered
    /// immediately even while the app is still catching up.
    static func effectiveIntent(in defaults: UserDefaults = SharedAppGroup.defaults)
        -> SharedCaptureIntent
    {
        pendingRequest(in: defaults)?.intent ?? appliedIntent(in: defaults)
    }

    // MARK: - Writing (the intent side)

    /// Records the desired tri-state and posts the Darwin notification. Returns what was
    /// requested so the caller can render an immediate, honest confirmation.
    @discardableResult
    static func request(
        _ intent: SharedCaptureIntent,
        at nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        in defaults: UserDefaults = SharedAppGroup.defaults,
        notify: Bool = true
    ) -> SharedCaptureIntent {
        defaults.set(intent.rawValue, forKey: Keys.requested)
        defaults.set(NSNumber(value: nowMs), forKey: Keys.requestedAtMs)
        if notify { postDarwinNotification() }
        return intent
    }

    /// Toggle from whatever the user last asked for (active ⇄ paused; never off).
    @discardableResult
    static func requestToggle(
        at nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        in defaults: UserDefaults = SharedAppGroup.defaults,
        notify: Bool = true
    ) -> SharedCaptureIntent {
        request(effectiveIntent(in: defaults).toggled, at: nowMs, in: defaults, notify: notify)
    }

    // MARK: - Consuming (the app side)

    /// Called by the app after it has applied a request through the normal ReceiverService
    /// path. Clears the mailbox and records the applied value.
    static func consume(
        _ intent: SharedCaptureIntent, in defaults: UserDefaults = SharedAppGroup.defaults
    ) {
        defaults.set(intent.rawValue, forKey: Keys.applied)
        defaults.removeObject(forKey: Keys.requested)
        defaults.removeObject(forKey: Keys.requestedAtMs)
    }

    /// Drops a pending request without applying it (e.g. capture is `off` and the user must
    /// make that choice in the app).
    static func clearPendingRequest(in defaults: UserDefaults = SharedAppGroup.defaults) {
        defaults.removeObject(forKey: Keys.requested)
        defaults.removeObject(forKey: Keys.requestedAtMs)
    }

    // MARK: - Darwin notification

    /// Cross-process wake-up: the extension writes, the app reacts. Payload-free by design —
    /// the receiver re-reads the defaults, so a coalesced notification loses nothing.
    static func postDarwinNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(SharedAppGroup.captureIntentChangedNotification as CFString),
            nil,
            nil,
            true
        )
    }

    /// Registers `handler` for the Darwin notification. The observer is the returned token's
    /// raw pointer; keep the token alive for as long as you want the callback.
    static func observeDarwinNotifications(_ handler: @escaping @Sendable () -> Void)
        -> CaptureIntentDarwinObserver
    {
        CaptureIntentDarwinObserver(handler: handler)
    }
}

/// Lifetime holder for a Darwin observation (Darwin callbacks are C function pointers, so the
/// closure lives in this object and the callback bounces through it).
final class CaptureIntentDarwinObserver {
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let holder = Unmanaged<CaptureIntentDarwinObserver>
                    .fromOpaque(observer).takeUnretainedValue()
                holder.handler()
            },
            SharedAppGroup.captureIntentChangedNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(SharedAppGroup.captureIntentChangedNotification as CFString),
            nil
        )
    }
}
