import SwiftUI
import WidgetKit

// "Day coverage" (plan 6.8) — kept, demoted.
//
// It is a rear-view diagnostic: it reports what already happened, in a form you cannot act on.
// That is genuinely useful when you are asking "did I lose anything today?", and useless as the
// one thing a person sees on a Home Screen, so it stays in the bundle and says so in its own
// gallery description. `CaptureStatusWidget` is the headline now.

struct CoverageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CompanionEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: accessory
            case .systemMedium: medium
            default: small
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(Route.today(date: nil).url)
    }

    // MARK: - Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            headlineRow
            Spacer(minLength: 0)
            if let snapshot = entry.snapshot {
                WidgetCoverageStrip(snapshot: snapshot)
                Text(Copy.Today.recorded(DurationPhrase.compact(ms: snapshot.totalRecordedMs)))
                    .font(AppFont.micro)
                    .foregroundStyle(Tokens.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                emptyStrip
                Text(Copy.Empty.todayFirstRun)
                    .font(AppFont.micro)
                    .foregroundStyle(Tokens.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            headlineRow
            if let detail = entry.snapshot?.detail, !detail.isEmpty {
                Text(detail)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let snapshot = entry.snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetCoverageStrip(snapshot: snapshot)
                    WidgetCoverageAxis()
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(Copy.Today.recorded(DurationPhrase.compact(ms: snapshot.totalRecordedMs)))
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)
                    Spacer()
                    if snapshot.totalMissingMs > 0 {
                        // Loss is always explicit — never rounded away, never hidden.
                        Text(Copy.Today.missing(DurationPhrase.compact(ms: snapshot.totalMissingMs)))
                            .font(AppFont.speaker)
                            .foregroundStyle(Tokens.missing)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            } else {
                emptyStrip
                Text(Copy.Empty.todayFirstRun)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tertiary)
            }
        }
    }

    private var headlineRow: some View {
        StatusDotLabel(word: entry.status.word, color: entry.status.dot)
    }

    private var emptyStrip: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Tokens.track)
            .frame(height: 12)
            .accessibilityHidden(true)
    }

    // MARK: - Lock Screen

    private var accessory: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.status.word)
                .font(.headline)
                .lineLimit(1)
            if let snapshot = entry.snapshot {
                WidgetCoverageStrip(snapshot: snapshot, palette: .monochrome, height: 6)
                Text(Copy.Today.recorded(DurationPhrase.compact(ms: snapshot.totalRecordedMs)))
                    .font(.caption2)
                    .lineLimit(1)
            } else {
                Text(Copy.Empty.todayFirstRun).font(.caption2).lineLimit(1)
            }
        }
        .widgetAccentable()
    }
}

struct CoverageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SharedAppGroup.coverageWidgetKind, provider: CompanionProvider()
        ) { entry in
            CoverageWidgetView(entry: entry)
        }
        .configurationDisplayName(Copy.Widgets.coverageName)
        .description(Copy.Widgets.coverageDescription)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

#Preview("Small", as: .systemSmall) {
    CoverageWidget()
} timeline: {
    CompanionEntry.placeholder()
    CompanionEntry.empty()
}

#Preview("Medium", as: .systemMedium) {
    CoverageWidget()
} timeline: {
    CompanionEntry.placeholder()
}
