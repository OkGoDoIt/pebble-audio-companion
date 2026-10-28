import AppDB
import Foundation
import Receiver
import Testing

@testable import CompanionRuntime

// The archive's device status: what a reading says (state → payload), when one is worth writing
// (the change gate), how readings coalesce (the window), and that the outbox only ever holds the
// newest. The two battery rules of 2026-09-09 are what these pin: nothing unchanged is written
// again, and nothing is written more than once for a link that flaps.

private let zone = "UTC"
/// 2026-10-28 12:00 UTC: well inside a logical day.
private let noonMs: Int64 = 1_793_188_800_000

private func inputs(
    nowMs: Int64 = noonMs, intent: CaptureIntent = .active,
    state: ReceiverSessionState = .streaming(streamId: 7), bound: Bool = true,
    lastAudioAtMs: Int64? = nil, battery: Int? = 80, firmware: String? = "v4.41.0-667",
    coverage: CoverageSnapshot? = nil, phone: Int? = 64
) -> ArchiveDeviceStatusInputs {
    ArchiveDeviceStatusInputs(
        nowMs: nowMs, captureIntent: intent, receiverState: state, watchBound: bound,
        lastAudioAtMs: lastAudioAtMs ?? nowMs - 2_000, watchBatteryPercent: battery,
        watchFirmware: firmware, coverage: coverage, phoneBatteryPercent: phone)
}

private func snapshot(
    nowMs: Int64, recordedMin: Int64, quietMin: Int64, lostMin: Int64, dateKey: String? = nil
) -> CoverageSnapshot {
    let key = dateKey ?? LogicalDay.dateKey(forMs: nowMs, timeZoneID: zone)
    let start = nowMs - (recordedMin + quietMin + lostMin) * 60_000
    let quietStart = start + recordedMin * 60_000
    let lostStart = quietStart + quietMin * 60_000
    return CoverageSnapshot(
        generatedAtMs: nowMs, dateKey: key, timeZoneID: zone, dayStartMs: start, nowMs: nowMs,
        spans: [
            CoverageSpan(kind: .recorded, startMs: start, endMs: quietStart),
            CoverageSpan(kind: .quiet, startMs: quietStart, endMs: lostStart),
            CoverageSpan(kind: .missing, startMs: lostStart, endMs: nowMs),
        ],
        totalRecordedMs: recordedMin * 60_000, totalMissingMs: lostMin * 60_000,
        headline: "Recording", dot: "active", isRecording: true)
}

