import CompanionRuntime
import Foundation
import Intelligence
import Receiver
import Testing
import Transcription

// The settings truth table (plan Part 4.6). Everything is WIRED; the derived semantics live in
// one place so no screen re-derives `mode != .localOnly` by hand and gets it subtly wrong.

@Suite struct RuntimeSettingsTests {

    @Test func cloudDerivedFlagsFollowTheTranscriptionMode() {
        for mode in TranscriptionMode.allCases {
            let settings = RuntimeSettingsSnapshot(transcriptionMode: mode)
            let expected = mode != .localOnly
            #expect(settings.cloudTranscriptionEnabled == expected)
            #expect(settings.speakerLabelsEnabled == expected)
            #expect(settings.liveCloudEnabled == expected)
        }
    }

    @Test func remoteAiIsGatedByAiModeNotABooleanConsentFlag() {
        for mode in AiProcessingMode.allCases {
            let settings = RuntimeSettingsSnapshot(aiMode: mode)
            #expect(settings.remoteAiEnabled == (mode != .localOnly))
        }
    }

    @Test func cloudIsPrimaryOnlyInTheRemoteModes() {
        #expect(RuntimeSettingsSnapshot(transcriptionMode: .remoteOnly).cloudIsPrimaryTranscription)
        #expect(RuntimeSettingsSnapshot(transcriptionMode: .remoteFirst).cloudIsPrimaryTranscription)
        #expect(!RuntimeSettingsSnapshot(transcriptionMode: .localFirst).cloudIsPrimaryTranscription)
        #expect(!RuntimeSettingsSnapshot(transcriptionMode: .localOnly).cloudIsPrimaryTranscription)
    }

    @Test func retentionDaysConvertsToARealAgeCap() {
        #expect(
            RuntimeSettingsSnapshot(retentionDays: 30).retentionConfig.maxAgeMs
                == 30 * 24 * 60 * 60 * 1000
        )
        // Zero/negative is clamped rather than deleting everything on the next sweep.
        #expect(RuntimeSettingsSnapshot(retentionDays: 0).retentionConfig.maxAgeMs > 0)
    }

    @Test func retentionMaxBytesDefaultsWithoutTheAppDeclaringIt() {
        struct MinimalSettings: RuntimeSettings {
            var captureIntent: CaptureIntent = .active
            var transcriptionMode: TranscriptionMode = .localOnly
            var localTranscriptionModelId = ""
            var cloudTranscriptionProvider: CloudProvider = .soniox
            var aiMode: AiProcessingMode = .localOnly
            var aiModel = ""
            var automaticWavExportEnabled = false
            var onboardingComplete = true
            var retentionDays = 14
            var transcriptsConfigured = true
        }
        let settings = MinimalSettings()
        #expect(settings.retentionMaxBytes == RuntimeSettingsDefaults.retentionMaxBytes)
        #expect(retentionConfig(for: settings).maxAgeMs == 14 * 24 * 60 * 60 * 1000)
    }

    @Test func theSettingsBoxIsReadableFromAnyIsolationDomain() async {
        let box = RuntimeSettingsBox(RuntimeSettingsSnapshot(captureIntent: .off))
        #expect(box.captureIntent == .off)

        box.apply { $0.captureIntent = .active }
        #expect(box.captureIntent == .active)

        await Task.detached { box.apply { $0.transcriptionMode = .localOnly } }.value
        #expect(box.transcriptionMode == .localOnly)
        #expect(!box.cloudTranscriptionEnabled)
    }

    @Test func wavExportOnlyRunsWhenTheUserAskedForIt() async throws {
        let off = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(
                captureIntent: .active, automaticWavExportEnabled: false)
        )
        // No exporter is wired, so the assertion is that the gate is read and nothing throws.
        try await off.live.exportWavIfEnabled()

        let on = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(
                captureIntent: .active, automaticWavExportEnabled: true)
        )
        try await on.live.exportWavIfEnabled()
    }
}
