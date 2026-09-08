import CompanionRuntime
import Foundation
import Receiver
import Testing

// The unified capture control and its opt-in timed pause (session: "is that doing exactly the
// same thing as turning it on and off on the today screen? … an option to temporarily pause
// recording … but neither of these should be the default behavior").
//
// The three properties worth failing a build over:
//
//   1. THE DEFAULT IS UNCHANGED. Flipping the switch off writes `.off`, arms no timer and
//      schedules no notification. Everything about the timed pause is reachable only from the
//      "Pause for…" menu.
//   2. THE TIMER CANNOT OUTLIVE ITS PAUSE. Every other surface — Control Center, a widget
//      button, Siri, the Settings switch — writes `captureIntent` without knowing this state
//      machine exists. A schedule left armed behind one of them would turn a microphone back on
//      minutes after someone deliberately switched it off.
//   3. A PROMISE THAT CANNOT BE KEPT IS WITHDRAWN. If iOS will not deliver the reminder, the
//      schedule is cleared and the caller is told, rather than the UI going on saying "we'll
//      ask you at 3:40".

@Suite("capture control") @MainActor
struct CaptureControlTests {

    /// A real `AppSettings` on a throwaway defaults suite — the persistence and the observed
    /// properties are part of what is being tested, so nothing here fakes them. One suite name
    /// per call: Swift Testing runs these in parallel.
    private func makeSettings() -> AppSettings {
        let suite = "capture-control-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults, keychain: KeychainStore(service: "tests.unused"))
    }

    /// Records what reached the runtime.
    private final class AppliedIntents {
        var values: [CaptureIntent] = []
    }

    private func makeController(
        _ settings: AppSettings,
        applied: AppliedIntents,
        reminder: any CapturePauseReminding = NoOpCapturePauseReminder(),
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> CaptureController {
        CaptureController(
            settings: settings,
            apply: { applied.values.append($0) },
            reminder: reminder,
            now: { now },
            // The test bundle has no widget extension and no App Group entitlement.
            reloadNativeSurfaces: {}
        )
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }

    // MARK: - The switch (default behaviour, unchanged)

    @Test func theSwitchOffWritesOffAndArmsNothing() {
        let settings = makeSettings()
        let applied = AppliedIntents()
        let reminder = NoOpCapturePauseReminder()
        let controller = makeController(settings, applied: applied, reminder: reminder)
        settings.captureIntent = .active

        controller.setCapturing(false)

        #expect(settings.captureIntent == .off)
        #expect(settings.capturePause == .none, "a plain toggle-off never arms a timer")
        #expect(applied.values == [.off], "the runtime is told, not just the preference")
        #expect(reminder.scheduled.isEmpty, "and no notification is scheduled")
    }

    @Test func theSwitchOnWritesActive() {
        let settings = makeSettings()
        let applied = AppliedIntents()
        let controller = makeController(settings, applied: applied)
        settings.captureIntent = .off

        controller.setCapturing(true)

        #expect(settings.captureIntent == .active)
        #expect(applied.values == [.active])
    }

    /// The whole point of the round: Today's off and Settings' off are the same operation now.
    /// Today used to write `.paused` here and Settings `.off`.
    @Test func bothSurfacesSendTheSameIntentsForTheSameGesture() {
        let today = makeSettings()
        let todayApplied = AppliedIntents()
        let settingsScreen = makeSettings()
        let settingsApplied = AppliedIntents()

        makeController(today, applied: todayApplied).setCapturing(false)
        makeController(settingsScreen, applied: settingsApplied).setCapturing(false)

        #expect(todayApplied.values == settingsApplied.values)
        #expect(today.captureIntent == settingsScreen.captureIntent)
    }

    @Test func turningItBackOnDropsAnArmedTimer() {
        let settings = makeSettings()
        let applied = AppliedIntents()
        let controller = makeController(settings, applied: applied)
        controller.pause(.resumeIn1Hour)
        #expect(settings.capturePause.isArmed)

        controller.resumeNow()

        #expect(settings.captureIntent == .active)
        #expect(settings.capturePause == .none, "a resume must not leave a timer behind it")
    }

    @Test func turningItOffDropsAnArmedTimer() {
        let settings = makeSettings()
        let applied = AppliedIntents()
        let controller = makeController(settings, applied: applied)
        controller.pause(.resumeIn2Hours)

        controller.setCapturing(false)

        #expect(settings.captureIntent == .off)
        #expect(
            settings.capturePause == .none,
            "otherwise the timer turns the microphone back on after a deliberate off")
    }

