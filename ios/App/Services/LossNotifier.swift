import AppDB
import AppIntents
import CompanionRuntime
import Foundation
import SegmentStore
import StatusUI
import UserNotifications

// Q9 — the ONE notification this product sends (plan 6.7 copy, 6.10 trigger mechanics). The
// kit's `LossEventEvaluator` decides WHETHER a loss qualifies (threshold, spool overflow,
// paused/quiet exclusions, B21 open-segment deferral); this file is the app-side seam it
// calls, and it owns three things the kit cannot:
//
//   1. Authorization is requested at the FIRST qualifying loss, never during onboarding —
//      asking for notification permission before there is anything to say is how apps train
//      people to deny it.
//   2. The rate limit is defended HERE too, in App Group defaults, so it survives a process
//      relaunch (the evaluator's in-memory limiter resets when the app is jetsammed).
//   3. The tap route, carried in userInfo and parsed by the same `Route.parse` the URL scheme
//      uses (no second navigation path): the conversation the gap fell in when the segment
//      resolves to one, `companion://today` when it does not. On iOS 27 the notification also
//      carries that conversation's App Intents entity id, so Siri can act on "this" from the
//      notification.

/// The UNUserNotificationCenter seam — a protocol so the notifier is testable without the
/// notification daemon, and so previews/simulators can no-op cleanly.
protocol LossNotificationScheduling: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Shows the system prompt. Returns whether we may post.
    func requestAuthorization() async -> Bool
    /// `conversationId` is the conversation the notification is about, when there is one; the
    /// system scheduler turns it into the notification's entity id on iOS 27.
    func schedule(title: String, body: String, userInfo: [String: String], conversationId: String?)
        async
}

struct SystemLossNotificationScheduler: LossNotificationScheduling {
    private var center: UNUserNotificationCenter { .current() }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func schedule(
        title: String, body: String, userInfo: [String: String], conversationId: String?
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        content.sound = .default
        content.interruptionLevel = .active
        if #available(iOS 27, *), let conversationId {
            content.appEntityIdentifiers = [
                EntityIdentifier(for: ConversationEntity.self, identifier: conversationId)
            ]
        }
        let request = UNNotificationRequest(
            identifier: "loss-\(UUID().uuidString)", content: content, trigger: nil
        )
        try? await center.add(request)
    }
}

