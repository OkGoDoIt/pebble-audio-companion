import Foundation

// A deliberately small Swift source reader, used by `LiveMockConformanceTests`.
//
// Why source and not runtime: every live data source is constructed from `AppComposition`,
// which opens the App Group database, the spool and Core Bluetooth. A test bundle has none of
// those, so the live objects cannot be instantiated here at all — and the defect this suite
// exists to catch is a SOURCE shape ("the live method ignores its argument", "the live method
// hard-codes the field the mock fills in"), which is exactly what can be read off the source.
//
// It is not a parser. It counts braces over a sanitized copy of the file (comments removed,
// string literals emptied) and remembers which type declaration it is inside. That is enough to
// answer "what does `LiveWorld.search(query:scope:)` contain?" and nothing more is needed.

/// One declared member of a type: a function, or a property (stored or computed).
struct SourceMember {
    enum Kind { case function, property }

    var typeName: String
    var kind: Kind
    var name: String
    /// Argument labels in declaration order; `_` for an unlabelled parameter.
    var labels: [String]
    /// Internal (body-visible) parameter names, `_` dropped.
    var parameterNames: [String]
    /// Everything between the member's outermost braces, sanitized. Empty for a stored
    /// property with no accessor block.
    var body: String
    /// The declaration line itself, sanitized (e.g. `var freeSpace = "—"`).
    var declaration: String
    /// True for a stored property. `body` then holds its initializer expression rather than an
    /// accessor block, which is the difference between "frozen at launch" and "recomputed".
    var isStored = false
    var file: String

    /// `search(query:scope:)` — the identity a protocol requirement is matched on.
    var signature: String {
        kind == .property ? name : "\(name)(\(labels.map { "\($0):" }.joined()))"
    }
}

/// One requirement declared inside a `protocol` body.
struct SourceRequirement {
    var protocolName: String
    var kind: SourceMember.Kind
    var name: String
    var labels: [String]
    var parameterNames: [String]

    var signature: String {
        kind == .property ? name : "\(name)(\(labels.map { "\($0):" }.joined()))"
    }
}

/// A struct-literal construction found in a member body: `NoteDisplay(id: …, momentsLabel: "")`.
struct SourceConstruction {
    var typeName: String
    /// label → the argument expression, sanitized and whitespace-collapsed.
    var arguments: [String: String]
    /// The member the construction sits in, for the failure message.
    var inMember: String
}

enum SwiftSource {
    // MARK: - Locating the tree

    /// The repository's `ios/` directory, derived from this file's own compile-time path.
    ///
    /// Simulator test bundles read the host filesystem, so this resolves to the real working
    /// tree rather than a copy — which is the point: the suite checks the sources that are
    /// about to be committed, not a snapshot of them.
    static let iosRoot: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // AppTests
        .deletingLastPathComponent()  // ios

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: iosRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - Sanitizing

