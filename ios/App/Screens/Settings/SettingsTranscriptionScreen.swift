import CompanionRuntime
import SwiftUI
import Transcription
import Intelligence

/// Settings · Transcription & AI (artboard 2.11 + plan 6.7): disclosure rows only (no
/// segmented controls), the four local-model row states, keys shown as "saved in Keychain"
/// with a pushed change flow — never inline fields.
///
/// **Every row here is conditional on the modes actually using it** (`TranscriptionAiRowPlan`).
/// It used to show all of them all of the time, so "AI · Mode · Local only" sat above "OpenAI
/// key · not set" — a credential that configuration never reads, rendered as a thing left
/// undone — and above a row called "Model" that names the CLOUD model. The inverse was just as
/// wrong: Cloud only offered a local engine picker nothing would ever resolve.
struct SettingsTranscriptionScreen: View {
    @Environment(AppSettings.self) private var settings

    private var sources: SettingsDataSources { SettingsDataSources.current }
    private var model: LocalModelManaging { sources.localModel }

    private var cloudHealth: CloudHealthSource { sources.cloudHealth }
    private var keyChecker: ApiKeyChecking { sources.apiKeys }

    /// Which rows this configuration implies. Derived from the two modes on every draw — the
    /// rule itself, and the reasoning behind it, live in `TranscriptionAiRowPlan`.
    private var rowPlan: TranscriptionAiRowPlan {
        TranscriptionAiRowPlan(
            transcriptionMode: settings.transcriptionMode,
            aiMode: settings.aiMode,
            cloudTranscriptionProvider: settings.cloudTranscriptionProvider
        )
    }

    /// Whether anything on this phone can transcribe right now: the chosen engine, or the Apple
    /// Speech fallback every other selection resolves to.
    private var localTranscriptionReadiness: OnDeviceTranscriptionReadiness {
        OnDeviceTranscriptionReadiness.resolve(
            selected: model.state(for: settings.localTranscriptionModelId),
            appleSpeech: model.state(for: LocalModelCatalog.appleSpeechId)
        )
    }

    /// Choosing a mode here also ANSWERS the question onboarding's "Later" deferred.
    ///
    /// `transcriptsConfigured` had exactly one writer — onboarding — while Today's "Transcripts
    /// are off" card sends people to this very screen to fix it. So anyone who picked "Later"
    /// kept that card forever, however they configured transcription afterwards: the card's own
    /// remedy could not clear it. Setting it from the mode's `didSet` would be wrong in the other
    /// direction, because onboarding writes the mode before recording the deferral; this is the
    /// narrower truth — a person standing on this screen picking a mode has decided.
    private var transcriptionModeBinding: Binding<TranscriptionMode> {
        Binding(
            get: { settings.transcriptionMode },
            set: { mode in
                settings.transcriptionMode = mode
                settings.transcriptsConfigured = true
            }
        )
    }

