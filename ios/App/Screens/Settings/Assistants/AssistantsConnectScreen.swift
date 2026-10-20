import CompanionRuntime
import SwiftUI
import UIKit

/// Step 3 of 3, Connect (round 3: 05a–05e), and Connect Another Assistant later. Each assistant
/// is connected in its own app; this screen says exactly what to do there, opens the right place,
/// and turns a card into a green check once the server lists that assistant as able to read.
/// It asks the server only while it is on screen and the app is in front.
struct AssistantsConnectScreen: View {
    let inSetup: Bool

    private var source: AssistantsSource { SettingsDataSources.current.assistants }

    @State private var open: ConnectCard?
    @State private var macTool: MacTool?
    @State private var copied = false
    @State private var decidedOpen = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private static let pollSeconds = 4.0

    var body: some View {
        AssistantScroll(bottom: 34) {
            if inSetup { SetupStepBar(now: 2) }
            Text(inSetup ? Copy.AssistantAccess.connectTitle : Copy.AssistantAccess.connectAnotherTitle)
                .font(AppFont.screenTitle)
                .kerning(0.36)
                .foregroundStyle(Tokens.label)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
            Text(Copy.AssistantAccess.connectLede)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.secondaryBody)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -4)
            addressCard
            AssistantList(minRowHeight: 0) {
                ForEach(rows, id: \.self) { row in
                    rowView(row)
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(inSetup ? Copy.AssistantAccess.connectTitle : Copy.AssistantAccess.connectAnotherTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            ToolbarItem(placement: .confirmationAction) {
                Button(Copy.AssistantAccess.done) { source.flow.finish() }
                    .font(AssistantFont.pill)
            }
        }
        .onAppear(perform: decideOpen)
        // Polled only while on screen and in front: the task ends with the screen, and a
        // backgrounded app re-runs it only when it comes back.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await source.refreshServerStatus()
                try? await Task.sleep(for: .seconds(Self.pollSeconds))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: connectedIds)
    }

    // MARK: The address