@Suite("archive device status — reading")
struct ArchiveDeviceStatusDerivationTests {
    @Test func aStreamingWatchTheyWantRecordingIsRecording() {
        let status = ArchiveDeviceStatusPayload.derive(
            inputs(lastAudioAtMs: noonMs - 1_500, battery: 62, firmware: " v4.41.0-667\n",
                   coverage: snapshot(nowMs: noonMs, recordedMin: 312, quietMin: 95, lostMin: 4)))
        #expect(status == ArchiveDeviceStatusPayload(
            updatedAtMs: noonMs, capture: .active, link: .streaming, recording: true,
            lastAudioAtMs: noonMs - 1_500, watchBatteryPercent: 62, watchFirmware: "v4.41.0-667",
            todayRecordedMinutes: 312, todayQuietMinutes: 95, todayLostMinutes: 4,
            storageUsedBytes: nil, phoneBatteryPercent: 64))
    }

    @Test func recordingNeedsBothTheStreamAndTheIntent() {
        #expect(!ArchiveDeviceStatusPayload.derive(inputs(intent: .paused)).recording)
        #expect(ArchiveDeviceStatusPayload.derive(inputs(intent: .paused)).capture == .paused)
        #expect(ArchiveDeviceStatusPayload.derive(inputs(intent: .off)).capture == .off)
        #expect(!ArchiveDeviceStatusPayload.derive(inputs(state: .authorized)).recording)
    }

    @Test func everyReceiverStateHasItsWord() {
        let expected: [(ReceiverSessionState, ArchiveDeviceStatusPayload.Link)] = [
            (.disconnected, .disconnected),
            (.connecting, .connecting),
            (.connectionFailed(kind: .watchUnreachable, detail: nil), .disconnected),
            (.authorizing, .connected),
            (.pendingConsent, .connected),
            (.pendingEnable, .connected),
            (.denied(statusRaw: 3), .connected),
            (.authorized, .connected),
            (.streaming(streamId: 1), .streaming),
            (.revoked(reasonRaw: 1), .revoked),
        ]
        for (state, link) in expected {
            #expect(ArchiveDeviceStatusPayload.derive(inputs(state: state)).link == link, "\(state)")
        }
        // A phone that never bound a watch says so rather than "disconnected"; one that is
        // talking to a watch says what the link is doing.
        #expect(ArchiveDeviceStatusPayload.derive(inputs(state: .disconnected, bound: false)).link == .unbound)
        #expect(ArchiveDeviceStatusPayload.derive(inputs(state: .connecting, bound: false)).link == .unbound)
        #expect(ArchiveDeviceStatusPayload.derive(inputs(state: .pendingConsent, bound: false)).link == .connected)
    }

    @Test func yesterdaysTotalsAreNotToday() {
        let stale = snapshot(nowMs: noonMs, recordedMin: 300, quietMin: 60, lostMin: 2,
                             dateKey: "2026-10-27")
        let status = ArchiveDeviceStatusPayload.derive(inputs(coverage: stale))
        #expect(status.todayRecordedMinutes == nil && status.todayQuietMinutes == nil
            && status.todayLostMinutes == nil)
        #expect(ArchiveDeviceStatusPayload.derive(inputs(coverage: nil)).todayRecordedMinutes == nil)
    }

    @Test func aReadingThatCannotBeRightIsKeptInRange() {
        let status = ArchiveDeviceStatusPayload.derive(inputs(battery: 140, firmware: "  ", phone: -3))
        #expect(status.watchBatteryPercent == 100)
        #expect(status.phoneBatteryPercent == 0)
        #expect(status.watchFirmware == nil)
    }

    /// The contract's own rule: every key is sent, `null` when unknown, times in epoch ms.
    @Test func everyKeyIsSentAndAnUnknownOneIsNull() throws {
        let status = ArchiveDeviceStatusPayload.derive(
            inputs(state: .disconnected, battery: nil, firmware: nil, phone: nil))
        let data = try ArchiveJSON.encoder().encode(status)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "updatedAtMs", "capture", "link", "recording", "lastAudioAtMs", "watchBatteryPercent",
            "watchFirmware", "todayRecordedMinutes", "todayQuietMinutes", "todayLostMinutes",
            "storageUsedBytes", "phoneBatteryPercent",
        ])
        #expect(object["watchBatteryPercent"] is NSNull && object["storageUsedBytes"] is NSNull)
        #expect((object["updatedAtMs"] as? NSNumber)?.int64Value == noonMs)
        #expect(object["capture"] as? String == "active" && object["link"] as? String == "disconnected")
        #expect(object["recording"] as? Bool == false)
        // And it reads back, as the reporter does after a relaunch.
        #expect(try JSONDecoder().decode(ArchiveDeviceStatusPayload.self, from: data) == status)
    }
}

@Suite("archive device status — change gate")
struct ArchiveDeviceStatusGateTests {
    let base = ArchiveDeviceStatusPayload.derive(
        inputs(coverage: snapshot(nowMs: noonMs, recordedMin: 100, quietMin: 40, lostMin: 3)))

    func later(by ms: Int64 = 60_000, _ edit: (inout ArchiveDeviceStatusPayload) -> Void = { _ in })
        -> ArchiveDeviceStatusPayload
    {
        var next = base
        next.updatedAtMs += ms
        next.lastAudioAtMs = next.updatedAtMs - 2_000
        edit(&next)
        return next
    }

    @Test func nothingThatMattersChangedIsNotWritten() {
        #expect(ArchiveDeviceStatusGate.reason(next: later(), last: base) == nil)
        // Small moves, the fields that never decide, and a value becoming unknown.
        let quiet: [(String, (inout ArchiveDeviceStatusPayload) -> Void)] = [
            ("battery -4", { $0.watchBatteryPercent = 76 }),
            ("minutes +9", { $0.todayRecordedMinutes = 109; $0.todayQuietMinutes = 49; $0.todayLostMinutes = 12 }),
            ("phone battery", { $0.phoneBatteryPercent = 12 }),
            ("storage", { $0.storageUsedBytes = 9_000_000 }),
            ("battery unknown", { $0.watchBatteryPercent = nil }),
            ("firmware unknown", { $0.watchFirmware = nil }),
            ("minutes unknown", { $0.todayRecordedMinutes = nil }),
            ("audio still fresh", { $0.lastAudioAtMs = $0.updatedAtMs - 9 * 60_000 }),
        ]
        for (name, edit) in quiet {
            #expect(ArchiveDeviceStatusGate.reason(next: later(edit), last: base) == nil, "\(name)")
        }
    }