    // MARK: - The opt-in timed pause

    @Test func pausingForADurationArmsAnAutoResume() {
        let settings = makeSettings()
        let applied = AppliedIntents()
        let controller = makeController(settings, applied: applied)

        controller.pause(.resumeIn15Minutes)

        #expect(settings.captureIntent == .paused)
        #expect(settings.capturePause.resumeAtMs == Self.nowMs + 15 * 60_000)
        #expect(settings.capturePause.remindAtMs == 0)
        #expect(applied.values == [.paused])
    }

    /// The reminder option does NOT resume by itself — it asks. Conflating the two would turn a
    /// microphone back on for someone who chose to decide again later.
    @Test func theReminderOptionNeverArmsAnAutoResume() {
        let settings = makeSettings()
        let applied = AppliedIntents()
        let controller = makeController(settings, applied: applied)

        controller.pause(.remindIn1Hour)

        #expect(settings.capturePause.resumeAtMs == 0)
        #expect(settings.capturePause.remindAtMs == Self.nowMs + 60 * 60_000)
        #expect(
            CapturePauseResolver.resolution(
                intent: .paused, schedule: settings.capturePause,
                nowMs: Self.nowMs + 2 * 60 * 60_000) == .nothing)
    }

    @Test func aPauseThatSurvivesRelaunchIsReadBackWhole() {
        let suite = "capture-control-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let first = AppSettings(defaults: defaults, keychain: KeychainStore(service: "tests.unused"))
        let applied = AppliedIntents()
        makeController(first, applied: applied).pause(.resumeIn1Hour)

        // Relaunch: a fresh object over the same App Group defaults.
        let second = AppSettings(defaults: defaults, keychain: KeychainStore(service: "tests.unused"))
        #expect(second.captureIntent == .paused)
        #expect(second.capturePause == first.capturePause)
        #expect(second.capturePause.resumeAtMs == Self.nowMs + 60 * 60_000)
    }

    @Test func cancellingTheTimerKeepsThePause() {
        let settings = makeSettings()
        let applied = AppliedIntents()
        let controller = makeController(settings, applied: applied)
        controller.pause(.resumeIn1Hour)

        controller.cancelTimer()

        #expect(settings.captureIntent == .paused, "it stays paused; only the timer goes")
        #expect(settings.capturePause == .none)
        #expect(applied.values == [.paused], "and nothing new is sent to the runtime")
    }

    @Test func aReminderIosWillNotDeliverIsWithdrawnAndReported() async {
        let settings = makeSettings()
        let applied = AppliedIntents()
        let controller = makeController(
            settings, applied: applied, reminder: NoOpCapturePauseReminder(permitted: false))
        var reported = false

        controller.pause(.remindIn1Hour) { reported = true }
        // The notification half is async; let it land.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(settings.captureIntent == .paused, "the pause still happened")
        #expect(reported, "and the surface is told the reminder did not")
        #expect(
            settings.capturePause == .none,
            "so nothing on screen goes on promising a nudge that will never arrive")
    }
}

// MARK: - The state machine

@Suite("capture pause schedule") @MainActor
struct CapturePauseScheduleTests {
    private static let nowMs: Int64 = 1_800_000_000_000

