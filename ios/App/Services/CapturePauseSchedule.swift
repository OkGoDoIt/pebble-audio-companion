import Foundation
import Receiver
import UserNotifications

// The opt-in timed pause (session: "an option to temporarily pause recording, for example if a
// user wants to not record a sensitive conversation but they don't want to forget to turn
// recording back on … neither of these should be the default behavior").
//
// STRICTLY opt-in, and that is a load-bearing property of this file:
//
//   • A plain toggle-off writes `.off` and nothing here runs. No timer, no notification, no
//     permission prompt. The switch behaves exactly as it always did.
//   • A schedule exists only after someone picked a duration from the "Pause for…" menu.
//   • The reminder is the only thing that touches `UNUserNotificationCenter`, and it only does
//     so when that specific option was chosen — the same rule the Q9 loss alert follows
//     (`LossNotifier`): asking for notification permission before there is anything to say is
//     how apps train people to deny it.
//
// Trustworthy resumption is the other half. A schedule is persisted in the App Group, so it
// survives relaunch, and `CapturePauseResolver.resolveIfDue` is called from the runtime's own
// refresh tick rather than from a screen — Today does not have to be open, or even built, for a
// pause to end. If the process was suspended at the deadline the resume happens at the next
// wake instead; since the UI can only be looked at while the process is running, what is on
// screen is always consistent with what capture is actually doing.

/// An opt-in timed pause. `.none` — both fields zero — is the normal state.
struct CapturePauseSchedule: Equatable, Sendable {
    /// Wall clock at which capture turns itself back on. 0 = never; the pause ends only when
    /// the person ends it.
    var resumeAtMs: Int64 = 0
    /// Wall clock at which we ask, once, whether to turn recording back on. 0 = no reminder.
    /// Recording does NOT resume by itself in this case — that is the whole difference between
    /// the two menu sections.
    var remindAtMs: Int64 = 0

    static let none = CapturePauseSchedule()

    var isArmed: Bool { resumeAtMs > 0 || remindAtMs > 0 }

    /// The moment this schedule is about, for the status line. Nil when nothing is armed.
    var deadlineMs: Int64? {
        if resumeAtMs > 0 { return resumeAtMs }
        if remindAtMs > 0 { return remindAtMs }
        return nil
    }

    /// True once an auto-resume has come due. A clock that moved backwards (timezone, NTP)
    /// cannot make this true early; a clock that jumped forward simply resumes sooner, which is
    /// the safe direction for a pause.
    func autoResumeIsDue(nowMs: Int64) -> Bool {
        resumeAtMs > 0 && nowMs >= resumeAtMs
    }
}

/// The four things the "Pause for…" menu offers. Three durations that end by themselves, and
/// one reminder for people who would rather decide again later than have the microphone come
/// back on without them.
enum CapturePauseOption: String, CaseIterable, Identifiable, Sendable {
    case resumeIn15Minutes
    case resumeIn1Hour
    case resumeIn2Hours
    case remindIn1Hour

    var id: String { rawValue }

    var minutes: Int {
        switch self {
        case .resumeIn15Minutes: return 15
        case .resumeIn1Hour, .remindIn1Hour: return 60
        case .resumeIn2Hours: return 120
        }
    }

    /// True for the option that only NOTIFIES. Capture stays paused until the person acts.
    var isReminder: Bool { self == .remindIn1Hour }

    var title: String {
        switch self {
        case .resumeIn15Minutes: return Copy.Capture.pause15Minutes
        case .resumeIn1Hour: return Copy.Capture.pauseOneHour
        case .resumeIn2Hours: return Copy.Capture.pauseTwoHours
        case .remindIn1Hour: return Copy.Capture.remindInAnHour
        }
    }

    /// The options that end by themselves, in menu order.
    static let autoResuming: [CapturePauseOption] = [
        .resumeIn15Minutes, .resumeIn1Hour, .resumeIn2Hours,
    ]
    static let reminding: [CapturePauseOption] = [.remindIn1Hour]

    func schedule(nowMs: Int64) -> CapturePauseSchedule {
        let deadline = nowMs + Int64(minutes) * 60_000
        return isReminder
            ? CapturePauseSchedule(resumeAtMs: 0, remindAtMs: deadline)
            : CapturePauseSchedule(resumeAtMs: deadline, remindAtMs: 0)
    }
}

// MARK: - Resolution

/// What an armed schedule should do right now.
enum CapturePauseResolution: Equatable {
    /// Leave it alone: nothing armed, or the deadline has not arrived.
    case nothing
    /// Drop the schedule without touching capture — capture is no longer paused, so whatever
    /// changed it (the switch, Control Center, a widget button, Siri) has superseded the timer.
    case clear
    /// The auto-resume came due: clear the schedule and turn capture back on.
    case resume
}

