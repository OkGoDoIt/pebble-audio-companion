import CompanionRuntime
import Foundation
import Intelligence
import Transcription
import UIKit

// Wires `CloudAccountHold` to what the person sees. See `CloudAccountAlerts`.

extension AppComposition {
    func installCloudAccountAlerts() {
        let alerts = CloudAccountAlerts.shared
        alerts.install(
            resolve: { [weak self] in await self?.cloudAccountIssues() ?? [] },
            recheckAccount: { [weak self] in await self?.recheckCloudAccount($0) },
            notifier: CloudAccountNotifier())

        let runtime = self.runtime
        cloudHold.onChanged {
            runtime.notifyConfigChanged(reviveFailures: false)
            Task { @MainActor in await CloudAccountAlerts.shared.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                await CloudAccountAlerts.shared.refresh()
                await CloudAccountAlerts.shared.returnedToApp()
            }
        }
        // A hold outlives the process, so an outage already in force is news at launch too.
        Task { await alerts.refresh() }
    }

    private func cloudAccountIssues() async -> [CloudAccountIssue] {
        // The ordinary case, and the whole cost of it: two dictionary reads.
        let hold = cloudHold
        guard CloudProvider.allCases.contains(where: { hold.active(for: $0) != nil }) else {
            return []
        }
        let localModel = SettingsDataSources.current.localModel
        await (localModel as? LiveLocalModelManager)?.refreshNow()
        let onDevice = OnDeviceTranscriptionReadiness.resolve(
            selected: localModel.state(for: settings.localTranscriptionModelId),
            appleSpeech: localModel.state(for: LocalModelCatalog.appleSpeechId))
        return CloudAccountIssue.resolve(
            settings: settings.runtimeSettings.value,
            hold: { hold.active(for: $0) },
            hasKey: { settings.hasApiKey(for: $0) },
            onDeviceTranscriptionReady: onDevice.isReady,
            onDeviceAiReady: OnDeviceAiReadiness.current.isReady,
            applePrivateCloudReady: ApplePrivateCloudReadiness.current.isReady)
    }

    /// Transcription's account with a second of silence, the way its own checks do; an account
    /// that only does AI work with the AI side's smallest request.
    private func recheckCloudAccount(_ provider: CloudProvider) async -> CloudAccountProbeOutcome? {
        let box = settings.runtimeSettings
        if box.cloudTranscriptionEnabled, box.cloudTranscriptionProvider == provider {
            return await runtime.recheckHeldCloudAccount(provider)
        }
        return provider == .openAi ? await openAiChat.recheckHeldAccount() : nil
    }
}