    private var addressCard: some View {
        AssistantList {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.AssistantAccess.serverAddress)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.tertiary)
                    Text(source.host ?? "")
                        .font(AppFont.rowTitle)
                        .foregroundStyle(Tokens.label)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: copyAddress) {
                    AssistantButtonLabel(
                        title: copied ? Copy.AssistantAccess.copied : Copy.AssistantAccess.copy,
                        systemImage: copied ? "checkmark" : "doc.on.doc", small: true)
                }
                .buttonStyle(.assistantSmall)
            }
        }
    }

    // MARK: The cards

    enum Row: Hashable {
        case chatGPT, claude, mac([MacTool]), other
        case connected(id: String)
    }

    private var connected: [ArchiveServerStatus.Access] { source.assistants }
    private var connectedIds: [String] { connected.map(\.id) }

    private func access(for mark: BrandMark) -> ArchiveServerStatus.Access? {
        connected.first { BrandMark.forAssistant(named: $0.name) == mark }
    }

    /// ChatGPT and Claude always have a card; each Mac tool that connected becomes its own row
    /// and the rest share one card; anything else connected sits above "Another assistant".
    var rows: [Row] {
        var out: [Row] = [.chatGPT, .claude]
        let macConnected = MacTool.allCases.compactMap { tool in access(for: tool.mark).map { (tool, $0) } }
        out += macConnected.map { .connected(id: $0.1.id) }
        let remaining = MacTool.allCases.filter { tool in !macConnected.contains { $0.0 == tool } }
        if !remaining.isEmpty { out.append(.mac(remaining)) }
        let known: Set<BrandMark> = [.chatgpt, .claude, .codex, .claudeCode, .cursor]
        out += connected.filter { !known.contains(BrandMark.forAssistant(named: $0.name)) }
            .map { .connected(id: $0.id) }
        out.append(.other)
        return out
    }

    private func decideOpen() {
        guard !decidedOpen else { return }
        decidedOpen = true
        if let demo = source.flow.demoOpenCard {
            open = demo
            macTool = source.flow.demoMacTool
            source.flow.demoOpenCard = nil
            source.flow.demoMacTool = nil
            return
        }
        // The first one not connected yet.
        if access(for: .chatgpt) == nil { open = .chatGPT }
        else if access(for: .claude) == nil { open = .claude }
        else { open = .mac }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .chatGPT:
            card(.chatGPT, tile: AnyView(BrandTile(mark: .chatgpt)), name: Copy.AssistantAccess.chatGPT,
                 access: access(for: .chatgpt)) { chatGPTSteps }
        case .claude:
            card(.claude, tile: AnyView(BrandTile(mark: .claude)), name: Copy.AssistantAccess.claude,
                 access: access(for: .claude)) { claudeSteps }
        case .mac(let tools):
            card(.mac, tile: AnyView(FolderTile(marks: tools.map(\.mark))),
                 name: Copy.AssistantAccess.macTitle(tools.map(\.name)),
                 subtitle: Copy.AssistantAccess.macSubtitle, access: nil) { macSteps(tools) }
        case .other:
            card(.other, tile: AnyView(FolderTile(marks: [.gemini], more: true)),
                 name: Copy.AssistantAccess.otherTitle, subtitle: Copy.AssistantAccess.otherSubtitle,
                 access: nil) { otherSteps }
        case .connected(let id):
            if let access = connected.first(where: { $0.id == id }) {
                head(tile: AnyView(BrandTile(mark: BrandMark.forAssistant(named: access.name))),
                     name: access.name, subtitle: connectedLine(access), state: .done)
            }
        }
    }

    private enum HeadState { case open, closed, done }

    private func connectedLine(_ access: ArchiveServerStatus.Access) -> String {
        guard let at = access.connectedAtMs else { return Copy.AssistantAccess.connectedAccessibility }
        return Copy.AssistantAccess.connected(AssistantTime.connected(at, nowMs: source.nowMs))
    }

    private func card<Steps: View>(
        _ id: ConnectCard, tile: AnyView, name: String, subtitle: String? = nil,
        access: ArchiveServerStatus.Access?, @ViewBuilder steps: () -> Steps
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let access {
                head(tile: tile, name: name, subtitle: connectedLine(access), state: .done)
            } else {
                Button {
                    open = open == id ? nil : id
                } label: {
                    head(tile: tile, name: name, subtitle: subtitle ?? Copy.AssistantAccess.notConnected,
                         state: open == id ? .open : .closed)
                }
                .buttonStyle(.plain)
                .accessibilityHint(open == id ? "" : name)
                if open == id {
                    VStack(alignment: .leading, spacing: 12) { steps() }
                        .padding(.leading, 46)
                        .padding(.bottom, 16)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func head(tile: AnyView, name: String, subtitle: String, state: HeadState) -> some View {
        HStack(spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(AppFont.rowTitle)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch state {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Tokens.good, in: Circle())
                    .accessibilityLabel(Copy.AssistantAccess.connectedAccessibility)
            case .open, .closed:
                Image(systemName: state == .open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.meta)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 42)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(state == .done ? [] : .isButton)
    }

    // MARK: What to do in each app

    private var chatGPTSteps: some View {
        Group {
            StepList(steps: Copy.AssistantAccess.chatGPTSteps)
            fullWidthButton {
                Button(Copy.AssistantAccess.chatGPTButton) {
                    copyAddress()
                    if let url = URL(string: "https://chatgpt.com") { openURL(url) }
                }
                .buttonStyle(.assistantFilled)
            }
        }
    }

    private var claudeSteps: some View {
        Group {
            StepList(steps: Copy.AssistantAccess.claudeSteps)
            fullWidthButton {
                Button {
                    if let url = claudeURL { openURL(url) }
                } label: {
                    AssistantButtonLabel(title: Copy.AssistantAccess.claudeButton, systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.assistantFilled)
            }
            Text(AttributedString.boldMarked(Copy.AssistantAccess.claudeAlt, bold: Tokens.secondaryBody))
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.tertiary)
                .tint(Tokens.secondaryBody)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func macSteps(_ tools: [MacTool]) -> some View {
        let tool = macTool.flatMap { tools.contains($0) ? $0 : nil } ?? tools[0]
        return Group {
            if tools.count > 1 {
                AssistantSegmented(
                    values: tools, label: \.name,
                    selection: Binding(get: { tool }, set: { macTool = $0 }), small: true,
                    accessibilityName: Copy.AssistantAccess.appAccessibility)
            }
            StepList(steps: Copy.AssistantAccess.macSteps(tool.name, cursor: tool == .cursor))
            fullWidthButton {
                Button {
                    if let url = setupURL(tool) { openURL(url) }
                } label: {
                    AssistantButtonLabel(title: Copy.AssistantAccess.openSetupInSafari, systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.assistantFilled)
            }
            fullWidthButton {
                Text(Copy.AssistantAccess.macAlt(source.host ?? ""))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var otherSteps: some View {
        Group {
            StepList(steps: Copy.AssistantAccess.otherSteps)
            fullWidthButton {
                Button(action: copyAddress) {
                    AssistantButtonLabel(
                        title: copied ? Copy.AssistantAccess.copied : Copy.AssistantAccess.copyAddress,
                        systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.assistantBordered)
            }
        }
    }

    /// A button under the steps spans the card from the tile's edge, as the mockups draw it.
    private func fullWidthButton<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(.leading, -46)
    }

    // MARK: Addresses

    private var origin: URL? { source.sync.origin.flatMap(URL.init(string:)) }

    /// `https://claude.ai/customize/connectors?…` with the server filled in (connect-commands.md).
    var claudeURL: URL? {
        guard let connector = source.connectorURL else { return nil }
        var components = URLComponents(string: "https://claude.ai/customize/connectors")
        components?.queryItems = [
            .init(name: "modal", value: "add-custom-connector"),
            .init(name: "connectorName", value: "Pebble Audio"),
            .init(name: "connectorUrl", value: connector),
        ]
        return components?.url
    }

    /// The server's own setup page for one Mac tool, opened in Safari.
    func setupURL(_ tool: MacTool) -> URL? {
        guard let origin else { return nil }
        return ArchiveEndpoint.url(origin, "/connect/\(tool.rawValue)")
    }

    private func copyAddress() {
        guard let address = source.connectorURL else { return }
        UIPasteboard.general.string = address
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// A numbered list of what to do in another app: 22 pt tinted numbers, the app's own labels in
/// bold.
struct StepList: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Tokens.tint)
                        .frame(width: 22, height: 22)
                        .background(Tokens.tintFill12, in: Circle())
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
                        .accessibilityHidden(true)
                    Text(AttributedString.boldMarked(step))
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.secondaryBody)
                        .tint(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(index + 1). \(step.replacingOccurrences(of: "**", with: ""))")
            }
        }
    }
}
