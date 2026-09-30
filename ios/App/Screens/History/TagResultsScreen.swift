import AppDB
import SwiftUI

/// Everything carrying one topic (plan 5.7): pushed from a topic pill at any level, or from a
/// tag chosen in Search. Newest first, grouped by day, each row in the week-row style and
/// opening its moment.
struct TagResultsScreen: View {
    let tag: String
    var source: any HistoryDataSource = HistoryDataSources.current.history
    let todayKey: String
    var openMoment: (Int64) -> Void

    @State private var results: [HistoryTagResult]?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HistoryPageTitle(title: tag, subtitle: subtitle)
                if let results {
                    if results.isEmpty {
                        Text(Copy.History.noTagResults)
                            .font(AppFont.historyBody(dynamicTypeSize))
                            .foregroundStyle(Tokens.meta)
                            .padding(.horizontal, 4)
                    } else {
                        ForEach(days(results), id: \.key) { day in
                            section(day.key, rows: day.rows)
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.bottom, Tokens.blockGap)
        }
        .background(Tokens.ground)
        .navigationTitle(tag)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .task { results = await source.tagResults(tag: tag) }
    }

    private var subtitle: String? {
        guard let results, !results.isEmpty else { return nil }
        return Copy.History.tagResultsCount(
            results: results.count, days: Set(results.map(\.dateKey)).count)
    }

    private func days(_ results: [HistoryTagResult]) -> [(key: String, rows: [HistoryTagResult])] {
        var order: [String] = []
        var groups: [String: [HistoryTagResult]] = [:]
        for result in results {
            if groups[result.dateKey] == nil { order.append(result.dateKey) }
            groups[result.dateKey, default: []].append(result)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func section(_ dateKey: String, rows: [HistoryTagResult]) -> some View {
        let zone = rows.first.flatMap { TimeZone(identifier: $0.zoneID) } ?? .current
        let title = HistoryFormat.dayTitle(dateKey, todayKey: todayKey, zone: zone)
        let header = dateKey == todayKey ? title.title : "\(title.title), \(title.subtitle)"
        return VStack(alignment: .leading, spacing: 8) {
            Text(header.uppercased())
                .font(AppFont.sectionHeader)
                .foregroundStyle(Tokens.meta)
                .kerning(0.4)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            ListCard {
                ForEach(rows) { TagResultRow(result: $0) { openMoment($0.startMs) } }
            }
        }
        .padding(.bottom, 20)
    }
}

/// One result in the week-row style: title, time line, two lines of summary, chevron.
private struct TagResultRow: View {
    let result: HistoryTagResult
    let onOpen: (HistoryTagResult) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let zone = TimeZone(identifier: result.zoneID) ?? .current
        let range = HistoryFormat.timeRange(result.startMs, result.endMs, zone: zone)
        let duration = HistoryFormat.duration(ms: result.endMs - result.startMs)
        Button { onOpen(result) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(result.title)
                        .font(AppFont.rowTitle)
                        .foregroundStyle(Tokens.label)
                        .lineLimit(1)
                    Text("\(range) · \(duration)")
                        .font(AppFont.timelineMeta)
                        .foregroundStyle(Tokens.meta)
                        .padding(.top, 2)
                    if let summary = result.summary, !summary.isEmpty {
                        Text(summary)
                            .font(AppFont.scaled(13, relativeTo: .footnote, dynamicTypeSize))
                            .foregroundStyle(Tokens.tertiary)
                            .lineSpacing(1.5)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Copy.History.A11y.openHint)
    }
}
