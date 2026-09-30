import AppDB
import SwiftUI

/// One follow-up as History shows it (plan 5.6): display only. An open one has a circle, a
/// done one a checked circle and dimmed text — the icon changes as well as the colour, so the
/// state never rests on colour alone. The circle is not a toggle: follow-ups are managed on the
/// Follow-ups tab, not ticked off from a timeline.
///
/// `.card` is the chapter card's line (14 pt); `.row` is the week row's smaller one (13 pt).
/// `more` adds a trailing "N more" for a collapsed card.
struct FollowUpLine: View {
    enum Size { case card, row }

    let text: String
    let done: Bool
    var size: Size = .card
    var more: Int = 0

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(text: String, done: Bool, size: Size = .card, more: Int = 0) {
        self.text = text
        self.done = done
        self.size = size
        self.more = more
    }

    init(_ line: HistoryFollowUpLine, size: Size = .card, more: Int = 0) {
        self.init(text: line.text, done: line.done, size: size, more: more)
    }

    var body: some View {
        HStack(spacing: size == .card ? 7 : 6) {
            Image(systemName: done ? "checkmark.circle" : "circle")
                .font(iconFont)
                .foregroundStyle(done ? Tokens.followUpDone : Tokens.tint)
                .accessibilityHidden(true)
            Text(text)
                .font(textFont)
                .foregroundStyle(done ? Tokens.followUpDone : textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            if more > 0 {
                Spacer(minLength: 6)
                Text(Copy.History.more(more))
                    .font(AppFont.timelineMeta)
                    .foregroundStyle(Tokens.meta)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.vertical, size == .card ? ChapterCardMetrics.followUpRowPadding : 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var textFont: Font {
        size == .card
            ? AppFont.historyBody(dynamicTypeSize)
            : AppFont.scaled(13, relativeTo: .footnote, dynamicTypeSize)
    }

    private var iconFont: Font {
        size == .card
            ? AppFont.scaled(16, relativeTo: .subheadline, dynamicTypeSize)
            : AppFont.scaled(14, relativeTo: .footnote, dynamicTypeSize)
    }

    private var textColor: Color { size == .card ? Tokens.label : Tokens.secondaryBody }

    private var accessibilityText: String {
        var parts = [text]
        if done { parts.append(Copy.History.A11y.followUpDone) }
        if more > 0 { parts.append(Copy.History.more(more)) }
        return parts.joined(separator: ", ")
    }
}

#Preview("Follow-up lines") {
    VStack(alignment: .leading, spacing: 12) {
        FollowUpLine(text: "Send the order number", done: false, more: 1)
        FollowUpLine(text: "Ask Simon for the agent’s number", done: true)
        FollowUpLine(text: "Email the vendor about the larger room", done: false, size: .row)
        FollowUpLine(text: "Fix the crash on older dates", done: true, size: .row)
    }
    .padding()
    .background(Tokens.surface)
}
