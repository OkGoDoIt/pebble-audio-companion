import AppDB
import Foundation
import Receiver

// What the phone tells the archive server about the watch: is it recording, the link, both
// batteries, today's minutes. A plugin inside the official Pebble app reads it from the server to
// show "recording" on a watchface; this app is the only thing that knows.
//
// One `deviceStatus` item per linked phone, upserted through the ordinary outbox and batch, so it
// rides the background session and the outbox's retries like everything else. What keeps it cheap
// is WHEN it is written (the two battery rules of 2026-09-09):
//
//  1. Never re-published unchanged. A reading is written only when a field that matters moved
//     (`ArchiveDeviceStatusGate`): the intent, the link, recording, the firmware, the watch
//     battery by 5 points or across 20 %, audio going stale or fresh, a minute total by 10.
//     Readings are coalesced over a short window first, so a flapping link writes once.
//  2. A heartbeat at most every 15 minutes, and only when the app is awake anyway: the minute
//     heartbeat, a snapshot write, a sync pass, backgrounding. No timer and no task of its own.
//
// Unsent readings never pile up: the outbox holds one row for the status, replaced in place.

/// The `deviceStatus` payload. Field names are the contract's; optional fields go as `null`.
public struct ArchiveDeviceStatusPayload: Codable, Equatable, Sendable {
    /// The person's intent: AppSettings' capture intent.
    public enum Capture: String, Codable, Sendable {
        case active, paused, off
    }

    public enum Link: String, Codable, Sendable {
        /// No watch was ever bound to this phone.
        case unbound
        case disconnected
        case connecting
        /// Connected and authorizing, waiting on the watch, or authorized with no stream open.
        case connected
        case streaming
        /// The watch withdrew this phone's binding.
        case revoked
    }

    /// When the reading was taken.
    public var updatedAtMs: Int64
    public var capture: Capture
    public var link: Link
    /// Only while the watch streams and the person wants it to.
    public var recording: Bool
    public var lastAudioAtMs: Int64?
    public var watchBatteryPercent: Int?
    public var watchFirmware: String?
    public var todayRecordedMinutes: Int?
    public var todayQuietMinutes: Int?
    public var todayLostMinutes: Int?
    public var storageUsedBytes: Int64?
    public var phoneBatteryPercent: Int?

    public init(
        updatedAtMs: Int64, capture: Capture, link: Link, recording: Bool,
        lastAudioAtMs: Int64? = nil, watchBatteryPercent: Int? = nil, watchFirmware: String? = nil,
        todayRecordedMinutes: Int? = nil, todayQuietMinutes: Int? = nil,
        todayLostMinutes: Int? = nil, storageUsedBytes: Int64? = nil,
        phoneBatteryPercent: Int? = nil
    ) {
        self.updatedAtMs = updatedAtMs
        self.capture = capture
        self.link = link
        self.recording = recording
        self.lastAudioAtMs = lastAudioAtMs
        self.watchBatteryPercent = watchBatteryPercent
        self.watchFirmware = watchFirmware
        self.todayRecordedMinutes = todayRecordedMinutes
        self.todayQuietMinutes = todayQuietMinutes
        self.todayLostMinutes = todayLostMinutes
        self.storageUsedBytes = storageUsedBytes
        self.phoneBatteryPercent = phoneBatteryPercent
    }

    enum CodingKeys: String, CodingKey {
        case updatedAtMs, capture, link, recording, lastAudioAtMs, watchBatteryPercent
        case watchFirmware, todayRecordedMinutes, todayQuietMinutes, todayLostMinutes
        case storageUsedBytes, phoneBatteryPercent
    }

    /// Every key, `null` for an unknown value: the contract never leaves one out.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(updatedAtMs, forKey: .updatedAtMs)
        try c.encode(capture, forKey: .capture)
        try c.encode(link, forKey: .link)
        try c.encode(recording, forKey: .recording)
        try c.encode(lastAudioAtMs, forKey: .lastAudioAtMs)
        try c.encode(watchBatteryPercent, forKey: .watchBatteryPercent)
        try c.encode(watchFirmware, forKey: .watchFirmware)
        try c.encode(todayRecordedMinutes, forKey: .todayRecordedMinutes)
        try c.encode(todayQuietMinutes, forKey: .todayQuietMinutes)
        try c.encode(todayLostMinutes, forKey: .todayLostMinutes)
        try c.encode(storageUsedBytes, forKey: .storageUsedBytes)
        try c.encode(phoneBatteryPercent, forKey: .phoneBatteryPercent)
    }
}

