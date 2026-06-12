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
        scheduleProcessingTask()
        task.expirationHandler = {
            IosAudioCompanionBootstrap.shared.stopReceiver()
        }
        IosAudioCompanionBootstrap.shared.applicationDidEnterBackground()
        IosAudioCompanionBootstrap.shared.refreshDiagnostics()
        task.setTaskCompleted(success: true)
    }

    private func scheduleProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