    /// Strips comments and empties string literals, so brace counting cannot be thrown off by a
    /// `{` inside a doc comment or a `"}"` inside a format string. Line structure is preserved.
    static func sanitize(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var chars = Array(source)
        var index = 0

        func matches(_ literal: String, at position: Int) -> Bool {
            let characters = Array(literal)
            guard position + characters.count <= chars.count else { return false }
            for offset in characters.indices where chars[position + offset] != characters[offset] {
                return false
            }
            return true
        }

        while index < chars.count {
            let character = chars[index]
            if matches("//", at: index) {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if matches("/*", at: index) {
                var depth = 1
                index += 2
                while index < chars.count, depth > 0 {
                    if matches("/*", at: index) {
                        depth += 1
                        index += 2
                    } else if matches("*/", at: index) {
                        depth -= 1
                        index += 2
                    } else {
                        if chars[index] == "\n" { out.append("\n") }
                        index += 1
                    }
                }
                continue
            }
            if matches("\"\"\"", at: index) || character == "\"" {
                let isMultiline = matches("\"\"\"", at: index)
                index += isMultiline ? 3 : 1
                // The TEXT of a literal is dropped — no check here cares what a string says.
                // Its INTERPOLATIONS are kept, because they are code: `whenLabel:
                // "\(TimeFmt.time(start))"` is a field built from a real value, and reducing
                // the whole thing to `""` would read as a hard-coded empty string.
                var interpolations: [String] = []
                var sawText = false
                while index < chars.count {
                    if isMultiline, matches("\"\"\"", at: index) {
                        index += 3
                        break
                    }
                    if !isMultiline, chars[index] == "\"" {
                        index += 1
                        break
                    }
                    if matches("\\(", at: index) {
                        var level = 0
                        var piece = ""
                        while index < chars.count {
                            let inner = chars[index]
                            if inner == "(" { level += 1 }
                            if inner == ")" {
                                level -= 1
                                if level == 0 {
                                    index += 1
                                    break
                                }
                            }
                            if inner != "\\" { piece.append(inner) }
                            index += 1
                        }
                        interpolations.append(String(piece.dropFirst()))
                        continue
                    }
                    if chars[index] == "\\", index + 1 < chars.count { index += 1 }
                    if chars[index] == "\n" { out.append("\n") }
                    if !chars[index].isWhitespace { sawText = true }
                    index += 1
                }
                if interpolations.isEmpty && !sawText {
                    // A genuinely empty literal stays recognisably empty.
                    out.append("\"\"")
                } else {
                    out.append("STR(\(interpolations.joined(separator: ", ")))")
                }
                continue
            }
            out.append(character)
            index += 1
        }
        return out
    }

    // MARK: - Members

    private static let typeKeywords = ["class", "struct", "enum", "actor", "extension", "protocol"]

    private static let declarationKeywords = [
        "func", "var", "let", "init", "deinit", "subscript", "case",
    ] + typeKeywords

    /// True when this line begins a declaration rather than continuing one.
    static func isDeclarationStart(_ line: String) -> Bool {
        let words = line
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" })
            .map(String.init)
        for word in words {
            if declarationKeywords.contains(word) { return true }
            // Attributes and access modifiers may precede the keyword; anything else means
            // this line is an expression, so it is a continuation.
            let isModifier =
                word.hasPrefix("@") || word.hasPrefix("private") || word.hasPrefix("public")
                || word.hasPrefix("internal") || word.hasPrefix("fileprivate")
                || ["final", "static", "class", "override", "nonisolated", "open", "indirect",
                    "@discardableResult", "convenience", "required", "lazy", "weak", "unowned",
                ].contains(word)
            if !isModifier { return false }
        }
        return false
    }

    /// Every member of every type declared in `file`.
    static func members(inFile relativePath: String) throws -> [SourceMember] {
        let text = sanitize(try read(relativePath))
        let chars = Array(text)
        var members: [SourceMember] = []
        // (typeName, brace depth of the type's own body)
        var typeStack: [(name: String, depth: Int)] = []
        var depth = 0
        var index = 0
        var lineStart = 0

        /// The declaration text that ends at this `{`. Walks BACK over continuation lines,
        /// because a wrapped signature —
        ///
        ///     private static func recap(
        ///         _ recap: DailyRecap?, aiModelName: String, rows: [ConversationListRow]
        ///     ) -> RecapDisplay? {
        ///
        /// is the normal shape here, and reading only the last line before the brace saw
        /// `) -> RecapDisplay?` and concluded the member did not exist.
        func currentLine(endingAt end: Int) -> String {
            var collected: [String] = []
            var lineEnd = min(end, chars.count)
            for _ in 0..<14 {
                var start = lineEnd
                while start > 0, chars[start - 1] != "\n" { start -= 1 }
                let line = String(chars[start..<lineEnd])
                // A brace on an earlier line is the end of a previous declaration, not part of
                // this one.
                if line.contains("{") || line.contains("}") { break }
                collected.insert(line, at: 0)
                if isDeclarationStart(line) || start == 0 { break }
                lineEnd = start - 1
            }
            if collected.isEmpty {
                collected = [String(chars[lineStart..<min(end, chars.count)])]
            }
            return collected.joined(separator: " ")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }

        /// Consumes a balanced `{ … }` starting at `open`, returning its interior and the index
        /// just past the closing brace.
        func balanced(from open: Int) -> (body: String, end: Int) {
            var level = 0
            var cursor = open
            while cursor < chars.count {
                if chars[cursor] == "{" { level += 1 }
                if chars[cursor] == "}" {
                    level -= 1
                    if level == 0 {
                        return (String(chars[(open + 1)..<cursor]), cursor + 1)
                    }
                }
                cursor += 1
            }
            return (String(chars[min(open + 1, chars.count)...]), chars.count)
        }

        while index < chars.count {
            let character = chars[index]
            if character == "\n" {
                index += 1
                lineStart = index
                continue
            }
            if character == "{" {
                // A declaration head ends here. Work out what it declared.
                let head = currentLine(endingAt: index)
                if let typeName = declaredTypeName(in: head) {
                    depth += 1
                    typeStack.append((typeName, depth))
                    index += 1
                    lineStart = index
                    continue
                }
                if let type = typeStack.last, depth == type.depth,
                    let member = declaredMember(in: head)
                {
                    let (body, end) = balanced(from: index)
                    members.append(
                        SourceMember(
                            typeName: type.name, kind: member.kind, name: member.name,
                            labels: member.labels, parameterNames: member.parameterNames,
                            body: body, declaration: head, file: relativePath))
                    index = end
                    lineStart = index
                    continue
                }
                depth += 1
                index += 1
                continue
            }
            if character == "}" {
                if typeStack.last?.depth == depth { typeStack.removeLast() }
                depth -= 1
                index += 1
                continue
            }
            // A stored property with no accessor block ends at its line break.
            if character == "\n" || index == chars.count - 1 { index += 1; continue }
            index += 1
        }

        members.append(contentsOf: try storedProperties(inFile: relativePath))
        return members
    }

    /// Stored properties (`private(set) var deviceName = "…"`, `let models: [X] = …`) — the
    /// brace walk above only sees members that open a block, and a protocol's `{ get }`
    /// requirement is very often satisfied by one of these.
    private static func storedProperties(inFile relativePath: String) throws -> [SourceMember] {
        let text = sanitize(try read(relativePath))
        var found: [SourceMember] = []
        var typeStack: [(name: String, depth: Int)] = []
        var depth = 0

        // Folded, so `private static let recapDetail = RecapDetailDisplay(` and the fifteen
        // lines of sample data after it are one declaration. Without that the mock's artboard
        // fixtures are invisible to the field comparison, and the live side is compared
        // against nothing.
        for line in foldedLines(text) {
            let opens = line.filter { $0 == "{" }.count
            let closes = line.filter { $0 == "}" }.count

            // `opens > closes`, not `opens > 0`: a type that opens AND closes on one line
            // (`private enum Phase { case recording, paused }`) never ends, so pushing it would
            // capture the whole rest of the file under its name.
            if let typeName = declaredTypeName(in: line), opens > closes {
                depth += opens - closes
                typeStack.append((typeName, depth))
                continue
            }
            // Only at the type's own level: a `let` inside a function body is a local, not a
            // property, and recording it would invent members that do not exist.
            if opens == 0, closes == 0, let type = typeStack.last, depth == type.depth,
                let name = storedPropertyName(in: line)
            {
                // Everything after the `=` is the property's value; treat it as the body so
                // constructions inside it are found.
                let value = line.split(separator: "=", maxSplits: 1).dropFirst().first
                    .map(String.init) ?? ""
                found.append(
                    SourceMember(
                        typeName: type.name, kind: .property, name: name, labels: [],
                        parameterNames: [], body: value, declaration: line, isStored: true,
                        file: relativePath))
                continue
            }
            depth += opens - closes
            while let last = typeStack.last, depth < last.depth { typeStack.removeLast() }
        }
        return found
    }

    private static func declaredTypeName(in head: String) -> String? {
        let words = head
            .replacingOccurrences(of: ":", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "<" })
            .map(String.init)
        guard let keywordIndex = words.firstIndex(where: { typeKeywords.contains($0) }),
            keywordIndex + 1 < words.count
        else { return nil }
        // `indirect enum`, `final class`, `@MainActor extension` all land here; anything after
        // the keyword that is not an identifier is not a declaration we care about.
        let name = words[keywordIndex + 1]
        guard name.first?.isLetter == true else { return nil }
        // `if`, `guard`, `switch` bodies can contain the word "class" only as an identifier.
        guard !head.hasPrefix("if "), !head.hasPrefix("guard "), !head.hasPrefix("switch ") else {
            return nil
        }
        return name
    }