    var body: some View {
        @Bindable var settings = settings
        // Read once per draw, and read INSIDE `body` deliberately: `SystemLanguageModel` is
        // `Observable`, so touching `availability` here subscribes this screen to it. Apple
        // Intelligence being switched on in iOS Settings, or its model finishing its download,
        // redraws these rows on its own — no timer, no notification of ours, no poll.
        let rows = rowPlan
        let aiReadiness = OnDeviceAiReadiness.current
        let localReadiness = localTranscriptionReadiness

        SettingsScroll {
            SettingsSectionHeader(title: Copy.Settings.TranscriptionAI.transcriptionSection)
            ListCard {
                SettingsPushRow(
                    title: Copy.Settings.TranscriptionAI.mode,
                    value: settings.transcriptionMode.displayName
                ) {
                    ChoiceScreen(
                        title: Copy.Settings.TranscriptionAI.mode,
                        options: TranscriptionMode.allCases.map {
                            .init(value: $0, label: $0.displayName)
                        },
                        selection: transcriptionModeBinding,
                        footer: Copy.Settings.TranscriptionAI.footer
                    )
                }
                // Never starts a download by itself — it pushes the catalog, where the size is
                // visible before anything is fetched.
                if rows.showsLocalModel {
                    SettingsPushRow(
                        title: Copy.Settings.TranscriptionAI.localModel,
                        value: localModelValue,
                        valueColor: localModelValueColor
                    ) {
                        SettingsLocalModelScreen()
                    }
                }
                if rows.showsCloudProvider {
                    SettingsPushRow(
                        title: Copy.Settings.TranscriptionAI.cloudProvider,
                        value: settings.cloudTranscriptionProvider.displayName
                    ) {
                        ChoiceScreen(
                            title: Copy.Settings.TranscriptionAI.cloudProvider,
                            options: CloudProvider.allCases.map {
                                .init(value: $0, label: $0.displayName)
                            },
                            selection: $settings.cloudTranscriptionProvider
                        )
                    }
                }
                if let provider = rows.transcriptionKey {
                    keyRow(for: provider)
                }
                // Where the backlog gets cleared. Phrased around what the person gets and what it
                // costs them, not around BGTaskScheduler. Shown in every mode: a local engine has
                // exactly the same queue of un-transcribed recordings a cloud one does.
                SettingsPushRow(
                    title: Copy.Settings.TranscriptionAI.backgroundCatchUp,
                    value: settings.backgroundCatchUp.displayName
                ) {
                    ChoiceScreen(
                        title: Copy.Settings.TranscriptionAI.backgroundCatchUp,
                        options: BackgroundCatchUp.allCases.map {
                            .init(value: $0, label: $0.displayName)
                        },
                        selection: $settings.backgroundCatchUp,
                        footer: Copy.Settings.TranscriptionAI.backgroundCatchUpFooter
                    )
                }
                // The other half of "what does this cost me": the row above spends battery, this
                // one spends data. Wi-Fi only by default — see `CloudUploadNetworkPolicy`. It
                // governs UPLOADS, so Local only has no choice to make here; local model
                // downloads are Wi-Fi-only under their own rule either way.
                if rows.showsUploadNetwork {
                    SettingsPushRow(
                        title: Copy.Settings.TranscriptionAI.uploadNetwork,
                        value: settings.cloudUploadNetwork.displayName
                    ) {
                        ChoiceScreen(
                            title: Copy.Settings.TranscriptionAI.uploadNetwork,
                            options: CloudUploadNetwork.allCases.map {
                                .init(value: $0, label: $0.displayName)
                            },
                            selection: $settings.cloudUploadNetwork,
                            footer: Copy.Settings.TranscriptionAI.uploadNetworkFooter
                        )
                    }
                }
            }
            // The consequence the "Local model" row cannot state on its own: it reports the
            // engine's state, this says what that means for the recordings.
            if let note = Copy.Settings.TranscriptionAI.localTranscriptionNote(
                mode: settings.transcriptionMode,
                readiness: localReadiness,
                cloudProvider: settings.cloudTranscriptionProvider.displayName
            ) {
                SettingsFooter(text: note)
            }

            SettingsSectionHeader(title: Copy.Settings.TranscriptionAI.aiSection)
            ListCard {
                SettingsPushRow(
                    title: Copy.Settings.TranscriptionAI.mode,
                    value: settings.aiMode.displayName
                ) {
                    ChoiceScreen(
                        title: Copy.Settings.TranscriptionAI.mode,
                        options: AiProcessingMode.allCases.map {
                            .init(value: $0, label: $0.displayName)
                        },
                        selection: $settings.aiMode,
                        // Only when this phone cannot do the local half — the moment of
                        // choosing is where that belongs, and it is the one place a person can
                        // pick "Local only" on a device that would then write nothing.
                        footer: Copy.Settings.TranscriptionAI.aiModeChoiceFooter(aiReadiness)
                    )
                }
                // The local half of this axis is not a picker — Apple's model is the only one —
                // so it is a plain readiness row. It exists mainly so the two mixed modes have
                // something that says which engine is which: "On this phone" above "Cloud
                // model", never one unlabelled "Model".
                if rows.showsOnDeviceAi {
                    SettingsRow(
                        title: Copy.Settings.TranscriptionAI.onThisPhone,
                        value: Copy.Settings.TranscriptionAI.onDeviceAiValue(aiReadiness),
                        valueColor: onDeviceAiValueColor(aiReadiness),
                        showsChevron: false
                    )
                }
                if rows.showsCloudModel {
                    SettingsPushRow(
                        title: Copy.Settings.TranscriptionAI.cloudModel,
                        value: sources.aiModelName(for: settings.aiModel)
                    ) {
                        ChoiceScreen(
                            title: Copy.Settings.TranscriptionAI.cloudModel,
                            options: sources.aiModels.map {
                                .init(value: $0.id, label: $0.displayName)
                            },
                            selection: $settings.aiModel
                        )
                    }
                }
                // The AI features use the OpenAI key. When OpenAI is ALSO the cloud
                // transcription provider that row is already on this screen, and showing the
                // same setting twice invites the reader to wonder which one is which — so the
                // plan returns nil for it rather than drawing it twice.
                if let provider = rows.aiKey {
                    keyRow(for: provider)
                }
            }
            if let note = Copy.Settings.TranscriptionAI.onDeviceAiNote(
                mode: settings.aiMode, readiness: aiReadiness
            ) {
                SettingsFooter(text: note)
            }

            // Probes the cloud TRANSCRIPTION backend only (see `showsTestConnection`), so it is
            // absent in a configuration that uploads no audio. An AI-only key is verified from
            // its own row's [Check Again].
            if rows.showsTestConnection {
                ListCard {
                    TintActionRow(
                        title: Copy.Settings.TranscriptionAI.testConnection,
                        action: testConnection
                    ) {
                        testAccessory
                    }
                }
            }
            // The standing hint is advice about a change; once both modes are already Local only
            // it is instructions for something the reader has done. Then state the result
            // instead — in the sentence Storage & Privacy leads with, so the two agree.
            SettingsFooter(
                text: rows.isFullyLocal
                    ? Copy.Settings.TranscriptionAI.everythingLocalFooter
                    : Copy.Settings.TranscriptionAI.footer
            )
        }
        .navigationTitle(Copy.Settings.TranscriptionAI.title)
        .task {
            model.refresh()
            await checkKeysIfNeeded()
        }
    }

