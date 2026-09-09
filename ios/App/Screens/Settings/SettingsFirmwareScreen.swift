import Firmware
import SwiftUI

/// Settings → **Watch firmware** (pushed).
///
/// ## What this screen is for
///
/// The watch runs firmware that is built and published by hand, and it keeps moving as upstream
/// PebbleOS does. Without this screen, getting a new build onto a watch means a laptop, a cable
/// and a toolchain. With it, the whole job is: see that there is a new build, read what changed,
/// and hand the file to the app that can flash it.
///
/// ## What it can and cannot know
///
/// Two honest gaps shape every word here, and neither is fixable from this app:
///
/// - **It does not know what is installed.** The audio-companion service carries a firmware
///   version field, and the firmware never fills it in
///   (`audio_companion_fill_info()` leaves `fw_version_packed` zero), so the app reads 0 and the
///   Watch screen's Firmware row stays hidden. The screen therefore *offers* rather than
///   *recommends*: a release is shown with its version and date, and the person — who knows what
///   they last flashed — decides. When this app has handed a build over before, that is shown
///   too, labelled as what it is.
/// - **It does not know what happened after the hand-off.** iOS reports which app was chosen and
///   nothing else. So the screen says "sent", never "installed".
///
/// ## Order of the screen
///
/// The available build first, because that is the question that brought someone here; what this
/// app knows about the watch second, because it is context, and thin context at that.
///
/// The screen is only reachable when a feed is configured — see `isReachable`.
struct SettingsFirmwareScreen: View {
    @State private var model = FirmwareUpdateModel(
        watchReportedVersion: { SettingsDataSources.current.watch.firmwareVersion }
    )

    /// Set between the consent dialog and the Open In menu.
    @State private var consentingTo: FirmwareRelease?
    @State private var showOpenInMenu = false
    @State private var showFilesExport = false
    @State private var showNoOpenerAlert = false
    /// The one-line result of the last hand-off. Cleared by any new action, so it can never
    /// describe something that is no longer true.
    @State private var handoffNote: String?

    /// Whether Settings should draw a row leading here.
    ///
    /// Nothing is published yet, so in a release build this is false and the row does not exist:
    /// a screen that could only ever report a failing feed would read as the app being broken.
    /// A development build always shows it so the screen is reachable while it is being worked
    /// on — with no feed it says so calmly and does nothing.
    static var isReachable: Bool {
        #if DEBUG
            return true
        #else
            return FirmwareFeedSource.isConfigured()
        #endif
    }

    /// The asset the guide's first step should link to, when there is one to offer. Nil in every
    /// other state — no feed configured, still checking, failed, or nothing published — and the
    /// guide then says builds are not published yet rather than offering a dead link.
    private var offeredAssetURL: URL? {
        guard case .loaded(let availability, _, _) = model.check else { return nil }
        return availability.release?.assetURL
    }

