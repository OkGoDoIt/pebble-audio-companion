import Foundation

/// A widget Muse put in an answer: `[[hatch_widget:<id>]]` in the text, its contents in the
/// message's `widgets`. The Muse app draws it; a screen without widgets shows its words.
///
/// What Muse said of its own widgets (2026-10-21): option buttons (`muse.create_options`, a tap
/// sends the option's exact text as the person's next message), lists (rows that open a link,
/// send a message, or show a flight), maps (places and pins), HTML cards (with a `fallback_text`
/// for screens that can't draw them), and cards for shopping, ideas, sharing and navigation.
/// Meta doesn't document the wire form, so this reads it loosely: the reply a button or row
/// sends, and the words that describe the rest.
public struct MuseWidget: Sendable, Equatable {
    /// Something the person can pick: what it says, and the message picking it sends.
    public struct Option: Sendable, Equatable {
        public let label: String
        public let reply: String

        public init(_ label: String, reply: String? = nil) {
            self.label = label
            self.reply = reply ?? label
        }
    }

    /// A row that opens a web page or an app.
    public struct Link: Sendable, Equatable {
        public let title: String
        public let url: String

        public init(title: String, url: String) {
            self.title = title
            self.url = url
        }
    }

    /// A place on a map, with where it is when Muse says.
    public struct Place: Sendable, Equatable {
        public let name: String
        public let latitude: Double?
        public let longitude: Double?

