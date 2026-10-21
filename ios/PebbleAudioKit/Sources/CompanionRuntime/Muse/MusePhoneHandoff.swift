import Foundation
import MuseLink

/// Part of a Muse answer that only the phone can open (a web page, a map, a card, a file), handed
/// over with a notification on the phone that opens exactly that. The watch says it went there.
public struct MusePhoneHandoff: Sendable, Equatable {
    public struct Action: Sendable, Equatable {
        public let title: String
        public let url: URL
    }

    /// Every handoff's title starts with "Muse": the watch firmware recognises the phone's copy of
    /// it by that, and drops it (it showed the answer already).
    public let title: String
    public let body: String
    /// What a tap opens.
    public let url: URL
    /// More to open, from the notification's long press.
    public let actions: [Action]
    /// The line the watch shows at the end of the answer in place of "See it in Muse".
    public let watchLine: String
}

/// Where a phone notification about a Muse answer should lead, decided from the answer alone.
///
/// The order is what someone most likely wants to do next: a card or map is opened in Muse (only
/// it draws them), a single map place in Maps, a single link in its own app or Safari, several
/// links from the Muse chat with one button each, a file in Muse, the rest of an answer too long
/// for the watch in Muse, and a lone phone number or address straight in Phone or Maps. Option
/// buttons, citations and plain text need no phone: the watch has them.
public enum MusePhoneHandoffPlanner {
    /// The most actions a notification shows.
    static let maxActions = 3

    public static func plan(raw: String, widgets: [MuseWidget], truncated: Bool, chat: URL?) -> MusePhoneHandoff? {
        let links = links(in: raw, widgets: widgets)
        let cards = widgets.filter(\.needsAScreen)
        let openInMuse = chat.map { MusePhoneHandoff.Action(title: "Open in Muse", url: $0) }
        let linkActions = links.prefix(maxActions).map { MusePhoneHandoff.Action(title: "Open \(shortTitle($0.title))", url: $0.url) }
        let plain = plainText(raw)
        let phones = detect(.phoneNumber, in: plain)
        let addresses = detect(.address, in: plain)

        if !cards.isEmpty {
            let places = cards.flatMap(\.places)
            if cards.count == 1, places.count == 1, let maps = mapsURL(places[0]) {
                return MusePhoneHandoff(
                    title: "Muse sent a place", body: places[0].name, url: maps,
                    actions: openInMuse.map { [$0] } ?? [], watchLine: "Place sent to your phone")
            }
            let isMap = cards.contains { $0.kind?.lowercased().contains("map") == true || !$0.places.isEmpty }
            guard let target = chat ?? links.first?.url else { return nil }
            let body = cards.compactMap(\.title).first ?? cards.first?.lines.first ?? firstLine(plain) ?? "Open it in Muse."
            return MusePhoneHandoff(
                title: isMap ? "Muse sent a map" : "Muse sent a card", body: body, url: target,
                actions: Array(linkActions), watchLine: isMap ? "Map sent to your phone" : "Card sent to your phone")
        }
        if let file = attachment(in: raw), let chat {
            return MusePhoneHandoff(
                title: "Muse sent a file", body: file, url: chat, actions: Array(linkActions),
                watchLine: "File sent to your phone")
        }
        if links.count == 1 {
            let link = links[0]
            return MusePhoneHandoff(
                title: "Muse sent a link", body: link.title, url: link.url,
                actions: openInMuse.map { [$0] } ?? [], watchLine: "Link sent to your phone")
        }
        if links.count > 1 {
            let body = links.prefix(maxActions).map(\.title).joined(separator: ", ")
            return MusePhoneHandoff(
                title: "Muse sent links", body: links.count > maxActions ? body + "\u{2026}" : body,
                url: chat ?? links[0].url, actions: Array(linkActions), watchLine: "Links sent to your phone")
        }
        if truncated, let chat {
            return MusePhoneHandoff(
                title: "Muse's full answer", body: firstLine(plain) ?? "", url: chat, actions: [],
                watchLine: "The rest is on your phone")
        }
        if phones.count == 1, addresses.isEmpty, let tel = telURL(phones[0]) {
            return MusePhoneHandoff(
                title: "Muse sent a number", body: phones[0], url: tel, actions: openInMuse.map { [$0] } ?? [],
                watchLine: "Number sent to your phone")
        }
        if addresses.count == 1, let maps = mapsURL(query: addresses[0]) {
            return MusePhoneHandoff(
                title: "Muse sent an address", body: addresses[0], url: maps, actions: openInMuse.map { [$0] } ?? [],
                watchLine: "Address sent to your phone")
        }
        return nil
    }

