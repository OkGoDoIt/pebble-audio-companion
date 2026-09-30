import AppDB
import SwiftUI

// DEBUG alternative (`-historyGroupShort`), for Roger to compare with the three card sizes:
// a run of short conversations drawn as ONE card whose rows are those conversations.
//
// Presentation only. The model and the day builder are unchanged; `HistoryDisplayGrouping`
// is a pure function from the day's items to what the timeline draws.

/// What the timeline draws for one slot: an item as it is, or a run of short conversations.
enum HistoryDisplayItem: Equatable, Identifiable {
    case item(HistoryItem)
    case shortRun([HistoryChapterBlock])
    /// A run of gaps drawn as one block (`HistoryStretch`).
    case stretch(HistoryStretch)

    var id: String {
        switch self {
        case .item(let item): return item.id
        case .shortRun(let blocks): return "run-" + (blocks.first?.id ?? "")
        case .stretch(let stretch): return stretch.id
        }
    }

    var startMs: Int64 {
        switch self {
        case .item(let item): return item.startMs
        case .shortRun(let blocks): return blocks.first?.startMs ?? 0
        case .stretch(let stretch): return stretch.startMs
        }
    }

    var endMs: Int64 {
        switch self {
        case .item(let item): return item.endMs
        case .shortRun(let blocks): return blocks.last?.endMs ?? 0
        case .stretch(let stretch): return stretch.endMs
        }
    }
}

enum HistoryDisplayGrouping {
    /// Quiet shorter than this between two short conversations keeps them in one run — the
    /// builder's no-conversation minimum, below which quiet is never labelled.
    static let quietJoinsBelowMinutes: Double = 15

    static var isEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-historyGroupShort")
        #else
        return false
        #endif
    }

    /// The day's items, with every run of two or more compact-tier conversations (each under
    /// 10 minutes) that only unlabelled quiet separates folded into one `.shortRun`. The quiet
    /// inside a run is absorbed: the run spans from its first conversation's start to its last
    /// one's end. A 10-minute-or-longer card, or any other gap, ends a run; a run of one stays
    /// a card.
    static func group(_ items: [HistoryItem], enabled: Bool = true) -> [HistoryDisplayItem] {
        group(items.map { HistoryDayEntry.item($0) }, enabled: enabled)
    }

    /// The same over a page's entries, where the quiet between two short conversations may be
    /// a stretch: it joins when it is quiet only and shorter than the minimum.
    static func group(_ entries: [HistoryDayEntry], enabled: Bool = true) -> [HistoryDisplayItem] {
        func display(_ entry: HistoryDayEntry) -> HistoryDisplayItem {
            switch entry {
            case .item(let item): return .item(item)
            case .stretch(let stretch): return .stretch(stretch)
            }
        }
        guard enabled else { return entries.map(display) }
        var result: [HistoryDisplayItem] = []
        var run: [HistoryChapterBlock] = []
        var pendingQuiet: [HistoryDayEntry] = []

        func flush() {
            if run.count >= 2 {
                result.append(.shortRun(run))
            } else if let only = run.first {
                result.append(.item(.chapter(only)))
            }
            run = []
            result += pendingQuiet.map(display)
            pendingQuiet = []
        }

        for entry in entries {
            switch entry {
            case .item(.chapter(let block)) where isShort(block):
                if run.isEmpty {
                    run = [block]
                } else {
                    // The quiet between two members belongs to the run.
                    pendingQuiet = []
                    run.append(block)
                }
            case .item(.gap(let gap)) where !run.isEmpty && joins(gap):
                pendingQuiet.append(entry)
            case .stretch(let stretch) where !run.isEmpty && stretch.parts.allSatisfy(joins)
                && Double(stretch.durationMs) / 60_000 < quietJoinsBelowMinutes:
                pendingQuiet.append(entry)
            default:
                flush()
                result.append(display(entry))
            }
        }
        flush()
        return result
    }

    static func isShort(_ block: HistoryChapterBlock) -> Bool {
        ChapterCardTier.tier(durationMs: block.endMs - block.startMs) == .compact
    }

    /// Quiet below the no-conversation minimum carries no label, so it does not split a run.
    static func joins(_ gap: HistoryGap) -> Bool {
        gap.kind == .quiet && Double(gap.endMs - gap.startMs) / 60_000 < quietJoinsBelowMinutes
    }
}

// MARK: - The view

/// One white card holding a run of short conversations as rows, hairlines between them like
/// the week list. The card spans the run's time on the scale; the rows sit at the top in time
/// order (they are not placed by time — hour labels interpolate across the card).
struct ShortConversationGroupCard: View {
    let blocks: [HistoryChapterBlock]
    var onOpen: (HistoryChapterBlock) -> Void = { _ in }

    static let rowVerticalPadding: CGFloat = 5

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                if index > 0 {
                    Rectangle().fill(Tokens.hairline).frame(height: 0.5)
                        .padding(.horizontal, ChapterCardMetrics.paddingHorizontal)
                }
                CompactConversationRow(block: block)
                    .padding(.horizontal, ChapterCardMetrics.paddingHorizontal)
                    .padding(.vertical, Self.rowVerticalPadding)
                    // The whole row width is the target, as in a list.
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(block) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(HistoryLabels.chapterAccessibilityLabel(block))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Copy.History.A11y.openHint)
                    .accessibilityAction(.default) { onOpen(block) }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.Timeline.cardRadius))
        .background(alignment: .leading) { TimelineTalkLine() }
        .accessibilityElement(children: .contain)
    }
}

/// The one-line content of a short conversation, shared by the compact card and a group row:
/// the title (or, untitled, its first words, or "Not summarised yet"), the follow-up indicator,
/// "9:05 AM · 6 min" trailing, and an amber "N min missing" when audio was lost.
struct CompactConversationRow: View {
    let block: HistoryChapterBlock

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            // Text leads on every card, titled or not; the time is the gray meta trailing.
            CardHeading(heading: HistoryLabels.heading(block))
                .lineLimit(1)
                .truncationMode(.tail)
                // The heading takes all the room the time leaves; the spacer only what is over.
                .layoutPriority(1)
            Spacer(minLength: 4)
            if !block.followUps.isEmpty { followUpIndicator }
            Text(HistoryLabels.compactTimeLine(block).main)
                .font(AppFont.timelineMeta)
                .foregroundStyle(Tokens.meta)
                .lineLimit(1)
                .fixedSize()
            if block.missingMs > 0 {
                // Loss is never hidden: on the one line it is an amber mark, and spoken in full.
                Text(Copy.History.missing(HistoryFormat.duration(ms: block.missingMs)))
                    .font(AppFont.timelineMeta)
                    .foregroundStyle(Tokens.missingText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// An open circle and the number of follow-ups not yet done — or a checked one when all are.
    private var followUpIndicator: some View {
        let open = block.followUps.filter { !$0.done }.count
        return HStack(spacing: 3) {
            Image(systemName: open == 0 ? "checkmark.circle" : "circle")
                .font(AppFont.timelineMeta)
            Text("\(open == 0 ? block.followUps.count : open)")
                .font(AppFont.timelineMeta.monospacedDigit())
        }
        .foregroundStyle(open == 0 ? Tokens.followUpDone : Tokens.tint)
        .fixedSize()
    }
}
