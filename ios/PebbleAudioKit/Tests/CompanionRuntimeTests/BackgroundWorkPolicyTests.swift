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
}
