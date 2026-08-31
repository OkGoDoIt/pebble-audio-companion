import Foundation

#if canImport(UIKit)
    import UIKit
#endif

// iOS lifecycle (plan Part 4.6). Ported design AND its validation debt — every trap below cost a
// session to find, so each is named where it is handled.

/// The lifecycle events the runtime reacts to, named so they can be driven from tests without
/// UIKit.
public enum AppLifecycleEvent: String, Sendable, Equatable, CaseIterable {
    /// The process was relaunched by Core Bluetooth state restoration, not by the user.
    case restorationRelaunch
    case didFinishLaunching
    case didBecomeActive
    case didEnterBackground
    case memoryWarning
    case willTerminate
    /// A `BGProcessingTask` window opened.
    case backgroundProcessingStarted
    /// The system is about to suspend us; only optional work is cancelled.
    case backgroundProcessingExpired
    /// `handleEventsForBackgroundURLSession`.
    case backgroundUrlSessionEvents
}

/// Applies lifecycle events to the runtime. Deliberately platform-free so the whole matrix is
/// testable on macOS; `UIApplicationLifecycleObserver` below is the thin UIKit adapter.
public actor AppLifecycleCoordinator {
    private let runtime: CompanionRuntime
    private let log: RuntimeLog

    /// The in-flight BGProcessing burst, so expiration can cancel exactly the optional work.
    private var backgroundWork: Task<Void, Never>?
    private var handled: [AppLifecycleEvent] = []

    public init(runtime: CompanionRuntime, log: RuntimeLog = .silent) {
        self.runtime = runtime
        self.log = log
    }

    /// Events handled so far (tests assert the transitions).
    public var handledEvents: [AppLifecycleEvent] { handled }

    public func handle(_ event: AppLifecycleEvent) async {
        handled.append(event)
        switch event {
        case .restorationRelaunch:
            // TRAP: receive-only must be applied BEFORE the receiver starts. The relaunch is a
            // background wake; starting the pipeline here would decode audio and load a model for
            // a UI nobody is looking at, on the tightest memory budget iOS ever gives us.
            await runtime.environment.receiver.applyLaunchedInBackground()
            await runtime.setForeground(false)

        case .didFinishLaunching:
            await runtime.start()

        case .didBecomeActive:
            // Idempotent by construction: `startCapture` is NOT called here — a foreground entry
            // must never prompt the watch (only an explicit Start/Settings tap arms that).
            await runtime.setForeground(true)
            if runtime.captureIntent != .off {
                await runtime.environment.receiver.start()
            }
            await runtime.reconcilePendingTranscriptions()

        case .didEnterBackground:
            await runtime.setForeground(false)

        case .memoryWarning:
            await runtime.releaseLocalModel(reason: "memory warning")

        case .willTerminate:
            await runtime.stop()

        case .backgroundProcessingStarted:
            await runBackgroundProcessing()

        case .backgroundProcessingExpired:
            // Expiration cancels OPTIONAL work only. It never touches the receiver's run state
            // and never changes the user's recording intent: a processing-task timeout must not
            // be able to turn recording off.
            backgroundWork?.cancel()
            backgroundWork = nil

        case .backgroundUrlSessionEvents:
            await runtime.handleBackgroundUploadEvents()
        }
    }

    /// The BGProcessing body: MAINTENANCE ONLY (retention, upload hand-off, diagnostics) plus the
    /// sanctioned bounded catch-up burst. Never STT/AI/export outside the burst, and never a
    /// change to the receiver's run state.
    private func runBackgroundProcessing() async {
        backgroundWork?.cancel()
        let runtime = self.runtime
        let task = Task {
            await runtime.runBackgroundMaintenance()
            _ = await runtime.runCatchUpBurst()
        }
        backgroundWork = task
        await task.value
        backgroundWork = nil
    }
}

/// The BGTaskScheduler identifier and policy (plan Part 4.6).
public enum BackgroundTaskPolicy {
    /// Registered in `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`.
    public static let processingTaskIdentifier = "dev.audiocompanion.app.receiver-processing"
    /// Earliest begin date: +15 minutes.
    public static let earliestBeginInterval: TimeInterval = 15 * 60
    /// No network and no power requirement: the work is local maintenance, and demanding either
    /// makes iOS schedule the task approximately never.
    public static let requiresNetworkConnectivity = false
    public static let requiresExternalPower = false
    /// Model residency while looping in the background.
    public static let backgroundLoopSleepMs = PipelinePacing.backgroundMs
    /// Foreground idle time before the resident model is released.
    public static let foregroundModelIdleMs = PipelinePacing.modelIdleTimeoutMs
}

#if canImport(UIKit)
    /// UIKit adapter.
    ///
    /// TRAP (the scene manifest): with a `UIApplicationSceneManifest` in `Info.plist`, the
    /// `UIApplicationDelegate` lifecycle callbacks (`applicationDidEnterBackground` and friends)
    /// **never fire** — the scene delegate owns them. Registering NOTIFICATION observers works
    /// regardless of whether the app is scene-based, which is why this is the only supported way
    /// to drive the coordinator.
    @MainActor
    public final class UIApplicationLifecycleObserver {
        private let coordinator: AppLifecycleCoordinator
        private var tokens: [NSObjectProtocol] = []

        public init(coordinator: AppLifecycleCoordinator) {
            self.coordinator = coordinator
        }

        /// Registers the observers. Call once, from the app's init — NOT from an app-delegate
        /// callback that may never run.
        public func start(center: NotificationCenter = .default) {
            let mapping: [(Notification.Name, AppLifecycleEvent)] = [
                (UIApplication.didBecomeActiveNotification, .didBecomeActive),
                (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
                (UIApplication.didReceiveMemoryWarningNotification, .memoryWarning),
                (UIApplication.willTerminateNotification, .willTerminate),
            ]
            for (name, event) in mapping {
                let token = center.addObserver(forName: name, object: nil, queue: nil) {
                    [coordinator] _ in
                    Task { await coordinator.handle(event) }
                }
                tokens.append(token)
            }
        }

        public func stop(center: NotificationCenter = .default) {
            tokens.forEach(center.removeObserver)
            tokens.removeAll()
        }

        deinit {
            let observers = tokens
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
        }
    }
#endif
