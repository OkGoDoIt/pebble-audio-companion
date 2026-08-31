import SwiftUI

// Inline-cited text (Ask answers + Saved Notes bullets): "[n]" markers render as 16×16 r8
// citation chips (`tintFill12`, 11/600 tint) flowing inline with the words. Citations tap
// through to the exact moment (plan 2.8/2.16).

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
        case word(String)
        case citation(number: Int, trailing: String)
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
        self.fragments = Self.parse(text)
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
                case .citation(let number, let trailing):
                    HStack(spacing: 0) {
                        CitationChip(number: number) {
                            onCitationTap?(number)
                        }
                        if !trailing.isEmpty {
                            Text(trailing).font(font).foregroundStyle(textColor)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func parse(_ text: String) -> [Fragment] {
        var fragments: [Fragment] = []
        let pattern = /\[(\d+)\]([,.;:!?]*)/
        var remainder = Substring(text)
        while let match = remainder.firstMatch(of: pattern) {
            let before = remainder[remainder.startIndex..<match.range.lowerBound]
            fragments.append(contentsOf: words(before))
            if let number = Int(match.output.1) {
                fragments.append(.citation(number: number, trailing: String(match.output.2)))
            }
            remainder = remainder[match.range.upperBound...]
        }
        fragments.append(contentsOf: words(remainder))
        return fragments
    }

    private static func words(_ text: Substring) -> [Fragment] {
        text.split(whereSeparator: { $0.isWhitespace }).map { .word(String($0)) }
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
            "You decided to take the ferry Saturday morning instead of driving [1], and to book "
                + "the theater walkthrough for Tuesday so the trip doesn't collide with it [2]. "
                + "Packing was left open — Sam offered to handle it Friday evening [2].",
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