/// Everything a reading is made from, already read: the derivation is pure over this.
public struct ArchiveDeviceStatusInputs: Equatable, Sendable {
    public var nowMs: Int64
    public var captureIntent: CaptureIntent
    public var receiverState: ReceiverSessionState
    /// The link remembers a watch: one has been bound to this phone.
    public var watchBound: Bool
    /// The stream evidence's last audio.
    public var lastAudioAtMs: Int64?
    /// The link's Battery Service reading (kept after a disconnect).
    public var watchBatteryPercent: Int?
    /// The Device Information Service revision Update Watch reads.
    public var watchFirmware: String?
    /// The widget's coverage snapshot, the one today's totals come from.
    public var coverage: CoverageSnapshot?
    public var phoneBatteryPercent: Int?

    public init(
        nowMs: Int64, captureIntent: CaptureIntent, receiverState: ReceiverSessionState,
        watchBound: Bool, lastAudioAtMs: Int64? = nil, watchBatteryPercent: Int? = nil,
        watchFirmware: String? = nil, coverage: CoverageSnapshot? = nil,
        phoneBatteryPercent: Int? = nil
    ) {
        self.nowMs = nowMs
        self.captureIntent = captureIntent
        self.receiverState = receiverState
        self.watchBound = watchBound
        self.lastAudioAtMs = lastAudioAtMs
        self.watchBatteryPercent = watchBatteryPercent
        self.watchFirmware = watchFirmware
        self.coverage = coverage
        self.phoneBatteryPercent = phoneBatteryPercent
    }
}

extension ArchiveDeviceStatusPayload {
    /// The reading these inputs make. `storageUsedBytes` is filled in only for a reading that is
    /// going to be sent (it lists the segments), so it is not an input here.
    public static func derive(_ inputs: ArchiveDeviceStatusInputs) -> ArchiveDeviceStatusPayload {
        let capture: Capture
        switch inputs.captureIntent {
        case .active: capture = .active
        case .paused: capture = .paused
        case .off: capture = .off
        }
        let link = link(inputs.receiverState, watchBound: inputs.watchBound)
        let today = inputs.coverage.flatMap { todayMinutes($0, nowMs: inputs.nowMs) }
        let firmware = inputs.watchFirmware?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ArchiveDeviceStatusPayload(
            updatedAtMs: inputs.nowMs, capture: capture, link: link,
            recording: link == .streaming && capture == .active,
            lastAudioAtMs: inputs.lastAudioAtMs,
            watchBatteryPercent: inputs.watchBatteryPercent.map { min(max($0, 0), 100) },
            watchFirmware: firmware?.isEmpty == false ? firmware : nil,
            todayRecordedMinutes: today?.recorded, todayQuietMinutes: today?.quiet,
            todayLostMinutes: today?.lost,
            phoneBatteryPercent: inputs.phoneBatteryPercent.map { min(max($0, 0), 100) })
    }

    /// The receiver's state in the contract's six words. A phone that never bound a watch is
    /// `unbound` until one answers it; every state past the connection that is not a stream is
    /// `connected`.
    static func link(_ state: ReceiverSessionState, watchBound: Bool) -> Link {
        switch state {
        case .streaming: return .streaming
        case .revoked: return .revoked
        case .authorizing, .pendingConsent, .pendingEnable, .denied, .authorized: return .connected
        case .connecting: return watchBound ? .connecting : .unbound
        case .disconnected, .connectionFailed: return watchBound ? .disconnected : .unbound
        }
    }

    /// Today's recorded, quiet and lost minutes from the snapshot, or nil when the snapshot is
    /// another day's (just past 5 AM, before the first write of the new day): yesterday's totals
    /// are not today's.
    static func todayMinutes(
        _ snapshot: CoverageSnapshot, nowMs: Int64
    ) -> (recorded: Int, quiet: Int, lost: Int)? {
        guard snapshot.dateKey == LogicalDay.dateKey(forMs: nowMs, timeZoneID: snapshot.timeZoneID)
        else { return nil }
        let quietMs = snapshot.spans.filter { $0.kind == .quiet }
            .reduce(Int64(0)) { $0 + max(0, $1.durationMs) }
        return (
            Int(max(0, snapshot.totalRecordedMs) / 60_000), Int(quietMs / 60_000),
            Int(max(0, snapshot.totalMissingMs) / 60_000)
        )
    }
}

