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

    /// Set when a chosen "remind me" pause could not be scheduled because iOS notifications are
    /// off. The pause still happened; only the reminder did not, and the row says which.
    @State private var pauseReminderUnavailable = false

    var body: some View {
        SettingsScroll {
            titleRow
            watchCard
            groupCard
            SettingsFooter(
                text: Copy.Settings.Root.footer(
                    transcription: settings.cloudTranscriptionDestination,
                    ai: settings.remoteAiDestination
                )
            )
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

            // The capture switch — the SAME control Today's status card draws, from the same
            // `CaptureController` policy, so the two surfaces cannot answer "is recording on?"
            // differently. It used to be a bare `Toggle` labelled "Background audio", which is
            // what made this read as a separate mode rather than as the app's on/off switch.
            CaptureToggle(controller: captureController, layout: .row) {
                pauseReminderUnavailable = true
            }

            // The visible door to the opt-in timed pause. The same options live behind a
            // long-press on the switch above (where Focus keeps its), but a long-press nobody
            // discovers is the same as no affordance at all, so exactly one surface shows them
            // — here, one row, and only while there is something to pause.
            if captureStatus.canPause {
                Menu {
                    CapturePauseMenuItems(controller: captureController) {
                        pauseReminderUnavailable = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(Copy.Capture.pauseMenu)
                            .font(AppFont.callout)
                            .foregroundStyle(Tokens.tint)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityHint(Copy.Capture.pauseMenuHint)
            }

            // Only while it is still true: the reminder failed, so `capturePause` was reset and
            // the pause is a plain one. Any later state — a pause that DID arm a timer, a
            // resume, a switch off — makes the sentence stale, and it disappears on its own
            // rather than needing something to remember to clear it.
            if pauseReminderUnavailable, captureStatus.isPaused,
                !captureStatus.schedule.isArmed
            {
                Text(Copy.Capture.reminderUnavailable)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

    /// Settings' half of the shared capture control.
    ///
    /// The policy — what on/off/pause each mean, what they write, what they clear — lives in
    /// `CaptureController`; this only supplies the transport. `applyCaptureIntent` is the
    /// runtime follow-through every capture surface makes (`aa2a934`, `8ecace0`): the write
    /// alone is a preference, and a switch that wrote one used to lie in both directions — ON
    /// left the watch uncontacted while every surface said "Recording", OFF left the receiver
    /// running on someone who had just switched recording off.
    private var captureController: CaptureController {
        CaptureController(settings: settings) { intent in
            sources.capture.applyCaptureIntent(intent)
        }
    }

    private var captureStatus: CaptureStatus { CaptureStatus(settings) }

    /// The watch card's own line. Sourced from the same `CaptureStatus` as the switch below it,
    /// so the two rows on this one screen can never disagree about whether the watch is
    /// capturing — and so a timed pause names its end here too rather than only on Today.
    private var watchStatusLine: String {
        switch settings.captureIntent {
        case .active: return Copy.Settings.Root.recordingConnected
        case .paused: return captureStatus.line
        case .off: return Copy.Status.notRecording
        }
    }

    private var watchStatusColor: Color { captureStatus.color }

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
