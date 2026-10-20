import SwiftUI

// The building blocks of the AI Assistants and Privacy screens, ported from the round-3 mockups
// (`docs/redesign/assistant-access-mockups/round3/tokens.css`) number for number: card padding
// 16, list rows at least 46 pt (60 for a row with a tile) with 10 pt above and below, section
// headers 13/600 tertiary with 10 pt above, footers 13/400 tertiary, buttons 50 pt with radius
// 14. Small gray text is `Tokens.tertiary`, which passes AA on both the card and the ground.

// MARK: - Scaffolding

/// A pushed screen's scroll: ground, 16 pt margins, 12 pt between blocks.
struct AssistantScroll<Content: View>: View {
    var spacing: CGFloat = Tokens.blockGap
    var bottom: CGFloat = 24
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.top, 2)
            .padding(.bottom, bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tokens.ground)
    }
}

/// `.card`: 16 pt all round on the surface, radius 12.
struct AssistantCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.cardRadius))
    }
}

/// `.list-card`: rows 16 pt in from the card's edges, each at least `minHeight` with 10 pt above
/// and below, a hairline between rows and never after the last.
struct AssistantList<Content: View>: View {
    var minRowHeight: CGFloat = 46
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews.indices, id: \.self) { index in
                    subviews[index]
                        .frame(maxWidth: .infinity, minHeight: minRowHeight - 20, alignment: .leading)
                        .padding(.vertical, 10)
                    if index < subviews.count - 1 {
                        Rectangle().fill(Tokens.hairline).frame(height: 0.5)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.cardRadius))
    }
}

/// `.section-header`: 13/600 uppercase, +0.4, tertiary, 10 pt above and 4 pt closer to its card.
struct AssistantSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(AppFont.sectionHeader)
            .textCase(.uppercase)
            .kerning(0.4)
            .foregroundStyle(Tokens.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, 10)
            .padding(.bottom, -4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// `.footer`: one 13/400 tertiary sentence under a card, 4 pt closer to it.
struct AssistantFooter: View {
    let text: String
    var color: Color = Tokens.tertiary

    var body: some View {
        Text(text)
            .font(AppFont.footnote)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, -4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - State

/// A state, as every status card in the app says one: a dot and a heading, then one line.
struct AssistantStateHead: View {
    enum Size { case regular, big }

    let dot: Color
    let heading: String
    var line: String?
    var size: Size = .regular
    /// `.state-line.small` (15) rather than the body size (17).
    var smallLine = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(dot).frame(width: 10, height: 10)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .accessibilityHidden(true)
                Text(heading)
                    .font(size == .big ? AssistantFont.stepHead : AppFont.headline)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if let line {
                Text(line)
                    .font(smallLine ? AppFont.subBody : AppFont.bodyPlain)
                    .foregroundStyle(Tokens.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons

/// `.btn`: 50 pt, radius 14, 17/600. Filled is the next step; bordered is a tinted fill; small is
/// the 44 pt in-row button.
struct AssistantButtonStyle: ButtonStyle {
    enum Kind { case filled, bordered, small }
    var kind: Kind = .filled

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = kind == .small ? 12 : Tokens.primaryButtonRadius
        configuration.label
            .font(kind == .small ? AppFont.cardHead : AppFont.headline)
            .foregroundStyle(kind == .filled ? Tokens.onTint : Tokens.tint)
            .multilineTextAlignment(.center)
            .padding(.horizontal, kind == .small ? 14 : 16)
            .padding(.vertical, 8)
            .frame(minHeight: kind == .small ? 44 : 50)
            .frame(maxWidth: kind == .small ? nil : .infinity)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(kind == .filled
                        ? (configuration.isPressed ? Tokens.tintPressed : Tokens.tint)
                        : Tokens.tintFill12))
            .opacity(isEnabled ? (configuration.isPressed && kind != .filled ? 0.7 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }
}

extension ButtonStyle where Self == AssistantButtonStyle {
    static var assistantFilled: Self { .init(kind: .filled) }
    static var assistantBordered: Self { .init(kind: .bordered) }
    static var assistantSmall: Self { .init(kind: .small) }
}

/// A button's label with its glyph (19 pt; 16 pt in the small button).
struct AssistantButtonLabel: View {
    let title: String
    var systemImage: String?
    var small = false

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: small ? 14 : 16, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(title)
        }
    }
}

// MARK: - Setup progress

/// Three steps as a shape: done (tint, with a check), now (tint, bold label), to come (track).
struct SetupStepBar: View {
    static let names = [Copy.AssistantAccess.stepLink, Copy.AssistantAccess.stepChoose, Copy.AssistantAccess.stepConnect]
    let now: Int

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Self.names.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(index <= now ? Tokens.tint : Tokens.track)
                        .frame(height: 4)
                    HStack(spacing: 4) {
                        if index < now {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(Self.names[index])
                            .fontWeight(index == now ? .semibold : .medium)
                    }
                    .font(AssistantFont.stepLabel)
                    .foregroundStyle(index < now ? Tokens.tint : (index == now ? Tokens.label : Tokens.tertiary))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.AssistantAccess.stepAccessibility(now))
    }
}

// MARK: - Rows

/// A row with a title, an optional line under it, and a switch (`.row.top`).
struct AssistantToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.bodyPlain)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(Tokens.good)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A disclosure row: a title (and an optional line), a trailing value, a chevron.
struct AssistantNavRowLabel: View {
    let title: String
    var subtitle: String?
    var value: String?
    var leading: AnyView?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            if let leading { leading }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.bodyPlain)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let value, typeSize.isAccessibilitySize {
                    Text(value)
                        .font(AppFont.bodyPlain)
                        .foregroundStyle(Tokens.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value, !typeSize.isAccessibilitySize {
                Text(value)
                    .font(AppFont.bodyPlain)
                    .foregroundStyle(Tokens.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            AssistantChevron()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct AssistantChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Tokens.chevron)
            .accessibilityHidden(true)
    }
}

// MARK: - Chips

/// "What goes, as a small shape": a gray pill with a glyph (24 pt; 22 pt in the flow tree).
struct AssistantChip: View {
    let chip: PrivacyChip
    var small = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(chip.icon))
                .font(.system(size: small ? 10 : 11, weight: .semibold))
                .foregroundStyle(Tokens.tertiary)
                .accessibilityHidden(true)
            Text(chip.label)
                .font(small ? AssistantFont.chipSmall : AssistantFont.chip)
                .foregroundStyle(Tokens.secondaryBody)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, small ? 8 : 9)
        .padding(.vertical, 3)
        .frame(minHeight: small ? 22 : 24)
        .background(Tokens.grayChipFill, in: RoundedRectangle(cornerRadius: small ? 11 : 12))
    }

    static func symbol(_ icon: PrivacyChip.Icon) -> String {
        switch icon {
        case .audio: return "waveform.path"
        case .text: return "text.alignleft"
        case .read: return "doc.text"
        case .question: return "questionmark.bubble"
        case .heart: return "heart"
        case .calendar: return "calendar"
        case .checklist: return "checklist"
        }
    }
}