    @Test func eachChangeThatMattersIsWritten() {
        let cases: [(ArchiveDeviceStatusGate.Reason, (inout ArchiveDeviceStatusPayload) -> Void)] = [
            (.capture, { $0.capture = .paused; $0.recording = false }),
            (.link, { $0.link = .disconnected; $0.recording = false }),
            (.recording, { $0.recording = false }),
            (.firmware, { $0.watchFirmware = "v4.41.0-700" }),
            (.watchBattery, { $0.watchBatteryPercent = 75 }),
            (.watchBattery, { $0.watchBatteryPercent = 85 }),
            (.audioFreshness, { $0.lastAudioAtMs = $0.updatedAtMs - 11 * 60_000 }),
            (.audioFreshness, { $0.lastAudioAtMs = nil }),
            (.todayMinutes, { $0.todayRecordedMinutes = 110 }),
            (.todayMinutes, { $0.todayQuietMinutes = 50 }),
            (.todayMinutes, { $0.todayLostMinutes = 13 }),
        ]
        for (reason, edit) in cases {
            #expect(ArchiveDeviceStatusGate.reason(next: later(edit), last: base) == reason, "\(reason)")
        }
    }

    @Test func aBatteryCrossingTwentyIsWrittenHoweverSmallTheStep() {
        var low = base
        low.watchBatteryPercent = 21
        #expect(ArchiveDeviceStatusGate.reason(next: later { $0.watchBatteryPercent = 19 }, last: low)
            == .watchBattery)
        low.watchBatteryPercent = 19
        #expect(ArchiveDeviceStatusGate.reason(next: later { $0.watchBatteryPercent = 21 }, last: low)
            == .watchBattery)
        #expect(ArchiveDeviceStatusGate.reason(next: later { $0.watchBatteryPercent = 17 }, last: low) == nil)
    }

    @Test func aValueBecomingKnownIsWritten() {
        var unknown = base
        unknown.watchBatteryPercent = nil
        unknown.watchFirmware = nil
        unknown.todayRecordedMinutes = nil
        #expect(ArchiveDeviceStatusGate.reason(next: later(), last: unknown) == .firmware)
        unknown.watchFirmware = base.watchFirmware
        #expect(ArchiveDeviceStatusGate.reason(next: later(), last: unknown) == .watchBattery)
        unknown.watchBatteryPercent = base.watchBatteryPercent
        #expect(ArchiveDeviceStatusGate.reason(next: later(), last: unknown) == .todayMinutes)
    }

    @Test func aQuarterHourWithNothingNewIsAHeartbeat() {
        #expect(ArchiveDeviceStatusGate.reason(next: later(by: 15 * 60_000 - 1), last: base) == nil)
        #expect(ArchiveDeviceStatusGate.reason(next: later(by: 15 * 60_000), last: base) == .heartbeat)
        #expect(ArchiveDeviceStatusGate.reason(next: base, last: nil) == .first)
    }
}

/// Mutable inputs for a reporter under test. Audio keeps arriving (two seconds ago, whatever
/// the clock says) until a test stops it.
final class DeviceStatusInputsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ArchiveDeviceStatusInputs
    private var _settings: ArchiveSyncSettings
    private var _audioFollowsClock = true
    init(_ value: ArchiveDeviceStatusInputs, settings: ArchiveSyncSettings) {
        _value = value
        _settings = settings
    }
    var settings: ArchiveSyncSettings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }
    func edit(_ change: (inout ArchiveDeviceStatusInputs) -> Void) {
        lock.withLock { change(&_value) }
    }
    /// Audio stopped at `ms`.
    func audioStopped(at ms: Int64) {
        lock.withLock {
            _audioFollowsClock = false
            _value.lastAudioAtMs = ms
        }
    }
    func read(nowMs: Int64) -> ArchiveDeviceStatusInputs {
        lock.withLock {
            var value = _value
            value.nowMs = nowMs
            if _audioFollowsClock { value.lastAudioAtMs = nowMs - 2_000 }
            return value
        }
    }
}

@Suite("archive device status — reporter")
struct ArchiveDeviceStatusReporterTests {
    struct World {
        var db: AppDatabase
        var outbox: ArchiveOutbox
        var clock: TestClock
        var box: DeviceStatusInputsBox
        var reporter: ArchiveDeviceStatusReporter
    }

    static let linked = ArchiveSyncSettings(
        origin: "https://pebbleaudio.okgodoit.com", deviceId: "dev-1", enabled: true)