        public init(name: String, latitude: Double? = nil, longitude: Double? = nil) {
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public let id: String
    /// What the widget says it is (`"kind": "options"`), when it says.
    public let kind: String?
    /// Its own words for itself: a fallback text, a title, what a map answers.
    public let title: String?
    /// Lines that describe it and can't be picked: places on a map, list rows that are links.
    public let lines: [String]
    public let options: [Option]
    /// What its rows open (list rows of type `link`).
    public let links: [Link]
    /// The places on a map.
    public let places: [Place]

    public init(
        id: String, kind: String? = nil, title: String? = nil, lines: [String] = [], options: [Option] = [],
        links: [Link] = [], places: [Place] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.lines = lines
        self.options = options
        self.links = links
        self.places = places
    }

    /// Something only a phone shows properly: anything beyond buttons and rows that send a message.
    public var needsAScreen: Bool { !lines.isEmpty || !links.isEmpty || !places.isEmpty || (title != nil && !isChoice) }

    /// Something to pick from: buttons, or list rows that send a message.
    public var isChoice: Bool { !options.isEmpty }

    /// Only buttons: their words say all of it.
    public var isOnlyOptionsWidget: Bool { isChoice && lines.isEmpty }

    /// What stands in for the widget in plain text: buttons as their words, one per line; anything
    /// more (a map, a chart, a card) its words and `elsewhere`, a pointer to where it can be seen.
    /// `optionsApart`: the screen shows the options on their own (as buttons), so the text
    /// leaves them out.
    public func plainText(elsewhere: String, optionsApart: Bool = false) -> String {
        if isOnlyOptionsWidget { return optionsApart ? "" : options.map(\.label).joined(separator: "\n") }
        var parts: [String] = []
        if let title { parts.append(title) }
        parts += lines
        if !optionsApart { parts += options.map(\.label) }
        if !elsewhere.isEmpty { parts.append(elsewhere) }
        return parts.joined(separator: "\n")
    }

    static let placeholderPrefix = "[[hatch_widget:"
    static let idKeys = ["widget_id", "id", "widgetId", "key"]
    static let kindKeys = ["kind", "type", "widget_type", "widgetType", "component"]
    /// Plain words for a widget, best first: `fallback_text` is Muse's own label for screens
    /// that can't draw it.
    static let titleKeys = [
        "fallback_text", "fallbackText", "display_text", "displayText", "title", "motivation", "question", "prompt",
        "heading", "header",
    ]
    /// Lists of buttons, Muse's own and any another widget carries.
    static let buttonKeys = ["options", "choices", "buttons", "answers", "quick_replies", "replies", "suggestions"]
    static let labelKeys = ["label", "title", "text", "display_text", "displayText", "name", "value", "content"]
    static let maxDepth = 5
    static let maxEntries = 24

    /// Every widget in a message's `widgets` (or `presentations`): a list, or an object keyed by id.
    public static func collect(_ value: MuseJSON?) -> [MuseWidget] {
        guard let value else { return [] }
        if let list = value.array {
            return list.enumerated().compactMap { parse($1, fallbackID: "#\($0)") }
        }
        guard let object = value.object else { return [] }
        // One widget on its own, rather than a map of them.
        if idKeys.contains(where: { object[$0]?.string != nil }) {
            return parse(value, fallbackID: nil).map { [$0] } ?? []
        }
        return object.keys.sorted().compactMap { parse(object[$0]!, fallbackID: $0) }
    }

    static func parse(_ value: MuseJSON, fallbackID: String?) -> MuseWidget? {
        guard let object = value.object else { return nil }
        let id = idKeys.lazy.compactMap { object[$0]?.string }.first(where: { !$0.isEmpty }) ?? fallbackID
        guard let id, !id.isEmpty else { return nil }
        var reading = Reading()
        reading.read(value, depth: 0)
        return MuseWidget(
            id: id, kind: kindKeys.lazy.compactMap { object[$0]?.string }.first(where: { !$0.isEmpty }),
            title: title(in: value, depth: 0), lines: reading.lines, options: reading.options,
            links: reading.links, places: reading.places)
    }

    /// Walks a widget for the parts a watch can use, wherever its spec nests them.
    struct Reading {
        var options: [Option] = []
        var lines: [String] = []
        var links: [Link] = []
        var places: [Place] = []
        var found = false

        mutating func read(_ value: MuseJSON, depth: Int) {
            guard !found, depth <= maxDepth else { return }
            if let object = value.object {
                // A list widget's rows.
                if let items = object["items"]?.array, items.contains(where: { $0.object != nil }) {
                    readRows(items)
                    if found { return }
                }
                // A map's places and pins.
                if let elements = object["elements"]?.array, elements.contains(where: { $0.object != nil }) {
                    lines = Array(elements.compactMap(MuseWidget.placeName).prefix(maxEntries))
                    places = Array(elements.compactMap(MuseWidget.place).prefix(maxEntries))
                    found = !lines.isEmpty
                    if found { return }
                }
                // Buttons: Muse's option buttons, or another widget's.
                for key in buttonKeys {
                    let labels = (object[key]?.array ?? []).compactMap(MuseWidget.label)
                    if !labels.isEmpty {
                        options = Array(labels.prefix(maxEntries).map { Option($0) })
                        found = true
                        return
                    }
                }
                for key in object.keys.sorted() { read(object[key]!, depth: depth + 1) }
            } else if let list = value.array {
                for item in list { read(item, depth: depth + 1) }
            }
        }

        /// A row that sends a message is something to pick; any other row is a line to read.
        mutating func readRows(_ items: [MuseJSON]) {
            for item in items.prefix(maxEntries) {
                guard let row = item.object else { continue }
                let words = ["title", "subtitle", "tertiary_title"].compactMap { row[$0]?.string.flatMap(MuseWidget.clean) }
                let send = row["type"]?.string == "send_message" ? row["data"]?["text"]?.string.flatMap(MuseWidget.clean) : nil
                if let send {
                    options.append(Option(words.first ?? send, reply: send))
                } else if !words.isEmpty {
                    lines.append(words.joined(separator: " \u{00B7} "))
                }
                if send == nil, let url = (row["data"]?["url"]?.string ?? row["url"]?.string).flatMap(MuseWidget.clean) {
                    links.append(Link(title: words.first ?? url, url: url))
                }
            }
            found = !options.isEmpty || !lines.isEmpty
        }
    }

    static func place(_ value: MuseJSON) -> Place? {
        guard let object = value.object, let name = (object["name"]?.string ?? object["title"]?.string).flatMap(clean)
        else { return nil }
        let coordinate = object["coordinate"] ?? object["location"]
        return Place(
            name: name, latitude: coordinate?["latitude"]?.number ?? coordinate?["lat"]?.number,
            longitude: coordinate?["longitude"]?.number ?? coordinate?["lng"]?.number ?? coordinate?["lon"]?.number)
    }

    static func placeName(_ value: MuseJSON) -> String? {
        guard let object = value.object,
            let name = (object["name"]?.string ?? object["title"]?.string).flatMap(clean)
        else { return nil }
        if let detail = (object["category"]?.string ?? object["subtitle"]?.string).flatMap(clean) {
            return "\(name) \u{00B7} \(detail)"
        }
        return name
    }

    static func label(_ value: MuseJSON) -> String? {
        if let text = value.string { return clean(text) }
        guard let object = value.object else { return nil }
        for key in labelKeys {
            if let text = object[key]?.string, let label = clean(text) { return label }
            // {"label": {"text": "…"}}
            if let inner = object[key]?.object {
                for innerKey in labelKeys {
                    if let text = inner[innerKey]?.string, let label = clean(text) { return label }
                }
            }
        }
        return nil
    }

    static func title(in value: MuseJSON, depth: Int) -> String? {
        guard depth <= 2, let object = value.object else { return nil }
        for key in titleKeys {
            if let text = object[key]?.string, let title = clean(text) { return title }
        }
        for key in object.keys.sorted() where !buttonKeys.contains(key) && key != "items" && key != "elements" {
            if let found = title(in: object[key]!, depth: depth + 1) { return found }
        }
        return nil
    }

    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether a placeholder's id names a widget, with or without its `widget-` prefix.
    static func names(_ placed: String, _ id: String) -> Bool {
        let bare = { (s: String) in s.hasPrefix("widget-") ? String(s.dropFirst(7)) : s }
        return bare(placed) == bare(id)
    }

    /// The widget a placeholder names, or the only widget there is.
    public static func find(_ placed: String, in widgets: [MuseWidget]) -> MuseWidget? {
        widgets.first { names(placed, $0.id) } ?? (widgets.count == 1 ? widgets[0] : nil)
    }

    /// `text` with each placeholder of a known widget replaced by its words. A placeholder for a
    /// widget not seen yet stays, so a later call can fill it in.
    public static func substitute(
        _ text: String, widgets: [MuseWidget], elsewhere: String = "", optionsApart: Bool = false
    ) -> String {
        guard text.contains(placeholderPrefix), !widgets.isEmpty else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: placeholderPrefix) {
            guard let close = rest[open.upperBound...].range(of: "]]") else { break }
            let id = String(rest[open.upperBound..<close.lowerBound])
            out += rest[..<open.lowerBound]
            if let widget = find(id, in: widgets) {
                out += widget.plainText(elsewhere: elsewhere, optionsApart: optionsApart)
            } else {
                out += rest[open.lowerBound..<close.upperBound]
            }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// `text` without widget placeholders, for when a widget's contents never came.
    public static func removingPlaceholders(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: placeholderPrefix) {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "]]") else { return out }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// The ids of the widgets `text` places, in order.
    public static func placedIDs(in text: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: placeholderPrefix), let close = rest[open.upperBound...].range(of: "]]") {
            ids.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return ids
    }

    /// The question a choice answers: the last line before its placeholder that asks something,
    /// or else the last line before it.
    public static func question(before id: String, in text: String) -> String? {
        let placed = placedIDs(in: text)
        let head: Substring
        if let mine = placed.first(where: { names($0, id) }) ?? placed.first,
            let range = text.range(of: placeholderPrefix + mine + "]]")
        {
            head = text[..<range.lowerBound]
        } else {
            head = Substring(text)
        }
        let lines = head.components(separatedBy: "\n").compactMap { clean($0) }
        return lines.last(where: { $0.hasSuffix("?") }) ?? lines.last
    }

    /// What a widget looks like, for the flight recorder: keys, list lengths and value types,
    /// never its words. Only a type-like value (`"kind": "options"`) is shown.
    public static func shape(_ value: MuseJSON, depth: Int = 0, key: String? = nil) -> String {
        guard depth <= maxDepth else { return "…" }
        switch value {
        case .null: return "null"
        case .bool: return "bool"
        case .number: return "num"
        case .string(let text):
            let typeKeys: Set<String> = [
                "type", "kind", "widget_type", "component", "style", "variant", "format", "button_style", "mode", "action",
            ]
            if let key, typeKeys.contains(key), text.count <= 32,
                text.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-").contains($0) })
            {
                return "\"\(text)\""
            }
            return "s\(text.count)"
        case .array(let list):
            guard let first = list.first else { return "[]" }
            return "[\(list.count)x\(shape(first, depth: depth + 1))]"
        case .object(let object):
            let inner = object.keys.sorted().map { "\($0):\(shape(object[$0]!, depth: depth + 1, key: $0))" }
            return "{\(inner.joined(separator: ","))}"
        }
    }
}
