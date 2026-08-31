import SwiftUI

/// Settings · Watch (artboard 2.10): device card w/ battery, firmware + watch-report rows,
/// Find Watch (inline connect progress, NO capture side effects — anti-B3), destructive
/// forget with confirmation.
struct SettingsWatchScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router

    private var watch: WatchStatusSource { SettingsDataSources.current.watch }

    private enum FindState: Equatable { case idle, connecting, connected, notFound }
    @State private var findState: FindState = .idle
    @State private var confirmForget = false

    var body: some View {
        SettingsScroll {
            deviceCard
            infoCard
            ListCard {
                TintActionRow(title: Copy.Settings.Watch.findWatch, action: findWatch) {
                    findAccessory
                }
            }
            ListCard {
                DestructiveRow(title: Copy.Settings.Watch.forgetWatch) {
                    confirmForget = true
                }
            }
            SettingsFooter(text: Copy.Settings.Watch.footer)
        }
        .navigationTitle(Copy.Settings.Watch.title)
        .confirmationDialog(
            Copy.Settings.Watch.forgetWatch,
            isPresented: $confirmForget,
            titleVisibility: .hidden
        ) {
            Button("Forget This Watch", role: .destructive, action: forgetWatch)
        }
    }

    // MARK: Cards

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

    private var infoCard: some View {
        ListCard {
            SettingsRow(
                title: Copy.Settings.Watch.firmware,
                value: watch.firmwareVersion.map(Copy.Settings.Watch.firmwareValue) ?? "—",
                showsChevron: false
            )
            SettingsRow(
                title: Copy.Settings.Watch.watchReports,
                value: watch.watchReports,
                showsChevron: false
            )
        }
    }

    private var statusLine: String {
        switch settings.captureIntent {
        case .active: return Copy.Settings.Root.recordingConnected
        case .paused: return Copy.Status.paused
        case .off: return Copy.Status.notRecording
        }
    }

    private var statusColor: Color {
        switch settings.captureIntent {
        case .active: return Tokens.good
        case .paused: return Tokens.attention
        case .off: return Tokens.meta
        }
    }

    @ViewBuilder
    private var findAccessory: some View {
        switch findState {
        case .idle:
            EmptyView()
        case .connecting:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Text(Copy.Settings.TranscriptionAI.connectedAgo("just now"))
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

    /// Attempts a connection and shows progress inline. Deliberately touches NOTHING about
    /// capture intent (anti-B3: connecting never silently enables recording).
    private func findWatch() {
        guard findState != .connecting else { return }
        findState = .connecting
        watch.findWatch()
        Task {
            // Give the link a moment, then report what actually happened rather than a
            // decorative "connected".
            try? await Task.sleep(for: .seconds(6))
            findState = watch.isConnected ? .connected : .notFound
        }
    }

    /// Forgetting the watch drops the binding: capture goes off and the app returns to
    /// pairing (the onboarding gate reopens).
    private func forgetWatch() {
        // Drop the binding first: capture off alone would leave the watch still authorized
        // to this phone.
        watch.forget()
        settings.captureIntent = .off
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
