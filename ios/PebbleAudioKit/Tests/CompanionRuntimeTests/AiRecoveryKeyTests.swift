import Foundation
import Intelligence
import Testing

@testable import CompanionRuntime

// Only a change that could rescue a failed AI job resets the AI retry budgets. The charger and
// the thermal state reach the same settings callback dozens of times a day; resetting on those
// would retry every failed title dozens of times a day — the shape the transcription side's
// recovery key was built to stop on 2026-09-29.

@Suite("AI recovery key")
struct AiRecoveryKeyTests {
    @Test func onlyTheAiModeProviderAndModelMoveTheKey() {
        let base = RuntimeSettingsSnapshot(
            captureIntent: .active, aiMode: .remoteFirst, aiModel: "gpt-5.6-luna")

        var capture = base
        capture.captureIntent = .paused
        var retention = base
        retention.retentionDays = 7
        var transcription = base
        transcription.transcriptionMode = .localOnly
        var charging = base
        charging.backgroundCatchUp = .always
        for unchanged in [capture, retention, transcription, charging] {
            #expect(unchanged.aiRecoveryKey == base.aiRecoveryKey)
        }

        var mode = base
        mode.aiMode = .localOnly
        var provider = base
        provider.remoteAiProvider = .applePrivateCloud
        var model = base
        model.aiModel = "gpt-5.6-terra"
        for changed in [mode, provider, model] {
            #expect(changed.aiRecoveryKey != base.aiRecoveryKey)
        }
    }
}
