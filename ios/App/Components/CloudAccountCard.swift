import CompanionRuntime
import SwiftUI
import Transcription

/// The cards for every refused account, or only those doing AI work (Ask). Draws nothing, and
/// takes no space, when every account is fine.
struct CloudAccountCards: View {
    var aiOnly = false

    private var issues: [CloudAccountIssue] {
        CloudAccountAlerts.shared.issues.filter { !aiOnly || $0.ai != nil }
    }

    var body: some View {
        ForEach(issues) { CloudAccountCard(issue: $0) }
    }
}

/// One refused account: the status card's shape, with the fix filled and the backup beside it.
struct CloudAccountCard: View {
    let issue: CloudAccountIssue

    @Environment(\.openURL) private var openURL
    @Environment(AppSettings.self) private var settings
    @State private var showsBackup = false
    @State private var showsKey = false

    private var name: String { issue.provider.displayName }
    private var isChecking: Bool { CloudAccountAlerts.shared.checking.contains(issue.provider) }
    private var since: String {
        Copy.CloudAccount.since(
            issue.sinceMs, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    heading
                    if isChecking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            lineText(Copy.CloudAccount.checking(name))
                        }
                    } else {
                        lineText(Copy.CloudAccount.line(issue))
                    }
                }
                .accessibilityElement(children: .combine)

                // Side by side while both labels fit on one line; stacked at larger text.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { buttons }
                    VStack(spacing: 8) { buttons }
                }
                .padding(.top, 2)
            }
        }
        .sheet(isPresented: $showsBackup) {
            CloudAccountBackupSheet(issue: issue).environment(settings)
        }
        .sheet(isPresented: $showsKey, onDismiss: checkAfterKey) {
            NavigationStack {
                ApiKeyChangeScreen(provider: issue.provider)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(Copy.Common.done) { showsKey = false }
                        }
                    }
            }
            .environment(settings)
        }
    }

    private var heading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                StatusDot(color: Tokens.attention, size: .status)
                headlineText.lineLimit(1)
                Spacer(minLength: 8)
                sinceText
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusDot(color: Tokens.attention, size: .status)
                    headlineText.fixedSize(horizontal: false, vertical: true)
                }
                sinceText
            }
        }
    }

    private var headlineText: some View {
        Text(Copy.CloudAccount.headline(issue.kind, provider: name))
            .font(AppFont.headline)
            .foregroundStyle(Tokens.label)
    }

    private var sinceText: some View {
        Text(since).font(AppFont.footnote).foregroundStyle(Tokens.meta)
    }

    private func lineText(_ text: String) -> some View {
        Text(text)
            .font(AppFont.subBody)
            .foregroundStyle(Tokens.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: fix) {
            Text(Copy.CloudAccount.fixAction(issue.kind)).lineLimit(1)
        }
        .buttonStyle(.inCardFilled)
        .disabled(isChecking)
        Button { showsBackup = true } label: {
            Text(Copy.CloudAccount.chooseBackup).lineLimit(1)
        }
        .buttonStyle(.borderedTint)
    }

    private func fix() {
        if issue.isAboutTheKey {
            showsKey = true
        } else {
            CloudAccountAlerts.shared.wentToFix(issue.provider)
            openURL(issue.provider.accountPage(for: issue.kind))
        }
    }

    private func checkAfterKey() {
        Task { await CloudAccountAlerts.shared.refresh() }
    }
}

#Preview("Refused accounts") {
    ScrollView {
        VStack(spacing: Tokens.blockGap) {
            CloudAccountCard(
                issue: .init(
                    provider: .soniox, kind: .accountOutOfFunds, sinceMs: 1_795_360_000_000,
                    transcription: .onDevice))
            CloudAccountCard(
                issue: .init(
                    provider: .openAi, kind: .spendingLimitReached, sinceMs: 1_795_360_000_000,
                    ai: .waiting))
        }
        .padding(Tokens.screenMargin)
    }
    .background(Tokens.ground)
    .environment(AppSettings())
}
