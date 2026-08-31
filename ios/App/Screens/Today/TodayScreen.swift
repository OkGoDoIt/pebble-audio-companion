import SwiftUI
import StatusUI

/// Today tab root (Main artboard, extraction §2.4): status card with the live minute,
/// day coverage, recap, follow-ups, conversations. Ask is one tap from the title bar.
struct TodayScreen: View {
    @Environment(AppRouter.self) private var router
    @State private var viewModel = TodayViewModel()
    @State private var poppedSpan: CoverageSpanDisplay?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.blockGap) {
                statusCard

                if viewModel.isFirstRun {
                    firstRunLine
                } else {
                    if let coverage = viewModel.snapshot.coverage {
                        coverageCard(coverage)
                    }
                    if let recap = viewModel.snapshot.recap {
                        recapCard(recap)
                    }
                    if !viewModel.snapshot.followUps.isEmpty {
                        followUpsCard
                    }
                    if !viewModel.snapshot.conversations.isEmpty {
                        conversationsSection
                    }
                }
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Tokens.ground)
        .navigationTitle(Copy.Today.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { askButton }
        }
        .navigationDestination(for: Route.self) { route in
            destination(for: route)
        }
        .task { await viewModel.observe() }
    }

    // MARK: Route destinations (the Today stack)

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .live:
            LiveConversationScreen()
        case .note:
            // The recap detail rides the `.note` route (digest id `day-<dateKey>`) —
            // the Saved-Notes pattern per the conventions.
            RecapDetailView(detail: viewModel.snapshot.recap?.detail)
        case .conversation(let id, _):
            // Placeholder until the Conversation screen lands (Library/Conversation
            // agent); swap this case to the real ConversationScreen when it exists.
            ConversationFallbackView(
                row: viewModel.snapshot.conversations.first(where: { $0.id == id })
            )
        default:
            Color.clear.background(Tokens.ground)
        }
    }

    // MARK: Title-bar Ask — the system draws the pill
    //
    // iOS 26 places toolbar items on a shared Liquid Glass background automatically, so a
    // hand-rolled `Capsule().fill(Tokens.tintFill10)` nests a violet pill inside the system's
    // own and fights the scroll-edge effect that keeps the control legible as cards scroll
    // under the bar (`.buttonStyle(.plain)` is what suppresses the system treatment). The
    // artboard's semantics are unchanged — trailing on the title bar, sparkle + "Ask", violet
    // as tint only — and the system supplies the shape, the material, the ≥44 pt hit region
    // (U10; a fixed 32 pt frame is 12 pt short) and the Dynamic Type metrics. Violet arrives
    // via the app-wide `.tint(Tokens.tint)`.
    //
    // Deliberately absent, so this is not re-litigated:
    //   • no `.buttonStyle(.glass)` — the item already has glass; the glass styles are for
    //     buttons in your own content.
    //   • no `.buttonStyle(.glassProminent)` — it tints the *material* with the accent: a
    //     filled violet surface with a near-white label. That inverts the token table (tint is
    //     the Ask pill's TEXT) and Q1's "violet as tint only".
    //   • no `sharedBackgroundVisibility` / `ToolbarSpacer` — one item, so no group to split.
    //     A second trailing item would silently merge into this capsule and Ask would stop
    //     reading as primary; separate them with
    //     `ToolbarSpacer(.fixed, placement: .topBarTrailing)`, never by drawing a shape.
    //   • no `.buttonBorderShape(.capsule)` — the toolbar already draws a capsule.
    //
    // The label keeps the word "Ask": HIG prefers symbols, but its stated exception is actions
    // not well represented by one, and the sparkle spans summarize/generate/enhance across the
    // industry — nobody infers "ask about your day" from it. It also keeps Voice Control's
    // "Tap Ask" working.

    private var askButton: some View {
        Button {
            router.askSheet = .ask(scope: AskScope.today.routeKey, query: nil)
        } label: {
            // An explicit glyph + text pair, NOT a `Label`: iOS 26 toolbars render `Label`
            // icon-only and ignore `.labelStyle(.titleAndIcon)` in either position. The system
            // still supplies the capsule, the material, the hit region and the metrics — this
            // only decides what goes inside it.
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text(Copy.Today.ask)
            }
        }
        .accessibilityLabel(Copy.Today.ask)
    }

    // MARK: Status card (all families; recording composes the live minute + Pause link)

    @ViewBuilder
    private var statusCard: some View {
        let status = viewModel.status
        if status.family == .recording {
            recordingCard(status)
        } else {
            StatusCard(
                dotColor: status.dot.tokenColor,
                headline: status.headline,
                line: status.detail ?? "",
                action: status.action.flatMap { action in
                    guard action != .stop else { return nil }
                    return StatusCard.Action(
                        title: action.defaultLabel ?? Copy.Common.tryAgain,
                        style: action.cardStyle
                    ) { viewModel.perform(action) }
                }
            )
        }
    }

    /// The artboard's Recording card: dot · "Recording" · Pause link; connected sub-line;
    /// 40-bar live minute; taxonomy legend.
    private func recordingCard(_ status: StatusModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(color: Tokens.good, size: .status)
                    Text(status.headline)
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                    Spacer()
                    Button(Copy.Today.pause) { viewModel.pauseTapped() }
                        .font(AppFont.pill)
                        .foregroundStyle(Tokens.tint)
                        .buttonStyle(.plain)
                }
                if let detail = status.detail {
                    Text(detail)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                }
                if viewModel.showsLiveMinute {
                    WaveformView(bars: viewModel.snapshot.liveMinute)
                    WaveformLegend()
                }
            }
        }
    }

    // MARK: First-run empty state (6.7)

    private var firstRunLine: some View {
        Text(Copy.Empty.todayFirstRun)
            .font(AppFont.subBody)
            .foregroundStyle(Tokens.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }

    // MARK: Day coverage (headline · missing · strip · axis; Q11 tap-to-explain)

    private func coverageCard(_ coverage: CoverageDisplay) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(coverage.headline)
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)
                    Spacer()
                    if let missing = coverage.missingText {
                        Text(missing)
                            .font(.system(.caption))
                            .foregroundStyle(Tokens.missing)
                    }
                }
                CoverageStrip(spans: coverage.stripSpans) { tapped in
                    if let hit = coverage.spans.first(where: { $0.span == tapped }),
                        hit.popoverText != nil
                    {
                        poppedSpan = hit
                    }
                }
                .popover(item: $poppedSpan) { span in
                    Text(span.popoverText ?? "")
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.label)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .presentationCompactAdaptation(.popover)
                        .task {
                            // Q11: one line, auto-dismisses.
                            try? await Task.sleep(for: .seconds(2.5))
                            poppedSpan = nil
                        }
                }
            }
        }
    }

    // MARK: Recap card (sparkle · "Today so far" · updated · digest → cited detail)

    private func recapCard(_ recap: RecapDisplay) -> some View {
        Button {
            router.todayPath.append(.note(id: recap.detail.id))
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tokens.tint)
                        Text(Copy.Today.recapTitle)
                            .font(AppFont.cardHead)
                            .foregroundStyle(Tokens.label)
                        Spacer()
                        Text(recap.updatedText)
                            .font(.system(.caption))
                            .foregroundStyle(Tokens.faint)
                    }
                    Text(recap.digest)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.secondaryBody)
                        .lineSpacing(5)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        }
        .buttonStyle(.plain)
    }

    // MARK: Follow-ups (circle checkmarks; "See all N" disclosure; "All caught up.")

    @ViewBuilder
    private var followUpsCard: some View {
        if viewModel.followUpsAllDone {
            Card {
                Text(Copy.Empty.followUpsAllDone)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
            }
        } else {
            ListCard(rowVerticalPadding: 13) {
                ForEach(Array(viewModel.visibleFollowUps.enumerated()), id: \.element.id) {
                    index, item in
                    followUpRow(item, showsSeeAll: index == 0)
                }
            }
        }
    }

    private func followUpRow(_ item: FollowUpDisplay, showsSeeAll: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                viewModel.toggleFollowUp(item)
            } label: {
                if item.done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Tokens.tint)
                } else {
                    Circle()
                        .strokeBorder(Tokens.chevron, lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.text)
            .accessibilityAddTraits(item.done ? .isSelected : [])

            Text(item.text)
                .font(AppFont.subBody)
                .foregroundStyle(item.done ? Tokens.meta : Tokens.label)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showsSeeAll, !viewModel.showAllFollowUps,
                viewModel.snapshot.followUps.count > 2
            {
                Button(Copy.Today.seeAll(viewModel.snapshot.followUps.count)) {
                    withAnimation(.snappy) { viewModel.showAllFollowUps = true }
                }
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.tint)
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
    }

    // MARK: Conversations (live row w/ rolling snippet + Live badge; finished rows)

    private var conversationsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
            Text(Copy.Today.conversationsSection)
                .font(AppFont.sectionTitle)
                .foregroundStyle(Tokens.label)
                .padding(.top, 4)

            ListCard {
                ForEach(viewModel.snapshot.conversations) { row in
                    conversationRow(row)
                }
            }
        }
    }

    private func conversationRow(_ row: ConversationRowDisplay) -> some View {
        Button {
            router.todayPath.append(
                row.isLive ? .live : .conversation(id: row.id, atMs: nil)
            )
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(AppFont.rowTitle)
                        .foregroundStyle(Tokens.label)
                    Text(row.meta)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                    if let snippet = row.snippet {
                        Text(snippet)
                            .font(AppFont.footnote)
                            .italic()
                            .foregroundStyle(Tokens.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if row.isLive {
                    LiveBadge()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Conversation placeholder (until the Conversation screen lands)

/// Temporary destination for `.conversation` pushes from Today. The Conversation screen is
/// owned by the Library/Conversation agent; the orchestrator swaps this for the real screen.
private struct ConversationFallbackView: View {
    let row: ConversationRowDisplay?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(row?.title ?? "Conversation")
                    .font(AppFont.detailTitle)
                    .foregroundStyle(Tokens.label)
                if let meta = row?.meta {
                    Text(meta)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.screenMargin)
        }
        .background(Tokens.ground)
        .toolbar(.hidden, for: .tabBar)
    }
}

// MARK: - Previews

#Preview("Today") {
    let router = AppRouter()
    return NavigationStack {
        TodayScreen()
    }
    .environment(router)
    .tint(Tokens.tint)
}
