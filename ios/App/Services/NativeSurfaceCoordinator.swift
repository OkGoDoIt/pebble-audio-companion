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
//   • Capture intents: an intent (Siri, Shortcuts, Control Center, a widget button) leaves a
//     request in the App Group and posts a Darwin notification. This coordinator picks it up —
//     live, or at the next activation if the app was asleep — and applies it through the
//     runtime's own start/pause API, which is the SAME path Today's buttons and onboarding
//     take.
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
    /// How an applied intent reaches the receiver. Injected so tests can observe the call; the
    /// default resolves the live composition.
    @ObservationIgnored var applyToRuntime: (CaptureIntent) async -> Void =
        NativeSurfaceCoordinator.liveApply

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// The production transport. `startCapture()` is deliberate: setting the intent alone only
    /// tells the session what to WANT — the session observes the link rather than dialling it,
    /// so without the reconnect inside `startCapture` the watch is never contacted and the
    /// toggle appears to do nothing. This is the same defect fixed for Today's Start button in
    /// `aa2a934`; the intent path now shares that fix instead of re-implementing it.
    private static func liveApply(_ intent: CaptureIntent) async {
        guard let composition = AppComposition.shared else { return }
        switch intent {
        case .active:
            await composition.runtime.startCapture()
        case .paused, .off:
            await composition.runtime.setCaptureIntent(intent, source: .intent)
        }
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

    /// Applies whatever an intent asked for, through the app's normal capture path.
    ///
    /// Every request is honoured, including `off → active`. That used to be dropped on an
    /// anti-B3 rationale, but B3 is about SIDE EFFECTS — Connect quietly enabling recording —
    /// not about a switch the user deliberately pressed on a system surface. The consent that
    /// matters is unchanged and enforced where it always was: `startCapture()` arms exactly one
    /// on-watch enable prompt, and the watch fails closed until the person answers it. A toggle
    /// that silently does nothing was the worse failure.
    func applyPendingCaptureRequest() {
        guard let request = CaptureIntentBridge.pendingRequest(),
            let applied = CaptureIntent(settingValue: request.intent.rawValue)
        else { return }

        // The preference first, so the app's own UI flips the moment the request lands rather
        // than waiting on a watch that may not be in range — the same order Today's Start uses.
        if settings.captureIntent != applied {
            settings.captureIntent = applied
        }
        // Answer the mailbox now: the app has committed to applying this, and the intent that
        // posted it is blocked waiting to learn whether anything is alive to act on it.
        CaptureIntentBridge.consume(request.intent)
        reloadSurfaces()

        let apply = applyToRuntime
        Task { @MainActor [weak self] in
            await apply(applied)
            self?.reloadSurfaces()
        }
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

    /// All four widget kinds read the same snapshot, so they refresh together — naming them
    /// individually here is how one of them silently stops updating after a rename.
    private func reloadSurfaces() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadControls(ofKind: SharedAppGroup.captureControlKind)
    }
}

// The runtime's `LossEventEvaluator` needs an app-side notifier; this is the one the app
// installs. Exposed here so the wiring is a single reference rather than a construction site.
extension NativeSurfaceCoordinator {
    static let lossNotifier = UserNotificationLossNotifier()
}
