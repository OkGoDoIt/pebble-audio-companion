import CompanionRuntime
import Firmware
import SwiftUI
import UIKit

/// Settings › Watch › Pebble App Plugin. One card that answers, in order: what the plugin gives
/// (the lede), whether it is set up (a dot and a heading, at most one line under it), and what to
/// do next (Install in Pebble App, and the code to enter there).
///
/// Built from the Settings motifs already on these screens: the section header, a `Card` with the
/// Muse screen's dot-and-heading status, the in-card filled button for the step that resolves
/// the state, small bordered buttons for helpers, and the same hairline the Firmware screen draws
/// inside a card. The code is set in the code-box face the link screen uses for codes.
///
/// The header and the card are siblings, so `SettingsScroll` spaces them like every other section;
/// the work (`.task`, the scene check) hangs on the card alone, never on the pair.
struct WatchPluginSection: View {
    let model: PluginInstallModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var showOpenInMenu = false
    @State private var fileURL: URL?
    @State private var copied = false

    var body: some View {
        SettingsSectionHeader(title: Copy.PluginInstall.header)
        card
            .task { await model.run() }
            // Back from the Pebble app, where the code was just entered: ask at once.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refreshConnection() } }
            }
    }

    var card: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(Copy.PluginInstall.lede)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.secondaryBody)
                    .fixedSize(horizontal: false, vertical: true)
                status
                next
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Is it set up

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Copy.PluginInstall.checking)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.meta)
            }
        case .needsServer:
            heading(Copy.PluginInstall.notSetUp, line: Copy.PluginInstall.notSetUpLine, dot: Tokens.neutralDot)
        case .unreachable:
            heading(Copy.PluginInstall.unreachable, line: Copy.PluginInstall.unreachableLine, dot: Tokens.attention)
        case .notConnected:
            heading(Copy.PluginInstall.notConnected, line: nil, dot: Tokens.neutralDot)
        case .connected(let lastReadAtMs):
            heading(
                Copy.PluginInstall.connected,
                line: Copy.PluginInstall.lastRead(lastReadAtMs, nowMs: model.nowMs()),
                dot: Tokens.good)
        }
    }

    private func heading(_ text: String, line: String?, dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StatusDot(color: dot, size: .status)
                Text(text)
                    .font(AppFont.headline)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if let line {
                Text(line)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: What to do next

    @ViewBuilder
    private var next: some View {
        switch model.phase {
        case .checking:
            EmptyView()
        case .needsServer:
            NavigationLink(value: Route.settings(.server)) {
                Text(Copy.PluginInstall.linkServer)
            }
            .buttonStyle(.inCardFilled)
        case .unreachable:
            Button(Copy.Common.tryAgain) { Task { await model.retry() } }
                .buttonStyle(.smallBordered)
        case .notConnected:
            setup
        case .connected:
            if model.reconnecting {
                hairline
                setup
            } else {
                Button(Copy.PluginInstall.connectAgain) { Task { await model.connectAgain() } }
                    .buttonStyle(.smallBordered)
            }
        }
    }

    /// Install, then the code.
    @ViewBuilder
    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            installButton
            Text(handoffLine)
                .font(AppFont.footnote)
                .foregroundStyle(model.handoff == .noPebbleApp ? Tokens.attention : Tokens.meta)
                .fixedSize(horizontal: false, vertical: true)
        }
        hairline
        codeBlock
    }

    @ViewBuilder
    private var installButton: some View {
        let button = Button(Copy.PluginInstall.install, action: install).buttonStyle(.inCardFilled)
        #if DEBUG
        if PluginInstallDemo.rendersWithoutMenuAnchor {
            button
        } else {
            button.pebbleAppOpenInMenu(
                isPresented: $showOpenInMenu, fileURL: fileURL,
                typeIdentifier: PebbleAppHandoff.appTypeIdentifier, onOutcome: model.record)
        }
        #else
        button.pebbleAppOpenInMenu(
            isPresented: $showOpenInMenu, fileURL: fileURL,
            typeIdentifier: PebbleAppHandoff.appTypeIdentifier, onOutcome: model.record)
        #endif
    }

    private var handoffLine: String {
        switch model.handoff {
        case .none, .sentToPebble: return Copy.PluginInstall.turnOnPlugins
        case .sentElsewhere: return Copy.PluginInstall.sentElsewhere
        case .noPebbleApp: return Copy.PluginInstall.needsPebbleApp
        }
    }

    @ViewBuilder
    private var codeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                switch model.code {
                case .ready(let current):
                    codeText(current.code, live: true)
                    Spacer(minLength: 8)
                    Button(action: { copy(current.code) }) {
                        Label(
                            copied ? Copy.PluginInstall.copied : Copy.PluginInstall.copy,
                            systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.smallBordered)
                case .expired(let old):
                    codeText(old.code, live: false)
                    Spacer(minLength: 8)
                    Button(Copy.PluginInstall.newCode) { Task { await model.newCode() } }
                        .buttonStyle(.smallBordered)
                case .none, .loading:
                    ProgressView().controlSize(.small)
                    Text(Copy.PluginInstall.gettingCode)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                case .failed:
                    Text(Copy.PluginInstall.codeFailed)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.secondaryBody)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(Copy.Common.tryAgain) { Task { await model.newCode() } }
                        .buttonStyle(.smallBordered)
                }
            }
            switch model.code {
            case .ready(let current):
                enterLine
                Text(Copy.PluginInstall.worksUntil(current.expiresAtMs))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
            case .expired:
                enterLine
                Text(Copy.PluginInstall.expired)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
            case .none, .loading, .failed:
                EmptyView()
            }
        }
    }

    private var enterLine: some View {
        Text(Copy.PluginInstall.enterCode)
            .font(AppFont.footnote)
            .foregroundStyle(Tokens.secondaryBody)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func codeText(_ code: String, live: Bool) -> some View {
        Text(code)
            .font(AssistantFont.codeBox)
            .foregroundStyle(live ? Tokens.label : Tokens.faint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .textSelection(.enabled)
            .accessibilityLabel(Copy.PluginInstall.codeAccessibility(code))
            .speechSpellsOutCharacters()
    }

    /// The same 0.5 pt rule `ListCard` draws between rows, inside a plain `Card`.
    private var hairline: some View {
        Rectangle().fill(Tokens.hairline).frame(height: 0.5)
    }

    // MARK: Actions

    private func install() {
        Haptics.impact(.light)
        guard let url = model.preparePluginFile() else { return }
        fileURL = url
        showOpenInMenu = true
    }

    private func copy(_ code: String) {
        UIPasteboard.general.string = code
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
