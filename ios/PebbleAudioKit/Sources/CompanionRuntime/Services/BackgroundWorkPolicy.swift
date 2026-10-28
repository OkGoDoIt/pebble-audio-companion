import Foundation

/// When the app may do EXPENSIVE catch-up work while it is not on screen.
///
/// "Expensive" means local transcription and the AI passes: work this process does itself, on the
/// CPU and the neural engine. It deliberately does not cover cloud uploads, which are handed to
/// `nsurlsessiond` and cost us almost nothing, and it never covers the receive path — recording is
/// the product and is not negotiable against a transcript being ready sooner.
public enum BackgroundCatchUp: String, Sendable, Equatable, CaseIterable, Codable {
    /// Only when the phone is plugged in and comfortable. The default, and right for almost
    /// everyone: a charging phone is one whose battery the user is not spending.
    case whileCharging
    /// Whenever there is a backlog, on battery too. Trades battery for transcripts being ready.
    case always
    /// Never in the background; catch up only while the app is open.
    case never
}

extension BackgroundCatchUp {
    /// Plain language, describing the outcome rather than the mechanism.
    public var displayName: String {
        switch self {
        case .whileCharging: return "While Charging"
        case .always: return "Always"
        case .never: return "Only When Open"
        }
    }
}

/// The device conditions the policy reads. A plain value so the decision is pure and testable —
/// the UIKit/ProcessInfo plumbing that produces it lives in the app layer.
public struct DevicePowerSnapshot: Sendable, Equatable {
    /// Plugged in (charging or already full). Not "battery above some level": what matters is
    /// whether the work costs the user anything.
    public var isPluggedIn: Bool
    /// The user has asked the system to conserve.
    public var isLowPowerMode: Bool
    /// `ProcessInfo.ThermalState`, mirrored so the kit does not depend on Foundation's enum in
    /// its test matrix.
    public var thermalState: ThermalState

    public enum ThermalState: Int, Sendable, Equatable, Comparable, CaseIterable {
        case nominal, fair, serious, critical
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public init(
        isPluggedIn: Bool = false,
        isLowPowerMode: Bool = false,
        thermalState: ThermalState = .nominal
    ) {
        self.isPluggedIn = isPluggedIn
        self.isLowPowerMode = isLowPowerMode
        self.thermalState = thermalState
    }
}

/// Whether to spend the phone's battery on catch-up right now, and — when not — why not.
///
/// The reason is not decoration. "Transcripts are behind" has several very different causes, and a
/// user looking at a stalled queue on a hot phone in Low Power Mode deserves to be told which one
/// they are looking at rather than left to guess at a bug.
public enum BackgroundWorkDecision: Sendable, Equatable {
    case run
    case hold(reason: HoldReason)

    public enum HoldReason: String, Sendable, Equatable {
        case userTurnedItOff
        case lowPowerMode
        case tooHot
        case onBattery
    }

    public var isRun: Bool { self == .run }
}

public enum BackgroundWorkPolicy {
    /// The whole policy, in the order the reasons override each other.
    ///
    /// Low Power Mode and thermal pressure beat the user's catch-up preference ON PURPOSE, and
    /// they beat `.always` too:
    ///
    /// - Low Power Mode is the user asking the whole system to stop spending battery. Apple's
    ///   guidance is explicit that discretionary work should stand down, and an app that keeps
    ///   grinding through it is the reason people uninstall background apps.
    /// - Thermal is a safety and honesty question rather than a preference. Once the device is
    ///   `.serious` the system is already throttling the CPU, so the work gets slower AND hotter —
    ///   the worst possible trade. This holds even while charging, because charging is itself a
    ///   heat source and "plugged in" is exactly when a phone cooks.
    ///
    /// `.always` therefore means "on battery as well as on charger", not "regardless of anything".
    public static func decide(
        _ setting: BackgroundCatchUp,
        _ device: DevicePowerSnapshot
    ) -> BackgroundWorkDecision {
        if setting == .never { return .hold(reason: .userTurnedItOff) }
        if device.isLowPowerMode { return .hold(reason: .lowPowerMode) }
        if device.thermalState >= .serious { return .hold(reason: .tooHot) }
        switch setting {
        case .always: return .run
        case .whileCharging: return device.isPluggedIn ? .run : .hold(reason: .onBattery)
        case .never: return .hold(reason: .userTurnedItOff)
        }
    }

    /// Voice recognition is charger work, on screen or not: two models over every ten seconds of
    /// a day's audio. It waits on battery even with the app open, and even under "Always", which
    /// was chosen for transcripts. "Only When Open" keeps it out of the background but not off a
    /// charging phone that is on screen. Low Power Mode and heat hold it like everything else.
    public static func decideVoiceRecognition(
        _ setting: BackgroundCatchUp,
        _ device: DevicePowerSnapshot,
        foreground: Bool
    ) -> BackgroundWorkDecision {
        if !foreground, setting == .never { return .hold(reason: .userTurnedItOff) }
        if device.isLowPowerMode { return .hold(reason: .lowPowerMode) }
        if device.thermalState >= .serious { return .hold(reason: .tooHot) }
        return device.isPluggedIn ? .run : .hold(reason: .onBattery)
    }
}

/// Spaces backgrounded voice slices so recognition never holds the CPU for long: a slice that
/// took `t` waits `max(3 s, 10 t)` before the next, which keeps it near a tenth of one core.
/// Charger-time CPU has starved the Bluetooth keepalive before (16–25 CPU-s/min, 2026-09-10).
/// On G17 a two-window slice measured 0.2–0.5 s (2026-10-27), so a 30 s floor checked 20 s of
/// audio per 30 s and a week's queue would have taken days. A pass that found nothing waits
/// `idleGapMs`. Every tenth slice yields a log line.
public final class VoiceBackgroundPace: @unchecked Sendable {
    public static let minimumGapMs: Int64 = 3_000
    public static let idleGapMs: Int64 = 30_000
    public static let gapPerBusyMs: Int64 = 10
    private let lock = NSLock()
    private var nextAtMs: Int64 = 0
    private var slices = 0
    private var busyMs: Int64 = 0
    private var windows = 0
    private var renamed = 0

    public init() {}

    public func isDue(nowMs: Int64) -> Bool { lock.withLock { nowMs >= nextAtMs } }

    /// How long until the next slice may run, for the pass's own sleep.
    public func msUntilDue(nowMs: Int64) -> Int64 { lock.withLock { max(0, nextAtMs - nowMs) } }

    /// Records a backgrounded voice pass: `windows` analysed, and recordings `renamed` from
    /// their prints. Returns a summary every tenth slice that did work.
    public func record(windows: Int, renamed: Int = 0, busyMs: Int64, nowMs: Int64) -> String? {
        lock.withLock {
            guard windows > 0 || renamed > 0 else { nextAtMs = nowMs + Self.idleGapMs; return nil }
            nextAtMs = nowMs + max(Self.minimumGapMs, busyMs * Self.gapPerBusyMs)
            slices += 1
            self.busyMs += busyMs
            self.windows += windows
            self.renamed += renamed
            guard slices >= 10 else { return nil }
            defer { slices = 0; self.busyMs = 0; self.windows = 0; self.renamed = 0 }
            return "voice recognition: \(slices) background slices, \(self.windows) windows, "
                + "\(self.busyMs) ms busy" + (self.renamed > 0 ? ", \(self.renamed) recordings re-matched" : "")
        }
    }
}