    var body: some View {
        // Headers and cards are siblings of the scroll's own stack, not nested inside grouping
        // properties: `SettingsScroll` spaces its direct children by `Tokens.blockGap`, and a
        // property returning a header plus a card would collapse to one child and lose the gap.
        SettingsScroll {
            SettingsSectionHeader(title: Copy.Firmware.availableHeading)
            availableCard
                // Anchored to the card that raises it. Attached to `SettingsScroll` the source
                // rect is the whole screen and iOS 26 places the panel against the top of it,
                // far from the Hand Off button that was tapped — and this dialog hands straight
                // on to the Open In menu, which is anchored to that button, so the two used to
                // appear at opposite ends of the screen. Same fix as `SettingsWatchScreen` and
                // `SettingsStorageScreen`.
                .confirmationDialog(
                    Copy.Firmware.consentTitle,
                    isPresented: Binding(
                        get: { consentingTo != nil }, set: { if !$0 { consentingTo = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: consentingTo
                ) { _ in
                    Button(Copy.Firmware.consentConfirm) {
                        Haptics.impact(.medium)
                        // After the dialog's own dismissal animation, not during it. The Open In
                        // menu is a UIKit presentation from this screen's view controller, and
                        // asking for one while the confirmation dialog is still on its way out
                        // is the classic "attempt to present while a presentation is in
                        // progress" — which fails silently and leaves a button that did nothing.
                        Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            showOpenInMenu = true
                        }
                    }
                } message: { _ in
                    Text(Copy.Firmware.consentMessage)
                }
            SettingsSectionHeader(title: Copy.Firmware.installedHeading)
            installedCard
            // The same four steps onboarding shows, from the same file — someone who reaches
            // this screen after setup should not have to remember what the flow told them once,
            // and two descriptions of one procedure would be two things to keep in step.
            // Passing the selected release turns its first step into a real link rather than
            // "builds are not published yet".
            SettingsSectionHeader(title: Copy.Firmware.howToHeading)
            FirmwareSetupGuide(releaseURL: offeredAssetURL)
            footer
        }
        .navigationTitle(Copy.Firmware.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .alert(Copy.Firmware.noOpenerTitle, isPresented: $showNoOpenerAlert) {
            Button(Copy.Common.done, role: .cancel) {}
        } message: {
            Text(Copy.Firmware.noOpenerMessage)
        }
        .firmwareFilesExport(
            isPresented: $showFilesExport,
            fileURL: model.download.verifiedFile,
            onOutcome: handle
        )
    }

    // MARK: - Available

    @ViewBuilder
    private var availableCard: some View {
        switch model.check {
        case .idle, .checking:
            Card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(Copy.Firmware.checking)
                        .font(AppFont.callout)
                        .foregroundStyle(Tokens.meta)
                }
            }
        case .failed(let failure):
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    noticeLine(Copy.Firmware.failure(failure), color: Tokens.attention)
                    Button(Copy.Firmware.checkAgain) { Task { await model.refresh() } }
                        .buttonStyle(.borderedTint)
                }
            }
        case .loaded(let availability, _, let fromCache):
            availabilityCard(availability, fromCache: fromCache)
        }
    }

    @ViewBuilder
    private func availabilityCard(
        _ availability: FirmwareAvailability, fromCache: Bool
    ) -> some View {
        switch availability {
        case .notConfigured:
            Card { noticeLine(Copy.Firmware.notConfigured, color: Tokens.meta) }
        case .noReleases:
            // No Check Again here: the footer already carries one for every loaded state, and
            // two identical buttons a thumb apart is a screen arguing with itself.
            Card { noticeLine(Copy.Firmware.noReleases, color: Tokens.meta) }
        case .available(let release), .update(let release, _),
            .upToDate(let release, _), .installedIsNewer(let release, _):
            releaseCard(release, standing: availability, fromCache: fromCache)
        }
    }

    /// The one card that matters: what the build is, what changed, and the two things you can
    /// do with it.
    private func releaseCard(
        _ release: FirmwareRelease, standing: FirmwareAvailability, fromCache: Bool
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(release.version.raw)
                        .font(AppFont.sectionTitle)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if standing.isUpdate {
                        Text(Copy.Firmware.rowUpdateAvailable)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Tokens.tintFill12))
                    }
                }

                // Board, date, size — the three facts someone checks before installing firmware.
                // The board is stated because this app cannot verify it: the watch tells us no
                // hardware id. The Pebble app does check it (`performSafetyChecks` refuses a
                // board mismatch), so a wrong build fails there rather than on the watch.
                Text(subtitleLine(release))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)

                if let standingNote = standingNote(standing) {
                    Text(standingNote)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.secondaryBody)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !release.notes.isEmpty {
                    hairline
                    // Verbatim, never parsed or trimmed: the notes are the one thing on this
                    // screen the person reads to decide, and this app has no business
                    // editorialising a firmware changelog.
                    Text(release.notes)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.secondaryBody)
                        .fixedSize(horizontal: false, vertical: true)
                }

                hairline
                actions(for: release)

                if fromCache {
                    Text(Copy.Firmware.offlineNote)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Dropping a release this app cannot vouch for is right; doing it silently is
                // not — the list would just look shorter than it is.
                if model.feedRejectedCount > 0 {
                    Text(Copy.Firmware.partiallyUnreadable(model.feedRejectedCount))
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func subtitleLine(_ release: FirmwareRelease) -> String {
        var parts = [Copy.Firmware.forBoard(release.board)]
        if let publishedAt = release.publishedAt { parts.append(Copy.Firmware.published(publishedAt)) }
        if let size = release.sizeBytes { parts.append(Copy.Firmware.size(size)) }
        return parts.joined(separator: " · ")
    }

    /// The sentence that says where this build stands relative to the watch — including the
    /// case where the honest answer is "you decide".
    private func standingNote(_ standing: FirmwareAvailability) -> String? {
        switch standing {
        case .available: return Copy.Firmware.judgeForYourself
        case .upToDate: return Copy.Firmware.upToDate
        case .installedIsNewer: return Copy.Firmware.installedIsNewer
        case .update, .noReleases, .notConfigured: return nil
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(for release: FirmwareRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.download {
            case .idle:
                Button(Copy.Firmware.download) {
                    handoffNote = nil
                    model.startDownload()
                }
                .buttonStyle(.inCardFilled)

            case .downloading(let received, let total):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: fraction(received, total))
                        .tint(Tokens.tint)
                    HStack {
                        Text(Copy.Firmware.downloadProgress(received, total))
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                        Spacer(minLength: 8)
                        Button(Copy.Common.cancel) { model.cancelDownload() }
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.tint)
                    }
                }

            case .ready:
                // Downloaded AND verified — nothing reaches this state without matching the
                // published digest, which is the one guarantee worth stating out loud.
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tokens.good)
                        .accessibilityHidden(true)
                    Text(Copy.Firmware.downloaded)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                }
                Button(Copy.Firmware.handOff) {
                    handoffNote = nil
                    consentingTo = release
                }
                .buttonStyle(.inCardFilled)
                .firmwareOpenInMenu(
                    isPresented: $showOpenInMenu,
                    fileURL: model.download.verifiedFile,
                    onOutcome: handle
                )
                Button(Copy.Firmware.handOffFallback) { showFilesExport = true }
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.tint)
                    .accessibilityHint(Copy.Firmware.handOffFallbackHint)

            case .failed(let failure):
                noticeLine(Copy.Firmware.failure(failure), color: Tokens.attention)
                Button(Copy.Common.tryAgain) {
                    model.discardDownload()
                    model.startDownload()
                }
                .buttonStyle(.borderedTint)
            }

            if let handoffNote {
                Text(handoffNote)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.secondaryBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fraction(_ received: Int64, _ total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(received) / Double(total)))
    }

    /// One place where a hand-off is turned into a record and a sentence, so the two can never
    /// disagree. A dismissal records nothing: the person changed their mind.
    private func handle(_ outcome: FirmwareHandoffOutcome) {
        guard let release = model.availability?.release else { return }
        switch outcome {
        case .openedIn(let bundleIdentifier):
            model.recordHandoff(
                of: release, destination: .openedInApp, openedIn: bundleIdentifier
            )
            handoffNote = PebbleAppHandoff.isPebbleApp(bundleIdentifier)
                ? Copy.Firmware.sentToPebble
                : Copy.Firmware.sentElsewhere
        case .savedToFiles:
            model.recordHandoff(of: release, destination: .savedToFiles)
            handoffNote = Copy.Firmware.savedToFiles
        case .dismissed:
            break
        case .noOpener:
            showNoOpenerAlert = true
        }
    }

    // MARK: - What is on the watch

    /// A `Card`, not a `ListCard`: this is one fact plus the sentence explaining it, and a list
    /// card would draw a hairline between the value and its own explanation — making the
    /// explanation read as a second setting.
    private var installedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SettingsRow(
                    title: Copy.Settings.Watch.firmware,
                    value: installedValue,
                    valueColor: model.known?.isFromWatch == true ? Tokens.label : Tokens.meta,
                    showsChevron: false
                )
                // The reason the row above says "Not known", stated once rather than left to be
                // read as a bug in this app.
                if model.known == nil {
                    Text(Copy.Firmware.installedUnknownNote)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The hand-off memory carries its own disclaimer, because it is the one line on
                // this screen that could be mistaken for the watch's own word.
                if model.lastHandoff != nil, model.known?.isFromWatch != true {
                    Text(Copy.Firmware.handedOverNote)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(Copy.Firmware.forgetHandoff) {
                        model.forgetHandoff()
                        Task { await model.refresh() }
                    }
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tint)
                    .accessibilityHint(Copy.Firmware.forgetHandoffHint)
                }
            }
        }
    }

    private var installedValue: String {
        guard let known = model.known else { return Copy.Firmware.installedUnknown }
        switch known.source {
        case .watchReported:
            return Copy.Firmware.installedReported(known.version.raw)
        case .handedOff(let date):
            return Copy.Firmware.handedOver(known.version.raw, on: date)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if case .loaded(let availability, let checkedAt, _) = model.check,
            availability != .notConfigured
        {
            VStack(alignment: .leading, spacing: 10) {
                checkAgainButton
                SettingsFooter(text: Copy.Firmware.lastChecked(checkedAt))
            }
        }
    }

    private var checkAgainButton: some View {
        Button(Copy.Firmware.checkAgain) {
            handoffNote = nil
            Task { await model.refresh() }
        }
        .buttonStyle(.smallBordered)
    }

    /// The same 0.5pt rule `ListCard` draws between rows, for use inside a plain `Card`.
    private var hairline: some View {
        Rectangle().fill(Tokens.hairline).frame(height: 0.5)
    }

    private func noticeLine(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(color: color, size: .lifecycle)
                .padding(.top, 5)
            Text(text)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.secondaryBody)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Watch firmware") {
    NavigationStack {
        SettingsFirmwareScreen()
    }
    .tint(Tokens.tint)
}
