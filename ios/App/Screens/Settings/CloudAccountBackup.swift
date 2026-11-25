import CompanionRuntime
import Intelligence
import SwiftUI
import Transcription

// Choosing what stands in for a refused account: from the alert card (a sheet), or ahead of time
// from Transcription & AI (a pushed list). One list, so the two can never offer different things.

/// One thing that can stand in.
struct CloudAccountBackupOption<Value: Hashable>: Identifiable, Equatable {
    var value: Value
    var title: String
    var detail: String? = nil
    /// A service with no key saved: choosing it asks for one, and it stands in once it has it.
    var needsKey: CloudProvider? = nil
    var isEnabled = true

    var id: Value { value }
}

enum CloudAccountBackupOptions {
    static func transcription(
        main: CloudProvider, mode: TranscriptionMode, onDeviceReady: Bool,
        hasKey: (CloudProvider) -> Bool, heldReason: (CloudProvider) -> String?
    ) -> [CloudAccountBackupOption<TranscriptionBackup>] {
        var options: [CloudAccountBackupOption<TranscriptionBackup>] = []
        if mode == .remoteOnly {
            options.append(
                .init(
                    value: .none, title: Copy.CloudAccount.waitFor(main.displayName),
                    detail: Copy.CloudAccount.waitDetail))
        }
        options.append(
            .init(
                value: .onDevice, title: Copy.CloudAccount.thisIPhone,
                detail: onDeviceReady ? nil : Copy.CloudAccount.notSetUp, isEnabled: onDeviceReady))
        for other in CloudProvider.allCases where other != main {
            let held = heldReason(other)
            let keyed = hasKey(other)
            options.append(
                .init(
                    value: TranscriptionBackup(provider: other), title: other.displayName,
                    detail: held?.capitalizedFirst ?? (keyed ? nil : Copy.CloudAccount.addAKey),
                    needsKey: keyed ? nil : other, isEnabled: held == nil))
        }
        return options
    }

    /// What the list shows as chosen: the first modes already use the phone when nothing is
    /// named, so "nothing named" is the phone there.
    static func shown(
        _ backup: TranscriptionBackup, main: CloudProvider, mode: TranscriptionMode
    ) -> TranscriptionBackup {
        let named = backup.provider == main ? .none : backup
        return named == .none && mode != .remoteOnly ? .onDevice : named
    }

    static func ai(
        mode: AiProcessingMode, onDevice: OnDeviceAiReadiness,
        applePrivateCloud: ApplePrivateCloudReadiness
    ) -> [CloudAccountBackupOption<AiBackup>] {
        var options: [CloudAccountBackupOption<AiBackup>] = []
        if mode == .remoteOnly {
            options.append(
                .init(
                    value: .none,
                    title: Copy.CloudAccount.waitFor(CloudProvider.openAi.displayName),
                    detail: Copy.CloudAccount.waitDetail))
        }
        options.append(
            .init(
                value: .onDevice, title: Copy.CloudAccount.thisIPhone,
                detail: onDevice.isReady
                    ? nil : Copy.Settings.TranscriptionAI.onDeviceAiValue(onDevice).capitalizedFirst,
                isEnabled: onDevice.isReady))
        // Only where it can work: a build or an OS that cannot use it has nothing to offer.
        switch applePrivateCloud {
        case .ready, .notReady:
            options.append(
                .init(
                    value: .applePrivateCloud,
                    title: Copy.Privacy.remoteAiName(for: .applePrivateCloud),
                    detail: applePrivateCloud.isReady
                        ? nil
                        : Copy.Settings.TranscriptionAI.applePrivateCloudValue(
                            applePrivateCloud, quota: .unknown
                        ).capitalizedFirst,
                    isEnabled: applePrivateCloud.isReady))
        case .notSupported, .notEnabledForThisBuild, .unsupportedOs: break
        }
        return options
    }

    static func shown(_ backup: AiBackup, mode: AiProcessingMode) -> AiBackup {
        backup == .none && mode != .remoteOnly ? .onDevice : backup
    }
}

