import CompanionRuntime
import Foundation
import UIKit

/// Reads the three device conditions `BackgroundWorkPolicy` judges on: charger, Low Power Mode,
/// and thermal pressure.
///
/// Deliberately a plain snapshot producer rather than a source of truth. The policy is pure and
/// lives in the kit, where its whole matrix is tested on the host; this is the UIKit plumbing that
/// feeds it, and it is the only part that cannot be.
///
/// The values are cached and refreshed from notifications rather than polled. The pipeline asks on
/// every pass, and `UIDevice.batteryState` in particular is not free to interrogate in a loop.
@MainActor
final class DevicePowerMonitor {
    private(set) var snapshot = DevicePowerSnapshot()
    private var tokens: [NSObjectProtocol] = []

    /// Called when any of the three conditions changes, so the pipeline can be woken rather than
    /// waiting up to a minute to discover it has been plugged in.
    var onChange: (@Sendable () -> Void)?

    func start() {
        // Required, or `batteryState` reports `.unknown` forever. It costs nothing beyond an
        // occasional notification.
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()

        let center = NotificationCenter.default
        for name in [
            UIDevice.batteryStateDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification,
        ] {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            )
        }
    }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }

    private func refresh() {
        let state = UIDevice.current.batteryState
        let updated = DevicePowerSnapshot(
            // `.full` counts: the question is whether the work costs the user anything, and a
            // phone sitting at 100% on a cable is the single best moment to do it.
            isPluggedIn: state == .charging || state == .full,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: Self.thermal(ProcessInfo.processInfo.thermalState)
        )
        guard updated != snapshot else { return }
        snapshot = updated
        AppRuntimeLog.shared.record(
            "device power: plugged=\(updated.isPluggedIn) lowPower=\(updated.isLowPowerMode) "
                + "thermal=\(updated.thermalState)"
        )
        onChange?()
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> DevicePowerSnapshot.ThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .fair
        }
    }
}
