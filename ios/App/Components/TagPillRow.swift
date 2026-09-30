import AppDB
import SwiftUI

/// A row of topic pills that opens a topic's results (plan 5.7: a tag pill, at any level, pushes
/// the chapters carrying it).
///
/// A pill is 17 pt tall and sits inside something that is already a target — a card, a row —
/// so it cannot be a 44 pt target of its own without taking taps meant for its neighbours
/// (plan 5.9: nothing smaller than 44 pt is tappable). So the ROW is one target: a tap anywhere
/// on it, grown to 44 pt, opens a short menu of its topics, and choosing one opens its results.
/// People pills ride along but are not in the menu: there is no per-person list yet.
struct TagPillRow: View {
    /// Up to three are shown (plan 5.3).
    let topics: [String]
    var people: [String] = []
    /// Nil draws plain pills that do nothing.
    var onSelect: ((String) -> Void)?
    var spacing: CGFloat = ChapterCardMetrics.pillSpacing

    var body: some View {
        if let onSelect, topics.count == 1 {
            // One topic: a menu of one would be a step for nothing.
            Button { onSelect(topics[0]) } label: { grownPills }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.History.A11y.pillRow(topics: topics, people: people))
                .accessibilityHint(Copy.History.A11y.pillRowHintOne)
        } else if let onSelect, !topics.isEmpty {
            Menu {
                Section(Copy.History.showDaysTagged) {
                    ForEach(topics, id: \.self) { topic in
                        Button(topic, systemImage: "tag") { onSelect(topic) }
                    }
                }
            } label: {
                grownPills
            }
            .buttonStyle(.plain)
            .menuStyle(.button)
            .accessibilityLabel(Copy.History.A11y.pillRow(topics: topics, people: people))
            .accessibilityHint(Copy.History.A11y.pillRowHint)
        } else {
            pills
        }
    }

    /// The pills with the hit area grown to 44 pt; the layout keeps the row's own height.
    private var grownPills: some View {
        pills
            .padding(.vertical, 13)
            .contentShape(Rectangle())
            .padding(.vertical, -13)
    }

    private var pills: some View {
        FlowLayout(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(topics, id: \.self) { TagChip(text: $0, tone: .topic) }
            ForEach(people, id: \.self) { TagChip(text: $0, tone: .person) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The month's tags with their day counts (plan 5.2), as one target like `TagPillRow`.
struct TagCountRow: View {
    let tags: [HistoryTagCount]
    var onSelect: ((String) -> Void)?

    var body: some View {
        if let onSelect {
            Menu {
                Section(Copy.History.showDaysTagged) {
                    ForEach(tags) { tag in
                        Button(Copy.History.tagCount(tag.name, days: tag.days), systemImage: "tag") {
                            onSelect(tag.name)
                        }
                    }
                }
            } label: {
                pills
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .padding(.vertical, -12)
            }
            .buttonStyle(.plain)
            .menuStyle(.button)
            .accessibilityLabel(Copy.History.A11y.pillRow(topics: tags.map(\.name), people: []))
            .accessibilityHint(Copy.History.A11y.pillRowHint)
        } else {
            pills
        }
    }

    private var pills: some View {
        FlowLayout(horizontalSpacing: 4, verticalSpacing: 6) {
            ForEach(tags) { TagCountPill(tag: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
