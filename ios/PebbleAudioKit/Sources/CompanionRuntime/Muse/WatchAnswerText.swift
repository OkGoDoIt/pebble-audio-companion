import Foundation

/// Muse's answer as the watch can show it: plain text in the watch's fonts.
///
/// Muse writes Markdown and emoji; the watch draws neither. Emphasis marks and heading hashes
/// go, list markers become bullets, links keep their words, and emoji are dropped.
///
/// The watch only appends, so a rendering of a partial answer must never change once sent. Every
/// rule here only deletes characters or swaps ones that are already settled, and a tail that could
/// still turn into Markdown (an open link, a lone `-` that may be a bullet) is held back until it
/// is complete or the answer is.
enum WatchAnswerText {
    static func render(_ markdown: String, final: Bool) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
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
        // An open link: hold from its "[" until the ")" arrives.
        if let open = line.lastIndex(of: "[") {
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
        line = replacingLinks(line)
        line = line.replacingOccurrences(of: "**", with: "")
        line = line.replacingOccurrences(of: "__", with: "")
        line = line.replacingOccurrences(of: "`", with: "")
        line = removingEmphasisStars(line)
        return removingEmoji(line)
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

    static func removingEmoji(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0xFE0F || value == 0x200D || value == 0x20E3 { continue }
            if scalar.properties.isEmojiPresentation { continue }
            if scalar.properties.isEmoji, value >= 0x1F000 { continue }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
