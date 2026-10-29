import AppDB
import CompanionRuntime
import Foundation
import SpeakerRecognition
import Testing
import WireProtocol

/// The Diagnostics rows that answer "why is nothing moving?" when the answer is not the app.
///
/// On 2026-10-29 a charging phone at "serious" held every model for an hour with nothing on the
/// screen saying so, and the CPU row told the person who had just opened the app that something
/// was looping — the minute it judged was eleven seconds on screen.
@Suite("diagnostics health rows") @MainActor
struct DiagnosticsHealthRowsTests {

    @Test func theCpuWatchdogJudgesOnlyWholeBackgroundMinutesOnBattery() {
        #expect(HeartbeatTelemetry.judges(backgroundedWholeMinute: true, pluggedIn: false))
        #expect(!HeartbeatTelemetry.judges(backgroundedWholeMinute: false, pluggedIn: false),
                "a minute partly on screen is not a background minute")
        #expect(!HeartbeatTelemetry.judges(backgroundedWholeMinute: true, pluggedIn: true),
                "charger minutes are where voice recognition is meant to spend")
    }

    @Test func aHotPhoneSaysWhatItIsHolding() {
        let hot = LiveDiagnosticsSource.phone(
            DevicePowerSnapshot(isPluggedIn: true, thermalState: .serious), percent: 50)
        #expect(hot.value == "charging · 50% · hot")
        #expect(hot.detail != nil)
        let calm = LiveDiagnosticsSource.phone(DevicePowerSnapshot(), percent: 82)
        #expect(calm == DiagnosticNotice(value: "on battery · 82%"))
    }

    @Test func voiceRecognitionNamesTheHoldBeforeTheLastCheck() {
        var status = VoiceRecognitionStatus(
            configuration: VoiceRecognitionConfiguration(mode: .local), models: .installed,
            isProcessing: false, lastMessage: nil)
        status.pendingRecordings = 132
        status.lastWorkAtMs = 1_000_000
        let held = LiveDiagnosticsSource.voices(
            status, hold: .hold(reason: .tooHot), nowMs: 1_003_000)
        #expect(held.value == "132 waiting · phone too hot")
        let running = LiveDiagnosticsSource.voices(status, hold: .run, nowMs: 1_003_000)
        #expect(running.value.hasPrefix("132 waiting · last check "))
        status.pendingRecordings = 0
        status.failedRecordings = 2
        let done = LiveDiagnosticsSource.voices(status, hold: .run, nowMs: 0)
        #expect(done.value == "up to date")
        #expect(done.detail == "2 recordings couldn’t be checked.")
        let off = VoiceRecognitionStatus(
            configuration: VoiceRecognitionConfiguration(), models: .installed,
            isProcessing: false, lastMessage: nil)
        #expect(LiveDiagnosticsSource.voices(off, hold: .run, nowMs: 0).value == "off")
    }

    /// Parked recordings are in neither "waiting" nor "failed"; the row has to say them.
    @Test func parkedRecordingsAreCounted() {
        #expect(Copy.Settings.Diagnostics.queueValue(waiting: 0, failed: 0, parked: 12)
                == "0 waiting · 12 parked · 0 failed")
    }

    /// A watch in a crash loop, or one whose guard turned audio off, says so here rather than
    /// reading as "Connected, waiting for audio".
    @Test func aWatchThatStoodDownSaysHowToTurnAudioBackOn() {
        let restart = InfoSnapshot.WatchRestart(
            reasonRaw: 16, faultBoots: 3, errorReboots: 126, stoodDown: true, faultPc: 0, faultLr: 0)
        let row = LiveDiagnosticsSource.watchRestart(restart)
        #expect(row?.value == "3 crashes in a row")
        #expect(row?.detail?.hasPrefix("Cause: watchdog.") == true)
        #expect(row?.detail?.contains("turned background audio off") == true)
        let update = LiveDiagnosticsSource.watchRestart(InfoSnapshot.WatchRestart(
            reasonRaw: 2, faultBoots: 0, errorReboots: 0, stoodDown: false, faultPc: 0, faultLr: 0))
        #expect(update == DiagnosticNotice(value: "software update"))
    }
}
