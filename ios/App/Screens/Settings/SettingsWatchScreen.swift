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

    var body: some View {
        SettingsScroll {
            deviceCard
            infoCard
            SettingsFooter(text: Copy.Settings.Watch.reportsFooter)
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

    /// What the watch itself says about the audio service.
    ///
    /// The Firmware row is rendered ONLY when the watch has actually reported a version, which
    /// today it never does: `InfoSnapshot.fwVersionPacked` exists in the wire layout
    /// (`PROTOCOL.md` §3, offset 12) but `audio_companion_fill_info()` never assigns it, so the
    /// designated initializer zero-fills those four bytes and the app correctly reads "unknown".
    /// A row whose value is a permanent em-dash is worse than no row: it reads as a value the
    /// app failed to fetch rather than one the firmware does not send. When a firmware build
    /// starts filling the field the row appears on its own, with no change here.
    private var infoCard: some View {
        ListCard {
            SettingsRow(
                title: Copy.Settings.Watch.watchReports,
                value: watch.watchReports,
                showsChevron: false
            )
            if let firmwareVersion = watch.firmwareVersion {
                SettingsRow(
                    title: Copy.Settings.Watch.firmware,
                    value: Copy.Settings.Watch.firmwareValue(firmwareVersion),
                    showsChevron: false
                )
            }
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
        capture.applyCaptureIntent(.off)
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