/// Whether a reading is worth writing, against the last one written.
///
/// A value becoming unknown is not a change by itself: after a relaunch the battery and the
/// firmware are unknown until the link reads them again, and a minute total until the first
/// snapshot, and none of that is news. It goes out with the next reading that is.
public enum ArchiveDeviceStatusGate {
    public enum Reason: String, Sendable {
        case first, capture, link, recording, firmware, watchBattery, audioFreshness, todayMinutes
        case heartbeat
    }

    public static let heartbeatMs: Int64 = 15 * 60_000
    /// Audio older than this is stale.
    public static let freshAudioMs: Int64 = 10 * 60_000
    public static let batteryStep = 5
    /// At or above is fine, below is low.
    public static let lowBatteryPercent = 20
    public static let minutesStep = 10

    /// Why `next` should be written, or nil when it says nothing `last` did not.
    public static func reason(
        next: ArchiveDeviceStatusPayload, last: ArchiveDeviceStatusPayload?
    ) -> Reason? {
        guard let last else { return .first }
        if next.capture != last.capture { return .capture }
        if next.link != last.link { return .link }
        if next.recording != last.recording { return .recording }
        if let firmware = next.watchFirmware, firmware != last.watchFirmware { return .firmware }
        if batteryMoved(next.watchBatteryPercent, from: last.watchBatteryPercent) {
            return .watchBattery
        }
        if audioIsFresh(next) != audioIsFresh(last) { return .audioFreshness }
        if moved(next.todayRecordedMinutes, from: last.todayRecordedMinutes)
            || moved(next.todayQuietMinutes, from: last.todayQuietMinutes)
            || moved(next.todayLostMinutes, from: last.todayLostMinutes)
        {
            return .todayMinutes
        }
        if next.updatedAtMs - last.updatedAtMs >= heartbeatMs { return .heartbeat }
        return nil
    }

    /// Audio arrived within `freshAudioMs` of the reading.
    static func audioIsFresh(_ status: ArchiveDeviceStatusPayload) -> Bool {
        guard let at = status.lastAudioAtMs else { return false }
        return status.updatedAtMs - at <= freshAudioMs
    }

    static func batteryMoved(_ next: Int?, from last: Int?) -> Bool {
        guard let next else { return false }
        guard let last else { return true }
        return abs(next - last) >= batteryStep
            || (next < lowBatteryPercent) != (last < lowBatteryPercent)
    }

    static func moved(_ next: Int?, from last: Int?) -> Bool {
        guard let next else { return false }
        guard let last else { return true }
        return abs(next - last) >= minutesStep
    }
}

