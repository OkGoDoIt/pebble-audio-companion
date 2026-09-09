import Intelligence
import Receiver
import Testing
import Transcription

@testable import CompanionRuntime

// Stream DU. `RuntimeSettingsBox` is the one surface the runtime reads user settings through, and
// it forwards each one BY HAND — so a property that is only declared on the snapshot, and left to
// the protocol extension's default on the box, is silently unreadable.
//
// That had already happened to `backgroundCatchUp`: `AppSettings` mirrored the user's choice into
// `RuntimeSettingsSnapshot` on every change, `CompanionRuntime.runChargingCatchUp` read it back
// through the box, and got `.whileCharging` every time — so "Always" and "Only When Open" did
// nothing at all. These tests exist so the next added setting cannot repeat it.

@Suite struct DuRuntimeSettingsBoxTests {

    @Test func theBoxReportsTheCatchUpChoiceItWasGiven() {
        let box = RuntimeSettingsBox(RuntimeSettingsSnapshot(backgroundCatchUp: .always))
        #expect(box.backgroundCatchUp == .always)

        box.apply { $0.backgroundCatchUp = .never }
        #expect(box.backgroundCatchUp == .never)

        box.set(RuntimeSettingsSnapshot(backgroundCatchUp: .whileCharging))
        #expect(box.backgroundCatchUp == .whileCharging)
    }

    @Test func theBoxReportsTheUploadNetworkChoiceItWasGiven() {
        let box = RuntimeSettingsBox(RuntimeSettingsSnapshot(cloudUploadNetwork: .anyNetwork))
        #expect(box.cloudUploadNetwork == .anyNetwork)

        box.apply { $0.cloudUploadNetwork = .wifiOnly }
        #expect(box.cloudUploadNetwork == .wifiOnly)
    }

    @Test func uploadsAreWifiOnlyUntilSomeoneSaysOtherwise() {
        // The default has to hold in all three places a value can come from, because they are
        // three separate declarations of it.
        #expect(CloudUploadNetworkPolicy.default == .wifiOnly)
        #expect(RuntimeSettingsSnapshot().cloudUploadNetwork == .wifiOnly)
        #expect(RuntimeSettingsBox().cloudUploadNetwork == .wifiOnly)
    }

    /// A conformer that declares neither property still compiles and reads sensibly — the reason
    /// the protocol extension defaults exist, and the reason the box's forwards are easy to
    /// forget.
    private struct MinimalSettings: RuntimeSettings {
        var captureIntent: CaptureIntent = .off
        var transcriptionMode: TranscriptionMode = .remoteFirst
        var localTranscriptionModelId: String = ""
        var cloudTranscriptionProvider: CloudProvider = .soniox
        var aiMode: AiProcessingMode = .remoteFirst
        var aiModel: String = ""
        var automaticWavExportEnabled: Bool = false
        var onboardingComplete: Bool = false
        var retentionDays: Int = 30
        var transcriptsConfigured: Bool = false
    }

    @Test func aConformerThatDeclaresNeitherStillGetsTheSafeAnswer() {
        let settings = MinimalSettings()
        #expect(settings.backgroundCatchUp == .whileCharging)
        #expect(settings.cloudUploadNetwork == .wifiOnly)
    }
}