    private static func declaredMember(
        in head: String
    ) -> (kind: SourceMember.Kind, name: String, labels: [String], parameterNames: [String])? {
        if let range = head.range(of: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#, options: .regularExpression) {
            let name = String(head[range])
                .replacingOccurrences(of: "func", with: "")
                .replacingOccurrences(of: "(", with: "")
                .trimmingCharacters(in: .whitespaces)
            let params = parameters(in: head, from: range.upperBound)
            return (.function, name, params.labels, params.internalNames)
        }
        if head.range(of: #"\binit\s*\("#, options: .regularExpression) != nil,
            let open = head.firstIndex(of: "(")
        {
            let params = parameters(in: head, from: head.index(after: open))
            return (.function, "init", params.labels, params.internalNames)
        }
        if let range = head.range(of: #"\b(var|let)\s+([A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) {
            let name = String(head[range])
                .replacingOccurrences(of: "var", with: "")
                .replacingOccurrences(of: "let", with: "")
                .trimmingCharacters(in: .whitespaces)
            return (.property, name, [], [])
        }
        return nil
    }

    private static func storedPropertyName(in line: String) -> String? {
        guard line.range(of: #"^(@\w+\s+)*(public |internal |private |fileprivate )?(private\(set\) |public\(set\) )?(static )?(var|let)\s+[A-Za-z_]"#, options: .regularExpression) != nil
        else { return nil }
        guard let range = line.range(of: #"\b(var|let)\s+([A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression)
        else { return nil }
        return String(line[range])
            .replacingOccurrences(of: "var", with: "")
            .replacingOccurrences(of: "let", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Splits a parameter list at the top level of its parentheses.
    private static func parameters(
        in head: String, from start: String.Index
    ) -> (labels: [String], internalNames: [String]) {
        var depth = 1
        var current = ""
        var parts: [String] = []
        var index = start
        while index < head.endIndex, depth > 0 {
            let character = head[index]
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            if character == ",", depth == 1 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = head.index(after: index)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }

        var labels: [String] = []
        var internalNames: [String] = []
        for part in parts {
            let head = part.split(separator: ":", maxSplits: 1).first.map(String.init) ?? part
            let words = head.split(separator: " ").map(String.init)
            guard let first = words.first else { continue }
            labels.append(first)
            let internalName = words.count > 1 ? words[1] : first
            if internalName != "_" { internalNames.append(internalName) }
        }
        return (labels, internalNames)
    }

    // MARK: - Protocol requirements

    static func requirements(inFile relativePath: String) throws -> [SourceRequirement] {
        let text = sanitize(try read(relativePath))
        var requirements: [SourceRequirement] = []
        for (name, body) in protocolBodies(in: text) {
            // A requirement's signature wraps just like an implementation's, so continuation
            // lines are folded back onto the `func` line before anything is parsed.
            for line in foldedLines(body) {
                if let member = declaredMember(in: line + " {"), line.hasPrefix("func ") {
                    requirements.append(
                        SourceRequirement(
                            protocolName: name, kind: .function, name: member.name,
                            labels: member.labels, parameterNames: member.parameterNames))
                } else if line.hasPrefix("var "), line.contains("{ get") {
                    let propertyName = line
                        .dropFirst(4)
                        .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    requirements.append(
                        SourceRequirement(
                            protocolName: name, kind: .property, name: String(propertyName),
                            labels: [], parameterNames: []))
                }
            }
        }
        return requirements
    }

    /// Splits `text` into logical lines: a line whose brackets do not balance absorbs the ones
    /// after it, so a wrapped declaration reads as one string.
    static func foldedLines(_ text: String) -> [String] {
        var folded: [String] = []
        var pending = ""
        var depth = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty, depth == 0 { continue }
            pending += pending.isEmpty ? line : " " + line
            // Braces are deliberately NOT counted: `{` opens a body, and folding on it would
            // swallow a whole type into a single line. Only a wrapped argument or literal
            // list continues a declaration.
            for character in line {
                if "([".contains(character) { depth += 1 }
                if ")]".contains(character) { depth -= 1 }
            }
            if depth <= 0 {
                folded.append(pending)
                pending = ""
                depth = 0
            }
        }
        if !pending.isEmpty { folded.append(pending) }
        return folded
    }

    /// name → body, for every `protocol X { … }` in `text` (already sanitized).
    static func protocolBodies(in text: String) -> [(String, String)] {
        var results: [(String, String)] = []
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard chars[index] == "{" else {
                index += 1
                continue
            }
            var lineStart = index
            while lineStart > 0, chars[lineStart - 1] != "\n" { lineStart -= 1 }
            let head = String(chars[lineStart..<index]).trimmingCharacters(in: .whitespaces)
            guard head.hasPrefix("protocol ") || head.contains(" protocol ") else {
                index += 1
                continue
            }
            var level = 0
            var cursor = index
            while cursor < chars.count {
                if chars[cursor] == "{" { level += 1 }
                if chars[cursor] == "}" {
                    level -= 1
                    if level == 0 { break }
                }
                cursor += 1
            }
            let name = head
                .replacingOccurrences(of: "protocol", with: " ")
                .split(whereSeparator: { $0 == " " || $0 == ":" })
                .map(String.init)
                .first { $0.first?.isLetter == true } ?? ""
            results.append((name, String(chars[(index + 1)..<min(cursor, chars.count)])))
            index = cursor
        }
        return results
    }

    /// Names of every `struct X` declared at the top level of `text`.
    static func structNames(inFile relativePath: String) throws -> [String] {
        let text = sanitize(try read(relativePath))
        var names: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("struct ") else { continue }
            let name = line.dropFirst(7).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { names.append(String(name)) }
        }
        return names
    }

    // MARK: - Constructions

    /// Every `TypeName(label: value, …)` in `member`'s body, for the given type names.
    static func constructions(of typeNames: Set<String>, in member: SourceMember) -> [SourceConstruction] {
        var found: [SourceConstruction] = []
        let chars = Array(member.body)
        var index = 0
        while index < chars.count {
            guard chars[index] == "(" else {
                index += 1
                continue
            }
            var nameEnd = index
            var nameStart = index
            while nameStart > 0,
                chars[nameStart - 1].isLetter || chars[nameStart - 1].isNumber
                    || chars[nameStart - 1] == "_"
            {
                nameStart -= 1
            }
            let name = String(chars[nameStart..<nameEnd])
            nameEnd = index
            guard typeNames.contains(name) else {
                index += 1
                continue
            }
            // Balanced argument list.
            var level = 0
            var cursor = index
            while cursor < chars.count {
                if chars[cursor] == "(" || chars[cursor] == "[" { level += 1 }
                if chars[cursor] == ")" || chars[cursor] == "]" {
                    level -= 1
                    if level == 0 { break }
                }
                cursor += 1
            }
            let inner = String(chars[(index + 1)..<min(cursor, chars.count)])
            found.append(
                SourceConstruction(
                    typeName: name, arguments: arguments(in: inner),
                    inMember: "\(member.typeName).\(member.signature)"))
            // Step INTO the argument list rather than over it: the mock's fixtures nest their
            // display models (`RecapDetailDisplay(bullets: [RecapBullet(…)])`), and skipping
            // past the outer one hid every inner construction from the comparison.
            index += 1
        }
        return found
    }

    private static func arguments(in list: String) -> [String: String] {
        var depth = 0
        var current = ""
        var parts: [String] = []
        for character in list {
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }

        var result: [String: String] = [:]
        for part in parts {
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let label = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !label.isEmpty
            else { continue }
            let value = pieces[1]
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            result[label] = value
        }
        return result
    }

    // MARK: - Predicates

    /// True when `body` mentions `identifier` as a whole word.
    static func mentions(_ identifier: String, in body: String) -> Bool {
        body.range(of: "\\b\(NSRegularExpression.escapedPattern(for: identifier))\\b",
                   options: .regularExpression) != nil
    }

    /// "This body does nothing worth calling": empty, or a single literal return.
    static func isTrivial(_ body: String) -> Bool {
        let statements = body
            .split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if statements.isEmpty { return true }
        guard statements.count == 1 else { return false }
        return isHollow(statements[0].replacingOccurrences(of: "return ", with: ""))
    }

    /// A value that carries no information: `nil`, `[]`, `""`, `0`, `false`.
    static func isHollow(_ expression: String) -> Bool {
        let value = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["nil", "[]", "[:]", "\"\"", "0", "false", "()", ""].contains(value)
    }
}