    struct Link: Equatable {
        let title: String
        let url: URL
    }

    /// Markdown links, bare links and link rows, in order, once each. Attachments in Muse's
    /// workspace (`sandbox://`) are files, not links.
    static func links(in raw: String, widgets: [MuseWidget]) -> [Link] {
        var found: [Link] = []
        func add(_ title: String, _ text: String) {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased(),
                scheme != "sandbox", !found.contains(where: { $0.url == url })
            else { return }
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(Link(title: name.isEmpty ? (url.host ?? text) : name, url: url))
        }
        var rest = raw
        for match in raw.matches(of: markdownLink) where !match.output.0.hasPrefix("!") {
            add(String(match.output.1), String(match.output.2))
        }
        rest = rest.replacing(markdownLink, with: "")
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for result in detector.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                guard let url = result.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                add(url.host ?? url.absoluteString, url.absoluteString)
            }
        }
        for widget in widgets {
            for link in widget.links { add(link.title, link.url) }
        }
        return found
    }

    /// `[title](url)`, and `![alt](url)` (an attachment, told apart by its `!`).
    nonisolated(unsafe) static let markdownLink = /!?\[([^\]\n]*)\]\(([a-zA-Z][a-zA-Z0-9+.-]*:[^)\s]+)\)/

    static func attachment(in raw: String) -> String? {
        for match in raw.matches(of: markdownLink) where match.output.0.hasPrefix("!") && match.output.2.hasPrefix("sandbox:") {
            let alt = match.output.1.trimmingCharacters(in: .whitespaces)
            return alt.isEmpty ? "A file" : alt
        }
        return nil
    }

    /// The answer's words, without Markdown links' targets or widget placeholders.
    static func plainText(_ raw: String) -> String {
        MuseWidget.removingPlaceholders(raw.replacing(markdownLink) { String($0.output.1) })
    }

    static func detect(_ type: NSTextCheckingResult.CheckingType, in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: type.rawValue) else { return [] }
        var found: [String] = []
        for result in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(result.range, in: text) else { continue }
            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !found.contains(value) { found.append(value) }
        }
        return found
    }

    static func telURL(_ number: String) -> URL? {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        return digits.count >= 3 ? URL(string: "tel:\(digits)") : nil
    }

    static func mapsURL(_ place: MuseWidget.Place) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        var items = [URLQueryItem(name: "q", value: place.name)]
        if let latitude = place.latitude, let longitude = place.longitude {
            items.append(URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"))
        }
        components?.queryItems = items
        return components?.url
    }

    static func mapsURL(query: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: query.replacingOccurrences(of: "\n", with: ", "))]
        return components?.url
    }

    static func firstLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > 120 ? String(line.prefix(119)) + "\u{2026}" : line
    }

    static func shortTitle(_ title: String) -> String {
        title.count > 28 ? String(title.prefix(27)) + "\u{2026}" : title
    }

    /// Muse's chat in its iPhone app: the watch's own chat is a thread of its own; the main chat
    /// is the app's chat. (muse.ai's universal links include /chat and /thread/*.)
    public static func chatURL(watchChatID: String?) -> URL? {
        guard let watchChatID else { return URL(string: "https://muse.ai/chat") }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        guard let id = watchChatID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://muse.ai/thread/\(id)")
    }
}

/// Posts a handoff on the phone; the app's is a local notification.
public protocol MusePhoneHandoffPosting: Sendable {
    /// True when the notification was posted (the person allows them, and isn't already looking
    /// at the app).
    func post(_ handoff: MusePhoneHandoff) async -> Bool
}
