import CompanionRuntime
import Testing

// The whole matrix, because this decides when the phone spends its battery on our behalf and the
// cost of getting it wrong is the complaint that started this work ("absolutely destroying the
// battery, running very hot").

@Suite struct BackgroundWorkPolicyTests {

    private func decide(
        _ setting: BackgroundCatchUp,
        plugged: Bool = false,
        lowPower: Bool = false,
        thermal: DevicePowerSnapshot.ThermalState = .nominal
    ) -> BackgroundWorkDecision {
        BackgroundWorkPolicy.decide(
            setting,
            DevicePowerSnapshot(
                isPluggedIn: plugged, isLowPowerMode: lowPower, thermalState: thermal
            )
        )
    }

    @Test func theDefaultWaitsForACharger() {
        #expect(decide(.whileCharging, plugged: true) == .run)
        #expect(decide(.whileCharging, plugged: false) == .hold(reason: .onBattery))
    }

    @Test func alwaysMeansOnBatteryToo() {
        #expect(decide(.always, plugged: false) == .run)
    }

    @Test func offIsOff() {
        #expect(decide(.never, plugged: true) == .hold(reason: .userTurnedItOff))
    }

    // Low Power Mode is the user asking the entire system to stop spending battery. An app that
    // grinds on through it is the reason people uninstall background apps.
    @Test func lowPowerModeBeatsEverySetting() {
        #expect(decide(.whileCharging, plugged: true, lowPower: true) == .hold(reason: .lowPowerMode))
        #expect(decide(.always, plugged: true, lowPower: true) == .hold(reason: .lowPowerMode))
    }

    // Thermal is not a preference. Past `.serious` the system is already throttling the CPU, so
    // the work gets slower AND hotter — and this holds while charging, because charging is itself
    // a heat source and plugged-in is exactly when a phone cooks.
    @Test func heatBeatsEverySettingIncludingWhileCharging() {
        #expect(decide(.always, plugged: true, thermal: .serious) == .hold(reason: .tooHot))
        #expect(decide(.whileCharging, plugged: true, thermal: .critical) == .hold(reason: .tooHot))
    }

    @Test func warmButNotHotStillRuns() {
        // `.fair` is ordinary use. Standing down there would mean almost never running.
        #expect(decide(.whileCharging, plugged: true, thermal: .fair) == .run)
    }

    // The reason is surfaced, so a stalled queue can explain itself instead of looking like a bug.
    @Test func everyHoldSaysWhy() {
        let holds: [BackgroundWorkDecision] = [
            decide(.never), decide(.whileCharging, lowPower: true),
            decide(.always, thermal: .critical), decide(.whileCharging),
        ]
        for hold in holds {
            guard case .hold(let reason) = hold else {
                Issue.record("expected a hold, got \(hold)")
                continue
            }
            #expect(!reason.rawValue.isEmpty)
        }
    }

    // Voice recognition is charger work wherever the app is: two models over every ten seconds
    // of audio. "Always" was chosen for transcripts and does not put voices on battery.
    @Test func voicesWaitForAChargerOnScreenAndOff() {
        func voice(_ setting: BackgroundCatchUp, plugged: Bool, foreground: Bool,
                   lowPower: Bool = false, thermal: DevicePowerSnapshot.ThermalState = .nominal) -> BackgroundWorkDecision {
            BackgroundWorkPolicy.decideVoiceRecognition(
                setting, DevicePowerSnapshot(isPluggedIn: plugged, isLowPowerMode: lowPower, thermalState: thermal),
                foreground: foreground)
        }
        for foreground in [true, false] {
            #expect(voice(.whileCharging, plugged: true, foreground: foreground) == .run)
            #expect(voice(.whileCharging, plugged: false, foreground: foreground) == .hold(reason: .onBattery))
            #expect(voice(.always, plugged: false, foreground: foreground) == .hold(reason: .onBattery))
            #expect(voice(.whileCharging, plugged: true, foreground: foreground, lowPower: true)
                    == .hold(reason: .lowPowerMode))
            #expect(voice(.always, plugged: true, foreground: foreground, thermal: .serious) == .hold(reason: .tooHot))
        }
        // "Only When Open" keeps it out of the background, not off a charging phone on screen.
        #expect(voice(.never, plugged: true, foreground: false) == .hold(reason: .userTurnedItOff))
        #expect(voice(.never, plugged: true, foreground: true) == .run)
    }

    // A tenth of one core at most, and never more often than every 3 s, so the Bluetooth
    // keepalive is not starved the way charger-time passes once starved it.
    @Test func backgroundVoiceSlicesAreSpacedByWhatTheyCost() {
        let pace = VoiceBackgroundPace()
        #expect(pace.isDue(nowMs: 0))
        #expect(pace.record(windows: 2, busyMs: 300, nowMs: 1_000) == nil)
        #expect(!pace.isDue(nowMs: 3_999) && pace.msUntilDue(nowMs: 3_000) == 1_000)
        #expect(pace.isDue(nowMs: 4_000))
        _ = pace.record(windows: 2, busyMs: 6_000, nowMs: 40_000)
        #expect(!pace.isDue(nowMs: 99_999))
        #expect(pace.isDue(nowMs: 100_000))
        // A pass that found nothing waits the minimum, and is not a slice.
        _ = pace.record(windows: 0, busyMs: 5, nowMs: 200_000)
        #expect(pace.isDue(nowMs: 230_000))
        var line: String?
        for index in 0..<8 { line = pace.record(windows: 1, busyMs: 100, nowMs: 300_000 + Int64(index)) }
        #expect(line == "voice recognition: 10 background slices, 12 windows, 7100 ms busy")
        #expect(pace.record(windows: 1, busyMs: 100, nowMs: 400_000) == nil)
    }

    /// Re-matching names after a new sample runs no models, but it is still work: it must not
    /// wait the idle half-minute between slices.
    @Test func aSliceThatOnlyRematchedIsWorkNotIdle() {
        let pace = VoiceBackgroundPace()
        _ = pace.record(windows: 0, renamed: 40, busyMs: 200, nowMs: 1_000)
        #expect(pace.isDue(nowMs: 4_000))
        var line: String?
        for index in 0..<9 { line = pace.record(windows: 0, renamed: 10, busyMs: 100, nowMs: 10_000 + Int64(index)) }
        #expect(line == "voice recognition: 10 background slices, 0 windows, 1100 ms busy, 130 recordings re-matched")
    }
}