    func world(
        db existing: AppDatabase? = nil, clock existingClock: TestClock? = nil,
        settings: ArchiveSyncSettings = linked, storage: Int64? = 734_003_200
    ) async throws -> World {
        let db = try existing ?? AppDatabase.inMemory()
        let outbox = ArchiveOutbox(db: db)
        try await outbox.setActive(true)
        let clock = existingClock ?? TestClock()
        if existingClock == nil { await clock.advance(by: noonMs) }
        let box = DeviceStatusInputsBox(inputs(), settings: settings)
        let reporter = ArchiveDeviceStatusReporter(
            .init(
                outbox: outbox, settings: { box.settings },
                inputs: { box.read(nowMs: clock.nowMs) },
                storageUsedBytes: { storage }, clock: clock))
        return World(db: db, outbox: outbox, clock: clock, box: box, reporter: reporter)
    }

    func written(_ w: World) async throws -> ArchiveDeviceStatusPayload? {
        guard let saved = try await w.outbox.deviceStatusPayload(deviceId: "dev-1") else { return nil }
        return try JSONDecoder().decode(ArchiveDeviceStatusPayload.self, from: saved)
    }

    @Test func eachChangeThatMattersIsOneWriteAndNothingElseIsAny() async throws {
        let w = try await world()
        await w.reporter.flush()
        #expect(await w.reporter.writes == 1)
        // Only a reading that is written asks what storage the recordings take.
        #expect(try await written(w)?.storageUsedBytes == 734_003_200)

        let changes: [(String, (inout ArchiveDeviceStatusInputs) -> Void)] = [
            ("capture", { $0.captureIntent = .paused }),
            ("link", { $0.receiverState = .disconnected }),
            ("firmware", { $0.watchFirmware = "v4.41.0-700" }),
            ("battery 5 points", { $0.watchBatteryPercent = 75 }),
            ("battery across 20", { $0.watchBatteryPercent = 22 }),
            ("battery across 20", { $0.watchBatteryPercent = 19 }),
            ("minutes", {
                $0.coverage = snapshot(nowMs: $0.nowMs, recordedMin: 10, quietMin: 0, lostMin: 0)
            }),
        ]
        for (name, change) in changes {
            let before = await w.reporter.writes
            w.box.edit(change)
            await w.clock.advance(by: 60_000)
            await w.reporter.idle()
            await w.reporter.flush()
            #expect(await w.reporter.writes == before + 1, "\(name)")
            // The same reading again is not written again.
            await w.clock.advance(by: 60_000)
            await w.reporter.idle()
            await w.reporter.flush()
            #expect(await w.reporter.writes == before + 1, "\(name), unchanged")
        }

        // Audio going stale: the same inputs, eleven minutes on.
        let before = await w.reporter.writes
        w.box.audioStopped(at: w.clock.nowMs)
        await w.clock.advance(by: 11 * 60_000)
        await w.reporter.idle()
        await w.reporter.flush()
        #expect(await w.reporter.writes == before + 1)
        #expect(try await written(w)?.watchFirmware == "v4.41.0-700")
    }

    @Test func pokesInsideTheWindowAreOneReading() async throws {
        let w = try await world()
        await w.reporter.flush()
        #expect(await w.reporter.writes == 1)

        // The link flaps: down, up, down, up within seconds. One reading, of where it settled,
        // which is where it was: nothing written.
        for state in [ReceiverSessionState.disconnected, .connecting, .authorized, .streaming(streamId: 8)] {
            w.box.edit { $0.receiverState = state }
            await w.reporter.poke()
            await w.clock.advance(by: 1_000)
            await w.reporter.idle()
        }
        await w.clock.advance(by: 10_000)
        await w.reporter.idle()
        #expect(await w.reporter.writes == 1)

        // A real change: written once, only after the pokes have been quiet for the window.
        w.box.edit { $0.receiverState = .disconnected }
        await w.reporter.poke()
        await w.clock.advance(by: 2_000)
        await w.reporter.idle()
        await w.reporter.poke()
        await w.clock.advance(by: 2_000)
        await w.reporter.idle()
        await w.reporter.poke()
        await w.clock.advance(by: 4_900)
        await w.reporter.idle()
        #expect(await w.reporter.writes == 1)
        await w.clock.advance(by: 200)
        await w.reporter.idle()
        #expect(await w.reporter.writes == 2)
        #expect(try await written(w)?.link == .disconnected)
    }