/// `CompanionRuntime.LossNotifier` implemented over UNUserNotificationCenter.
///
/// Conforms to the kit's existing protocol — no parallel `LossNotifying` is defined here.
actor UserNotificationLossNotifier: LossNotifier {
    /// Belt-and-braces with `LossEventEvaluator.rateLimitMs`: at most one per hour.
    static let rateLimitMs: Int64 = 60 * 60 * 1000
    private static let lastFiredKey = "loss_notification_last_fired_ms"
    /// Set once the user has said no, so we never re-prompt on every subsequent gap.
    private static let authorizationAskedKey = "loss_notification_authorization_asked"

    private let scheduler: any LossNotificationScheduling
    private let defaults: UserDefaults
    private let now: @Sendable () -> Int64
    /// The conversation a loss fell in, or nil when it cannot be resolved (no runtime up, a
    /// segment not yet grouped). Handed the whole event rather than its segment id: a segment
    /// usually holds the end of one conversation and the start of the next, so which one a gap
    /// is in depends on where in the segment it is. Injected so tests can answer without a
    /// database.
    private let conversationId: @Sendable (LossEvent) async -> String?

    /// The Q9 alert is OPT-IN (default off). Read at fire time rather than captured at
    /// construction so toggling it in Settings takes effect immediately.
    private var isEnabled: Bool {
        defaults.bool(forKey: "loss_alerts_enabled")
    }

    init(
        scheduler: any LossNotificationScheduling = SystemLossNotificationScheduler(),
        defaults: UserDefaults = SharedAppGroup.defaults,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        conversationId: @escaping @Sendable (LossEvent) async -> String? =
            UserNotificationLossNotifier.liveConversationId
    ) {
        self.scheduler = scheduler
        self.defaults = defaults
        self.now = now
        self.conversationId = conversationId
    }

    /// The production resolver: the conversation that owns the MOMENT of the segment the
    /// audio went missing at. Reads the composition off the main actor and answers nil when
    /// none is up.
    ///
    /// Asked at the gap's own position when the segment's sidecar still says where that is,
    /// and at the segment's start otherwise — which is what this always asked, and is right
    /// whenever the segment is not shared.
    private static let liveConversationId: @Sendable (LossEvent) async -> String? = { event in
        let graph = await MainActor.run {
            AppComposition.shared.map { (files: $0.files, database: $0.database) }
        }
        guard let graph else { return nil }
        let mediaMs = graph.files.readMeta(event.segmentId)
            .flatMap { UserNotificationLossNotifier.gapMediaMs(of: event, in: $0) }
        return try? await ConversationQueries(db: graph.database).conversationId(
            ofSegment: event.segmentId, atMediaMs: mediaMs ?? 0)
    }

    /// Where in its segment's STORED audio a loss sits — the clock a conversation's pieces are
    /// cut on — or nil when the sidecar has no record that matches the event.
    ///
    /// The event carries a segment and a duration, not a position, so the record is found by
    /// its length: the newest visible loss of exactly that duration (the evaluator fires on
    /// the record that was just persisted, or on the longest one deferred until the segment
    /// closed). The position returned is the last stored instant BEFORE the gap: missing audio
    /// is shown at the end of the conversation it interrupted (`TranscriptItems` files a gap
    /// under the piece its start falls in), so a gap sitting exactly where the next
    /// conversation starts opens the one that lost it, not the one that began after it.
    static func gapMediaMs(of event: LossEvent, in meta: SegmentMeta) -> Int64? {
        let visibility = GapVisibility(meta.gaps)
        guard
            let gap = meta.gaps.last(where: {
                visibility.isVisibleLoss($0)
                    && gapDurationMs($0, frameDurationMs: meta.frameDurationMs) == event.durationMs
            }),
            let first = meta.firstSampleIndex, gap.firstMissingSampleIndex >= first,
            meta.sampleRateHz > 0
        else { return nil }
        let wallMs =
            Int64(gap.firstMissingSampleIndex - first) * 1_000 / Int64(meta.sampleRateHz)
        let clock = SegmentMediaClock(meta)
        let mediaMs = clock.isExact ? clock.media(fromWall: wallMs) : min(wallMs, clock.mediaSpanMs)
        return max(mediaMs - 1, 0)
    }

    /// The route a tap opens. Kept as a string in userInfo so the payload stays plist-simple.
    static let routeUserInfoKey = "route"
    static var routeURLString: String { Route.today(date: nil).url.absoluteString }

    /// Where a loss notification lands: the conversation the gap fell in when it is known,
    /// Today (which shows the gap on the coverage strip) when it is not.
    static func routeURLString(conversationId: String?) -> String {
        guard let conversationId else { return routeURLString }
        return Route.conversation(id: conversationId, atMs: nil).url.absoluteString
    }

    func notifyCaptureStoppedOnWatch() async {
        // Same opt-in gate as the loss alert, and the same permission rule: never prompt off the
        // back of an event. Not rate-limited with the loss alert — this is a different fact, it
        // happens once per stand-down, and the person can act on it immediately.
        guard isEnabled else { return }
        guard await hasPermission() else { return }
        await scheduler.schedule(
            title: Copy.Notifications.watchOffTitle,
            body: Copy.Notifications.watchOffBody,
            userInfo: [Self.routeUserInfoKey: Self.routeURLString],
            conversationId: nil
        )
    }

    func notifyAudioMissed(_ event: LossEvent) async {
        // Opt-in gate first: when the alert is off the app must be completely silent, and in
        // particular must never prompt for notification permission off the back of a gap.
        guard isEnabled else { return }
        let nowMs = now()
        guard !isRateLimited(nowMs: nowMs) else { return }
        guard await hasPermission() else { return }

        // Stamp BEFORE posting: a failed post must still consume the hour, or a storm of
        // gaps during one bad afternoon becomes a storm of prompts.
        defaults.set(NSNumber(value: nowMs), forKey: Self.lastFiredKey)

        // The gap's conversation, when the segment has been grouped into one. A segment that
        // is still open (the B21 deferral has already been applied by the evaluator) or a
        // runtime that is not up answers nil, and the tap goes to Today as it always did.
        let conversationId = event.segmentId.isEmpty ? nil : await conversationId(event)

        await scheduler.schedule(
            title: Copy.Notifications.lossTitle,
            // "…couldn't reach this phone for about {duration} — audio in that window is
            // missing." The copy supplies "about", so the phrase must not repeat it.
            body: Copy.Notifications.lossBody(
                duration: DurationPhrase.approximate(ms: event.durationMs)
            ),
            userInfo: [Self.routeUserInfoKey: Self.routeURLString(conversationId: conversationId)],
            conversationId: conversationId
        )
    }

    // MARK: - Internals

    private func isRateLimited(nowMs: Int64) -> Bool {
        guard let last = (defaults.object(forKey: Self.lastFiredKey) as? NSNumber)?.int64Value
        else { return false }
        // A clock that moved backwards (timezone/NTP) must not lock the notification out.
        if nowMs < last { return false }
        return nowMs - last < Self.rateLimitMs
    }

    /// The Settings switch's half of the consent: turning the alert ON is the moment to ask
    /// iOS, not the middle of a gap weeks later. Shares `hasPermission`'s ask-once bookkeeping,
    /// so opting in and the first qualifying loss can never produce two prompts.
    func requestAuthorizationIfNeeded() async -> Bool {
        await hasPermission()
    }

    /// Asks exactly once, on the first qualifying loss AFTER the user opted in (turning the
    /// toggle on is the consent; this is just the system half of it). A denial is remembered —
    /// the product keeps working, it just stops talking.
    private func hasPermission() async -> Bool {
        switch await scheduler.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            guard !defaults.bool(forKey: Self.authorizationAskedKey) else { return false }
            defaults.set(true, forKey: Self.authorizationAskedKey)
            return await scheduler.requestAuthorization()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}

/// Routes a notification tap into the app's one navigation path.
///
/// Installed by `PebbleAudioApp`; the handler is the same `router.navigate(to:)` that
/// `onOpenURL` uses, so a tapped notification and a pasted `companion://` URL land identically.
@MainActor
final class LossNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LossNotificationRouter()

    private var handler: ((Route) -> Void)?
    /// A tap that arrives before the router is ready (cold launch) is held, not dropped.
    private var pendingRoute: Route?

    private override init() { super.init() }

    /// Claims the delegate slot. Must run during `didFinishLaunching` — a notification tapped
    /// while the app was dead is delivered as soon as launch completes, and a delegate
    /// installed later simply never hears about it.
    func prepare() {
        UNUserNotificationCenter.current().delegate = self
    }

    func install(handler: @escaping (Route) -> Void) {
        self.handler = handler
        prepare()
        if let pendingRoute {
            self.pendingRoute = nil
            handler(pendingRoute)
        }
    }

    /// Pure: the route a notification payload points at, if any.
    nonisolated static func route(for userInfo: [AnyHashable: Any]) -> Route? {
        guard let raw = userInfo[UserNotificationLossNotifier.routeUserInfoKey] as? String,
            let url = URL(string: raw)
        else { return nil }
        return Route.parse(url)
    }

    // Both delegate methods are `nonisolated`: UserNotifications documents no thread for them,
    // so nothing here assumes one. The response is reduced to a `Route` (a value) on the caller's
    // thread and only that crosses to the main actor, where the router state lives.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = Self.route(for: response.notification.request.content.userInfo) else {
            return
        }
        await deliver(route)
    }

    private func deliver(_ route: Route) {
        if let handler {
            handler(route)
        } else {
            pendingRoute = route
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // In the foreground the coverage strip is already showing the gap, so this lands in
        // Notification Center instead of interrupting with a banner over the same information.
        [.list]
    }
}
