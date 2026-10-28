import Firmware
import SwiftUI

/// Every string here comes from one enum, and the qualified name is longer than most values.
private typealias Install = Copy.FirmwareInstall

// The install screen: the offer (what it is, why it is safe, one button), then the wait for the
// watch. Chrome-free, so onboarding puts its back bar above it and the sheet its own title row.

struct FirmwareInstallView: View {
    @Bindable var model: FirmwareInstallModel
    @State private var showAbout = false
    @State private var showGuide = false

    var body: some View {
        VStack(spacing: 0) {
            // Centred while it fits; scrolls under large type or on a small phone.
            GeometryReader { proxy in
                ScrollView {
                    Group {
                        if model.stage == .waiting {
                            waiting
                        } else {
                            offer
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: proxy.size.height,
                        alignment: model.stage == .waiting ? .top : .center
                    )
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            if model.stage != .waiting {
                offerActions
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .padding(.top, 8)
            }
        }
        // Anchored to the whole screen: on iPhone the menu is a sheet and ignores it, and the
        // iPad popover then points at the screen it came from rather than at a moved button.
        .firmwareOpenInMenu(
            isPresented: $model.showMenu, fileURL: model.firmware.download.verifiedFile
        ) { outcome in
            model.handle(outcome)
        }
        .onChange(of: model.firmware.download) { model.downloadChanged() }
        .task { await model.prepare() }
        .alert(Copy.Firmware.noOpenerTitle, isPresented: $model.showNoOpener) {
            Button(Copy.Common.done, role: .cancel) {}
        } message: {
            Text(Copy.Firmware.noOpenerMessage)
        }
        .sheet(isPresented: $showAbout) {
            if let release = model.release { FirmwareAboutSheet(release: release) }
        }
        .sheet(isPresented: $showGuide) { FirmwareSetupGuideSheet(install: model) }
        .motionAware(.snappy(duration: 0.25), value: model.stage)
    }

    // MARK: Offer

    private var offer: some View {
        VStack(spacing: 0) {
            InstallHeroGlyph()
                .padding(.bottom, 18)
            // While the iOS menu covers the bottom half, the top of this screen is the one place
            // left to say which icon to tap.
            Text(model.stage == .choosing ? Install.chooseTitle : Install.title)
                .font(AppFont.screenTitle)
                .foregroundStyle(Tokens.label)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.stage == .choosing ? Install.chooseLine : Install.lede)
                .font(AppFont.bodyPlain)
                .foregroundStyle(Tokens.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
                .padding(.top, 10)

            ListCard {
                TrustRow(
                    symbol: "chevron.left.forwardslash.chevron.right",
                    title: Install.openSourceTitle, line: Install.openSourceLine
                )
                TrustRow(
                    symbol: "checkmark.shield",
                    title: Install.installerTitle, line: Install.installerLine
                )
                TrustRow(
                    symbol: "mic.slash",
                    title: Install.microphoneTitle, line: Install.microphoneLine
                )
            }
            .padding(.top, 24)

            if let release = model.release {
                Text(Install.buildLine(release))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                Button(Install.about) { showAbout = true }
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tint)
                    .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var offerActions: some View {
        VStack(spacing: 8) {
            if let problem = offerProblem {
                Text(problem)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.secondaryBody)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            primaryButton
            Button(Install.installMyself) { showGuide = true }
                .font(AppFont.bodyPlain)
                .foregroundStyle(Tokens.tint)
                .padding(8)
        }
    }

    /// One line above the button when the button cannot do its job as labelled.
    private var offerProblem: String? {
        if let failure = model.checkFailure { return Copy.Firmware.failure(failure) }
        if case .failed(let failure) = model.firmware.download {
            return Copy.Firmware.downloadFailure(failure)
        }
        if !model.isChecking, model.release == nil { return Install.noRelease }
        return nil
    }

    @ViewBuilder
    private var primaryButton: some View {
        if model.checkFailure != nil {
            Button(Copy.Common.tryAgain) { Task { await model.checkAgain() } }
                .buttonStyle(.primaryFilled)
        } else if model.isChecking {
            Button {} label: { busyLabel(Install.checking) }
                .buttonStyle(.primaryFilled)
                .disabled(true)
        } else if case .downloading(let received, let total) = model.firmware.download {
            Button {} label: { busyLabel(Copy.Firmware.downloadProgress(received, total)) }
                .buttonStyle(.primaryFilled)
                .accessibilityLabel(Copy.Firmware.downloadingUpdate)
        } else {
            Button(Install.install) { model.install() }
                .buttonStyle(.primaryFilled)
                .disabled(model.release == nil)
        }
    }

    private func busyLabel(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(Tokens.onTint)
            Text(text).monospacedDigit()
        }
    }

    // MARK: Waiting

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Install.waitingTitle)
                .font(AppFont.screenTitle)
                .foregroundStyle(Tokens.label)
                .fixedSize(horizontal: false, vertical: true)
            Text(Install.waitingLede)
                .font(AppFont.bodyPlain)
                .foregroundStyle(Tokens.tertiary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            ListCard {
                TrackerStep(
                    state: .done, number: 1, title: Install.stepDownloaded,
                    line: model.release.map(Install.stepDownloadedLine)
                )
                TrackerStep(
                    state: .now, number: 2, title: Install.stepInstalling,
                    line: model.sentElsewhere
                        ? Install.stepInstallingElsewhereLine : Install.stepInstallingLine
                ) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        StatusDot(color: Tokens.tint, size: .lifecycle)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(Install.waitingForRestart)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.tertiary)
                    }
                    .padding(.top, 6)
                }
                TrackerStep(
                    state: .later, number: 3, title: Install.stepAllow, line: Install.stepAllowLine
                )
            }
            .padding(.top, 22)

            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Install.notUpdatingTitle)
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)
                    Text(Install.notUpdatingLine)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.install()
                    } label: {
                        Label(Install.sendAgain, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedTint)
                    .disabled(model.firmware.download.isBusy)
                    .padding(.top, 8)
                }
            }
            .padding(.top, 12)
        }
    }
}

