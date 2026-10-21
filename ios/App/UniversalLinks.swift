import CompanionRuntime
import Foundation

/// The server's own pages that open in the app (`applinks:pebbleaudio.okgodoit.com`): its viewer
/// links (`server/docs/tool-results.md`, "Viewer links") and its Link a phone page. Each maps onto
/// a screen the app already has; anything else stays in Safari.
enum UniversalLink: Equatable {
    /// `/link?code=…`: the Link step with the code filled in.
    case link(ArchiveLinkInvitation)
    /// `/c/{id}?t={seconds from the conversation's start}`.
    case conversation(id: String, secondsFromStart: Int?)
    /// `/d/{YYYY-MM-DD}`.
    case day(String)
    /// `/b/week/{YYYY-MM-DD}`, the week's first day.
    case week(String)
    /// `/b/month/{YYYY-MM}`.
    case month(String)

    /// The hosts whose pages these are: the product's own server, and the one this phone links.
    static func parse(_ url: URL, servers: [String]) -> UniversalLink? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
            servers.map({ $0.lowercased() }).contains(host)
        else { return nil }
        if let invitation = ArchiveLinkInvitation.parse(url) { return .link(invitation) }
        let parts = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch parts.first {
        case "c":
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            // A `t` that is not a whole number of seconds is not a moment: open from the top.
            let seconds = query.first(where: { $0.name == "t" })?.value.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
            return .conversation(id: parts[1], secondsFromStart: seconds)
        case "d":
            guard parts.count == 2, isDay(parts[1]) else { return nil }
            return .day(parts[1])
        case "b":
            guard parts.count == 3 else { return nil }
            if parts[1] == "week", isDay(parts[2]) { return .week(parts[2]) }
            if parts[1] == "month", isMonth(parts[2]) { return .month(parts[2]) }
            return nil
        default:
            return nil
        }
    }

    static func isDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-")
        return parts.count == 3 && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    static func isMonth(_ text: String) -> Bool {
        let parts = text.split(separator: "-")
        return parts.count == 2 && parts[0].count == 4 && parts[1].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// The route for every link but a conversation moment, which needs the conversation's start
    /// (`AppRouter.open(_:)` looks it up).
    var route: Route? {
        switch self {
        case .link: return .settings(.server)
        case .conversation(let id, nil): return .conversation(id: id, atMs: nil)
        case .conversation: return nil
        case .day(let day): return .history(date: day, level: "day")
        case .week(let day): return .history(date: day, level: "week")
        case .month(let month): return .history(date: month + "-01", level: "month")
        }
    }
}

extension AppRouter {
    /// Opens a universal link: a link code into the AI Assistants setup, a moment into its
    /// conversation, a day, week, or month into History.
    @MainActor
    func open(_ link: UniversalLink) {
        switch link {
        case .link(let invitation):
            navigate(to: .settings(.server))
            SettingsDataSources.current.assistants.receive(invitation)
        case .conversation(let id, let seconds?):
            Task { @MainActor in
                let display = try? await AskLibraryDataSources.current.conversations.display(id: id)
                guard let start = display?.startedAt else {
                    navigate(to: .conversation(id: id, atMs: nil))
                    return
                }
                let wall = Int64(start.timeIntervalSince1970 * 1000) + Int64(seconds) * 1000
                navigate(to: await Route.moment(atWallMs: wall, inConversation: id) ?? .conversation(id: id, atMs: nil))
            }
        default:
            if let route = link.route { navigate(to: route) }
        }
    }
}
