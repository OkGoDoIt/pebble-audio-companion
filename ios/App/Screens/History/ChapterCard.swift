import AppDB
import SwiftUI

// A stretch of talk on the day (plan 5.3 "Chapter card").
//
// White, the app's card radius, padding 10/13/11. Title (16/600, two lines), time line (12,
// gray, with an amber "· 4 min missing" when audio was lost inside it), summary (14, `tertiary`,
// as many lines as the card's band allows, none under 25 minutes), topic then people pills,
// and follow-ups under a hairline.
//
// The card is fitted with ONE measure (plan 7.12): `ChapterCardLayout` measures the fixed parts
// and proposes the summary the height left under `duration × 3 pt`, never less than a line;
// `Text` answers with the whole lines that fit (`TextHeightProposalTests`). Whether the
// follow-ups collapse to the first plus "N more" is decided before layout by `ChapterCardFit`.
// No `ViewThatFits`: the spike measured it at 90–120 ms a day.
//
// A card drawn from a conversation stretch (`source == .conversation`, plan 5.8) has the
// conversation's title — or "Conversation" — and no summary.

struct ChapterCard: View {
    let block: HistoryChapterBlock
    var onOpen: () -> Void = {}
    var onOpenFollowUp: (HistoryFollowUpLine) -> Void = { _ in }
    /// A topic pill's results (plan 5.7). Nil: the pills do nothing.
    var onOpenTag: ((String) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let summary = block.source == .chapter ? block.summary.flatMap { $0.isEmpty ? nil : $0 } : nil
        Group {
            switch tier {
            case .full: fullCard
            case .medium: mediumCard
            case .compact: compactCard
            }
        }
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.Timeline.cardRadius))
        .background(alignment: .leading) { TimelineTalkLine() }
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Timeline.cardRadius))
        .onTapGesture(perform: onOpen)
        .contextMenu { menu(summary: summary) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HistoryLabels.chapterAccessibilityLabel(block))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Copy.History.A11y.openHint)
        .accessibilityAction(.default, onOpen)
        .accessibilityActions {
            ForEach(block.followUps) { line in
                Button(Copy.History.A11y.followUpAction(line.text)) { onOpenFollowUp(line) }
            }
        }
    }

    /// Which card this conversation gets (`ChapterCardTier`). DEBUG `-historyNoTiers` draws
    /// every card full, for comparing the two.
    private var tier: ChapterCardTier {
        #if DEBUG
        if ChapterCard.tiersDisabled { return .full }
        #endif
        return ChapterCardTier.tier(
            durationMs: block.endMs - block.startMs,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    #if DEBUG
    static let tiersDisabled = ProcessInfo.processInfo.arguments.contains("-historyNoTiers")
    #endif

    private var snippet: String? {
        HistoryLabels.isUntitled(block) ? block.snippet.flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    // MARK: Medium: 10 to 25 minutes

    private var mediumCard: some View {
        let time = HistoryLabels.chapterTimeLine(block)
        let topics = Array(block.tags.prefix(3))
        return VStack(alignment: .leading, spacing: ChapterCardMetrics.titleToTime) {
            Text(HistoryLabels.chapterHeading(block))
                .font(AppFont.rowTitle)
                .foregroundStyle(Tokens.label)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
            InlineTrailingLayout(spacing: 8) {
                timeLine(main: time.main, missing: time.missing)
                    .lineLimit(1)
                if let snippet {
                    quote(snippet)
                        .lineLimit(1)
                        .layoutValue(key: InlineTrailingLayout.Truncates.self, value: true)
                } else if !topics.isEmpty || !block.people.isEmpty {
                    TagPillRow(topics: topics, people: block.people, onSelect: onOpenTag)
                        .fixedSize()
                }
            }
            if let first = block.followUps.first {
                followUp(first, more: block.followUps.count - 1)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, ChapterCardMetrics.paddingHorizontal)
        .padding(.top, ChapterCardTier.mediumPaddingTop)
        .padding(.bottom, ChapterCardTier.mediumPaddingBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Compact: under 10 minutes

    private var compactCard: some View {
        CompactConversationRow(block: block)
            .padding(.horizontal, ChapterCardMetrics.paddingHorizontal)
            .padding(.vertical, ChapterCardTier.compactPaddingVertical)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func quote(_ text: String) -> some View {
        Text(Copy.History.quote(text))
            .font(AppFont.historyBody(dynamicTypeSize))
            .italic()
            .foregroundStyle(Tokens.tertiary)
    }

    // MARK: Full: 25 minutes and longer

    @ViewBuilder
    private var fullCard: some View {
        let sizes = HistoryMetrics.at(dynamicTypeSize)
        let durationMs = block.endMs - block.startMs
        let summary = block.source == .chapter ? block.summary.flatMap { $0.isEmpty ? nil : $0 } : nil
        // An untitled stretch's body is its first words, shown at every length: without them
        // the card would be a time and nothing else.
        let snippet = HistoryLabels.isUntitled(block) ? block.snippet.flatMap { $0.isEmpty ? nil : $0 } : nil
        let showsSummary = snippet != nil
            || ChapterCardFit.showsSummary(durationMs: durationMs, hasSummary: summary != nil)
        let topics = Array(block.tags.prefix(3))
        let hasPills = !topics.isEmpty || !block.people.isEmpty
        let collapses = ChapterCardFit.collapsesFollowUps(
            durationMs: durationMs, followUpCount: block.followUps.count, showsSummary: showsSummary,
            hasPills: hasPills, metrics: sizes.card, timeline: sizes.timeline)
        let softMax = TimelineGeometry.softMaxHeight(
            for: TimelineSpan(startMs: block.startMs, endMs: block.endMs), metrics: sizes.timeline)

        ChapterCardLayout(
            softMaxHeight: softMax - ChapterCardMetrics.paddingTop - ChapterCardMetrics.paddingBottom,
            // At the accessibility sizes a summary keeps at least two lines: one line of large
            // type is a few words, which says nothing. The card may exceed its band there.
            minSummaryHeight: dynamicTypeSize.isAccessibilitySize
                ? sizes.card.summaryLine * 2 + ChapterCard.summaryLineSpacing
                : sizes.card.summaryLine
        ) {
            header
            if let snippet {
                // Verbatim, so it is quoted and set like the Live card's line.
                Text(Copy.History.quote(snippet))
                    .font(AppFont.historyBody(dynamicTypeSize))
                    .italic()
                    .foregroundStyle(Tokens.tertiary)
                    .lineSpacing(ChapterCard.summaryLineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutValue(key: ChapterCardPart.self, value: .summary)
            } else if showsSummary, let summary {
                Text(summary)
                    .font(AppFont.historyBody(dynamicTypeSize))
                    .foregroundStyle(Tokens.tertiary)
                    .lineSpacing(ChapterCard.summaryLineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutValue(key: ChapterCardPart.self, value: .summary)
            }
            if hasPills || !block.followUps.isEmpty {
                footer(topics: topics, collapses: collapses)
            }
        }
        .padding(EdgeInsets(
            top: ChapterCardMetrics.paddingTop, leading: ChapterCardMetrics.paddingHorizontal,
            bottom: ChapterCardMetrics.paddingBottom, trailing: ChapterCardMetrics.paddingHorizontal))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Between summary lines: the mockup's 1.35 line height at 14 pt.
    static let summaryLineSpacing: CGFloat = 2

    private var header: some View {
        let time = HistoryLabels.chapterTimeLine(block)
        return VStack(alignment: .leading, spacing: ChapterCardMetrics.titleToTime) {
            Text(HistoryLabels.chapterHeading(block))
                .font(AppFont.rowTitle)
                .foregroundStyle(Tokens.label)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
            timeLine(main: time.main, missing: time.missing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeLine(main: String, missing: String?) -> some View {
        Group {
            if let missing {
                Text("\(main) · \(Text(missing).foregroundStyle(Tokens.missingText))")
            } else {
                Text(main)
            }
        }
        .font(AppFont.timelineMeta)
        .foregroundStyle(Tokens.meta)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func footer(topics: [String], collapses: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !topics.isEmpty || !block.people.isEmpty {
                TagPillRow(topics: topics, people: block.people, onSelect: onOpenTag)
                    .padding(.top, ChapterCardMetrics.pillsTop)
            }
            if !block.followUps.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(Tokens.hairline).frame(height: 0.5)
                        .padding(.bottom, ChapterCardMetrics.followUpsInset)
                    if collapses, let first = block.followUps.first {
                        followUp(first, more: block.followUps.count - 1)
                    } else {
                        ForEach(block.followUps) { followUp($0, more: 0) }
                    }
                }
                .padding(.top, ChapterCardMetrics.followUpsTop)
            }
        }
    }

    private func followUp(_ line: HistoryFollowUpLine, more: Int) -> some View {
        FollowUpLine(line, more: more)
            .contentShape(Rectangle())
            .onTapGesture { onOpenFollowUp(line) }
    }

    @ViewBuilder
    private func menu(summary: String?) -> some View {
        Button(Copy.History.open, systemImage: "arrow.up.right", action: onOpen)
        if let summary {
            ShareLink(item: summary) { Label(Copy.History.shareSummary, systemImage: "square.and.arrow.up") }
            Button(Copy.History.copySummary, systemImage: "doc.on.doc") {
                UIPasteboard.general.string = summary
            }
        }
    }
}

// MARK: - The one-measure layout

/// Which part of the card a subview is. Only the summary is fitted; everything else is fixed.
enum ChapterCardPart: LayoutValueKey {
    static let defaultValue = Role.fixed
    enum Role: Equatable, Sendable { case fixed, summary }
}

/// Stacks a card's parts, giving the summary what is left of the soft maximum after the fixed
/// parts — never less than one line. `Text` truncates itself to the whole lines that fit.
struct ChapterCardLayout: Layout {
    /// The soft maximum for the content, the card's padding already taken off.
    var softMaxHeight: CGFloat
    /// One summary line: the floor of what the summary is proposed.
    var minSummaryHeight: CGFloat
    /// Between the time line and the summary.
    var summaryGap: CGFloat = ChapterCardMetrics.timeToSummary

    struct Cache {
        var width: CGFloat = -1
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func heights(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGFloat] {
        if cache.width == width, cache.heights.count == subviews.count { return cache.heights }
        let free = ProposedViewSize(width: width, height: nil)
        var heights = subviews.map { sub -> CGFloat in
            sub[ChapterCardPart.self] == .fixed ? sub.sizeThatFits(free).height : 0
        }
        if let index = subviews.firstIndex(where: { $0[ChapterCardPart.self] == .summary }) {
            let fixed = heights.reduce(0, +) + summaryGap
            let room = max(minSummaryHeight, softMaxHeight - fixed)
            heights[index] = subviews[index].sizeThatFits(
                ProposedViewSize(width: width, height: room)).height
        }
        cache = Cache(width: width, heights: heights)
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 320
        let heights = heights(width: width, subviews: subviews, cache: &cache)
        let gap = subviews.contains { $0[ChapterCardPart.self] == .summary } ? summaryGap : 0
        return CGSize(width: width, height: heights.reduce(0, +) + gap)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) {
        let heights = heights(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (index, sub) in subviews.enumerated() {
            let isSummary = sub[ChapterCardPart.self] == .summary
            if isSummary { y += summaryGap }
            sub.place(
                at: CGPoint(x: bounds.minX, y: y),
                proposal: ProposedViewSize(width: bounds.width, height: heights[index]))
            y += heights[index]
        }
    }
}

// MARK: - Metrics at a text size

/// The timeline scale and the card's line heights at one Dynamic Type size, computed once per
/// size instead of once per card per update.
@MainActor
enum HistoryMetrics {
    struct Sizes {
        var timeline: TimelineMetrics
        var card: ChapterCardMetrics
    }

    private static var cache: [DynamicTypeSize: Sizes] = [:]

    static func at(_ size: DynamicTypeSize) -> Sizes {
        if let hit = cache[size] { return hit }
        let sizes = Sizes(
            timeline: TimelineMetrics(dynamicTypeSize: size),
            card: ChapterCardMetrics(dynamicTypeSize: size))
        cache[size] = sizes
        return sizes
    }
}

// MARK: - The axis beside talk

/// The hour axis beside a card, drawn in light tint for the card's whole duration: the day's
/// talk reads down the axis at a glance, and gaps keep their own axis styles (bare, stripes,
/// amber, the soft gray bar, dashes). Drawn behind the card, offset into the gutter; the hour
/// ticks and labels are placed after the items, so they sit on top of it.
struct TimelineTalkLine: View {
    var color: Color = Tokens.timelineTalk

    var body: some View {
        let axisCentre = Tokens.Timeline.axisX + Tokens.Timeline.axisWidth / 2
        Capsule()
            .fill(color)
            .frame(width: Tokens.Timeline.talkLineWidth)
            .frame(maxHeight: .infinity)
            .offset(x: axisCentre - Tokens.Timeline.gutter - Tokens.Timeline.talkLineWidth / 2)
            .accessibilityHidden(true)
    }
}

// MARK: - One line, the second part only if it fits

/// Two views on one line: the first at its own width, the second after it — at its own width
/// when it fits and hidden when it does not (pills), or given what is left and truncating
/// (`Truncates`, a quote). Pills never wrap onto a second line of a medium card.
struct InlineTrailingLayout: Layout {
    var spacing: CGFloat = 8

    struct Truncates: LayoutValueKey {
        static let defaultValue = false
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        guard let first = subviews.first else { return .zero }
        let a = first.sizeThatFits(.unspecified)
        var height = a.height
        if subviews.count > 1, let b = trailingSize(subviews[1], after: a.width, in: width) {
            height = max(height, b.height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let a = first.sizeThatFits(.unspecified)
        let b = subviews.count > 1 ? trailingSize(subviews[1], after: a.width, in: bounds.width) : nil
        let height = max(a.height, b?.height ?? 0)
        first.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + (height - a.height) / 2),
            proposal: ProposedViewSize(a))
        guard subviews.count > 1 else { return }
        if let b {
            subviews[1].place(
                at: CGPoint(x: bounds.minX + a.width + spacing, y: bounds.minY + (height - b.height) / 2),
                proposal: ProposedViewSize(b))
        } else {
            // Does not fit: kept out of sight rather than squeezed or wrapped.
            subviews[1].place(at: CGPoint(x: -10_000, y: bounds.minY), proposal: .zero)
        }
    }

    private func trailingSize(_ view: LayoutSubview, after leading: CGFloat, in width: CGFloat) -> CGSize? {
        let room = width - leading - spacing
        guard room > 24 else { return nil }
        if view[Truncates.self] {
            let fitted = view.sizeThatFits(ProposedViewSize(width: room, height: nil))
            return CGSize(width: min(fitted.width, room), height: fitted.height)
        }
        let ideal = view.sizeThatFits(.unspecified)
        return ideal.width <= room ? ideal : nil
    }
}
