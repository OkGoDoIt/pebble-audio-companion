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
    /// The charger-gated `BGProcessingTask` window opened — see
    /// `BackgroundTaskPolicy.chargingTaskIdentifier`.
    case chargingCatchUpStarted
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
            // TRAP 2: the relaunch notice is NOT proof that nobody is looking. iOS supplies
            // `UIApplicationLaunchOptionsBluetoothCentralsKey` to every launch that has Core
            // Bluetooth state to restore, so a user tapping the icon while the watch is connected
            // gets one too — 21 of the 22 launches in the September 8 flight recorder carried it,
            // including the foreground one at 18:51:48 that wedged Today and Library. Receive-only
            // is therefore applied ONLY while no scene has come up. Once one has, the latch is
            // cleared instead, because `runtime.start()` reads it seconds later (after
            // `recoverBeforeReceiving()`) and would otherwise demote a visible app with nothing
            // able to promote it again: `setForeground` is a transition guard, so this launch's
            // own `didBecomeActive` is already spent and only a background round trip can repair
            // it. That is exactly the "I left the app and came back and it started working".
            guard !handled.contains(.didBecomeActive) else {
                runtime.environment.receiver.clearLaunchedInBackground()
                return
            }
            // TRAP: receive-only must be applied BEFORE the receiver starts. The relaunch is a
            // background wake; starting the pipeline here would decode audio and load a model for
            // a UI nobody is looking at, on the tightest memory budget iOS ever gives us.
            await runtime.environment.receiver.applyLaunchedInBackground()
            await runtime.setForeground(false)

        case .didFinishLaunching:
            await runtime.start()

        case .didBecomeActive:
            // FIRST, and synchronously: a scene became active, so this process is not headless
            // however the launch was labelled. `runtime.start()` may still be inside
            // `recoverBeforeReceiving()` and about to read this latch; clearing it here is what
            // stops it demoting an app the person is looking at. Ordering-proof in both
            // directions — see `ReceiverService.clearLaunchedInBackground`.
            runtime.environment.receiver.clearLaunchedInBackground()
            // Idempotent by construction: `startCapture` is NOT called here — a foreground entry
            // must never prompt the watch (only an explicit Start/Settings tap arms that).
            await runtime.setForeground(true)
            if runtime.captureIntent != .off {
                await runtime.environment.receiver.start()
            }
            await runtime.reconcilePendingTranscriptions()
            // Foreground entry always rewrites the widget's file. `setForeground(true)` cannot
            // be relied on for this: it is a transition guard, and the very first activation of
            // a launch finds the runtime already marked foreground, so it returns without doing
            // anything. That is precisely the launch where the snapshot most needs to exist.
            await runtime.refreshSnapshot(.manual)

        case .didEnterBackground:
            // The one moment residency has to be right. Playing a recording reconfigures the
            // shared AVAudioSession (`.playback`/`.spokenAudio`, no `.mixWithOthers`) and never
            // puts it back, so an app that played something and was then backgrounded would carry
            // the wrong category into the period where it decides whether we get suspended.
            runtime.environment.receiver.reassertResidencyAfterPlayback()
            await runtime.setForeground(false)

        case .memoryWarning:
            await runtime.releaseLocalModel(reason: "memory warning")

        case .willTerminate:
            await runtime.stop()

        case .backgroundProcessingStarted:
            await runBackgroundProcessing()

        case .chargingCatchUpStarted:
            await runChargingCatchUp()

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

    /// The charger window: drain as much of the backlog as the window allows.
    ///
    /// Unlike `runBackgroundProcessing`, this one is allowed to be expensive — that is its whole
    /// purpose — but it still asks the policy first, because iOS granting the window says the
    /// SYSTEM is idle, not that the user wants their battery spent (Low Power Mode) or that the
    /// phone is in a fit state to do it (thermal).
    private func runChargingCatchUp() async {
        backgroundWork?.cancel()
        let runtime = self.runtime
        let task = Task {
            _ = await runtime.runChargingCatchUp()
        }
        backgroundWork = task
        await task.value
        backgroundWork = nil
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

    /// The heavy one: local transcription and AI, on a charger.
    ///
    /// A SECOND identifier rather than a flag on the first, because the two want opposite
    /// scheduling. `processingTaskIdentifier` does light maintenance — retention, the upload
    /// hand-off, diagnostics — which must keep happening on battery, so it cannot ask for external
    /// power. This one is exactly the state the OS already models for us: `requiresExternalPower`
    /// tells iOS to run it when the device is idle and plugged in, which in practice means
    /// overnight, and it grants minutes rather than the seconds a Bluetooth wake gets.
    ///
    /// It still asks the policy before doing anything: iOS decides WHEN it is convenient for the
    /// system, and `BackgroundWorkPolicy` decides whether it is convenient for the user (Low Power
    /// Mode, a hot phone, their own setting).
    public static let chargingTaskIdentifier = "dev.audiocompanion.app.charging-catchup"

    /// Bigger than the ordinary burst: this window exists to clear a night's backlog, and the
    /// battery it spends is a battery that is being refilled.
    public static let chargingCatchUpMaxSegments = 200
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
