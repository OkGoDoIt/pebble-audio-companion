import CompanionRuntime
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
            // Did iOS start us without a user? Receive-only is applied before the receiver starts.
            //
            // Two signals, neither trustworthy alone, and the correction made where the truth is:
            //
            //   1. `willRestoreState` — the link reports it (`AppComposition.noteStateRestored`)
            //      the instant Core Bluetooth restores the central, usually before this method
            //      even runs. It replaced the `bluetoothCentrals` launch option, deprecated in
            //      iOS 26 with exactly this guidance: reinstantiate the central from its restore
            //      identifier at launch and let `willRestoreState` speak for itself. Like the
            //      option, it over-fires: iOS restores state on ANY launch that has some,
            //      including a person tapping the icon (21 of the 22 process starts in the
            //      2026-09-08 flight recorder, including a foreground launch that left Today and
            //      Library with no live conversation for a whole healthy recording).
            //   2. the application state, which covers every other headless start — a
            //      BGProcessing window, a background URLSession completion, a widget or Siri
            //      invocation — none of which restore any Bluetooth state. MEASURED to read
            //      `.active` on plainly headless wakes (all 22 starts on 2026-09-08), so it
            //      rarely fires, but when it does it is right.
            //
            // Getting this wrong is not cosmetic: the flag is what keeps a background wake from
            // loading a transcription model and running the whole foreground pipeline on the
            // tightest memory budget iOS ever gives us. So this stays deliberately conservative —
            // assume headless, because being wrong that way is cheap — and the correction is made
            // where the truth actually is: the scene phase, through `AppComposition.noteScenePhase`.
            // A guess about why the process exists must never outlive a window the person can see.
            if application.applicationState == .background {
                AppComposition.shared?.handleRestorationRelaunch(
                    reason: "started in the background")
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping @Sendable () -> Void
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
    // No inline default on `settings` or `nativeSurfaces`: `init` supplies both. Since Xcode 27
    // `@State` is a macro, and a property that has an inline initial value keeps it — the value
    // assigned in `init` is silently discarded (TN3211). With `= AppSettings()` here, the views
    // read one `AppSettings` while the runtime was bootstrapped with another: a toggle in the
    // UI wrote defaults but never reached the runtime's settings box or woke the pipeline.
    @State private var settings: AppSettings
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
            _ = AppComposition.bootstrap(settings: settings, nativeSurfaces: surfaces)
        }
    }

    /// The servers whose pages open in the app: the product's own, and the one this phone links.
    private var archiveServers: [String] {
        [URL(string: ArchiveSyncProtocol.defaultOrigin)?.host, settings.archiveSync.origin.flatMap { URL(string: $0)?.host }]
            .compactMap { $0 }
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
                    // The QR code on the Pebble Audio server's Link a phone page, or the page
                    // itself: the Link step, filled in. Nothing is sent until Link This Phone.
                    if url.scheme == ArchiveLinkInvitation.scheme,
                        let invitation = ArchiveLinkInvitation.parse(url)
                    {
                        router.open(.link(invitation))
                        return
                    }
                    // The server's own pages (universal links): a moment, a day, a brief.
                    if let link = UniversalLink.parse(url, servers: archiveServers) {
                        router.open(link)
                        return
                    }
                    if let route = Route.parse(url) { router.navigate(to: route) }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL,
                        let link = UniversalLink.parse(url, servers: archiveServers)
                    else { return }
                    router.open(link)
                }
                // Widget taps, the Q9 loss notification, Siri, and Spotlight results all end
                // up here — one navigation path, no per-surface special cases.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    nativeSurfaces.handle(userActivity: activity)
                }
                .task {
                    // A window exists — but only an ACTIVE scene means a person is looking at it,
                    // and that is what decides foreground (see `SceneForegroundRule`). A launch on
                    // a locked phone builds this view with the scene in `.background`; promoting
                    // on the window alone left the runtime in its foreground shape for the life
                    // of the process on 2026-09-16. This must come before the surfaces work
                    // because it is also what un-wedges a launch iOS mis-labelled as headless.
                    // The surfaces work itself is NOT gated: a Control Center request in the
                    // mailbox should be applied by whichever launch gets here first.
                    AppComposition.noteScenePhase(scenePhase)
                    nativeSurfaces.start { route in router.navigate(to: route) }
                    await nativeSurfaces.handleForeground()
                }
                .onChange(of: scenePhase) { _, phase in
                    AppComposition.noteScenePhase(phase)
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
                // `-siri-snippet-preview`: the Ask My Archive card over everything, with made-up
                // content, for light/dark screenshots (use with `-onboarding.skip`).
                .overlay {
                    if AskArchiveSnippetPreview.isRequested { AskArchiveSnippetPreview() }
                }
                // `-recap-notification-preview`: one made-up recap notification, for screenshots.
                .task {
                    if RecapNotificationPreview.isRequested { await RecapNotificationPreview.run() }
                }
                #endif
        }
    }
}