    // MARK: Local model row

    /// "Apple Speech" · "Parakeet TDT 0.6B · 706 MB" when installed; otherwise the state
    /// itself, in the same lowercase register as "not set" on the key rows.
    private var localModelValue: String {
        switch model.state(for: settings.localTranscriptionModelId) {
        case .notInstalled:
            // A chosen model that has to be downloaded and isn't here means Apple Speech is
            // doing the transcribing. The row names the engine that is actually running — the
            // alternative is a settings row that quietly describes nothing.
            //
            // ... but only when Apple Speech can actually run. `fallsBackToAppleSpeech` answers
            // "would the kit fall back?", not "would the fallback work?", so on a phone whose
            // speech assets are absent or whose language iOS has no model for, this row was
            // naming an engine that transcribes nothing. Saying "not installed" plainly is the
            // honest version; the footer under the card says what that means.
            guard model.fallsBackToAppleSpeech(settings.localTranscriptionModelId),
                model.state(for: LocalModelCatalog.appleSpeechId) == .installed
            else {
                return Copy.Settings.TranscriptionAI.notInstalled
            }
            return Copy.Settings.TranscriptionAI.notInstalledUsingAppleSpeech
        case .waitingForWiFi:
            return Copy.Settings.TranscriptionAI.waitingForWiFi
        case .downloading(let progress):
            return Copy.Settings.TranscriptionAI.downloading(Int(progress * 100))
        case .installing:
            return Copy.Settings.TranscriptionAI.installing
        case .failed:
            return Copy.Settings.TranscriptionAI.downloadFailed
        case .unavailable:
            return Copy.Settings.TranscriptionAI.unavailable
        case .installed:
            guard let option = model.selectedModel(settings.localTranscriptionModelId) else {
                return Copy.Settings.TranscriptionAI.notInstalled
            }
            return [option.compactName, option.sizeText]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
    }

    /// Attention for a failed download, and equally for a selection that is not running — a
    /// model this phone does not have is a gap the user has to know about, not a grey detail.
    private var localModelValueColor: Color {
        let state = model.state(for: settings.localTranscriptionModelId)
        if state == .failed { return Tokens.attention }
        if state == .notInstalled,
            model.fallsBackToAppleSpeech(settings.localTranscriptionModelId)
        {
            return Tokens.attention
        }
        return Tokens.meta
    }

    // MARK: On-device AI row

    /// Attention only where it changes the outcome. In AI "Local only" an unavailable model
    /// means nothing is written at all, which the person has to know; in the two "first" modes
    /// the cloud carries the work, so the same fact is information rather than a fault — the
    /// same restraint `Copy+ProcessingFallback` shows about a working fallback.
    private func onDeviceAiValueColor(_ readiness: OnDeviceAiReadiness) -> Color {
        if readiness.isReady { return Tokens.meta }
        return settings.aiMode == .localOnly ? Tokens.attention : Tokens.meta
    }

    // MARK: Key rows

    /// "not set" · "sk-…4f2a · verified" · "sk-…4f2a · no credit" — the row answers "is my key
    /// good?", not merely "is one set?".
    private func keyRow(for provider: CloudProvider) -> some View {
        SettingsPushRow(
            title: Copy.Settings.TranscriptionAI.keyRow(provider: provider.displayName),
            value: keyRowValue(for: provider),
            valueColor: keyRowColor(for: provider)
        ) {
            ApiKeyChangeScreen(provider: provider)
        }
    }

    private func keyRowValue(for provider: CloudProvider) -> String {
        guard let masked = settings.maskedApiKey(for: provider) else {
            return Copy.Settings.TranscriptionAI.notSet
        }
        guard let word = keyChecker.status(for: provider).rowWord else { return masked }
        return "\(masked) · \(word)"
    }

    private func keyRowColor(for provider: CloudProvider) -> Color {
        // A verdict outlives the key it was about: the checker keeps its last answer for the
        // session, so after a key is deleted "not set" would otherwise render in the green of
        // the key that is gone. No key, no verdict.
        guard settings.hasApiKey(for: provider) else { return Tokens.meta }
        switch keyChecker.status(for: provider) {
        case .checked(.valid): return Tokens.good
        case .checked(let outcome) where outcome != .missing: return Tokens.attention
        default: return Tokens.meta
        }
    }

    /// Asks the provider about any saved key we have no verdict for yet — one cheap
    /// authenticated GET, so the rows mean something the first time the screen is opened.
    ///
    /// Scoped to the providers this configuration actually authenticates against, not to every
    /// provider with a key on file. A key left over from a previous configuration has no row on
    /// this screen any more, so checking it buys nothing and costs a request; in the fully local
    /// configuration this now makes no network call at all.
    private func checkKeysIfNeeded() async {
        for provider in rowPlan.providersInUse
        where settings.hasApiKey(for: provider) && keyChecker.status(for: provider) == .unchecked {
            await keyChecker.recheckSaved(provider)
        }
    }

    // MARK: Test connection

    @ViewBuilder
    private var testAccessory: some View {
        switch cloudHealth.testState {
        case .untested:
            // Nothing has been asked yet, so there is nothing honest to report.
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .connected(let ago):
            Text(Copy.Settings.TranscriptionAI.connectedAgo(ago))
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.good)
        case .problem(let message):
            Text(message)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.attention)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    /// One tap, both truths: the end-to-end provider check AND a fresh verdict on the key it
    /// would use — so the key row and this row can never sit there disagreeing.
    private func testConnection() {
        cloudHealth.test()
        Task { await keyChecker.recheckSaved(settings.cloudTranscriptionProvider) }
    }
}

// MARK: - API-key change flow (6.7)

/// Pushed screen per provider, in three labelled sections: the key that is saved and what the
/// provider says about it, a field that replaces it, and a way to remove it outright. Keys
/// never render in plaintext (B13).
///
/// Two things the earlier single-stack layout got wrong, and why this shape exists:
/// the masked key was the *value* of a row titled "saved in Keychain" — the key is the subject,
/// so it is now the row itself and the Keychain is a footnote; and the verdict the user came
/// here to read ("verified" / "no credit") was visible on the parent row but vanished on the
/// screen that manages the key. It is now the first thing on the screen, with [Check Again]
/// beside it so "is my key still good?" no longer requires re-pasting the key.
///
/// Saving also TESTS the key against the provider. The save itself is never gated on that — a
/// key can be right while the network is down — so "Saved to this phone's Keychain." is stated
/// on its own under the field, and the provider's verdict appears separately above it. A failed
/// check can never read as a lost key, nor a passing one as a silent green tick.
struct ApiKeyChangeScreen: View {
    let provider: CloudProvider

