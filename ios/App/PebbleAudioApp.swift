import CoreSpotlight
import SwiftUI

/// Exists for two reasons the SwiftUI lifecycle cannot cover: the notification delegate has to
/// be in place before launch finishes (or a loss notification tapped while the app was dead is
/// delivered to nobody), and `handleEventsForBackgroundURLSession` has no scene equivalent.
final class CompanionAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated {
            LossNotificationRouter.shared.prepare()
            // Core Bluetooth restored us in the background: receive-only, applied before the
            // receiver starts.
            if options?[.bluetoothCentrals] != nil {
                AppComposition.shared?.handleRestorationRelaunch()
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            guard let composition = AppComposition.shared else {
                // No graph (a composition failure): nothing can drain the session, and iOS kills
                // an app that never calls this back.
                completionHandler()
                return
            }
            // The handler is NOT called here — the transport calls it once the session reports
            // its events drained. Calling it now would let the system re-suspend us before the
            // finished uploads are delivered, and the transcripts would be lost until relaunch.
            composition.handleBackgroundUrlSessionEvents(
                identifier: identifier, completionHandler: completionHandler
            )
        }
    }
}

@main
struct PebbleAudioApp: App {
    @UIApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = AppRouter()
    @State private var settings = AppSettings()
    /// Widget/Control Center/Siri/Spotlight/notification plumbing (plan 6.8).
    @State private var nativeSurfaces: NativeSurfaceCoordinator

    init() {
        let settings = AppSettings()
        let surfaces = NativeSurfaceCoordinator(settings: settings)
        _settings = State(initialValue: settings)
        _nativeSurfaces = State(initialValue: surfaces)
        // The composition root: opens the database, builds the runtime, and swaps the screens'
        // data sources from the mock world to the live one. Built here (not in `.task`) so the
        // lifecycle observers exist before the first `didBecomeActive` notification fires.
        MainActor.assumeIsolated {
            AppComposition.bootstrap(settings: settings, nativeSurfaces: surfaces)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Onboarding gate: the flow covers the app until the user finishes
                // connect → confirm-on-watch → transcripts (Q14). Dismissal happens only
                // by `onboardingComplete` flipping true inside the flow.
                .fullScreenCover(
                    isPresented: Binding(
                        get: { !settings.onboardingComplete },
                        set: { _ in }
                    )
                ) {
                    OnboardingFlow()
                        .environment(settings)
                        .tint(Tokens.tint)
                }
                .environment(router)
                .environment(settings)
                .tint(Tokens.tint)
                .onOpenURL { url in
                    if let route = Route.parse(url) { router.navigate(to: route) }
                }
                // Widget taps, the Q9 loss notification, Siri, and Spotlight results all end
                // up here — one navigation path, no per-surface special cases.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    nativeSurfaces.handle(userActivity: activity)
                }
                .task {
                    nativeSurfaces.start { route in router.navigate(to: route) }
                    await nativeSurfaces.handleForeground()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: Task { await nativeSurfaces.handleForeground() }
                    case .background: nativeSurfaces.handleBackground()
                    default: break
                    }
                }
                #if DEBUG
                // Simulator-automation staging: "-route settings/watch" behaves exactly
                // like an incoming companion:// URL (same parse + navigate path). Router
                // logic itself is untouched. DEBUG builds only.
                .onAppear {
                    let args = ProcessInfo.processInfo.arguments
                    if let index = args.firstIndex(of: "-route"), index + 1 < args.count,
                        let url = URL(string: "companion://\(args[index + 1])"),
                        let route = Route.parse(url) {
                        router.navigate(to: route)
                    }
                }
                #endif
        }
    }
}
