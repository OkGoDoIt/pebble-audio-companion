import CompanionRuntime
import SwiftUI
import Transcription

/// The cards for every refused account, or only those doing AI work (Ask). Draws nothing, and
/// takes no space, when every account is fine.
struct CloudAccountCards: View {
    var aiOnly = false

    private var issues: [CloudAccountIssue] {
        guard aiOnly else { return CloudAccountAlerts.shared.issues }
        // Only the half this screen is about: Ask has nothing to say about transcribing.
        return CloudAccountAlerts.shared.issues.filter { $0.ai != nil }.map {
            var issue = $0
            issue.transcription = nil
            return issue
        }
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
                    EqualWidthPair(spacing: 10) {
                        fixButton
                        backupButton
                    }
                    VStack(spacing: 8) {
                        fixButton
                        backupButton
                    }
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

    private var fixButton: some View {
        Button(Copy.CloudAccount.fixAction(issue.kind), action: fix)
            .buttonStyle(.inCardFilled)
            .disabled(isChecking)
    }

    private var backupButton: some View {
        Button(Copy.CloudAccount.chooseBackup) { showsBackup = true }
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

/// Two views side by side at equal widths, asking for twice the WIDER one's ideal width. An
/// `HStack` asks only for the sum, so at larger text `ViewThatFits` kept the pair and the equal
/// split then cut the longer label off.
private struct EqualWidthPair: Layout {
    var spacing: CGFloat

    private func cell(_ subviews: Subviews, total: CGFloat?) -> CGFloat {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        guard let total, total.isFinite else { return ideal }
        return (total - spacing) / 2
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = cell(subviews, total: proposal.width)
        let height =
            subviews.map { $0.sizeThatFits(.init(width: width, height: nil)).height }.max() ?? 0
        return CGSize(width: width * 2 + spacing, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let width = cell(subviews, total: bounds.width)
        for (index, view) in subviews.enumerated() {
            view.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * (width + spacing), y: bounds.minY),
                proposal: .init(width: width, height: bounds.height))
        }
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
