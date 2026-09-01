import SwiftUI
import WidgetKit

// Open follow-ups. The only other thing in this app that is worth a Home Screen slot: unlike
// coverage, a follow-up is something the user can act on. Tapping one opens that follow-up;
// tapping anywhere else opens the list — never Today, which shows three of them and another
// "See all N", so the count you tapped took two more taps to reach.

struct FollowUpsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SharedAppGroup.followUpsWidgetKind, provider: CompanionProvider()
        ) { entry in
            FollowUpsWidgetView(entry: entry)
        }
        .configurationDisplayName(Copy.Widgets.followUpsName)
        .description(Copy.Widgets.followUpsDescription)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FollowUpsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CompanionEntry

    /// Follow-ups do not go stale the way live status does — an open follow-up from this
    /// morning is still open — so this view uses the snapshot regardless of its age.
    private var items: [CoverageSnapshot.FollowUp] { entry.snapshot?.followUps ?? [] }
    private var total: Int { entry.snapshot?.openFollowUpCount ?? 0 }
    private var visible: Int { family == .systemMedium ? 3 : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if entry.snapshot == nil {
                Text(Copy.Widgets.noData)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tertiary)
                    .lineLimit(2)
            } else if items.isEmpty {
                Text(Copy.Empty.followUpsAllDone)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tertiary)
            } else {
                ForEach(items.prefix(visible), id: \.id) { item in
                    row(item)
                }
            }
            Spacer(minLength: 0)
            // Only ever say there are more when there provably are: the snapshot carries the
            // full open count alongside the handful it shipped.
            if total > items.prefix(visible).count {
                // A Link, not a label: it looks like the way to the rest and now is one. The
                // whole widget also opens the list rather than Today, which shows three of them
                // and another "See all N".
                Link(destination: Route.followUps(scope: nil).url) {
                    Text(Copy.Today.seeAll(total))
                        .font(AppFont.micro)
                        .foregroundStyle(Tokens.tint)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(Route.followUps(scope: nil).url)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Copy.Conversation.followUps)
                .font(AppFont.cardHead)
                .foregroundStyle(Tokens.label)
            Spacer(minLength: 0)
            if total > 0 {
                Text(Copy.Widgets.openCount(total))
                    .font(AppFont.micro)
                    .foregroundStyle(Tokens.tertiary)
            }
        }
    }

    /// One tappable row.
    private func row(_ item: CoverageSnapshot.FollowUp) -> some View {
        Link(destination: destination(for: item)) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "circle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.tint)
                    .padding(.top, 3)
                Text(item.text)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.secondaryBody)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
    }

    /// The item itself, not the recording behind it: the widget is a to-do list, and the
    /// thing you want when you tap one is the follow-up — where it came from is one more tap
    /// from there.
    private func destination(for item: CoverageSnapshot.FollowUp) -> URL {
        Route.followUp(id: item.id).url
    }
}

#Preview("Small", as: .systemSmall) {
    FollowUpsWidget()
} timeline: {
    CompanionEntry.placeholder()
    CompanionEntry.empty()
}

#Preview("Medium", as: .systemMedium) {
    FollowUpsWidget()
} timeline: {
    CompanionEntry.placeholder()
}
