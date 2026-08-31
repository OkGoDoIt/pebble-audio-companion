import SwiftUI
import WidgetKit

// "Today's coverage" (plan 6.8). The timeline provider reads ONE thing: `coverage_snapshot.json`
// in the App Group. No database, no segment directory, no coverage computation — a widget that
// opened the DB would fight the app for the writer lock and blow the extension's memory budget.
//
// The widget therefore renders exactly what the app last knew, and says so honestly when the
// snapshot is missing rather than inventing an empty day.

struct CoverageEntry: TimelineEntry {
    let date: Date
    /// nil = nothing has been written yet (fresh install, or capture never started).
    let snapshot: CoverageSnapshot?

    static func current(now: Date = Date()) -> CoverageEntry {
        CoverageEntry(date: now, snapshot: CoverageSnapshot.loadFromAppGroup())
    }

    /// Redacted-placeholder + gallery sample: shape-accurate, obviously not real data.
    static func placeholder(now: Date = Date()) -> CoverageEntry {
        let dayStart = Int64(now.timeIntervalSince1970 * 1000) - 10 * 3600 * 1000
        func span(_ kind: CoverageSnapshot.Span.Kind, _ fromHr: Double, _ toHr: Double)
            -> CoverageSnapshot.Span
        {
            CoverageSnapshot.Span(
                kind: kind,
                startMs: dayStart + Int64(fromHr * 3_600_000),
                endMs: dayStart + Int64(toHr * 3_600_000)
            )
        }
        return CoverageEntry(
            date: now,
            snapshot: CoverageSnapshot(
                generatedAtMs: Int64(now.timeIntervalSince1970 * 1000),
                dateKey: "",
                dayStartMs: dayStart,
                nowMs: dayStart + 10 * 3_600_000,
                spans: [
                    span(.recorded, 2, 4.4), span(.quiet, 4.4, 5.8), span(.recorded, 5.8, 8.7),
                    span(.missing, 8.7, 8.9), span(.recorded, 8.9, 10),
                ],
                totalRecordedMs: Int64(4.2 * 3_600_000),
                totalMissingMs: 60_000,
                headline: Copy.Status.recording,
                detail: nil,
                dot: "active",
                isRecording: true
            )
        )
    }
}

struct CoverageProvider: TimelineProvider {
    func placeholder(in context: Context) -> CoverageEntry { .placeholder() }

    func getSnapshot(in context: Context, completion: @escaping (CoverageEntry) -> Void) {
        // The widget gallery must never show a stranger's real day; everywhere else is live.
        completion(context.isPreview ? .placeholder() : .current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CoverageEntry>) -> Void) {
        let entry = CoverageEntry.current()
        // ~15 min cadence. The app also calls `WidgetCenter.reloadTimelines` on the snapshot
        // triggers (segment close, pause, background), so this is only the floor.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date)
            ?? entry.date.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct CoverageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CoverageEntry

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
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(headline)
                .font(AppFont.cardHead)
                .foregroundStyle(Tokens.label)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
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
            Text(headline)
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

    // MARK: - Derived

    /// The status headline comes from the snapshot already in approved plain language; the
    /// widget never re-derives status vocabulary of its own (U9).
    private var headline: String {
        let text = entry.snapshot?.headline ?? ""
        return text.isEmpty ? Copy.Status.notRecording : text
    }

    private var dotColor: Color {
        switch entry.snapshot?.dot {
        case "active": return Tokens.good
        case "attention", "consent": return Tokens.attention
        case "problem": return Tokens.destructive
        case "info": return Tokens.tint
        default: return Tokens.neutralDot
        }
    }
}

struct CoverageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedAppGroup.coverageWidgetKind, provider: CoverageProvider()) {
            entry in
            CoverageWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's coverage")
        .description("What your Pebble captured today — recorded, quiet, and missing.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

#Preview("Small", as: .systemSmall) {
    CoverageWidget()
} timeline: {
    CoverageEntry.placeholder()
    CoverageEntry(date: Date(), snapshot: nil)
}

#Preview("Medium", as: .systemMedium) {
    CoverageWidget()
} timeline: {
    CoverageEntry.placeholder()
}