/// Chips that wrap onto as many lines as they need, and a chip wider than the line wraps its
/// own text instead of running off the card (accessibility sizes).
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(width: width, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, max(used, 0)) } ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in layout(width: bounds.width, subviews: subviews) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Item { var index: Int; var x: CGFloat; var size: CGSize }
    private struct Row { var y: CGFloat; var width: CGFloat; var height: CGFloat; var items: [Item] }

    private func layout(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row(y: 0, width: 0, height: 0, items: [])
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            let x = current.items.isEmpty ? 0 : current.width + spacing
            if !current.items.isEmpty, x + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing, width: 0, height: 0, items: [])
            }
            let placedX = current.items.isEmpty ? 0 : current.width + spacing
            current.items.append(Item(index: index, x: placedX, size: size))
            current.width = placedX + size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Choices

/// `.option`: a selectable card, radius 14, 1 pt border (2 pt tint when chosen), a radio on the
/// right.
struct AssistantOptionCard<Extra: View>: View {
    let title: String
    let line: String
    var detail: String?
    let isSelected: Bool
    var verticalPadding: CGFloat = 10
    let action: () -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.optionCardRadius)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.rowTitle)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                extra
                Text(line)
                    .font(AssistantFont.caption)
                    .foregroundStyle(Tokens.secondaryBody)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(AssistantFont.caption)
                        .foregroundStyle(Tokens.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AssistantRadio(isOn: isSelected)
        }
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 16)
        .background(Tokens.surface, in: shape)
        .overlay(shape.strokeBorder(isSelected ? Tokens.tint : Tokens.cardBorder, lineWidth: isSelected ? 2 : 1))
        .contentShape(shape)
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}

struct AssistantRadio: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(Tokens.tint)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Tokens.onTint)
            } else {
                Circle().strokeBorder(Tokens.chevron, lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// `.seg`: a pill track with 44 pt segments, the chosen one on the surface.
struct AssistantSegmented<Value: Hashable>: View {
    let values: [Value]
    let label: (Value) -> String
    @Binding var selection: Value
    var small = false
    var accessibilityName: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                let on = value == selection
                Button {
                    selection = value
                } label: {
                    Text(label(value))
                        .font(small ? AssistantFont.segmentSmall : AssistantFont.segment)
                        .fontWeight(on ? .semibold : .medium)
                        .foregroundStyle(Tokens.label)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Tokens.segmentOn)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Tokens.pillFill, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }
}
