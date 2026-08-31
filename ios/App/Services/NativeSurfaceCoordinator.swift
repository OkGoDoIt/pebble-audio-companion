import AppDB
import CoreSpotlight
import Foundation
import Receiver
import SwiftUI
import WidgetKit

// The app half of the native surfaces (plan 6.8). Everything here is a courier: it moves
// requests and taps onto paths that already exist — `AppSettings` for capture intent, the
// router for navigation — and never invents a second one.
//
//   • Capture intents: an intent (Siri, Shortcuts, Control Center) leaves a request in the App
//     Group and posts a Darwin notification. This coordinator picks it up — live, or at the
//     next activation if the app was asleep — and applies it by setting `AppSettings
//     .captureIntent`, which is the same thing the Pause/Resume buttons touch.
//   • Widget/Control freshness: reloaded when the intent lands and when the app backgrounds
//     (the runtime writes `coverage_snapshot.json` on its own triggers).
//   • Spotlight: an incremental donation pass on foreground, once a database is attached.
//   • Notification + Spotlight taps: parsed to a `Route` and handed to `router.navigate`.
@MainActor
@Observable
final class NativeSurfaceCoordinator {
    private let settings: AppSettings
    private var navigate: ((Route) -> Void)?
    @ObservationIgnored private var darwinObserver: CaptureIntentDarwinObserver?
    @ObservationIgnored private var spotlight: SpotlightService?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Installs the cross-process listeners. Safe to call once per app launch.
    func start(navigate: @escaping (Route) -> Void) {
        guard darwinObserver == nil else { return }
        self.navigate = navigate
        LossNotificationRouter.shared.install(handler: navigate)

        darwinObserver = CaptureIntentBridge.observeDarwinNotifications {
            // Darwin callbacks arrive on an arbitrary thread; settings are main-actor state.
            Task { @MainActor [weak self] in self?.applyPendingCaptureRequest() }
        }
        // A request may have been posted while the app was dead.
        applyPendingCaptureRequest()
        publishAppliedCaptureIntent()
    }

    /// Called by the runtime wiring once the shared database is open, so Spotlight donation
    /// reuses that connection instead of opening a second pool on the same file.
    func attachDatabase(_ database: AppDatabase) {
        guard spotlight == nil else { return }
        spotlight = SpotlightService(database: database)
    }

    // MARK: - Lifecycle

    func handleForeground() async {
        applyPendingCaptureRequest()
        publishAppliedCaptureIntent()
        await spotlight?.donateOnForeground()
        reloadSurfaces()
    }

    func handleBackground() {
        // The runtime refreshes the snapshot on backgrounding; ask the widget to re-read it.
        reloadSurfaces()
    }

    // MARK: - Capture intent

    /// Applies whatever an intent asked for, through the app's normal settings path.
    func applyPendingCaptureRequest() {
        guard let request = CaptureIntentBridge.pendingRequest() else { return }

        // Capture is OFF: turning it back on is a consent-bearing choice that belongs to the
        // app's own flow (anti-B3). Drop the request rather than silently enabling a
        // microphone — the intent already told the user to open the app.
        if settings.captureIntent == .off, request.intent == .active {
            CaptureIntentBridge.clearPendingRequest()
            return
        }

        if let applied = CaptureIntent(settingValue: request.intent.rawValue),
            settings.captureIntent != applied
        {
            settings.captureIntent = applied
        }
        CaptureIntentBridge.consume(request.intent)
        reloadSurfaces()
    }

    /// Keeps the App Group's applied value in step with settings, so Control Center and the
    /// widget describe the real state even if the app changed it from the inside.
    func publishAppliedCaptureIntent() {
        guard CaptureIntentBridge.pendingRequest() == nil else { return }
        let current = SharedCaptureIntent(rawValue: settings.captureIntent.settingValue) ?? .off
        guard CaptureIntentBridge.appliedIntent() != current else { return }
        SharedAppGroup.defaults.set(
            current.rawValue, forKey: CaptureIntentBridge.Keys.applied
        )
        reloadSurfaces()
    }

    // MARK: - Taps

    /// Spotlight result → deep link → the one navigation path.
    func handle(userActivity: NSUserActivity) {
        guard let route = SpotlightService.route(for: userActivity) else { return }
        navigate?(route)
    }

    // MARK: - Refresh

    private func reloadSurfaces() {
        WidgetCenter.shared.reloadTimelines(ofKind: SharedAppGroup.coverageWidgetKind)
        ControlCenter.shared.reloadControls(ofKind: SharedAppGroup.captureControlKind)
    }
}

// The runtime's `LossEventEvaluator` needs an app-side notifier; this is the one the app
// installs. Exposed here so the wiring is a single reference rather than a construction site.
extension NativeSurfaceCoordinator {
    static let lossNotifier = UserNotificationLossNotifier()
}
