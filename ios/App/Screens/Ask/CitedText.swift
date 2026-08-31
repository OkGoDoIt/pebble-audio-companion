import SwiftUI

// Inline-cited text (Ask answers + Saved Notes bullets): "[n]" markers render as 16×16 r8
// citation chips (`tintFill12`, 11/600 tint) flowing inline with the words. Citations tap
// through to the exact moment (plan 2.8/2.16). Models write their answers in Markdown, so
// inline emphasis (`**bold**`, `*italic*`, `` `code` ``, ~~strike~~, links) is parsed into
// real styling rather than shown as literal punctuation; block structure (headings, lists,
// quotes) is handled one level up by `MarkdownText`.

// MARK: - Citation chip

struct CitationChip: View {
    let number: Int
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) { chip.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Source \(number)")
            } else {
                chip
            }
        }
    }

    private var chip: some View {
        Text("\(number)")
            .font(AppFont.microBold)
            .foregroundStyle(Tokens.tint)
            .frame(minWidth: 16, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.tintFill12))
    }
}

// MARK: - Cited text

/// Renders one paragraph whose "[n]" markers become inline citation chips. Trailing
/// punctuation after a marker stays glued to the chip so wraps look natural.
struct CitedText: View {
    enum Fragment: Hashable {
        case word(AttributedString)
        /// A word with its citation chips glued on. Two things follow from keeping them in one
        /// fragment: the chip can never wrap onto the next line away from the phrase it cites,
        /// and the sentence's punctuation stays on the WORD - "tomorrow.①", the way a footnote
        /// marker is set - instead of floating a lone period past the chip's rounded box.
        case cited(word: AttributedString, numbers: [Int])
    }

    let fragments: [Fragment]
    var font: Font = AppFont.subBody
    var textColor: Color = Tokens.label
    var lineSpacing: CGFloat = 6
    var onCitationTap: ((Int) -> Void)? = nil

    init(
        _ text: String,
        font: Font = AppFont.subBody,
        textColor: Color = Tokens.label,
        lineSpacing: CGFloat = 6,
        onCitationTap: ((Int) -> Void)? = nil
    ) {
        self.fragments = Self.parse(text, font: font)
        self.font = font
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.onCitationTap = onCitationTap
    }