/// Takes readings when the app is awake anyway and writes the ones the gate lets through.
///
/// `poke()` is every "something may have changed" — the receiver's state, a snapshot write, the
/// minute heartbeat — and only opens a window: the reading is taken once the pokes have been
/// quiet for `debounceMs` (and never later than `maxWaitMs` after the first), so a link that
/// flaps through five states in three seconds is one reading. `flush()` takes it now, for the
/// moments a sync pass is about to go (background entry, a BGProcessing window).
public actor ArchiveDeviceStatusReporter {
    public struct Dependencies: Sendable {
        public var outbox: ArchiveOutbox
        public var settings: @Sendable () -> ArchiveSyncSettings
        /// One reading's inputs. In-memory reads only: it runs on every window.
        public var inputs: @Sendable () async -> ArchiveDeviceStatusInputs
        /// What the recordings take on the phone, asked only for a reading that is written.
        public var storageUsedBytes: @Sendable () async -> Int64?
        public var clock: RuntimeClock
        public var log: RuntimeLog

        public init(
            outbox: ArchiveOutbox, settings: @escaping @Sendable () -> ArchiveSyncSettings,
            inputs: @escaping @Sendable () async -> ArchiveDeviceStatusInputs,
            storageUsedBytes: @escaping @Sendable () async -> Int64? = { nil },
            clock: RuntimeClock, log: RuntimeLog = .silent
        ) {
            self.outbox = outbox
            self.settings = settings
            self.inputs = inputs
            self.storageUsedBytes = storageUsedBytes
            self.clock = clock
            self.log = log
        }
    }

    public static let debounceMs: Int64 = 5_000
    public static let maxWaitMs: Int64 = 30_000

    private let deps: Dependencies
    /// The reading last written, and the device it was written for. Loaded once from the
    /// database, so a relaunch compares against what the server last heard.
    private var last: (deviceId: String, status: ArchiveDeviceStatusPayload)?
    private var loaded = false
    private var window: Task<Void, Never>?
    private var windowSleeping = false
    private var windowStartMs: Int64 = 0
    private var lastPokeMs: Int64 = 0
    private var evaluating = false
    private var evaluateAgain = false
    private var observation: Task<Void, Never>?
    /// Readings written by this process.
    private(set) var writes = 0

    public init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// Pokes on every change of the receiver's state. Idempotent.
    public func start(observing state: StateSubject<ReceiverSessionState>) {
        guard observation == nil else { return }
        let changes = state.stream()
        observation = Task { [weak self] in
            for await _ in changes {
                await self?.poke()
            }
        }
    }

    /// Something may have changed: a reading once things settle.
    public func poke() {
        let now = deps.clock.nowMs
        lastPokeMs = now
        guard window == nil else { return }
        windowStartMs = now
        window = Task { await self.runWindow() }
    }

    /// The server dropped the status it held (a Delete All wiped the archive): the next reading
    /// is written whatever it says, rather than a quarter hour later.
    public func serverForgot() {
        last = nil
        loaded = true
    }

    /// A reading now, ending any open window: a sync pass is about to go and should carry it.
    public func flush() async {
        window?.cancel()
        window = nil
        await evaluate()
    }

    private func runWindow() async {
        while true {
            let due = min(lastPokeMs + Self.debounceMs, windowStartMs + Self.maxWaitMs)
            let wait = due - deps.clock.nowMs
            if wait <= 0 { break }
            windowSleeping = true
            defer { windowSleeping = false }
            do { try await deps.clock.sleep(ms: wait) } catch { return }
            if Task.isCancelled { return }
        }
        window = nil
        await evaluate()
    }

    private func evaluate() async {
        if evaluating {
            evaluateAgain = true
            return
        }
        evaluating = true
        repeat {
            evaluateAgain = false
            await evaluateOnce()
        } while evaluateAgain
        evaluating = false
    }

    private func evaluateOnce() async {
        // Nothing at all unless the text is syncing: a paused or unfinished link sends nothing,
        // so a reading would only be written to be replaced.
        let settings = deps.settings()
        guard settings.isSyncing, let deviceId = settings.deviceId else { return }
        if !loaded {
            loaded = true
            if let saved = try? await deps.outbox.deviceStatus(),
                let status = try? JSONDecoder().decode(
                    ArchiveDeviceStatusPayload.self, from: saved.payload)
            {
                last = (saved.deviceId, status)
            }
        }
        var next = ArchiveDeviceStatusPayload.derive(await deps.inputs())
        let previous = last?.deviceId == deviceId ? last?.status : nil
        guard let reason = ArchiveDeviceStatusGate.reason(next: next, last: previous) else { return }
        next.storageUsedBytes = await deps.storageUsedBytes()
        do {
            let payload = try ArchiveJSON.encoder().encode(next)
            guard
                try await deps.outbox.recordDeviceStatus(
                    deviceId: deviceId, payload: payload, atMs: next.updatedAtMs)
            else { return }
            last = (deviceId, next)
            writes += 1
            if reason != .heartbeat {
                deps.log.write(
                    "archive sync: device status (\(reason.rawValue)) link=\(next.link.rawValue) "
                        + "capture=\(next.capture.rawValue) recording=\(next.recording)")
            }
        } catch {
            deps.log.failure("archive sync device status", error)
        }
    }

    /// For tests: returns once nothing is being read or written (an open window that is still
    /// waiting out its time counts as idle).
    func idle() async {
        while evaluating || (window != nil && !windowSleeping) { await Task.yield() }
    }
}
