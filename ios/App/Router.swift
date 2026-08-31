import Foundation

/// The part of a conversation a citation points at: a member segment, narrowed to a
/// wall-clock stretch of it when the citation knows one.
struct TranscriptFocus: Equatable, Hashable {
    var segmentId: String
    var startMs: Int64?
    var endMs: Int64?

    /// Does this row belong to the cited stretch? Times win when they exist — they are what
    /// makes the highlight a few lines instead of a whole recording — and the member is the
    /// fallback for citations stored before stretches existed.
    func contains(segmentId rowSegmentId: String, at startedAt: Date?) -> Bool {
        guard let startMs, let endMs else { return rowSegmentId == segmentId }
        guard let startedAt else { return false }
        let ms = Int64(startedAt.timeIntervalSince1970 * 1000)
        // Inclusive of the end: a stretch ends where the next one begins, and a row landing
        // exactly on the boundary belongs to the one that cited it.
        return ms >= startMs && ms <= endMs
    }
}

/// The complete deep-link route space (plan Part 6.8, scheme `companion://`). Every screen is
/// addressable — Spotlight donations, the loss notification, widgets, and Siri all target
/// these routes.
enum Route: Equatable, Hashable, Identifiable {
    var id: String { url.absoluteString }

    case today(date: String?)          // companion://today[?date=YYYY-MM-DD]
    /// `focus` is the stretch a citation chip sent us to: the transcript scrolls to it, marks
    /// those lines, and offers to play from there. Nil for every ordinary open.
    case conversation(id: String, atMs: Int64?, focus: TranscriptFocus? = nil)
    case live
    case library(tag: String?)
    case search(query: String?)
    case ask(scope: String?, query: String?)
    case note(id: String)
    case settings(SettingsPage?)

    enum SettingsPage: String, Equatable {
        case watch, transcription, storage, aboutyou, diagnostics
    }

    static let scheme = "companion"

    static func parse(_ url: URL) -> Route? {
        guard url.scheme == scheme else { return nil }
        let host = url.host ?? ""
        let pathParts = url.path.split(separator: "/").map(String.init)
        let query = url.queryItems

        switch host {
        case "today":
            return .today(date: query["date"])
        case "conversation":
            guard let id = pathParts.first else { return nil }
            let t = query["t"].flatMap { Int64($0) }
            let focus = query["s"].map {
                TranscriptFocus(
                    segmentId: $0,
                    startMs: query["fs"].flatMap { Int64($0) },
                    endMs: query["fe"].flatMap { Int64($0) })
            }
            return .conversation(id: id, atMs: t, focus: focus)
        case "live":
            return .live
        case "library":
            return .library(tag: query["tag"])
        case "search":
            return .search(query: query["q"])
        case "ask":
            return .ask(scope: query["scope"], query: query["q"])
        case "note":
            guard let id = pathParts.first else { return nil }
            return .note(id: id)
        case "settings":
            if let page = pathParts.first {
                guard let p = SettingsPage(rawValue: page) else { return nil }
                return .settings(p)
            }
            return .settings(nil)
        default:
            return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Route.scheme
        switch self {
        case .today(let date):
            components.host = "today"
            if let date { components.queryItems = [.init(name: "date", value: date)] }
        case .conversation(let id, let atMs, let focus):
            components.host = "conversation"
            components.path = "/\(id)"
            var items: [URLQueryItem] = []
            if let atMs { items.append(.init(name: "t", value: String(atMs))) }
            if let focus {
                items.append(.init(name: "s", value: focus.segmentId))
                if let start = focus.startMs {
                    items.append(.init(name: "fs", value: String(start)))
                }
                if let end = focus.endMs { items.append(.init(name: "fe", value: String(end))) }
            }
            if !items.isEmpty { components.queryItems = items }
        case .live:
            components.host = "live"
        case .library(let tag):
            components.host = "library"
            if let tag { components.queryItems = [.init(name: "tag", value: tag)] }
        case .search(let q):
            components.host = "search"
            if let q { components.queryItems = [.init(name: "q", value: q)] }
        case .ask(let scope, let q):
            components.host = "ask"
            var items: [URLQueryItem] = []
            if let scope { items.append(.init(name: "scope", value: scope)) }
            if let q { items.append(.init(name: "q", value: q)) }
            if !items.isEmpty { components.queryItems = items }
        case .note(let id):
            components.host = "note"
            components.path = "/\(id)"
        case .settings(let page):
            components.host = "settings"
            if let page { components.path = "/\(page.rawValue)" }
        }
        return components.url!
    }
}

private extension URL {
    var queryItems: [String: String] {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return [:] }
        return Dictionary(
            items.compactMap { i in i.value.flatMap { $0.isEmpty ? nil : (i.name, $0) } }
        ) { a, _ in a }
    }
}
