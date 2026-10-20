import CompanionRuntime
import SwiftUI

/// Settings › AI Assistants (round 3: 02, 07a, 07c, 07e). The person's own Pebble Audio server
/// holds the text of their conversations so the assistants they connect can read it.
///
/// Before linking, the screen answers what this is for, what it takes, and exactly what would go
/// where, then offers the one next step. Once linked, in order: is it syncing (and the switch),
/// who can read, what goes to the server and how far back, what assistants may also do, and the
/// way out, which deletes the server's copy. The setup steps (Link · Choose · Connect) push from
/// here and pop back here when done.
struct SettingsServerScreen: View {
    private var source: AssistantsSource { SettingsDataSources.current.assistants }

    @State private var confirmUnlink = false
    @State private var unlinkError: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var flow = source.flow
        AssistantScroll {
            if source.sync.isLinked, source.sync.setupComplete {
                linkedContent
            } else {
                introContent
            }
        }
        .navigationTitle(Copy.AssistantAccess.title)
        .navigationBarTitleDisplayMode(.large)
        // The source watches the sync, and asks the server who can read, only while this screen
        // is on screen and the app is in front.
        .onAppear {
            source.startObserving()
            if flow.demoConfirmUnlink {
                flow.demoConfirmUnlink = false
                confirmUnlink = true
            }
        }
        .onDisappear { source.stopObserving() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await source.loadCounts()
            await source.refreshServerStatus()
        }
        .navigationDestination(isPresented: $flow.showLink) { AssistantsLinkScreen() }
        .navigationDestination(isPresented: $flow.showChooseDirect) { AssistantsChooseScreen() }
        .navigationDestination(isPresented: $flow.showConnectOnly) { AssistantsConnectScreen(inSetup: false) }
        .navigationDestination(isPresented: $flow.showScope) { AssistantsScopeScreen() }
        .navigationDestination(item: $flow.detailAccessId) { id in AssistantDetailScreen(accessId: id) }
        .assistantConfirm(
            isPresented: $confirmUnlink, title: Copy.AssistantAccess.unlinkTitle,
            message: Copy.AssistantAccess.unlinkMessage(
                count: serverConversationCount, host: source.host ?? AssistantsDemo.host,
                assistants: source.assistants.map(\.name)),
            confirmTitle: Copy.AssistantAccess.unlinkConfirm, onConfirm: unlink)
    }

    // MARK: Before linking (02), and linked but not yet chosen

    @ViewBuilder
    private var introContent: some View {
        AssistantCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Tokens.tint)
                    .frame(width: 44, height: 44)
                    .background(Tokens.tintFill12, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Copy.AssistantAccess.introHeading)
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Copy.AssistantAccess.introLine)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.secondaryBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                needRow("server.rack", Copy.AssistantAccess.needServer)
                needRow("macwindow", Copy.AssistantAccess.needBrowser)
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Tokens.hairline).frame(height: 0.5) }
            .padding(.top, 12)
        }

        AssistantCard {
            if source.sync.isLinked, let host = source.host {
                AssistantStateHead(
                    dot: Tokens.neutralDot, heading: Copy.AssistantAccess.linkedHeading(host),
                    line: Copy.AssistantAccess.offLine, size: .big, smallLine: false)
            } else {
                AssistantStateHead(
                    dot: Tokens.neutralDot, heading: Copy.AssistantAccess.offHeading,
                    line: source.unlinkNote ?? Copy.AssistantAccess.offLine, size: .big,
                    smallLine: false)
            }
            AssistantGoesBlock(
                heading: Copy.AssistantAccess.whatGoesToYourServer,
                paragraphs: [Copy.AssistantAccess.introGoesText, Copy.AssistantAccess.introGoesAssistants])
                .padding(.top, 14)
            if source.sync.isLinked {
                Button(Copy.AssistantAccess.chooseWhatSyncs) { source.flow.showChooseDirect = true }
                    .buttonStyle(.assistantFilled)
                    .padding(.top, 14)
            } else {
                Button(Copy.AssistantAccess.linkYourServer) { source.flow.startLink() }
                    .buttonStyle(.assistantFilled)
                    .padding(.top, 14)
            }
        }
    }

    private func needRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Tokens.tertiary)
                .frame(width: 17)
                .accessibilityHidden(true)
            Text(text)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.secondaryBody)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Linked (07a, 07e)

    @ViewBuilder
    private var linkedContent: some View {
        let status = source.status
        AssistantList {
            statusHead
                .padding(.top, 6)
                .padding(.bottom, 4)
            if case .revoked = status.link {
                Button(Copy.AssistantAccess.linkAgain) { source.flow.startLink(server: source.host ?? "") }
                    .buttonStyle(.assistantFilled)
            } else {
                AssistantToggleRow(
                    title: Copy.AssistantAccess.syncToggle,
                    isOn: Binding(get: { source.sync.enabled }, set: { source.setEnabled($0) }))
            }
        }

        AssistantSectionHeader(title: Copy.AssistantAccess.whoCanRead)
        AssistantList {
            if source.assistants.isEmpty {
                Text(Copy.AssistantAccess.noAssistantYet)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.tertiary)
            }
            ForEach(source.assistants) { access in
                Button {
                    source.flow.detailAccessId = access.id
                } label: {
                    accessRow(access)
                }
                .buttonStyle(.plain)
            }
            Button {
                source.flow.showConnectOnly = true
            } label: {
                HStack(spacing: 12) {
                    GlyphTile(systemName: "plus", style: .own)
                    Text(Copy.AssistantAccess.connectAnother)
                        .font(AppFont.bodyPlain)
                        .foregroundStyle(Tokens.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        if let host = source.host {
            AssistantSectionHeader(title: Copy.AssistantAccess.whatGoesTo(host))
        }
        AssistantList {
            VStack(alignment: .leading, spacing: 8) {
                if source.sync.enabled {
                    Text(
                        Copy.AssistantAccess.linkedGoesLine(
                            count: phoneConversationCount, scope: source.sync.preferences.scope,
                            clips: source.sync.preferences.clips))
                    Text(Copy.AssistantAccess.deletesTooLine)
                } else {
                    Text(Copy.AssistantAccess.pausedGoesLine(count: serverConversationCount ?? phoneConversationCount))
                }
            }
            .font(AppFont.subBody)
            .foregroundStyle(Tokens.secondaryBody)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)
            .padding(.bottom, 2)
            Button {
                source.flow.showScope = true
            } label: {
                AssistantNavRowLabel(
                    title: Copy.AssistantAccess.conversationsRow,
                    value: Copy.AssistantAccess.scopeLabel(source.sync.preferences.scope))
            }
            .buttonStyle(.plain)
        }
        if let footer = scopeFooter {
            AssistantFooter(text: footer)
        }

        AssistantSectionHeader(title: Copy.AssistantAccess.mayAlso)
        AssistantMayAlso(
            preferences: source.sync.preferences, set: { source.setPreferences($0) })

        AssistantList {
            Button {
                unlinkError = nil
                confirmUnlink = true
            } label: {
                Text(Copy.AssistantAccess.unlinkRow)
                    .font(AppFont.bodyPlain)
                    .foregroundStyle(Tokens.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(source.isWorking)
        }
        .padding(.top, 8)
        if let unlinkError {
            AssistantFooter(text: unlinkError, color: Tokens.attention)
        }
    }

    private var statusHead: some View {
        let status = source.status
        let host = source.host ?? ""
        let (dot, heading, line): (Color, String, String) = {
            if case .revoked = status.link {
                return (Tokens.attention, Copy.AssistantAccess.revokedHeading, Copy.AssistantAccess.revokedLine)
            }
            if status.appTooOld {
                return (Tokens.attention, Copy.AssistantAccess.tooOldHeading, Copy.AssistantAccess.tooOldLine(host))
            }
            if !source.sync.enabled {
                return (Tokens.neutralDot, Copy.AssistantAccess.pausedHeading, Copy.AssistantAccess.pausedLine)
            }
            let heading = Copy.AssistantAccess.syncingHeading(host)
            if status.wipePending { return (Tokens.good, heading, Copy.AssistantAccess.wipePendingLine) }
            if status.lastError != nil, status.pending > 0 {
                return (Tokens.attention, heading, Copy.AssistantAccess.retryingLine)
            }
            guard let last = status.lastBatchAtMs else {
                return (Tokens.good, heading, Copy.AssistantAccess.firstSyncLine)
            }
            return (Tokens.good, heading, Copy.AssistantAccess.lastSyncedLine(AssistantTime.synced(last, nowMs: source.nowMs)))
        }()
        return AssistantStateHead(dot: dot, heading: heading, line: line)
    }

    private func accessRow(_ access: ArchiveServerStatus.Access) -> some View {
        let mayDo = Copy.AssistantAccess.mayDo(
            clips: source.sync.preferences.clips,
            add: source.sync.preferences.edits && access.canWrite)
        let lastRead = access.lastUsedAtMs.map {
            Copy.AssistantAccess.lastRead(AssistantTime.ago($0, nowMs: source.nowMs))
        } ?? Copy.AssistantAccess.notReadYet
        return HStack(spacing: 12) {
            BrandTile(mark: BrandMark.forAssistant(named: access.name))
            VStack(alignment: .leading, spacing: 2) {
                Text(access.name)
                    .font(AppFont.rowTitle)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Copy.AssistantAccess.accessLine(mayDo, lastRead: lastRead))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AssistantChevron()
        }
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var phoneConversationCount: Int {
        source.counts?.count(source.sync.preferences.scope, nowMs: source.nowMs)
            ?? source.status.server?.counts["conversation"] ?? 0
    }

    private var serverConversationCount: Int? { source.status.server?.counts["conversation"] }

    private var scopeFooter: String? {
        switch source.sync.preferences.scope {
        case .all: return Copy.AssistantAccess.keepAudioLine
        case .since: return nil
        case .lastDays(let days): return Copy.AssistantAccess.rollingLine(days)
        }
    }

    private func unlink() {
        Task {
            switch await source.unlink() {
            case .deleted, .alreadyUnlinked: unlinkError = nil
            case .unreachable: unlinkError = Copy.AssistantAccess.unlinkUnreachable
            case .refused: unlinkError = Copy.AssistantAccess.unlinkRefused
            }
        }
    }
}

/// "What goes to …": the block every destination shows before the button that starts it.
struct AssistantGoesBlock: View {
    let heading: String
    let paragraphs: [String]
    var background: Color = Tokens.inset

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(AppFont.cardHead)
                .foregroundStyle(Tokens.label)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.secondaryBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// "Assistants may also": clips and edits, both off until switched on.
struct AssistantMayAlso: View {
    let preferences: ArchivePreferences
    let set: (ArchivePreferences) -> Void

    var body: some View {
        AssistantList {
            AssistantToggleRow(
                title: Copy.AssistantAccess.clipsTitle, subtitle: Copy.AssistantAccess.clipsLine,
                isOn: Binding(
                    get: { preferences.clips },
                    set: { value in
                        var next = preferences
                        next.clips = value
                        set(next)
                    }))
            AssistantToggleRow(
                title: Copy.AssistantAccess.editsTitle, subtitle: Copy.AssistantAccess.editsLine,
                isOn: Binding(
                    get: { preferences.edits },
                    set: { value in
                        var next = preferences
                        next.edits = value
                        set(next)
                    }))
        }
    }
}

#Preview("AI Assistants") {
    NavigationStack {
        SettingsServerScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
