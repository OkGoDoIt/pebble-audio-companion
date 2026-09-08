import Receiver
import SwiftUI
import WidgetKit

// The ONE capture control (session: "is that doing exactly the same thing as turning it on and
// off on the today screen? … maybe a better UI for that would be a toggle switch").
//
// What was actually true before this file existed:
//
//   • Settings' "Background audio" switch wrote `.off` and went through
//     `CaptureControlling.applyCaptureIntent`.
//   • Today's "Pause" text link wrote `.paused` and went through `TodayDataSource.requestPause`.
//
// So the answer to the question was "no, almost" — the same switch in two places producing two
// different states, under two different names, one of them a link. That is the confusion, not
// the labelling alone.
//
// The model now, and it is the same on every surface:
//
//   ON  (.active)  the watch is capturing
//   OFF (.off)     the receiver is stopped. This is what the switch's off position means, and
//                  it is unchanged in spirit: off until you turn it back on.
//   PAUSED         a TEMPORARY, deliberately-chosen suspension. Reachable only from the
//                  "Pause for…" menu (and from the widget's own Pause button), never from
//                  flipping the switch — which is what finally gives `.paused` one meaning
//                  instead of two. The switch stays ON and amber while paused, the way a Focus
//                  stays on while it is scheduled off; the state line says when it ends.
//
// `CaptureStatus` is the one vocabulary and `CaptureController` is the one policy; only the
// TRANSPORT differs between the two surfaces, and both transports are the same
// `LiveTodayDataSource` object in a real build (it conforms to `TodayDataSource` AND
// `CaptureControlling`), reaching the same `CompanionRuntime` calls. Today keeps its own
// transport so `PreviewTodayData` still animates the approved artboards.

// MARK: - Status (one vocabulary)

/// What capture is doing, in the words every surface uses for it.
struct CaptureStatus: Equatable {
    let intent: CaptureIntent
    let schedule: CapturePauseSchedule

    init(intent: CaptureIntent, schedule: CapturePauseSchedule) {
        self.intent = intent
        // A schedule only ever describes a pause. Reading it as "not armed" for every other
        // intent means a stale row can never announce a resume time over a capture state that
        // has already moved on — the resolver clears it moments later either way.
        self.schedule = intent == .paused ? schedule : .none
    }

    @MainActor
    init(_ settings: AppSettings) {
        self.init(intent: settings.captureIntent, schedule: settings.capturePause)
    }

    /// The switch position. Paused counts as ON: the setting is enabled, it is just suspended.
    var isCapturing: Bool { intent != .off }
    var isPaused: Bool { intent == .paused }
    /// The "Pause for…" menu belongs to states where there is something to pause.
    var canPause: Bool { isCapturing }

    /// The one sentence, for whichever surface has room for it.
    var line: String {
        switch intent {
        case .active:
            return Copy.Capture.onLine
        case .paused:
            if schedule.resumeAtMs > 0 {
                return Copy.Capture.pausedResumingLine(Self.clock(schedule.resumeAtMs))
            }
            if schedule.remindAtMs > 0 {
                return Copy.Capture.pausedReminderLine(Self.clock(schedule.remindAtMs))
            }
            return Copy.Capture.pausedLine
        case .off:
            return Copy.Capture.offLine
        }
    }

    var color: Color {
        switch intent {
        case .active: return Tokens.good
        case .paused: return Tokens.attention
        case .off: return Tokens.meta
        }
    }

