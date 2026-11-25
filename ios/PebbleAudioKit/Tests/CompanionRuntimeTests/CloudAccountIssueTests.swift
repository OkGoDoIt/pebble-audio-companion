import Foundation
import Intelligence
import Testing
import Transcription

@testable import CompanionRuntime

// What the person is told about a refused account, and what is said to be doing its work.

@Suite struct CloudAccountIssueTests {
    private func hold(
        _ provider: CloudProvider, _ kind: TranscriptionFailureKind = .accountOutOfFunds
    ) -> CloudAccountHold.Hold {
        let holds = CloudAccountHold(fileURL: nil, apiKey: { _ in "key" }, nowMs: { 42 })
        holds.trip(kind, provider: provider)
        return holds.active(for: provider)!
    }

    private func issues(
        _ settings: RuntimeSettingsSnapshot, held: [CloudAccountHold.Hold],
        keys: Set<CloudProvider> = [.soniox, .openAi], phone: Bool = true, apple: Bool = false
    ) -> [CloudAccountIssue] {
        CloudAccountIssue.resolve(
            settings: settings, hold: { p in held.first { $0.provider == p } },
            hasKey: { keys.contains($0) }, onDeviceTranscriptionReady: phone,
            onDeviceAiReady: phone, applePrivateCloudReady: apple)
    }

    private func settings(
        _ mode: TranscriptionMode = .remoteFirst, provider: CloudProvider = .soniox,
        backup: TranscriptionBackup = .none, ai: AiProcessingMode = .remoteFirst,
        remoteAi: RemoteAiProvider = .openAi, aiBackup: AiBackup = .none
    ) -> RuntimeSettingsSnapshot {
        RuntimeSettingsSnapshot(
            transcriptionMode: mode, cloudTranscriptionProvider: provider, aiMode: ai,
            transcriptsConfigured: true, remoteAiProvider: remoteAi, transcriptionBackup: backup,
            aiBackup: aiBackup)
    }

    @Test func nothingHeldOrNothingUsingTheAccountIsNotNews() {
        #expect(issues(settings(), held: []).isEmpty)
        #expect(issues(settings(.localOnly), held: [hold(.soniox)]).isEmpty)
        #expect(
            issues(settings(ai: .localOnly), held: [hold(.openAi)]).isEmpty)
        #expect(issues(settings(remoteAi: .applePrivateCloud), held: [hold(.openAi)]).isEmpty)
        var unset = settings()
        unset.transcriptsConfigured = false
        #expect(issues(unset, held: [hold(.soniox)]).isEmpty)
    }

    /// 2026-11-22 to 11-25: Remote first, Soniox dry, and nothing anywhere said so.
    @Test func aFirstModeWhoseFallbackIsWorkingIsStillNews() {
        let found = issues(settings(), held: [hold(.soniox)])
        #expect(found.map(\.provider) == [.soniox])
        #expect(found.first?.transcription == .onDevice)
        #expect(found.first?.ai == nil)
        #expect(found.first?.sinceMs == 42)
    }

    @Test func whatStandsInIsNeverClaimedWhenItCannot() {
        #expect(issues(settings(), held: [hold(.soniox)], phone: false).first?.transcription == .waiting)
        #expect(issues(settings(.remoteOnly), held: [hold(.soniox)]).first?.transcription == .waiting)
        #expect(
            issues(settings(.remoteOnly, backup: .onDevice), held: [hold(.soniox)])
                .first?.transcription == .onDevice)
        #expect(
            issues(settings(.remoteOnly, backup: .openAi), held: [hold(.soniox)])
                .first?.transcription == .provider(.openAi))
        // Named, but no key yet; or out of money itself.
        #expect(
            issues(settings(.remoteOnly, backup: .openAi), held: [hold(.soniox)], keys: [.soniox])
                .first?.transcription == .waiting)
        #expect(
            issues(
                settings(.remoteOnly, backup: .openAi, ai: .localOnly),
                held: [hold(.soniox), hold(.openAi)]
            ).first?.transcription == .waiting)
        #expect(
            issues(settings(ai: .remoteOnly), held: [hold(.openAi)]).first?.ai == .waiting)
        #expect(
            issues(settings(ai: .remoteOnly, aiBackup: .onDevice), held: [hold(.openAi)])
                .first?.ai == .onDevice)
        #expect(
            issues(settings(aiBackup: .applePrivateCloud), held: [hold(.openAi)]).first?.ai
                == .onDevice)
        #expect(
            issues(settings(aiBackup: .applePrivateCloud), held: [hold(.openAi)], apple: true)
                .first?.ai == .applePrivateCloud)
    }

    @Test func oneAccountDoingBothJobsIsOneIssue() {
        let found = issues(settings(provider: .openAi), held: [hold(.openAi)])
        #expect(found.count == 1)
        #expect(found.first?.transcription == .onDevice)
        #expect(found.first?.ai == .onDevice)
    }

    /// A 403 about audio stops transcription and says nothing about AI.
    @Test func aKeyThatMayNotTranscribeIsNotAnAiIssue() {
        #expect(issues(settings(), held: [hold(.openAi, .keyNotPermitted)]).isEmpty)
        let both = issues(settings(provider: .openAi), held: [hold(.openAi, .keyNotPermitted)])
        #expect(both.first?.transcription == .onDevice)
        #expect(both.first?.ai == nil)
    }

    @Test func theBoxForwardsBothBackupsAndAChangeRevivesWork() {
        let box = RuntimeSettingsBox(settings(backup: .openAi, aiBackup: .onDevice))
        #expect(box.transcriptionBackup == .openAi)
        #expect(box.aiBackup == .onDevice)
        let before = (box.transcriptionRecoveryKey, box.aiRecoveryKey)
        box.apply {
            $0.transcriptionBackup = .none
            $0.aiBackup = .none
        }
        #expect(box.transcriptionRecoveryKey != before.0)
        #expect(box.aiRecoveryKey != before.1)
    }
}