    @Environment(AppSettings.self) private var settings
    @State private var newKey = ""
    @State private var didSave = false
    @State private var confirmDelete = false

    private var keyChecker: ApiKeyChecking { SettingsDataSources.current.apiKeys }

    private var trimmedKey: String { newKey.trimmingCharacters(in: .whitespaces) }
    private var savedKey: String? { settings.maskedApiKey(for: provider) }
    private var status: ApiKeyStatus { keyChecker.status(for: provider) }
    private var canSave: Bool { !trimmedKey.isEmpty && status != .checking }

    var body: some View {
        SettingsScroll {
            if let savedKey {
                SettingsSectionHeader(
                    title: Copy.Settings.TranscriptionAI.currentKeySection
                )
                ListCard {
                    savedKeyRow(savedKey)
                    TintActionRow(title: Copy.KeyCheck.checkAgain) {
                        Task { await keyChecker.recheckSaved(provider) }
                    }
                }
                SettingsFooter(text: Copy.Settings.TranscriptionAI.keychainFootnote)
            }

            SettingsSectionHeader(
                title: savedKey == nil
                    ? Copy.Settings.TranscriptionAI.addKeySection
                    : Copy.Settings.TranscriptionAI.replaceKeySection
            )
            Card { keyField }
            // The primary action exists only once there is something to save. A permanently
            // disabled filled button is the loudest thing on a screen where it can do nothing.
            if !trimmedKey.isEmpty {
                Button(Copy.Settings.TranscriptionAI.saveKey, action: saveAndCheck)
                    .buttonStyle(.primaryFilled)
                    .disabled(!canSave)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            if let replaceFooter { SettingsFooter(text: replaceFooter) }

            // No footer under the delete row: the confirmation it raises says what stops
            // working, which is where that belongs.
            if savedKey != nil {
                ListCard {
                    DestructiveRow(title: Copy.Settings.TranscriptionAI.deleteKey) {
                        confirmDelete = true
                    }
                }
                // Anchored to the card that raises it. Attached to `SettingsScroll` the source
                // rect is the whole screen and iOS 26 places the panel against the top of it,
                // far from the row that was tapped. Same fix as `SettingsWatchScreen` and
                // `SettingsStorageScreen`.
                .confirmationDialog(
                    Copy.Settings.TranscriptionAI.deleteKey,
                    isPresented: $confirmDelete,
                    titleVisibility: .hidden
                ) {
                    Button(
                        Copy.Settings.TranscriptionAI.deleteKeyButton, role: .destructive
                    ) {
                        Haptics.destructiveConfirmed()
                        settings.removeApiKey(for: provider)
                        newKey = ""
                        didSave = false
                        // Cleared here as well as by the dialog's own dismissal: deleting the
                        // key collapses the `savedKey != nil` block this dialog is anchored to,
                        // and a host that disappears before SwiftUI writes `false` through the
                        // binding would leave the flag set — so the row would raise its own
                        // confirmation, unasked, the next time a key was saved.
                        confirmDelete = false
                    }
                } message: {
                    Text(
                        Copy.Settings.TranscriptionAI
                            .deleteKeyMessage(provider: provider.displayName)
                    )
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: trimmedKey.isEmpty)
        .animation(.snappy(duration: 0.22), value: savedKey)
        .navigationTitle(Copy.Settings.TranscriptionAI.keyRow(provider: provider.displayName))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Current key

    /// The masked key IS the row; the verdict is its trailing value, and a failure explains
    /// itself on a second line rather than leaving one ambiguous word on screen.
    private func savedKeyRow(_ masked: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(masked)
                    // Monospaced: a masked key is an opaque token to compare, not prose.
                    .font(AppFont.callout.monospaced())
                    .foregroundStyle(Tokens.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 10)
                verdict
            }
            if case .checked(let outcome) = status, let reason = outcome.failureReason {
                Text(reason)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.secondaryBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// One word for the verdict, in the colour that word deserves. Silent until something has
    /// actually asked the provider — an unchecked key makes no claim either way.
    @ViewBuilder
    private var verdict: some View {
        switch status {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(Copy.KeyCheck.Row.checking)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.meta)
            }
        case .checked(let outcome) where outcome != .missing:
            HStack(spacing: 5) {
                if outcome.isValid {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.good)
                        .accessibilityHidden(true)
                }
                Text(outcome.rowWord ?? "")
                    .font(AppFont.subBody)
                    .foregroundStyle(outcome.isValid ? Tokens.good : Tokens.attention)
                    .lineLimit(1)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Replace / add

    /// The app's field idiom (as on the onboarding key screen): a filled inset inside the white
    /// card, so the row reads as something to type in rather than a third label.
    private var keyField: some View {
        // Placeholder names the thing, not the act: the section header above already says
        // whether this adds or replaces, and "Replace key" under "REPLACE KEY" said it twice.
        SecureField(Copy.Onboarding.keyPlaceholder, text: $newKey)
        .font(AppFont.callout)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .onSubmit { if canSave { saveAndCheck() } }
        // Typing again retires the previous "Saved." — it describes a key that is no longer
        // the one in the field.
        .onChange(of: newKey) { _, value in
            if !value.isEmpty { didSave = false }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.fieldFill))
        .accessibilityLabel(
            Copy.Settings.TranscriptionAI.keyRow(provider: provider.displayName)
        )
    }

    /// That a save happened, and — the first time, when nothing above has said it yet — where
    /// the key goes. Never the verdict: that belongs to the key above, so the two facts can
    /// never be mistaken for each other.
    ///
    /// Nil while replacing an existing key: the card above already carries "Stored in this
    /// phone's Keychain.", and the section is headed "Replace key", so a second line saying
    /// saving replaces it was the same sentence a third time.
    private var replaceFooter: String? {
        if didSave { return Copy.Settings.TranscriptionAI.keySavedFootnote }
        return savedKey == nil ? Copy.Settings.TranscriptionAI.keychainFootnote : nil
    }

    /// Save first, then ask the provider: the key belongs to the user, so it is stored whatever
    /// the network says about it.
    private func saveAndCheck() {
        let key = trimmedKey
        guard !key.isEmpty else { return }
        settings.setApiKey(key, for: provider)
        newKey = ""
        didSave = true
        Task { await keyChecker.check(key, for: provider) }
    }
}

// Outcome→words lives in `DesignSystem/ApiKeyCheckOutcome+Copy.swift`, shared with the
// onboarding key screen so the two surfaces cannot drift apart again.

extension ApiKeyStatus {
    /// What the key row appends after the masked value; nil when there is nothing to say.
    var rowWord: String? {
        switch self {
        case .unchecked: return nil
        case .checking: return Copy.KeyCheck.Row.checking
        case .checked(let outcome): return outcome.rowWord
        }
    }
}

#Preview("Transcription & AI") {
    NavigationStack {
        SettingsTranscriptionScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
