import CompanionRuntime
import StatusUI
import SwiftUI

/// Settings · Pebble Audio server: link this phone to the person's own server, see that it is
/// syncing and what it shares, and what assistants have read there.
///
/// The questions, in order: is this phone linked, and is it working? What goes there? What did
/// an assistant read? Then the two actions: sync now, unlink. Linking is the whole screen until
/// it is done — there is nothing else to show a phone that is not linked.
struct SettingsServerScreen: View {
    private var source: ArchiveServerSource { SettingsDataSources.current.server }
    private var status: ArchiveSyncStatus { source.status }

    @State private var serverText = ""
    @State private var codeText = ""
    @FocusState private var focused: Field?

    private enum Field { case server, code }

    var body: some View {
        SettingsScroll {
            if let invitation = source.pendingInvitation {
                invitationCard(invitation)
            }
            switch status.link {
            case .notLinked:
                stateCard(
                    heading: Copy.ArchiveServer.notLinkedHeading,
                    line: Copy.ArchiveServer.notLinkedLine, dot: Tokens.neutralDot)
                linkForm
            case .revoked(let host):
                stateCard(
                    heading: Copy.ArchiveServer.revokedHeading,
                    line: Copy.ArchiveServer.revokedLine(host), dot: Tokens.attention)
                linkForm
                unlinkCard(host)
            case .linked(let host):
                linkedState(host)
                sharedCard(host)
                statusCard
                aiReadCard
                unlinkCard(host)
            }
        }
        .navigationTitle(Copy.ArchiveServer.title)
        .navigationBarTitleDisplayMode(.inline)
        // The source watches the sync only while this screen is on screen.
        .onAppear { source.startObserving() }
        .onDisappear { source.stopObserving() }
    }

    // MARK: State

