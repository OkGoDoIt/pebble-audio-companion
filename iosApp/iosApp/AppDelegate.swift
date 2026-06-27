import AudioCompanionApp
import BackgroundTasks
import UIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let processingTaskIdentifier = "dev.audiocompanion.app.receiver-processing"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register the on-device Apple Foundation Models bridge (iOS 26+ eligible devices). If this
        // is not registered — older iOS, ineligible device, or an SDK without FoundationModels — the
        // Kotlin side reports on-device AI unavailable and falls back to the cloud / snippets.
        OnDeviceAIBridge.registerIfAvailable()

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingTaskIdentifier,
            using: nil
        ) { task in
            self.handleProcessingTask(task)
        }
        // A Core Bluetooth restoration relaunch wakes the app directly into the background:
        // didFinishLaunching runs but applicationDidEnterBackground does not. Pass the launch state
        // so the runtime applies receive-only mode BEFORE it starts the receiver — otherwise it
        // would run the full transcription pipeline during a background relaunch, the worst moment
        // for a jetsam kill.
        IosAudioCompanionBootstrap.shared.applicationDidFinishLaunching(
            launchedInBackground: application.applicationState == .background
        )
        scheduleProcessingTask()
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        IosAudioCompanionBootstrap.shared.applicationWillEnterForeground()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        IosAudioCompanionBootstrap.shared.applicationDidEnterBackground()
        scheduleProcessingTask()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        IosAudioCompanionBootstrap.shared.applicationDidReceiveMemoryWarning()
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // A background transcription upload finished while suspended. Let the runtime reconnect to
        // the session and process the outcome; call the system handler when events have drained.
        IosAudioCompanionBootstrap.shared.handleBackgroundUrlSessionEvents(completion: completionHandler)
    }

    private func handleProcessingTask(_ task: BGTask) {
        // Always chain the next opportunity first.
        scheduleProcessingTask()

        // BGProcessing is optional maintenance, not a relaunch hook for receiving. On expiration we
        // must NOT stop the receiver or change the user's background-recording intent — Core
        // Bluetooth restoration owns the receive path. So just cancel the optional work and report
        // it unfinished; the receiver keeps running untouched.
        var completed = false
        let complete: (Bool) -> Void = { success in
            DispatchQueue.main.async {
                guard !completed else { return }
                completed = true
                task.setTaskCompleted(success: success)
            }
        }
        task.expirationHandler = {
            IosAudioCompanionBootstrap.shared.cancelBackgroundMaintenance()
            complete(false)
        }
        IosAudioCompanionBootstrap.shared.runBackgroundMaintenance {
            complete(true)
        }
    }

    private func scheduleProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Registers the Swift implementation of the Kotlin `OnDeviceLanguageModelBridge` so the shared
/// runtime can use Apple's on-device Foundation Models for segment titles/summaries.
///
/// NOTE: The bridge below uses the FoundationModels framework (iOS 26 SDK / Xcode 26). It compiles
/// out cleanly on older SDKs via `#if canImport(FoundationModels)` and is gated at runtime by
/// `#available`. It has not been compiled in this workspace (no Xcode); verify on an iOS 26 build.
enum OnDeviceAIBridge {
    static func registerIfAvailable() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            IosOnDeviceModelRegistry.shared.bridge = FoundationModelsBridge()
        }
        #endif
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
final class FoundationModelsBridge: NSObject, OnDeviceLanguageModelBridge {
    func availability(callback: @escaping (KotlinInt) -> Void) {
        let code: Int32
        switch SystemLanguageModel.default.availability {
        case .available:
            code = 0 // AVAILABILITY_AVAILABLE
        case .unavailable(.modelNotReady):
            code = 2 // AVAILABILITY_DOWNLOADING (model still downloading / initializing)
        case .unavailable:
            code = 3 // AVAILABILITY_UNAVAILABLE (deviceNotEligible / appleIntelligenceNotEnabled / other)
        @unknown default:
            code = 3
        }
        callback(KotlinInt(int: code))
    }

    func generate(
        instructions: String,
        prompt: String,
        maxOutputTokens: Int32,
        onResult: @escaping (String?, String?) -> Void
    ) {
        Task {
            do {
                let session = LanguageModelSession(instructions: instructions)
                // The annotation prompt already asks for a short two-line answer, so we rely on that
                // rather than a token cap (kept in the signature for parity with Android).
                let response = try await session.respond(to: prompt)
                onResult(response.content, nil)
            } catch {
                onResult(nil, error.localizedDescription)
            }
        }
    }
}
#endif