// MARK: - Pieces

/// The watch with a download badge: "something goes onto the watch".
private struct InstallHeroGlyph: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "applewatch")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Tokens.tint)
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Tokens.onTint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Tokens.tint))
                .background(Circle().fill(Tokens.ground).padding(-3))
                .offset(x: 8, y: 2)
        }
        .frame(height: 72)
        .accessibilityHidden(true)
    }
}

/// One reason it is safe to say yes.
private struct TrustRow: View {
    let symbol: String
    let title: String
    let line: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.tintFill12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.cardHead)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(line)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One step of the install, as far as this app can see it: done, happening, or still to come.
private struct TrackerStep<Accessory: View>: View {
    enum State { case done, now, later }

    let state: State
    let number: Int
    let title: String
    let line: String?
    @ViewBuilder var accessory: Accessory

    init(
        state: State, number: Int, title: String, line: String?,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.state = state
        self.number = number
        self.title = title
        self.line = line
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(state == .later ? AppFont.callout : AppFont.headline)
                    .foregroundStyle(state == .later ? Tokens.tertiary : Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let line {
                    Text(line)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                accessory
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Tokens.onTint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Tokens.good))
        case .now:
            Text("\(number)")
                .font(AppFont.cardHead)
                .foregroundStyle(Tokens.onTint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Tokens.tint))
                .background(Circle().fill(Tokens.tintFill12).padding(-5))
        case .later:
            Text("\(number)")
                .font(AppFont.cardHead)
                .foregroundStyle(Tokens.meta)
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(Tokens.chevron, lineWidth: 1.5))
        }
    }
}

// MARK: - About this firmware

/// The detail behind the three reasons, for anyone who wants it. Every line is something the
/// release feed or the official app's own behaviour backs.
struct FirmwareAboutSheet: View {
    let release: FirmwareRelease
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SheetTitleRow(title: Install.about) {
                    Button(Copy.Common.done) { dismiss() }
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.tint)
                        .buttonStyle(.plain)
                }
                .padding(.bottom, 4)

                ListCard {
                    fact(Install.aboutVersion, release.version.label)
                    fact(Install.aboutFor, release.board.displayName ?? release.board.id)
                    if let published = release.publishedAt {
                        fact(Install.aboutPublished, Install.publishedDate(published))
                    }
                    if let size = release.sizeBytes {
                        fact(Install.aboutSize, Copy.Firmware.size(size))
                    }
                }

                section(Install.aboutAddsHeading, Install.aboutAdds)
                section(Install.aboutSourceHeading, Install.aboutSource) {
                    if let page = release.releasePageURL {
                        Link(Install.aboutSourceLink, destination: page)
                            .font(AppFont.subBody)
                            .foregroundStyle(Tokens.tint)
                            .padding(.top, 6)
                    }
                }
                section(Install.aboutOfficialHeading, Install.aboutOfficial)
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(Tokens.ground)
        .presentationDetents([.large])
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(AppFont.callout)
                .foregroundStyle(Tokens.label)
            Spacer(minLength: 8)
            Text(value)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.meta)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func section<Extra: View>(
        _ heading: String, _ text: String, @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: heading)
                .padding(.horizontal, 4)
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.secondaryBody)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    extra()
                }
            }
        }
    }
}

// MARK: - From Today and Settings → Watch

/// The same install for a watch that has lost the audio firmware — an official update replaced
/// it — or carries one too old for this app. Closes itself once the watch comes back offering
/// the audio service.
struct FirmwareInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = FirmwareInstallModel()

    private var watch: any WatchStatusSource { SettingsDataSources.current.watch }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(model.hasSent ? Copy.Common.done : Copy.Common.cancel) { dismiss() }
                    .font(AppFont.headline)
                    .foregroundStyle(Tokens.tint)
                    .buttonStyle(.plain)
                    .padding(.vertical, 12)
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.top, 8)

            FirmwareInstallView(model: model)
        }
        .background(Tokens.ground)
        .onChange(of: watch.needsAudioFirmware) { _, needs in
            if !needs, model.hasSent { dismiss() }
        }
        // While the watch restarts into the new build, ask for it now and then — only while
        // this sheet is on screen and the app in front. The link's own backoff would find it
        // too, up to two minutes later.
        .task(id: model.hasSent && scenePhase == .active) {
            guard model.hasSent, scenePhase == .active else { return }
            while !Task.isCancelled {
                watch.findWatch()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}