    private func stateCard(heading: String, line: String, dot: Color) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(color: dot, size: .lifecycle)
                    Text(heading)
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(line)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.secondaryBody)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func linkedState(_ host: String) -> some View {
        if status.appTooOld {
            stateCard(
                heading: Copy.ArchiveServer.tooOldHeading,
                line: Copy.ArchiveServer.tooOldLine(host), dot: Tokens.attention)
        } else if !status.enabled {
            stateCard(
                heading: Copy.ArchiveServer.pausedHeading, line: Copy.ArchiveServer.pausedLine,
                dot: Tokens.neutralDot)
        } else {
            stateCard(
                heading: Copy.ArchiveServer.linkedHeading(host),
                line: Copy.ArchiveServer.linkedLine, dot: Tokens.good)
        }
        ListCard {
            HStack(spacing: 12) {
                Text(Copy.ArchiveServer.syncToggle)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                Spacer(minLength: 10)
                Toggle(
                    Copy.ArchiveServer.syncToggle,
                    isOn: Binding(get: { status.enabled }, set: { source.setEnabled($0) })
                )
                .labelsHidden()
                .tint(Tokens.good)
            }
        }
    }

    // MARK: Linking

    private func invitationCard(_ invitation: ArchiveLinkInvitation) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Copy.ArchiveServer.invitationHeading(invitation.host))
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Copy.ArchiveServer.invitationLine)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.secondaryBody)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button(Copy.ArchiveServer.invitationLink) { source.confirmInvitation() }
                        .buttonStyle(.inCardFilled)
                        .disabled(source.isWorking)
                    Button(Copy.ArchiveServer.invitationCancel) { source.dismissInvitation() }
                        .buttonStyle(.borderedTint)
                }
            }
        }
    }

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    field(
                        Copy.ArchiveServer.serverField, placeholder: Copy.ArchiveServer.serverPlaceholder,
                        text: $serverText, which: .server
                    )
                    .keyboardType(.URL)
                    field(
                        Copy.ArchiveServer.codeField, placeholder: Copy.ArchiveServer.codePlaceholder,
                        text: $codeText, which: .code
                    )
                    .textInputAutocapitalization(.characters)
                    Button(Copy.ArchiveServer.linkButton, action: link)
                        .buttonStyle(.inCardFilled)
                        .opacity(canLink ? 1 : 0.5)
                        .disabled(!canLink)
                    if source.isWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(Copy.ArchiveServer.linking)
                                .font(AppFont.footnote)
                                .foregroundStyle(Tokens.meta)
                        }
                    }
                    if let error = source.linkError {
                        Text(error)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SettingsFooter(text: Copy.ArchiveServer.linkFooter)
        }
    }

    private func field(
        _ label: String, placeholder: String, text: Binding<String>, which: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.meta)
            TextField(placeholder, text: text)
                .font(AppFont.callout)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: which)
                .submitLabel(which == .server ? .next : .go)
                .onSubmit {
                    if which == .server { focused = .code } else if canLink { link() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.fieldFill))
                .accessibilityLabel(label)
        }
    }

    private var canLink: Bool {
        !source.isWorking && ArchiveLinkInvitation.normalizedCode(codeText).count >= 6
    }

    private func link() {
        focused = nil
        source.link(code: codeText, server: serverText)
    }

    // MARK: Linked

    private func sharedCard(_ host: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
            SettingsSectionHeader(title: Copy.ArchiveServer.sharedSection)
            ListCard {
                ForEach(
                    [
                        Copy.ArchiveServer.sharedText(host), Copy.ArchiveServer.sharedAudio,
                        Copy.ArchiveServer.sharedDeletes, Copy.ArchiveServer.sharedDeleteAll,
                    ], id: \.self
                ) { line in
                    Text(line)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.secondaryBody)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
            SettingsSectionHeader(title: Copy.ArchiveServer.statusSection)
            ListCard {
                SettingsRow(
                    title: Copy.ArchiveServer.lastSynced,
                    value: status.lastBatchAtMs.map(Self.ago) ?? Copy.ArchiveServer.notYet,
                    showsChevron: false)
                SettingsRow(
                    title: Copy.ArchiveServer.waiting,
                    value: status.pending == 0 ? Copy.ArchiveServer.nothingWaiting : "\(status.pending)",
                    showsChevron: false)
                if status.parked > 0 {
                    SettingsRow(
                        title: Copy.ArchiveServer.couldNotSync, value: "\(status.parked)",
                        valueColor: Tokens.attention, showsChevron: false)
                }
                if let error = status.lastError {
                    Text(error)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                TintActionRow(title: Copy.ArchiveServer.syncNow, action: source.syncNow) {
                    if status.sending {
                        ProgressView().controlSize(.small)
                    }
                }
                .disabled(!status.enabled)
            }
        }
    }

    private var aiReadCard: some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
            SettingsSectionHeader(title: Copy.ArchiveServer.aiReadSection)
            ListCard {
                let reads = Array((status.server?.aiReads ?? []).prefix(3))
                if reads.isEmpty {
                    Text(Copy.ArchiveServer.aiReadNone)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(reads.enumerated()), id: \.offset) { _, read in
                        Text(
                            Copy.ArchiveServer.aiRead(
                                client: read.client, count: read.ids.count,
                                when: read.atMs.map(Self.ago) ?? ""))
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.secondaryBody)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func unlinkCard(_ host: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
            ListCard {
                DestructiveRow(title: Copy.ArchiveServer.unlink) { source.unlink() }
                    .disabled(source.isWorking)
            }
            SettingsFooter(text: Copy.ArchiveServer.unlinkFooter(host))
        }
    }

    /// "just now", "5 min ago", "3 hr ago", then the date.
    static func ago(_ ms: Int64) -> String {
        let since = max(0, Int64(Date().timeIntervalSince1970 * 1000) - ms)
        if since < 60_000 { return "just now" }
        if since < 24 * 3_600_000 { return "\(Formatting.duration(since)) ago" }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
            .formatted(.dateTime.month(.abbreviated).day())
    }
}

#Preview("Pebble Audio server") {
    NavigationStack {
        SettingsServerScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
