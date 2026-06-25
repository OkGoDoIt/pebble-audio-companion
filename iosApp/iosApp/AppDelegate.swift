import AudioCompanionApp
import BackgroundTasks
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let processingTaskIdentifier = "dev.audiocompanion.app.receiver-processing"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingTaskIdentifier,
            using: nil
        ) { task in
            self.handleProcessingTask(task)
        }
        IosAudioCompanionBootstrap.shared.applicationDidFinishLaunching()
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
