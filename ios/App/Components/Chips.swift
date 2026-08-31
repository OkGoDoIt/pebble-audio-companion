import SwiftUI

// MARK: - Tint filter chip

/// Library/Search filter chip: 13/500 tint on 10% tint fill, r13 (capsule), padding 4/11.
/// Optional trailing count ("travel 12").
struct FilterChip: View {
    let text: String
    var count: Int? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        maybeButton {
            HStack(spacing: 5) {
                Text(text)
                if let count { Text("\(count)").opacity(0.55) }
            }
            .font(AppFont.chip)
            .foregroundStyle(Tokens.tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, 4)
            .padding(.horizontal, 11)
            .background(Capsule().fill(Tokens.tintFill10))
            .contentShape(Capsule())
        }
        .accessibilityLabel(Copy.A11y.filterChip(text, count: count))
    }

    @ViewBuilder
    private func maybeButton<C: View>(@ViewBuilder _ label: () -> C) -> some View {
        if let action {
            Button(action: action, label: label).buttonStyle(.plain)
        } else {
            label()
        }
    }
}

// MARK: - Gray read-only tag chip

/// Read-only tag on rows: 11/500 on `grayChipFill`, r9, padding 2/8. On detail screens
/// (over `ground`) it switches to a white fill with padding 3/9.
struct TagChip: View {
    enum Style { case onCard, onGround }

    let text: String
    var style: Style = .onCard

    var body: some View {
        Text(text)
            .font(AppFont.tagChip)
            .foregroundStyle(Tokens.tertiary)
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, style == .onCard ? 2 : 3)
            .padding(.horizontal, style == .onCard ? 8 : 9)
            .background(Capsule().fill(style == .onCard ? Tokens.grayChipFill : Tokens.surface))
            .accessibilityLabel(Copy.A11y.tag(text))
    }
}

// MARK: - Editable tag chip (Tag Editor sheet)

/// Editable tag chip: 14/500 tint on 10% fill, r15, padding 6/12, trailing × to remove.
/// Rename state: white fill, 1.5px tint border, padding 5/11, trailing 1.5×14 caret.
struct EditableTagChip: View {
    let text: String
    var isRenaming: Bool = false
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            Text(text).font(AppFont.editableChip)
                .lineLimit(1)
                .fixedSize()
            if isRenaming {
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(Tokens.tint)
                    .frame(width: 1.5, height: 14)
                    .accessibilityHidden(true)
            } else if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.tint.opacity(0.7))
                        // Drawn at 16 pt so the chip keeps its mockup height; the hit area
                        // is grown to 44 pt and the surrounding padding pulled back, so
                        // touch gets the HIG target without inflating the layout.
                        .frame(width: 16, height: 16)
                        .padding(14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)  // surfaced as a rotor action on the chip
                .padding(-14)
            }
        }
        .foregroundStyle(Tokens.tint)
        .padding(.vertical, isRenaming ? 5 : 6)
        .padding(.horizontal, isRenaming ? 11 : 12)
        .background(Capsule().fill(isRenaming ? Tokens.surface : Tokens.tintFill10))
        .overlay(Capsule().strokeBorder(Tokens.tint, lineWidth: isRenaming ? 1.5 : 0))
        // One element per chip, with Remove as a named action (U10).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Copy.A11y.tag(text))
        .accessibilityAction(named: Copy.A11y.removeTag(text)) { onRemove?() }
    }
}

// MARK: - Suggestion chip

/// AI tag suggestion: "+ name", 14/500 tint on white, r15.
struct SuggestionChip: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("+ \(name)")
                .font(AppFont.editableChip)
                .foregroundStyle(Tokens.tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Capsule().fill(Tokens.surface))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add tag \(name)")
    }
}

// MARK: - Action pill

/// h36 r18 pill: filled-tint (15/600 white) or neutral (`pillFill`, 15/500 label).
/// Optional leading glyph (sparkle on Ask).
struct ActionPill: View {
    enum Style { case filled, neutral }

    let title: String
    var systemImage: String? = nil
    var style: Style = .neutral
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(style == .filled ? AppFont.cardHead : AppFont.pill)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(style == .filled ? Tokens.onTint : Tokens.label)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(Capsule().fill(style == .filled ? Tokens.tint : Tokens.pillFill))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("Chips") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                FilterChip(text: "travel", count: 12) {}
                FilterChip(text: "work", count: 8) {}
                FilterChip(text: "family", count: 5) {}
            }
            HStack(spacing: 6) {
                TagChip(text: "work")
                TagChip(text: "planning")
                TagChip(text: "money", style: .onGround)
            }
            HStack(spacing: 8) {
                EditableTagChip(text: "work", onRemove: {})
                EditableTagChip(text: "planning", isRenaming: true)
                EditableTagChip(text: "money", onRemove: {})
            }
            HStack(spacing: 8) {
                SuggestionChip(name: "budget") {}
                SuggestionChip(name: "evening") {}
                SuggestionChip(name: "family") {}
            }
            HStack(spacing: 10) {
                ActionPill(title: Copy.Conversation.ask, systemImage: "sparkles", style: .filled) {}
                ActionPill(title: Copy.Conversation.notes) {}
                ActionPill(title: Copy.Conversation.followUps) {}
            }
        }
        .padding(Tokens.screenMargin)
    }
    .background(Tokens.ground)
}
