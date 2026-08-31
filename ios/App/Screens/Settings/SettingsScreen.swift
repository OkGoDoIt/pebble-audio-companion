import Receiver
import SwiftUI
import UserNotifications

/// Settings root (artboard 2.9) — fits one screen; everything else is a pushed screen (Q7).
/// Registers the `.settings(page)` navigation destinations for the settings stack, so deep
/// links (`companion://settings/...`) resolve here.
struct SettingsScreen: View {
    @Environment(AppSettings.self) private var settings

    private var sources: SettingsDataSources { SettingsDataSources.current }

    /// iOS-level notification permission, re-read whenever this screen appears (it can be
    /// revoked in iOS Settings while the app's own switch stays on).
    @State private var notificationsDenied = false

    var body: some View {
        SettingsScroll {
            titleRow
            watchCard
            groupCard
            SettingsFooter(text: Copy.Settings.Root.footer)
        }
        // The tab roots own their titles. A system large title would reserve a full 54 pt
        // navigation-bar row above it, and this root — unlike Today, which puts Ask there —
        // has nothing to put in that row, so it rendered as dead space above "Settings".
        // Library already draws its title inline for the same reason; this matches it and the
        // artboards' 54 pt top inset. `navigationTitle` stays: it is what the pushed settings
        // screens use as their back label (B15).
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle(Copy.Settings.Root.title)
        .navigationDestination(for: Route.self) { route in
            destination(for: route)
        }
    }

    private var titleRow: some View {
        Text(Copy.Settings.Root.title)
            .font(AppFont.tabTitle)
            .foregroundStyle(Tokens.label)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Watch card

    private var watchCard: some View {
        ListCard {
            NavigationLink(value: Route.settings(.watch)) {
                HStack(alignment: .top, spacing: 12) {
                    WatchIconTile(side: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sources.watch.deviceName)
                            .font(AppFont.rowTitle)
                            .foregroundStyle(Tokens.label)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(watchStatusLine)
                            .font(AppFont.footnote)
                            .foregroundStyle(watchStatusColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.chevron)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The toggle keeps its intrinsic width, so at accessibility sizes the label
            // has to move above it rather than be hyphenated into the leftover column.
            Toggle(isOn: backgroundAudioBinding) {
                Text(Copy.Settings.Root.backgroundAudio)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)
            .tint(Tokens.good)

            // Two-line toggle row, same shape as Storage's auto-export row.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.Settings.Root.lossAlerts)
                        .font(AppFont.callout)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(lossAlertsSubline)
                        .font(AppFont.footnote)
                        .foregroundStyle(notificationsDenied ? Tokens.attention : Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Toggle(Copy.Settings.Root.lossAlerts, isOn: lossAlertsBinding)
                    .labelsHidden()
                    .tint(Tokens.good)
            }
        }
        .task { await refreshNotificationPermission() }
    }

    /// Turning it ON is the moment to ask iOS — asking during a gap, months later, is an
    /// ambush. A denial is shown on the row instead of leaving a switch that does nothing.
    private var lossAlertsBinding: Binding<Bool> {
        Binding(
            get: { settings.lossAlertsEnabled },
            set: { enabled in
                settings.lossAlertsEnabled = enabled
                guard enabled else { return }
                Task {
                    _ = await UserNotificationLossNotifier().requestAuthorizationIfNeeded()
                    await refreshNotificationPermission()
                }
            }
        )
    }

    private var lossAlertsSubline: String {
        settings.lossAlertsEnabled && notificationsDenied
            ? Copy.Settings.Root.lossAlertsDenied
            : Copy.Settings.Root.lossAlertsSub
    }

    private func refreshNotificationPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
        notificationsDenied = status == .denied
    }

    /// "Background audio" is the master switch: active↔off. A paused intent still reads as
    /// ON (pause is the temporary form of on — plan 6.1); flipping OFF from paused turns
    /// capture fully off, flipping ON resumes.
    ///
    /// The write alone is only a preference. This switch used to do nothing else, which made it
    /// lie in both directions: ON left the watch uncontacted while every surface said
    /// "Recording", and OFF left the receiver running on a person who had just switched
    /// recording off. `capture` is the runtime follow-through every other capture surface makes
    /// (`aa2a934`, `8ecace0`) — intent first so the row flips at once, then the link.
    private var backgroundAudioBinding: Binding<Bool> {
        Binding(
            get: { settings.captureIntent != .off },
            set: { on in
                let intent: CaptureIntent = on ? .active : .off
                settings.captureIntent = intent
                sources.capture.applyCaptureIntent(intent)
            }
        )
    }

    private var watchStatusLine: String {
        switch settings.captureIntent {
        case .active: return Copy.Settings.Root.recordingConnected
        case .paused: return Copy.Status.paused
        case .off: return Copy.Status.notRecording
        }
    }

    private var watchStatusColor: Color {
        switch settings.captureIntent {
        case .active: return Tokens.good
        case .paused: return Tokens.attention
        case .off: return Tokens.meta
        }
    }

    // MARK: Groups

    private var groupCard: some View {
        ListCard {
            SettingsNavRow(
                title: Copy.Settings.Root.transcriptionAI,
                value: transcriptionPreview,
                route: .settings(.transcription)
            )
            SettingsNavRow(
                title: Copy.Settings.Root.storagePrivacy,
                value: storagePreview,
                route: .settings(.storage)
            )
            SettingsNavRow(title: Copy.Settings.Root.aboutYou, route: .settings(.aboutyou))
            SettingsNavRow(title: Copy.Settings.Root.diagnostics, route: .settings(.diagnostics))
        }
    }

    /// e.g. "Soniox · GPT-5.6".
    private var transcriptionPreview: String {
        let transcription = settings.transcriptionMode == .localOnly
            ? Copy.Settings.TranscriptionAI.localOnly
            : settings.cloudTranscriptionProvider.displayName
        return "\(transcription) · \(sources.aiModelShortName(for: settings.aiModel))"
    }

    /// e.g. "30 days · 383 recordings".
    private var storagePreview: String {
        "\(settings.retentionDays) days · \(sources.storage.recordingCount) recordings"
    }

    // MARK: Destinations

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .settings(.watch): SettingsWatchScreen()
        case .settings(.transcription): SettingsTranscriptionScreen()
        case .settings(.storage): SettingsStorageScreen()
        case .settings(.aboutyou): SettingsAboutYouScreen()
        case .settings(.diagnostics): SettingsDiagnosticsScreen()
        default: EmptyView()  // non-settings routes never land on the settings stack
        }
    }
}

/// The tinted watch icon tile (36pt on the root card, 44pt on the Watch screen).
struct WatchIconTile: View {
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: side / 4)
            .fill(Tokens.tintFill12)
            .frame(width: side, height: side)
            .overlay(
                Image(systemName: "applewatch")
                    .font(.system(size: side * 0.55, weight: .regular))
                    .foregroundStyle(Tokens.tint)
            )
            .accessibilityHidden(true)
    }
}

#Preview("Settings root") {
    NavigationStack {
        SettingsScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