    @Test func nothingIsArmedByDefault() {
        #expect(!CapturePauseSchedule.none.isArmed)
        #expect(CapturePauseSchedule.none.deadlineMs == nil)
        #expect(!CapturePauseSchedule.none.autoResumeIsDue(nowMs: Self.nowMs))
        #expect(
            CapturePauseResolver.resolution(
                intent: .paused, schedule: .none, nowMs: Self.nowMs) == .nothing)
    }

    @Test func anAutoResumeIsDueOnlyAtItsDeadline() {
        let schedule = CapturePauseSchedule(resumeAtMs: Self.nowMs + 60_000)
        #expect(!schedule.autoResumeIsDue(nowMs: Self.nowMs))
        #expect(!schedule.autoResumeIsDue(nowMs: Self.nowMs + 59_999))
        #expect(schedule.autoResumeIsDue(nowMs: Self.nowMs + 60_000))
        // A phone that was asleep past the deadline resumes at the next wake, however late.
        #expect(schedule.autoResumeIsDue(nowMs: Self.nowMs + 9 * 60 * 60_000))
    }

    @Test func aClockThatMovedBackwardsCannotResumeEarly() {
        let schedule = CapturePauseSchedule(resumeAtMs: Self.nowMs + 60_000)
        #expect(!schedule.autoResumeIsDue(nowMs: Self.nowMs - 5 * 60 * 60_000))
    }

    @Test func theResolverResumesWhenTheDeadlinePasses() {
        let schedule = CapturePauseSchedule(resumeAtMs: Self.nowMs)
        #expect(
            CapturePauseResolver.resolution(
                intent: .paused, schedule: schedule, nowMs: Self.nowMs - 1) == .nothing)
        #expect(
            CapturePauseResolver.resolution(
                intent: .paused, schedule: schedule, nowMs: Self.nowMs) == .resume)
    }

    /// Control Center, a widget's Resume, Siri and the Settings switch all write `captureIntent`
    /// without knowing this file exists. A schedule that outlived one of them is the bug.
    @Test func aScheduleIsDroppedWhenSomethingElseChangedCapture() {
        let schedule = CapturePauseSchedule(resumeAtMs: Self.nowMs + 60_000)
        #expect(
            CapturePauseResolver.resolution(
                intent: .active, schedule: schedule, nowMs: Self.nowMs) == .clear)
        #expect(
            CapturePauseResolver.resolution(
                intent: .off, schedule: schedule, nowMs: Self.nowMs) == .clear)
    }

    @Test func resolveIfDueTurnsCaptureBackOn() {
        let suite = "capture-resolve-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(
            defaults: defaults, keychain: KeychainStore(service: "tests.unused"))
        settings.captureIntent = .paused
        settings.capturePause = CapturePauseSchedule(resumeAtMs: Self.nowMs)
        var applied: [CaptureIntent] = []

        let before = CapturePauseResolver.resolveIfDue(
            settings: settings, nowMs: Self.nowMs - 1, reminder: NoOpCapturePauseReminder()
        ) { applied.append($0) }
        #expect(!before)
        #expect(settings.captureIntent == .paused)

        let resumed = CapturePauseResolver.resolveIfDue(
            settings: settings, nowMs: Self.nowMs, reminder: NoOpCapturePauseReminder()
        ) { applied.append($0) }

        #expect(resumed)
        #expect(settings.captureIntent == .active)
        #expect(applied == [.active])
        // Cleared BEFORE the apply, so re-entering the refresh path cannot resolve it twice.
        #expect(settings.capturePause == .none)

        let again = CapturePauseResolver.resolveIfDue(
            settings: settings, nowMs: Self.nowMs + 60_000, reminder: NoOpCapturePauseReminder()
        ) { applied.append($0) }
        #expect(!again)
        #expect(applied == [.active])
    }

    @Test func resolveIfDueClearsAScheduleThatNoLongerDescribesAPause() {
        let suite = "capture-resolve-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(
            defaults: defaults, keychain: KeychainStore(service: "tests.unused"))
        settings.captureIntent = .off
        settings.capturePause = CapturePauseSchedule(resumeAtMs: Self.nowMs + 60_000)
        var applied: [CaptureIntent] = []

        let resumed = CapturePauseResolver.resolveIfDue(
            settings: settings, nowMs: Self.nowMs, reminder: NoOpCapturePauseReminder()
        ) { applied.append($0) }

        #expect(!resumed)
        #expect(settings.capturePause == .none)
        #expect(settings.captureIntent == .off, "clearing a timer never changes capture")
        #expect(applied.isEmpty)
    }
}

