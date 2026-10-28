import Firmware
import SwiftUI

/// Settings · Watch (artboard 2.10): device card w/ battery, what the watch itself reports,
/// Reconnect (inline progress, NO capture side effects — anti-B3), destructive forget with
/// confirmation.
struct SettingsWatchScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router

    private var watch: WatchStatusSource { SettingsDataSources.current.watch }
    private var capture: CaptureControlling { SettingsDataSources.current.capture }

    private enum FindState: Equatable { case idle, connecting, connected, notFound }
    @State private var findState: FindState = .idle
    @State private var confirmForget = false
    @State private var showFocusHelp = false
    private var focus: FocusQuietTimeController { .shared }

    /// Shared with the Firmware screen this pushes, so a download started here is the one
    /// shown there.
    @State private var firmware = SettingsFirmwareScreen.makeModel()
    /// Set by Update Watch while its download runs, so the send-to-Pebble question follows
    /// the download on its own instead of needing a second tap.
    @State private var updateAwaitingDownload = false
    @State private var confirmUpdate = false
    @State private var showOpenInMenu = false
    @State private var showNoOpenerAlert = false
    /// The result of the last hand-off from this screen. Cleared by the next tap.
    @State private var handoffNote: String?

    var body: some View {
        SettingsScroll {
            deviceCard
            infoCard
            focusCard
            ListCard {
                TintActionRow(
                    title: Copy.Settings.Watch.reconnect,
                    subtitle: Copy.Settings.Watch.reconnectSub,
                    action: findWatch
                ) {
                    findAccessory
                }
            }
            ListCard {
                DestructiveRow(title: Copy.Settings.Watch.forgetWatch) {
                    confirmForget = true
                }
            }
            // Anchored to the card that raises it, not to the screen.
            //
            // A confirmation dialog takes its presentation source from the view the modifier is
            // attached to. This one was attached to `SettingsScroll` — a ScrollView filling the
            // whole screen — so the source rect was the entire screen and iOS 26 placed the panel
            // against the top of it, floating far from the row that had just been tapped. On the
            // one screen where a mis-tap forgets the watch, the confirmation has to read as
            // belonging to the button that raised it.
            //
            // It also has words now: title, and a message that says what is lost (the
            // authorization) and what is not (every recording).
            .confirmationDialog(
                Copy.Settings.Watch.forgetTitle,
                isPresented: $confirmForget,
                titleVisibility: .visible
            ) {
                Button(
                    Copy.Settings.Watch.forgetConfirm, role: .destructive, action: forgetWatch
                )
            } message: {
                Text(Copy.Settings.Watch.forgetMessage)
            }
            SettingsFooter(text: Copy.Settings.Watch.footer)
        }
        .navigationTitle(Copy.Settings.Watch.title)
        // Once per visit, not per appearance: coming back from the Firmware screen (which
        // refreshes the same model) must not blank the answer and take the Update Watch row,
        // and the Open In menu anchored to it, away mid-flow.
        .task { if firmware.availability == nil { await firmware.refresh() } }
        .onChange(of: watch.firmwareRevision) { firmware.reevaluate() }
        .onChange(of: firmware.download) { _, download in
            guard updateAwaitingDownload, !download.isBusy else { return }
            updateAwaitingDownload = false
            if download.verifiedFile != nil { confirmUpdate = true }
        }
        .alert(Copy.Firmware.noOpenerTitle, isPresented: $showNoOpenerAlert) {
            Button(Copy.Common.done, role: .cancel) {}
        } message: {
            Text(Copy.Firmware.noOpenerMessage)
        }
    }

    // MARK: Cards

    private var focusCard: some View {
        Group {
            SettingsSectionHeader(title: Copy.Focus.title)
            ListCard {
                Toggle(Copy.Focus.toggle, isOn: Binding(
                    get: { focus.enabled }, set: { focus.setEnabled($0) }
                ))
                .font(AppFont.callout)
                .tint(Tokens.tint)
                if focus.enabled || focus.status == .syncing || focus.status == .retry {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Copy.Focus.status(focus.status))
                            .font(AppFont.callout)
                            .foregroundStyle(Tokens.secondaryBody)
                        if let detail = Copy.Focus.detail(focus.status) {
                            Text(detail).font(AppFont.footnote).foregroundStyle(Tokens.meta)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DisclosureGroup(Copy.Focus.setup, isExpanded: $showFocusHelp) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(Copy.Focus.steps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(Copy.Focus.recording).foregroundStyle(Tokens.meta)
                    }
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.secondaryBody)
                    .padding(.top, 12)
                }
                .font(AppFont.callout)
                .tint(Tokens.tint)
            }
            SettingsFooter(text: Copy.Focus.footer)
        }
    }

    private var deviceCard: some View {
        Card {
            HStack(spacing: 14) {
                WatchIconTile(side: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(watch.deviceName)
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                    Text(statusLine)
                        .font(AppFont.footnote)
                        .foregroundStyle(statusColor)
                }
                Spacer(minLength: 10)
                if let battery = watch.batteryPercent {
                    Text("\(battery)%")
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.meta)
                }
            }
        }
    }

    /// What the watch itself says, and the firmware it runs.
    ///
    /// The Firmware row leads to the Firmware screen whenever a release feed is configured, and
    /// otherwise appears only once the watch has reported a version: a row whose value is a
    /// permanent em-dash reads as something the app failed to fetch. Update Watch appears below
    /// it only when the watch's own build is older than the published one.
    private var infoCard: some View {
        ListCard {
            SettingsRow(
                title: Copy.Settings.Watch.watchReports,
                value: watch.watchReports,
                showsChevron: false
            )
            if SettingsFirmwareScreen.isReachable {
                SettingsPushRow(title: Copy.Settings.Watch.firmware, value: firmwareValue) {
                    SettingsFirmwareScreen(model: firmware)
                }
            } else if let firmwareValue {
                SettingsRow(
                    title: Copy.Settings.Watch.firmware,
                    value: firmwareValue,
                    showsChevron: false
                )
            }
            if let update = offeredUpdate {
                TintActionRow(
                    title: Copy.Firmware.updateWatch,
                    subtitle: updateSubtitle(update),
                    action: updateWatch
                ) {
                    if firmware.download.isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
                .firmwareOpenInMenu(
                    isPresented: $showOpenInMenu,
                    fileURL: firmware.download.verifiedFile,
                    onOutcome: handleHandoff
                )
            }
        }
        // Anchored to the card holding the row that raises it, for the reason the Forget
        // dialog below gives; and this one hands straight on to the Open In menu, which is
        // anchored to that row.
        .confirmationDialog(
            Copy.Firmware.consentTitle, isPresented: $confirmUpdate, titleVisibility: .visible
        ) {
            Button(Copy.Firmware.consentConfirm) {
                Haptics.impact(.medium)
                // After the dialog's own dismissal animation: presenting the Open In menu while
                // it is still on its way out fails silently (see `SettingsFirmwareScreen`).
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    showOpenInMenu = true
                }
            }
        } message: {
            Text(Copy.Firmware.consentMessage)
        }
    }

    /// The exact build when the watch has reported it ("v4.41.0-678"), else the
    /// major.minor.patch the companion service carries, else nothing.
    private var firmwareValue: String? {
        if let revision = watch.firmwareRevision {
            return FirmwareVersion(revision)?.label ?? revision
        }
        return watch.firmwareVersion.map(Copy.Settings.Watch.firmwareValue)
    }

    /// The published build, when the watch itself has said it is running an older one — never
    /// on this app's memory of what it sent. Kept on screen after a hand-off while the watch
    /// still reports the old build, so the "sent" line has somewhere to sit and a failed install
    /// can be tried again.
    private var offeredUpdate: FirmwareRelease? {
        guard let availability = firmware.availability, availability.isUpdate,
            firmware.known?.isFromWatch == true
        else { return nil }
        return availability.release
    }

    private func updateSubtitle(_ release: FirmwareRelease) -> String {
        switch firmware.download {
        case .downloading(let received, let total):
            return total > 0
                ? Copy.Firmware.downloadProgress(received, total) : Copy.Firmware.downloadingUpdate
        case .failed(let failure):
            return Copy.Firmware.downloadFailure(failure)
        case .idle, .ready:
            return handoffNote ?? Copy.Firmware.updateAvailable(release.version.label)
        }
    }

    /// Deferred to `CaptureStatus` rather than switching on `captureIntent` here, which is what
    /// this used to do. The intent alone can no longer describe the state: a timed pause carries
    /// the time it ends, and a local switch would have gone on saying a bare "Paused" while the
    /// two surfaces that own the control said "Paused until 3:40 PM". One vocabulary, one answer.
    private var statusLine: String { CaptureStatus(settings).line }

    private var statusColor: Color { CaptureStatus(settings).color }

    @ViewBuilder
    private var findAccessory: some View {
        switch findState {
        case .idle:
            EmptyView()
        case .connecting:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Text(Copy.Settings.Watch.reconnected)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.good)
        case .notFound:
            // A spinner that just disappears is the same as saying nothing (B10).
            Text(Copy.Onboarding.Failure.noPebbleFound)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.attention)
        }
    }

    // MARK: Actions

    /// Download (or reuse the verified copy), then ask, then the Open In menu. A tap while the
    /// download runs does nothing; a tap after a failure starts it again.
    private func updateWatch() {
        guard !firmware.download.isBusy else { return }
        handoffNote = nil
        if case .failed = firmware.download { firmware.discardDownload() }
        if firmware.download.verifiedFile == nil { firmware.startDownload() }
        if firmware.download.verifiedFile != nil {
            confirmUpdate = true
        } else {
            updateAwaitingDownload = firmware.download.isBusy
        }
    }

    private func handleHandoff(_ outcome: FirmwareHandoffOutcome) {
        if outcome == .noOpener { showNoOpenerAlert = true }
        if let note = firmware.recordHandoff(outcome) { handoffNote = note }
    }

    /// Rebuilds the link and shows progress inline. Deliberately touches NOTHING about capture
    /// intent (anti-B3: connecting never silently enables recording).
    ///
    /// It polls instead of sleeping the full timeout: a rebuild that lands in a second used to
    /// spin for six anyway, which reads as a stall on the one action a user takes *because*
    /// something already feels stuck.
    private func findWatch() {
        guard findState != .connecting else { return }
        findState = .connecting
        watch.findWatch()
        Task {
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while ContinuousClock.now < deadline, !watch.isConnected {
                try? await Task.sleep(for: .milliseconds(250))
            }
            // Report what actually happened rather than a decorative "connected".
            let outcome: FindState = watch.isConnected ? .connected : .notFound
            findState = outcome
            // And let it go again. The result described one attempt a moment ago; leaving
            // "Connected" pinned under the row turns it into a claim about now, which it stops
            // being the second the watch walks out of range.
            try? await Task.sleep(for: .seconds(8))
            if findState == outcome { findState = .idle }
        }
    }

    /// Forgetting the watch drops the binding: capture goes off and the app returns to
    /// pairing (the onboarding gate reopens).
    private func forgetWatch() {
        // The same confirmation feedback every other destructive action in the app gives; this
        // one is the most destructive on the screen (it also reopens the onboarding gate) and
        // was the only one that gave none.
        Haptics.destructiveConfirmed()
        // Drop the binding first: capture off alone would leave the watch still authorized
        // to this phone.
        watch.forget()
        // The preference AND the runtime, in that order. Writing the intent alone left the
        // receiver holding its own `.active` — and an open pause interval open forever, so
        // coverage went on rendering the rest of the day as paused.
        settings.captureIntent = .off
        capture.applyCaptureIntent(.off, source: .forgetWatch)
        // …and the two surfaces outside this process, which read the App Group and are never
        // told it changed. A forgotten watch that leaves the Home Screen widget and the Control
        // Center toggle saying "Recording" is the worst version of that staleness: it is the one
        // capture change where the person has explicitly asked for everything to stop.
        CaptureController.reloadWidgetSurfaces()
        router.settingsPath = []
        settings.onboardingComplete = false
    }
}

#Preview("Watch") {
    NavigationStack {
        SettingsWatchScreen()
    }
    .environment(AppSettings())
    .environment(AppRouter())
    .tint(Tokens.tint)
}