/// The rows: a check mark on the chosen one, a reason under one that cannot be chosen.
struct CloudAccountBackupList<Value: Hashable>: View {
    let options: [CloudAccountBackupOption<Value>]
    let selection: Value
    let choose: (CloudAccountBackupOption<Value>) -> Void

    var body: some View {
        ListCard {
            ForEach(options) { option in
                Button { choose(option) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(AppFont.callout)
                                .foregroundStyle(option.isEnabled ? Tokens.label : Tokens.meta)
                            if let detail = option.detail {
                                Text(detail)
                                    .font(AppFont.footnote)
                                    .foregroundStyle(
                                        option.needsKey != nil && option.isEnabled
                                            ? Tokens.tint : Tokens.meta)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 10)
                        if option.value == selection {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Tokens.tint)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!option.isEnabled)
                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
    }
}

/// The lists themselves, for one account. Shared by the sheet and the Settings rows.
struct CloudAccountBackupLists: View {
    let provider: CloudProvider
    var showsTranscription: Bool
    var showsAi: Bool
    /// Called when a choice is made that needs nothing more.
    var chose: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @State private var keyFor: CloudProvider?

    private var onDeviceTranscriptionReady: Bool {
        let model = SettingsDataSources.current.localModel
        return OnDeviceTranscriptionReadiness.resolve(
            selected: model.state(for: settings.localTranscriptionModelId),
            appleSpeech: model.state(for: LocalModelCatalog.appleSpeechId)
        ).isReady
    }

    var body: some View {
        SettingsScroll {
            if showsTranscription {
                if showsAi { SettingsSectionHeader(title: Copy.CloudAccount.transcriptionSection) }
                CloudAccountBackupList(
                    options: CloudAccountBackupOptions.transcription(
                        main: provider, mode: settings.transcriptionMode,
                        onDeviceReady: onDeviceTranscriptionReady,
                        hasKey: { settings.hasApiKey(for: $0) },
                        heldReason: { other in
                            CloudAccountAlerts.shared.issues.first { $0.provider == other }?
                                .kind.shortReason
                        }),
                    selection: CloudAccountBackupOptions.shown(
                        settings.transcriptionBackup, main: provider,
                        mode: settings.transcriptionMode)
                ) { option in
                    settings.transcriptionBackup = option.value
                    if let needed = option.needsKey { keyFor = needed } else { chose() }
                }
            }
            if showsAi {
                if showsTranscription { SettingsSectionHeader(title: Copy.CloudAccount.aiSection) }
                CloudAccountBackupList(
                    options: CloudAccountBackupOptions.ai(
                        mode: settings.aiMode, onDevice: OnDeviceAiReadiness.current,
                        applePrivateCloud: ApplePrivateCloudReadiness.current),
                    selection: CloudAccountBackupOptions.shown(
                        settings.aiBackup, mode: settings.aiMode)
                ) { option in
                    settings.aiBackup = option.value
                    chose()
                }
            }
            SettingsFooter(text: Copy.CloudAccount.backupFooter(provider.displayName))
        }
        .task { SettingsDataSources.current.localModel.refresh() }
        .navigationDestination(item: $keyFor) { ApiKeyChangeScreen(provider: $0) }
    }
}

struct CloudAccountBackupSheet: View {
    let issue: CloudAccountIssue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CloudAccountBackupLists(
                provider: issue.provider, showsTranscription: issue.transcription != nil,
                showsAi: issue.ai != nil
            )
            .navigationTitle(Copy.CloudAccount.backupTitle(issue.provider.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Common.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Settings: the same list, pushed, before anything has gone wrong.
struct CloudAccountBackupScreen: View {
    let provider: CloudProvider
    var showsTranscription = false
    var showsAi = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CloudAccountBackupLists(
            provider: provider, showsTranscription: showsTranscription, showsAi: showsAi,
            chose: { dismiss() }
        )
        .navigationTitle(Copy.CloudAccount.backupRow(provider.displayName))
        .navigationBarTitleDisplayMode(.inline)
    }
}
