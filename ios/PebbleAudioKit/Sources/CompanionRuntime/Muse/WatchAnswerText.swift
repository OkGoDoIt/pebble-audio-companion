import Foundation

/// Muse's answer as the watch can show it: plain text in the watch's fonts.
///
/// Muse writes Markdown; the watch draws plain text. Emphasis marks and heading hashes go, list
/// markers become bullets, and links keep their words. Emoji stay: the watch's system fonts carry
/// an emoji set of about 1,400 glyphs, and it skips joiners and variation selectors itself.
///
/// The watch only appends, so a rendering of a partial answer must never change once sent. Every
/// rule here only deletes characters or swaps ones that are already settled, and a tail that could
/// still turn into Markdown (an open link, a lone `-` that may be a bullet) is held back until it
/// is complete or the answer is.
///
/// A widget Muse places (`[[hatch_widget:<id>]]`) arrives here already replaced by its words
/// when its contents came with it; one still waiting for them holds back everything after it,
/// and at the end it goes. Muse's other formats, as it described them (2026-10-21): a reply in
/// several bubbles is split by `<message_break/>`, which becomes a paragraph break; a file it
/// attaches is a line `![name](sandbox://workspace/…)`, which becomes a paperclip and the name;
/// a citation `【source†L12-L20】` goes; and any other `[[name…]]` marker goes.
enum WatchAnswerText {
    static let widgetMarker = "[[hatch_"

    static func render(_ markdown: String, final: Bool) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"<message_break\s*/?>"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"【[^】\n]*】"#, with: "", options: .regularExpression)
        if final {
            text = removingWidgetMarkers(text)
        } else if let marker = text.range(of: widgetMarker) {
            text = String(text[..<marker.lowerBound])
        }
        var lines = text.components(separatedBy: "\n")
        if !final, let last = lines.last {
            lines[lines.count - 1] = splitUnsettled(last).0
        }
        var out: [String] = []
        var previousBlank = false
        for raw in lines {
            let line = renderLine(raw)
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            // Runs of blank lines become one; the watch has little room.
            if blank, previousBlank || out.isEmpty { continue }
            out.append(line)
            previousBlank = blank
        }
        // Trailing blank lines wait for what follows them (and go if nothing does), so a later
        // rendering only ever adds to this one.
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// The settled part of an unfinished last line, and the part to hold back.
    static func splitUnsettled(_ line: String) -> (String, String) {
        let trimmed = line.drop(while: { $0 == " " })
        // A line that has only started may still become a bullet, a heading or a rule.
        if trimmed.count <= 2, let first = trimmed.first, "-*+#0123456789".contains(first) {
            return ("", line)
        }
        // A tag ("<message_break/>") or a citation ("【…】") still arriving.
        for (open, close) in [("<", ">"), ("【", "】")] {
            if let start = line.range(of: open, options: .backwards), !line[start.upperBound...].contains(close) {
                return (String(line[..<start.lowerBound]), String(line[start.lowerBound...]))
            }
        }
        // An open link, or a widget's "[[": hold from its first "[" until the ")" arrives.
        if var open = line.lastIndex(of: "[") {
            while open > line.startIndex, line[line.index(before: open)] == "[" { open = line.index(before: open) }
            let tail = line[open...]
            if !tail.contains(")") { return (String(line[..<open]), String(tail)) }
        }
        // Trailing "*", "_" or "`" may be the start of emphasis or code.
        let marks = line.reversed().prefix(while: { "*_`".contains($0) }).count
        if marks > 0 {
            return (String(line.dropLast(marks)), String(line.suffix(marks)))
        }
        return (line, "")
    }

    /// `[[name…]]` markers taken out (a name in lower case, then `:` and an argument, or
    /// nothing); the line they stood on keeps its other words.
    static func removingWidgetMarkers(_ text: String) -> String {
        text.replacingOccurrences(of: markerPattern, with: "", options: .regularExpression)
    }

    static let markerPattern = #"\[\[[a-z][a-z0-9_]*(:[^\]\s]*)?\]\]"#

    /// The names of the markers in `text` ("hatch_widget"), for the flight recorder.
    static func markerNames(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([a-z][a-z0-9_]*)(:[^\]\s]*)?\]\]"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var names: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let name = Range(match.range(at: 1), in: text).map({ String(text[$0]) }), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    static func renderLine(_ raw: String) -> String {
        var line = raw
        let indent = line.prefix(while: { $0 == " " })
        var body = String(line.dropFirst(indent.count))
        // Headings: "## Title" -> "Title".
        if body.hasPrefix("#") {
            body = String(body.drop(while: { $0 == "#" }))
            if body.hasPrefix(" ") { body.removeFirst() }
        } else if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            body = "\u{2022} " + body.dropFirst(2)
        } else if body == "---" || body == "***" || body == "___" {
            body = ""
        }
        line = String(indent) + body
        line = replacingAttachments(line)
        line = replacingLinks(line)
        line = line.replacingOccurrences(of: "**", with: "")
        line = line.replacingOccurrences(of: "__", with: "")
        line = line.replacingOccurrences(of: "`", with: "")
        line = removingEmphasisStars(line)
        return line
    }

    /// A file Muse attaches, "![name](sandbox://workspace/…)" -> "📎 name".
    static func replacingAttachments(_ line: String) -> String {
        guard line.contains("![") else { return line }
        return line.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "\u{1F4CE} $1", options: .regularExpression)
            .replacingOccurrences(of: "\u{1F4CE} \n", with: "\u{1F4CE} Attachment\n")
            .replacingOccurrences(of: #"\x{1F4CE} $"#, with: "\u{1F4CE} Attachment", options: .regularExpression)
    }

    /// "[words](url)" -> "words".
    static func replacingLinks(_ line: String) -> String {
        var out = ""
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "[") {
            out += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "]"),
                rest.index(after: close) < rest.endIndex, rest[rest.index(after: close)] == "(",
                let end = rest[close...].firstIndex(of: ")")
            else {
                out += rest[open...]
                return out
            }
            out += rest[afterOpen..<close]
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    /// Single "*" used for italics; a "*" between digits or spaces (arithmetic) stays.
    static func removingEmphasisStars(_ line: String) -> String {
        let characters = Array(line)
        var out = ""
        for (i, character) in characters.enumerated() {
            if character == "*" {
                let before = i > 0 ? characters[i - 1] : " "
                let after = i + 1 < characters.count ? characters[i + 1] : " "
                let arithmetic = (before.isNumber || before == " ") && (after.isNumber || after == " ")
                if !arithmetic { continue }
            }
            out.append(character)
        }
        return out
    }
}