    @Test func pokesThatNeverStopStillGiveAReadingWithinTheCap() async throws {
        let w = try await world()
        await w.reporter.flush()
        w.box.edit { $0.captureIntent = .paused }
        var elapsed: Int64 = 0
        while elapsed < 40_000 {
            await w.reporter.poke()
            await w.clock.advance(by: 4_000)
            await w.reporter.idle()
            elapsed += 4_000
            if elapsed < ArchiveDeviceStatusReporter.maxWaitMs {
                #expect(await w.reporter.writes == 1, "at \(elapsed)")
            }
        }
        #expect(await w.reporter.writes == 2)
    }

    @Test func aHeartbeatAtMostEveryQuarterHourAndOnlyWhenAsked() async throws {
        let w = try await world()
        await w.reporter.flush()
        // Nothing of its own runs: an hour with nobody asking writes nothing.
        await w.clock.advance(by: 60 * 60_000)
        await w.reporter.idle()
        #expect(await w.reporter.writes == 1)
        // The awake moments ask; the first one after a quarter hour writes.
        await w.reporter.poke()
        await w.clock.advance(by: 6_000)
        await w.reporter.idle()
        #expect(await w.reporter.writes == 2)
        // A minute heartbeat's worth of pokes for the next fourteen minutes: nothing new.
        for _ in 0..<14 {
            await w.clock.advance(by: 55_000)
            await w.reporter.idle()
            await w.reporter.poke()
            await w.clock.advance(by: 6_000)
            await w.reporter.idle()
        }
        #expect(await w.reporter.writes == 2)
        await w.clock.advance(by: 60_000)
        await w.reporter.idle()
        await w.reporter.flush()
        #expect(await w.reporter.writes == 3)
    }

    @Test func nothingIsWrittenUnlessTheTextIsSyncing() async throws {
        var paused = Self.linked
        paused.enabled = false
        let w = try await world(settings: paused)
        await w.reporter.flush()
        #expect(await w.reporter.writes == 0)
        #expect(try await w.outbox.deviceStatus() == nil)
        w.box.settings = ArchiveSyncSettings()
        await w.reporter.flush()
        #expect(await w.reporter.writes == 0)
        w.box.settings = Self.linked
        await w.reporter.flush()
        #expect(await w.reporter.writes == 1)
    }

    /// A relaunch compares against what was last written, not against nothing: the first
    /// reading of a new process is not a write when nothing changed.
    @Test func aRelaunchDoesNotReportAgainWhatNothingChanged() async throws {
        let first = try await world()
        await first.reporter.flush()
        #expect(await first.reporter.writes == 1)

        await first.clock.advance(by: 60_000)
        await first.reporter.idle()
        let second = try await world(db: first.db, clock: first.clock)
        await second.reporter.flush()
        #expect(await second.reporter.writes == 0)
        second.box.edit { $0.receiverState = .connecting }
        await second.reporter.flush()
        #expect(await second.reporter.writes == 1)

        // A new link (a new device id) is a new server row: written at once, the old one gone.
        second.box.settings.deviceId = "dev-2"
        await second.reporter.flush()
        #expect(await second.reporter.writes == 2)
        #expect(try await second.outbox.row(kind: .deviceStatus, id: "dev-1") == nil)
        #expect(try await second.outbox.row(kind: .deviceStatus, id: "dev-2")?.pending == true)
    }

    @Test func aWipedServerHearsTheStatusAgainAtOnce() async throws {
        let w = try await world()
        await w.reporter.flush()
        await w.clock.advance(by: 60_000)
        await w.reporter.idle()
        await w.reporter.flush()
        #expect(await w.reporter.writes == 1)
        await w.reporter.serverForgot()
        await w.reporter.flush()
        #expect(await w.reporter.writes == 2)
    }

    @Test func theReceiversStateIsWatched() async throws {
        let w = try await world()
        let state = StateSubject<ReceiverSessionState>(.streaming(streamId: 7))
        await w.reporter.start(observing: state)
        await w.clock.advance(by: 6_000)
        await w.reporter.idle()
        #expect(await w.reporter.writes == 1)
        state.value = .disconnected
        await w.clock.advance(by: 6_000)
        await w.reporter.idle()
        #expect(await w.reporter.writes == 1)  // the inputs still say streaming
        w.box.edit { $0.receiverState = .disconnected }
        state.value = .connecting
        await w.clock.advance(by: 6_000)
        await w.reporter.idle()
        #expect(await w.reporter.writes == 2)
    }
}