    private static func clock(_ ms: Int64) -> String {
        TimeFmt.time(Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

// MARK: - Controller (one policy)

/// Everything a capture surface can ask for, decided in one place.
///
/// `apply` is the only injected part: it is what carries the chosen intent to the runtime. The
/// settings write always happens FIRST — `CaptureControlling.applyCaptureIntent` documents that
/// contract, and it is what lets a row flip the instant it is tapped instead of waiting on a
/// watch that may be out of range.
@MainActor
struct CaptureController {
    let settings: AppSettings
    let apply: (CaptureIntent) -> Void
    var reminder: any CapturePauseReminding = SystemCapturePauseReminder()
    var now: () -> Date = Date.init
    /// How the widget and the Control Center toggle are told to look again. Injected so the
    /// unit-test bundle — which has no widget extension and no App Group entitlement — never
    /// reaches into WidgetKit.
    var reloadNativeSurfaces: @MainActor () -> Void = CaptureController.reloadWidgetSurfaces

    var status: CaptureStatus { CaptureStatus(settings) }

    /// The switch. Off is a durable off with no timer and no notification — deliberately
    /// unchanged from what the Settings switch always did.
    func setCapturing(_ on: Bool) {
        set(on ? .active : .off)
    }

    /// "Resume now" from a paused card, and the auto-resume's manual twin.
    func resumeNow() { set(.active) }

    /// Arms an opt-in timed pause.
    ///
    /// `onReminderUnavailable` fires only for the reminder option, and only when iOS will not
    /// deliver it: the pause has still happened, and the surface says so rather than leaving a
    /// person to rely on a nudge that is never coming.
    func pause(_ option: CapturePauseOption, onReminderUnavailable: @escaping () -> Void = {}) {
        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        settings.captureIntent = .paused
        settings.capturePause = option.schedule(nowMs: nowMs)
        apply(.paused)

        reloadNativeSurfaces()

        let reminder = self.reminder
        Task { @MainActor in
            await reminder.cancel()
            guard option.isReminder else { return }
            let scheduled = await reminder.schedule(
                afterSeconds: TimeInterval(option.minutes * 60))
            if !scheduled {
                // The pause stands; only the reminder failed. Drop the promise from the state
                // line too, so nothing on screen claims a nudge that will not arrive.
                settings.capturePause = .none
                onReminderUnavailable()
            }
        }
    }

    /// Keeps the pause and drops the timer — the "actually, leave it off" escape from a timed
    /// pause, without having to turn capture off and on again.
    func cancelTimer() {
        settings.capturePause = .none
        let reminder = self.reminder
        Task { await reminder.cancel() }
    }

    private func set(_ intent: CaptureIntent) {
        settings.captureIntent = intent
        // Any deliberate on/off supersedes a timer: leaving one armed is how a schedule
        // resumes capture minutes after the person switched it off.
        if settings.capturePause.isArmed { settings.capturePause = .none }
        let reminder = self.reminder
        Task { await reminder.cancel() }
        apply(intent)
        reloadNativeSurfaces()
    }

    /// The widget and the Control Center toggle read the App Group, which `AppSettings` has
    /// just written — but nothing asks them to look again, so they went on showing the old
    /// state until the app next backgrounded. `NativeSurfaceCoordinator` does exactly this when
    /// a request arrives FROM one of those surfaces; this is the same call for a change made in
    /// the app, so "every surface agrees" is true in both directions rather than one.
    static func reloadWidgetSurfaces() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadControls(ofKind: SharedAppGroup.captureControlKind)
    }
}

// MARK: - The control

/// The capture switch, rendered the same way wherever it appears.
struct CaptureToggle: View {
    enum Layout {
        /// Just the switch — for a status card whose headline and dot already say what state
        /// this is (Today).
        case compact
        /// Title, state line and switch — a settings row (Settings root).
        case row
    }

    let controller: CaptureController
    var layout: Layout = .compact
    /// Reported when a chosen reminder cannot be delivered; the surface decides how to say it.
    var onReminderUnavailable: () -> Void = {}

    private var status: CaptureStatus { controller.status }

    private var binding: Binding<Bool> {
        Binding(
            get: { status.isCapturing },
            set: { on in
                // Only the capture transport gets a haptic, and only for the direction that
                // changed — same rule the status card's buttons follow.
                if on { Haptics.captureStarted() } else { Haptics.captureEnded() }
                controller.setCapturing(on)
            }
        )
    }

    var body: some View {
        // Long-press is the iOS-idiomatic home for "this control, but with a duration" — it is
        // where Focus and Do Not Disturb keep theirs. It is deliberately NOT the only door:
        // Settings shows the same options as a visible row, because an affordance nobody can
        // find is the same as one that does not exist.
        //
        // The modifier is applied conditionally rather than given empty content: a long press
        // that opens an empty menu is worse than one that does nothing.
        if status.canPause {
            content.contextMenu {
                CapturePauseMenuItems(
                    controller: controller, onReminderUnavailable: onReminderUnavailable)
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .compact:
            // A hint, not a value: `accessibilityValue` would REPLACE VoiceOver's "on"/"off"
            // with the sentence, and on a microphone switch the on/off word is the part that
            // must always be spoken. The card's headline carries the state visually; the hint
            // adds what the headline cannot say (when a pause ends).
            Toggle(Copy.Capture.title, isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Tokens.good)
                .accessibilityLabel(Copy.Capture.title)
                .accessibilityHint(status.line)
        case .row:
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.Capture.title)
                        .font(AppFont.callout)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(status.line)
                        .font(AppFont.footnote)
                        .foregroundStyle(status.isPaused ? Tokens.attention : Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The switch keeps its intrinsic width, so at accessibility sizes the label
                // wraps rather than being hyphenated into the leftover column.
                Spacer(minLength: 10)
                // No hint here: the state line beside it is a real element VoiceOver already
                // reads, and repeating it as a hint would say the same sentence twice.
                Toggle(Copy.Capture.title, isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Tokens.good)
                    .accessibilityLabel(Copy.Capture.title)
            }
        }
    }

}

/// The "Pause for…" options. One definition, so the long-press menu and the Settings row can
/// never offer different sets.
struct CapturePauseMenuItems: View {
    let controller: CaptureController
    var onReminderUnavailable: () -> Void = {}

    var body: some View {
        Section(Copy.Capture.pauseResumeSection) {
            ForEach(CapturePauseOption.autoResuming) { option in
                Button(option.title) { choose(option) }
            }
        }
        Section(Copy.Capture.pauseRemindSection) {
            ForEach(CapturePauseOption.reminding) { option in
                Button(option.title) { choose(option) }
            }
        }
        if controller.status.schedule.isArmed {
            Section {
                Button(Copy.Capture.cancelTimer) { controller.cancelTimer() }
            }
        }
    }

    private func choose(_ option: CapturePauseOption) {
        Haptics.captureEnded()
        controller.pause(option, onReminderUnavailable: onReminderUnavailable)
    }
}

// MARK: - Previews

#Preview("Capture toggle · row") {
    let settings = AppSettings()
    return VStack(spacing: Tokens.blockGap) {
        ListCard {
            CaptureToggle(
                controller: CaptureController(
                    settings: settings, apply: { _ in }, reminder: NoOpCapturePauseReminder(),
                    reloadNativeSurfaces: {}),
                layout: .row
            )
        }
    }
    .padding(Tokens.screenMargin)
    .background(Tokens.ground)
    .environment(settings)
}