    var body: some View {
        FlowLayout(horizontalSpacing: 3.6, verticalSpacing: lineSpacing) {
            ForEach(Array(fragments.enumerated()), id: \.offset) { _, fragment in
                switch fragment {
                case .word(let word):
                    Text(word).font(font).foregroundStyle(textColor)
                case .cited(let word, let numbers):
                    HStack(spacing: 2) {
                        if !word.characters.isEmpty {
                            Text(word).font(font).foregroundStyle(textColor)
                        }
                        ForEach(numbers, id: \.self) { number in
                            CitationChip(number: number) { onCitationTap?(number) }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Markdown-styles the line, then splits it into flow fragments: whitespace-separated
    /// words (each carrying its own emphasis) and the "[n]" markers, which attach to the word
    /// they follow along with any punctuation that came after them.
    static func parse(_ text: String, font: Font = AppFont.subBody) -> [Fragment] {
        let styled = InlineMarkdown.attributed(text, font: font)
        let characters = styled.characters
        var fragments: [Fragment] = []
        var word = AttributedString()

        func flushWord() {
            guard !word.characters.isEmpty else { return }
            fragments.append(.word(word))
            word = AttributedString()
        }

        /// Move the word being built (or the last one finished) under a citation chip.
        func attach(_ number: Int) {
            if !word.characters.isEmpty {
                fragments.append(.cited(word: word, numbers: [number]))
                word = AttributedString()
                return
            }
            if case .cited(let previous, let numbers) = fragments.last {
                fragments[fragments.count - 1] = .cited(word: previous, numbers: numbers + [number])
                return
            }
            if case .word(let previous) = fragments.last {
                fragments[fragments.count - 1] = .cited(word: previous, numbers: [number])
                return
            }
            fragments.append(.cited(word: AttributedString(), numbers: [number]))
        }

        /// "[1]." reads as "tomorrow.①": the period belongs to the sentence, not after the chip.
        func appendTrailing(_ punctuation: AttributedString) {
            guard !punctuation.characters.isEmpty else { return }
            if case .cited(var previous, let numbers) = fragments.last {
                previous.append(punctuation)
                fragments[fragments.count - 1] = .cited(word: previous, numbers: numbers)
            } else {
                word.append(punctuation)
            }
        }

        var index = characters.startIndex
        while index < characters.endIndex {
            let character = characters[index]
            if character.isWhitespace {
                flushWord()
                index = characters.index(after: index)
                continue
            }
            if character == "[", let citation = citation(in: characters, at: index) {
                attach(citation.number)
                var after = citation.end
                while after < characters.endIndex, trailingPunctuation.contains(characters[after]) {
                    after = characters.index(after: after)
                }
                appendTrailing(AttributedString(styled[citation.end..<after]))
                index = after
                continue
            }
            let next = characters.index(after: index)
            word.append(styled[index..<next])
            index = next
        }
        flushWord()
        return fragments
    }

    private static let trailingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?"]

    /// Matches "[123]" starting at `start` (which must be the "[").
    private static func citation(
        in characters: AttributedString.CharacterView, at start: AttributedString.Index
    ) -> (number: Int, end: AttributedString.Index)? {
        var index = characters.index(after: start)
        var digits = ""
        while index < characters.endIndex, characters[index].isNumber {
            digits.append(characters[index])
            index = characters.index(after: index)
        }
        guard !digits.isEmpty, index < characters.endIndex, characters[index] == "]",
            let number = Int(digits)
        else { return nil }
        return (number, characters.index(after: index))
    }
}

// MARK: - Inline markdown

/// Parses inline Markdown emphasis into concrete SwiftUI attributes. The presentation intents
/// the parser emits are turned into explicit fonts derived from the caller's font so emphasis
/// stays on our type scale instead of falling back to the system body font.
enum InlineMarkdown {
    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    static func attributed(_ text: String, font: Font) -> AttributedString {
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        var out = AttributedString()
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if let intent = run.inlinePresentationIntent {
                var styled = font
                if intent.contains(.stronglyEmphasized) { styled = styled.bold() }
                if intent.contains(.emphasized) { styled = styled.italic() }
                if intent.contains(.code) { styled = styled.monospaced() }
                piece.font = styled
                if intent.contains(.strikethrough) { piece.strikethroughStyle = .single }
            }
            out.append(piece)
        }
        return out
    }

    /// Strips inline emphasis for plain-text contexts (previews, share sheets, snippets).
    static func plainText(_ text: String) -> String {
        String(attributed(text, font: AppFont.subBody).characters)
    }
}

// MARK: - Flow layout

/// Left-aligned wrapping layout (chips in the Tag Editor, word-flow in CitedText).
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +)
            + CGFloat(max(rows.count - 1, 0)) * verticalSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : x + horizontalSpacing + size.width
            if !current.indices.isEmpty, needed > maxWidth {
                rows.append(current)
                current = Row()
                x = 0
            }
            x = current.indices.isEmpty ? size.width : x + horizontalSpacing + size.width
            current.indices.append(index)
            current.width = x
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview("Cited text") {
    VStack(alignment: .leading, spacing: 16) {
        CitedText(
            "You decided to take the **ferry** Saturday morning instead of driving [1], and to "
                + "book the theater walkthrough for Tuesday so the trip doesn't collide with it "
                + "[2]. Packing was left open — Sam offered to handle it Friday evening [2].",
            lineSpacing: 7
        )
        CitedText(
            "Stop for the night; plan and finish the remaining work tomorrow [1].",
            lineSpacing: 7
        )
    }
    .padding(Tokens.screenMargin)
    .background(Tokens.surface)
}