@MainActor
enum CapturePauseResolver {

    /// Pure decision, so the state machine is testable without settings, notifications or a
    /// runtime.
    ///
    /// The `clear` case is the one that keeps every other surface honest: a widget's Resume, a
    /// Control Center toggle and the Settings switch all write `captureIntent` without knowing
    /// this file exists, and a schedule left armed behind them would resume capture minutes
    /// after the person had already turned it off.
    static func resolution(
        intent: CaptureIntent, schedule: CapturePauseSchedule, nowMs: Int64
    ) -> CapturePauseResolution {
        guard schedule.isArmed else { return .nothing }
        guard intent == .paused else { return .clear }
        return schedule.autoResumeIsDue(nowMs: nowMs) ? .resume : .nothing
    }

    /// Applies the decision. Called from the runtime's refresh tick, so it runs whether or not
    /// any screen is on.
    ///
    /// Clears the schedule BEFORE applying the intent: `apply` re-enters the refresh path, and
    /// a schedule still armed at that point would be re-resolved on the way back in.
    ///
    /// Returns true when it resumed capture.
    @discardableResult
    static func resolveIfDue(
        settings: AppSettings,
        nowMs: Int64,
        reminder: any CapturePauseReminding = SystemCapturePauseReminder(),
        apply: (CaptureIntent) -> Void
    ) -> Bool {
        let decision = resolution(
            intent: settings.captureIntent, schedule: settings.capturePause, nowMs: nowMs)
        switch decision {
        case .nothing:
            return false
        case .clear:
            settings.capturePause = .none
            Task { await reminder.cancel() }
            return false
        case .resume:
            settings.capturePause = .none
            settings.captureIntent = .active
            Task { await reminder.cancel() }
            apply(.active)
            return true
        }
    }
}

// MARK: - The reminder

/// The pause reminder's half of `UNUserNotificationCenter`, as a seam so the state machine is
/// testable and so previews/simulators can no-op cleanly.
///
/// Deliberately separate from `LossNotificationScheduling`: that one posts immediately (a gap
/// has just happened), this one has to fire at a future time with the app asleep, which is a
/// different trigger and a different identifier to cancel.
protocol CapturePauseReminding: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Shows the system prompt. Returns whether we may post.
    func requestAuthorization() async -> Bool
    /// Schedules the one pause reminder, replacing any previous one. Returns false when it
    /// could not be scheduled, so the caller can say so instead of promising a nudge that will
    /// never arrive.
    @discardableResult
    func schedule(afterSeconds: TimeInterval) async -> Bool
    func cancel() async
}

struct SystemCapturePauseReminder: CapturePauseReminding {
    /// One identifier, so arming a second pause replaces the first rather than stacking.
    static let identifier = "capture-pause-reminder"

    private var center: UNUserNotificationCenter { .current() }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    @discardableResult
    func schedule(afterSeconds: TimeInterval) async -> Bool {
        guard afterSeconds > 0 else { return false }
        guard await hasPermission() else { return false }
        let content = UNMutableNotificationContent()
        content.title = Copy.Capture.reminderTitle
        content.body = Copy.Capture.reminderBody
        // Reuses the loss notification's key and the same `Route.parse` path, so a tapped
        // reminder lands on Today exactly like every other notification this app sends.
        content.userInfo = [
            UserNotificationLossNotifier.routeUserInfoKey:
                UserNotificationLossNotifier.routeURLString
        ]
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(
            identifier: Self.identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: afterSeconds, repeats: false)
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    func cancel() async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    /// Asks only here, and only because the person just chose the reminder option — turning it
    /// on IS the consent, and this is the system half of it. A denial is reported back rather
    /// than swallowed; the pause still happens either way.
    private func hasPermission() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return await requestAuthorization()
        case .denied: return false
        @unknown default: return false
        }
    }
}

/// Previews, `-demo-data` and tests: records what was asked for, never touches the daemon.
final class NoOpCapturePauseReminder: CapturePauseReminding, @unchecked Sendable {
    private let lock = NSLock()
    private var _scheduled: [TimeInterval] = []
    private var _cancels = 0
    private let permitted: Bool

    init(permitted: Bool = true) { self.permitted = permitted }

    var scheduled: [TimeInterval] { lock.withLock { _scheduled } }
    var cancels: Int { lock.withLock { _cancels } }

    func authorizationStatus() async -> UNAuthorizationStatus {
        permitted ? .authorized : .denied
    }
    func requestAuthorization() async -> Bool { permitted }

    @discardableResult
    func schedule(afterSeconds: TimeInterval) async -> Bool {
        guard permitted else { return false }
        lock.withLock { _scheduled.append(afterSeconds) }
        return true
    }

    func cancel() async { lock.withLock { _cancels += 1 } }
}