// MARK: - One vocabulary

@Suite("capture status vocabulary") @MainActor
struct CaptureStatusTests {
    private static let nowMs: Int64 = 1_800_000_000_000

    @Test func theSwitchIsOnWheneverCaptureIsEnabled() {
        #expect(CaptureStatus(intent: .active, schedule: .none).isCapturing)
        #expect(
            CaptureStatus(intent: .paused, schedule: .none).isCapturing,
            "paused is the temporary form of on, so the switch stays on")
        #expect(!CaptureStatus(intent: .off, schedule: .none).isCapturing)
    }

    @Test func eachStateHasItsOwnSentence() {
        let lines = [
            CaptureStatus(intent: .active, schedule: .none).line,
            CaptureStatus(intent: .paused, schedule: .none).line,
            CaptureStatus(intent: .off, schedule: .none).line,
            CaptureStatus(
                intent: .paused, schedule: CapturePauseSchedule(resumeAtMs: Self.nowMs)).line,
            CaptureStatus(
                intent: .paused, schedule: CapturePauseSchedule(remindAtMs: Self.nowMs)).line,
        ]
        #expect(Set(lines).count == lines.count, "five states, five sentences")
        // The two timed forms must not be interchangeable: one resumes by itself, one does not.
        #expect(lines[3] != lines[4])
    }

    /// A stale schedule can never announce a resume time over a capture state that has moved on.
    @Test func aScheduleIsIgnoredUnlessCaptureIsPaused() {
        let armed = CapturePauseSchedule(resumeAtMs: Self.nowMs + 60_000)
        #expect(CaptureStatus(intent: .active, schedule: armed).schedule == .none)
        #expect(CaptureStatus(intent: .off, schedule: armed).schedule == .none)
        #expect(CaptureStatus(intent: .paused, schedule: armed).schedule == armed)
    }

    @Test func thePauseMenuOnlyExistsWhereThereIsSomethingToPause() {
        #expect(CaptureStatus(intent: .active, schedule: .none).canPause)
        #expect(CaptureStatus(intent: .paused, schedule: .none).canPause)
        #expect(!CaptureStatus(intent: .off, schedule: .none).canPause)
    }

    @Test func everyMenuOptionProducesExactlyOneKindOfSchedule() {
        for option in CapturePauseOption.allCases {
            let schedule = option.schedule(nowMs: Self.nowMs)
            #expect(schedule.isArmed)
            #expect(
                (schedule.resumeAtMs == 0) != (schedule.remindAtMs == 0),
                "\(option) must be an auto-resume or a reminder, never both or neither")
            #expect(schedule.deadlineMs == Self.nowMs + Int64(option.minutes) * 60_000)
        }
        // Hoisted out of the `#expect`s deliberately. `map` and `allSatisfy` are `rethrows`, and
        // inside the macro expansion the compiler cannot prove the closure does not throw, so
        // writing them inline fails to build with "call can throw, but it is not marked with
        // 'try'" — pointing at generated source, which is why it reads as a mystery.
        let titles = Set(CapturePauseOption.allCases.map(\.title))
        let autoResumingAreAutoResuming = CapturePauseOption.autoResuming
            .allSatisfy { !$0.isReminder }
        let remindingAreReminders = CapturePauseOption.reminding.allSatisfy { $0.isReminder }
        #expect(titles.count == CapturePauseOption.allCases.count)
        #expect(autoResumingAreAutoResuming)
        #expect(remindingAreReminders)
        #expect(
            Set(CapturePauseOption.autoResuming + CapturePauseOption.reminding)
                == Set(CapturePauseOption.allCases),
            "every option is in exactly one menu section")
    }
}
