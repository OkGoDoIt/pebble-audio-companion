import SwiftUI

// Block-level Markdown for model-written text (Saved Notes bodies, Ask answers). The note
// templates ask for structured output — "topic, discussion points, decisions" — so models
// reply with headings, bullets and numbered lists. Rendering that as one plain string leaked
// the raw syntax ("# Meeting Notes", "- **Decision.** context") into the UI. We render the
// structure instead of stripping it: normalising the model's text would rewrite the user's
// saved note, and hiding it would lose the outline the template asked for.
//
// Inline emphasis and the "[n]" citation chips are handled by `CitedText`, one line at a time.

enum NoteMarkdown {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case bullet(depth: Int, text: String)
        case ordered(depth: Int, marker: String, text: String)
        case quote(text: String)
        case paragraph(text: String)
        case code(text: String)
        case rule

        var isHeading: Bool { if case .heading = self { return true } else { return false } }

        var isListItem: Bool {
            switch self {
            case .bullet, .ordered: return true
            default: return false
            }
        }
    }

    private static let headingPattern = /^(#{1,6})\s+(.*)$/
    private static let bulletPattern = /^([ \t]*)([-*+])\s+(.*)$/
    private static let orderedPattern = /^([ \t]*)(\d{1,3})[.)]\s+(.*)$/
    private static let quotePattern = /^[ \t]*>\s?(.*)$/
    private static let rulePattern = /^[ \t]*([-*_])(\s*\1){2,}\s*$/

    /// Splits model text into renderable blocks. Every source line stays its own block: notes
    /// are line-oriented (one bullet per line) and re-flowing them would merge items the model
    /// meant to keep apart.
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var fence: [String]? = nil

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false)
        {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if let open = fence {
                    blocks.append(.code(text: open.joined(separator: "\n")))
                    fence = nil
                } else {
                    fence = []
                }
                continue
            }
            if fence != nil {
                fence?.append(line)
                continue
            }

            if trimmed.isEmpty { continue }
            if trimmed.wholeMatch(of: rulePattern) != nil {
                blocks.append(.rule)
            } else if let match = trimmed.wholeMatch(of: headingPattern) {
                let body = String(match.output.2).trimmingCharacters(in: .whitespaces)
                let level = match.output.1.count
                // "###" alone is a separator the model forgot to fill in; drop it.
                if !body.isEmpty { blocks.append(.heading(level: level, text: trailingHashes(body))) }
            } else if let match = line.wholeMatch(of: bulletPattern) {
                blocks.append(
                    .bullet(depth: depth(String(match.output.1)), text: String(match.output.3)))
            } else if let match = line.wholeMatch(of: orderedPattern) {
                blocks.append(
                    .ordered(
                        depth: depth(String(match.output.1)),
                        marker: "\(match.output.2).",
                        text: String(match.output.3)))
            } else if let match = line.wholeMatch(of: quotePattern) {
                blocks.append(.quote(text: String(match.output.1)))
            } else {
                blocks.append(.paragraph(text: trimmed))
            }
        }
        if let open = fence, !open.isEmpty {
            blocks.append(.code(text: open.joined(separator: "\n")))
        }
        return blocks
    }

    /// "## Topic ##" — closing hashes are decoration in ATX headings.
    private static func trailingHashes(_ text: String) -> String {
        guard let match = text.wholeMatch(of: /(.*?)\s+#+/) else { return text }
        let stripped = String(match.output.1).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? text : stripped
    }

    /// Two spaces (or one tab) per nesting level, capped so a stray indent can't push text
    /// off the card.
    private static func depth(_ indent: String) -> Int {
        let columns = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        return min(columns / 2, 3)
    }
}

// MARK: - View

/// Renders `NoteMarkdown` blocks on the app's type scale, with citation chips intact.
struct MarkdownText: View {
    private let blocks: [NoteMarkdown.Block]
    private let font: Font
    private let textColor: Color
    private let lineSpacing: CGFloat
    private let onCitationTap: ((Int) -> Void)?

    init(
        _ text: String,
        font: Font = AppFont.subBody,
        textColor: Color = Tokens.label,
        lineSpacing: CGFloat = 7,
        onCitationTap: ((Int) -> Void)? = nil
    ) {
        self.blocks = NoteMarkdown.blocks(text)
        self.font = font
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.onCitationTap = onCitationTap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(.top, index == 0 ? 0 : gap(from: blocks[index - 1], to: block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: NoteMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            self.text(text, font: headingFont(level))

        case .bullet(let depth, let text):
            marker(bulletGlyph(depth), width: 12, body: text, depth: depth)

        case .ordered(let depth, let marker, let text):
            self.marker(marker, width: 20, body: text, depth: depth)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(Tokens.quiet).frame(width: 2)
                self.text(text, color: Tokens.secondaryBody)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            self.text(text)

        case .code(let text):
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Tokens.secondaryBody)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.grayChipFill))

        case .rule:
            Rectangle().fill(Tokens.hairline).frame(height: 0.5)
        }
    }

    /// List row: the glyph sits in a fixed gutter so wrapped lines stay hung under the text.
    private func marker(
        _ glyph: String, width: CGFloat, body: String, depth: Int
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(glyph)
                .font(font)
                .foregroundStyle(Tokens.meta)
                .monospacedDigit()
                .frame(minWidth: width, alignment: .leading)
                .accessibilityHidden(true)
            text(body)
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    private func text(
        _ value: String, font: Font? = nil, color: Color? = nil
    ) -> some View {
        CitedText(
            value,
            font: font ?? self.font,
            textColor: color ?? textColor,
            lineSpacing: lineSpacing,
            onCitationTap: onCitationTap
        )
    }

    private func bulletGlyph(_ depth: Int) -> String {
        switch depth {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return AppFont.sectionTitle
        case 2: return AppFont.headline
        default: return AppFont.cardHead
        }
    }

    /// Headings get air above them; consecutive list items stay tight so a list reads as one
    /// block rather than a stack of paragraphs.
    private func gap(from previous: NoteMarkdown.Block, to next: NoteMarkdown.Block) -> CGFloat {
        if case .rule = next { return 14 }
        if case .rule = previous { return 14 }
        if next.isHeading { return previous.isHeading ? 8 : 18 }
        if previous.isHeading { return 8 }
        if next.isListItem, previous.isListItem { return 8 }
        return 11
    }
}

#Preview("Markdown note") {
    ScrollView {
        MarkdownText(
            """
            # Meeting Notes

            ## 1. TK school enrollment and first day

            ### Discussion points

            - The child was accepted into TK with very little advance notice [1].
            - **Bring the available immunization summary to school.** If the school rejects it,
              they will contact the doctor's office.
              - The yellow form may not include the latest vaccination.

            1. Arrive around 8:00 a.m.
            2. Side door opens at 8:25.

            > Pickup was described as every weekday except Wednesday.
            """
        ) { _ in }
        .padding(Tokens.screenMargin)
    }
    .background(Tokens.surface)
}
