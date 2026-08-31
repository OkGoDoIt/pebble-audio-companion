import SwiftUI
import WidgetKit

// Open follow-ups. The only other thing in this app that is worth a Home Screen slot: unlike
// coverage, a follow-up is something the user can act on, and tapping one lands in the
// conversation it came from rather than dumping them at the app's front door.

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
                Text(Copy.Today.seeAll(total))
                    .font(AppFont.micro)
                    .foregroundStyle(Tokens.tint)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(Route.today(date: nil).url)
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

    /// One tappable row. A follow-up whose source conversation is gone still lists — it is a
    /// real open item — it just opens Today instead of a conversation that no longer exists.
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

    private func destination(for item: CoverageSnapshot.FollowUp) -> URL {
        guard let conversationId = item.conversationId?.nonBlank else {
            return Route.today(date: nil).url
        }
        return Route.conversation(id: conversationId, atMs: nil).url
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
