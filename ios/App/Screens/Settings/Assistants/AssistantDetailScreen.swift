import CompanionRuntime
import SwiftUI

/// One assistant (round 3: 08): what it may do, what it read and added, by day, and the way to
/// end its access. Built from the server's AI-read log (`aiReads`, the last twenty tool calls),
/// which names the tool and the ids it was given, never the words it searched for.
struct AssistantDetailScreen: View {
    let accessId: String

    private var source: AssistantsSource { SettingsDataSources.current.assistants }

    @Environment(AppRouter.self) private var router
    @State private var titles: [String: String] = [:]
    @State private var confirmDisconnect = false
    @State private var disconnectFailed = false

    var body: some View {
        AssistantScroll {
            if let access {
                header(access)
                AssistantCard {
                    AssistantStateHead(
                        dot: Tokens.good, heading: Copy.AssistantAccess.detailHeading,
                        line: Copy.AssistantAccess.detailLine(
                            connected: access.connectedAtMs.map { AssistantTime.longDay($0) },
                            clips: source.sync.preferences.clips,
                            add: source.sync.preferences.edits && access.canWrite))
                }
                activity(access)
                AssistantList {
                    Button {
                        disconnectFailed = false
                        confirmDisconnect = true
                    } label: {
                        Text(Copy.AssistantAccess.disconnect(access.name))
                            .font(AppFont.callout)
                            .foregroundStyle(Tokens.destructive)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
                AssistantFooter(
                    text: disconnectFailed
                        ? Copy.AssistantAccess.disconnectFailed : Copy.AssistantAccess.disconnectFooter(access.name),
                    color: disconnectFailed ? Tokens.attention : Tokens.tertiary)
                .confirmationDialog(
                    Copy.AssistantAccess.disconnectTitle(access.name), isPresented: $confirmDisconnect,
                    titleVisibility: .visible
                ) {
                    Button(Copy.AssistantAccess.disconnect(access.name), role: .destructive) {
                        disconnect(access)
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .navigationTitle(access?.name ?? Copy.AssistantAccess.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } }
        .task(id: reads.count) {
            let ids = reads.flatMap(\.ids).filter { $0.hasPrefix("conv") }
            guard !ids.isEmpty else { return }
            titles = await source.titles(conversationIds: Array(Set(ids)))
        }
    }

    private var access: ArchiveServerStatus.Access? {
        source.assistants.first { $0.id == accessId }
    }

    /// This assistant's entries in the read log, newest first.
    private var reads: [ArchiveServerStatus.AiRead] {
        guard let access else { return [] }
        return (source.status.server?.aiReads ?? [])
            .filter { $0.client.caseInsensitiveCompare(access.name) == .orderedSame }
            .sorted { ($0.atMs ?? 0) > ($1.atMs ?? 0) }
    }

    private func header(_ access: ArchiveServerStatus.Access) -> some View {
        HStack(spacing: 14) {
            BrandTile(mark: BrandMark.forAssistant(named: access.name), size: .header)
            Text(access.name)
                .font(AppFont.tabTitle)
                .kerning(0.37)
                .foregroundStyle(Tokens.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.vertical, 4)
    }

    // MARK: What it read

    struct Item: Identifiable {
        var id: String
        var symbol: String
        var title: String
        var subtitle: String
        var route: Route?
    }

    private var items: [(day: String, items: [Item])] {
        var days: [(String, [Item])] = []
        for (index, read) in reads.enumerated() {
            let at = read.atMs ?? source.nowMs
            let day = AssistantTime.dayHeader(at, nowMs: source.nowMs)
            let made = Self.items(read, index: index, titles: titles, nowMs: source.nowMs)
            guard !made.isEmpty else { continue }
            if let last = days.last, last.0 == day {
                days[days.count - 1].1 += made
            } else {
                days.append((day, made))
            }
        }
        return days.map { (day: $0.0, items: $0.1) }
    }

    @ViewBuilder
    private func activity(_ access: ArchiveServerStatus.Access) -> some View {
        let days = items
        if days.isEmpty {
            AssistantList {
                Text(Copy.AssistantAccess.nothingReadYet)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.tertiary)
            }
        }
        ForEach(days, id: \.day) { day in
            AssistantSectionHeader(title: day.day)
            AssistantList {
                ForEach(day.items) { item in
                    if let route = item.route {
                        Button { router.navigate(to: route) } label: { row(item, chevron: true) }
                            .buttonStyle(.plain)
                    } else {
                        row(item, chevron: false)
                    }
                }
            }
        }
    }

    private func row(_ item: Item, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            GlyphTile(systemName: item.symbol, style: .neutral)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.subtitle)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if chevron { AssistantChevron() }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// One log entry as rows: a read of a conversation opens it, a day its recap, a brief its
    /// week or month; a search or a listing has nothing to open.
    static func items(
        _ read: ArchiveServerStatus.AiRead, index: Int, titles: [String: String], nowMs: Int64
    ) -> [Item] {
        let at = read.atMs ?? nowMs
        let time = AssistantTime.clock(at)
        let readLine = "\(Copy.AssistantAccess.readPrefix) · \(time)"
        func conversationRows(_ prefix: (String) -> String = { $0 }) -> [Item] {
            read.ids.filter { $0.hasPrefix("conv") }.map { id in
                Item(
                    id: "\(index)-\(id)", symbol: "doc.text",
                    title: prefix(titles[id] ?? Copy.AssistantAccess.untitledConversation),
                    subtitle: readLine, route: .conversation(id: id, atMs: nil))
            }
        }
        func plain(_ symbol: String, _ title: String) -> [Item] {
            [Item(id: "\(index)", symbol: symbol, title: title, subtitle: time, route: nil)]
        }
        switch read.tool {
        case "fetch", "get_conversation", "resource:conversation":
            return conversationRows()
        case "get_audio":
            return read.ids.filter { $0.hasPrefix("conv") }.map { id in
                Item(
                    id: "\(index)-\(id)", symbol: "waveform",
                    title: Copy.AssistantAccess.clipOf(titles[id] ?? Copy.AssistantAccess.untitledConversation),
                    subtitle: time, route: .conversation(id: id, atMs: nil))
            }
        case "search":
            return plain("magnifyingglass", Copy.AssistantAccess.searched)
        case "get_day", "resource:day":
            guard let day = read.ids.first(where: { !$0.hasPrefix("conv") }) else { return [] }
            return [
                Item(
                    id: "\(index)-\(day)", symbol: "calendar", title: recapTitle(day, nowMs: nowMs),
                    subtitle: readLine, route: .history(date: day, level: "day"))
            ]
        case "get_brief":
            guard let key = read.ids.first else { return [] }
            let isMonth = key.hasPrefix("month:")
            let start = String(key.drop(while: { $0 != ":" }).dropFirst())
            let day = isMonth ? start + "-01" : start
            let title: String
            if let ms = Self.dayMs(day) {
                title = isMonth
                    ? Copy.AssistantAccess.monthBrief(Date(timeIntervalSince1970: Double(ms) / 1000).formatted(.dateTime.month(.wide)))
                    : Copy.AssistantAccess.weekBrief(AssistantTime.longDay(ms))
            } else {
                title = key
            }
            return [
                Item(
                    id: "\(index)-\(key)", symbol: "calendar", title: title, subtitle: readLine,
                    route: .history(date: day, level: isMonth ? "month" : "week"))
            ]
        case "list_conversations": return plain("list.bullet", Copy.AssistantAccess.listedConversations)
        case "list_days": return plain("list.bullet", Copy.AssistantAccess.listedDays)
        case "list_follow_ups": return plain("checklist", Copy.AssistantAccess.listedFollowUps)
        case "get_people": return plain("person.2", Copy.AssistantAccess.lookedUpPeople)
        case "get_tags": return plain("tag", Copy.AssistantAccess.lookedUpTags)
        case "create_follow_up": return plain("plus.circle", Copy.AssistantAccess.addedFollowUp)
        case "update_follow_up": return plain("checklist", Copy.AssistantAccess.changedFollowUp)
        case "create_note": return plain("note.text", Copy.AssistantAccess.addedNote)
        default:
            return []
        }
    }

    /// "Monday's recap" within the last week, else "October 3 recap".
    static func recapTitle(_ dayKey: String, nowMs: Int64) -> String {
        guard let ms = dayMs(dayKey) else { return Copy.AssistantAccess.recapOf(dayKey) }
        if nowMs - ms < 6 * 86_400_000 {
            return Copy.AssistantAccess.weekdayRecap(AssistantTime.weekday(ms))
        }
        return Copy.AssistantAccess.recapOf(AssistantTime.longDay(ms))
    }

    /// Noon of a `YYYY-MM-DD` day here (a safe instant inside it).
    static func dayMs(_ key: String) -> Int64? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func disconnect(_ access: ArchiveServerStatus.Access) {
        Task {
            if await source.revoke(access) {
                source.flow.detailAccessId = nil
            } else {
                disconnectFailed = true
            }
        }
    }
}
