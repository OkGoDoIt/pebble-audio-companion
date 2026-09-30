import AppDB
import SwiftUI

/// The white card every History level starts with (plan 5.2), modelled on Today's recap card:
/// a sparkles header in tint, the period's summary unclamped, and a gray footer with the
/// follow-up count. On a month, a row of tag pills with their day counts sits under the text.
///
/// It is never a spinner. With no summary yet it shows one gray line in the text's place
/// (`placeholder`, plan 5.8), and `note` adds a second gray line under it ("Topics are being
/// prepared").
struct BriefCard: View {
    let title: String
    /// The brief. Nil draws `placeholder` instead.
    let text: String?
    var placeholder: String = Copy.History.noSummaryYet
    /// "4 follow-ups · 2 open", "… · updated 11:15 AM". Nil hides the footer.
    var footer: String?
    /// Month only.
    var tagCounts: [HistoryTagCount] = []
    var note: String?
    /// Opens the Follow-ups tab filtered to the period. Nil: the footer is plain text.
    var onFooterTap: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.tint)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                Text(text ?? placeholder)
                    .font(AppFont.historyBody(dynamicTypeSize))
                    .foregroundStyle(text == nil ? Tokens.meta : Tokens.secondaryBody)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                if let note {
                    Text(note)
                        .font(AppFont.historyBody(dynamicTypeSize))
                        .foregroundStyle(Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }

                if !tagCounts.isEmpty {
                    FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(tagCounts) { tag in
                            FilterChip(text: tag.name, count: tag.days)
                        }
                    }
                    .padding(.top, 10)
                }

                if let footer {
                    footerView(footer)
                        .padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func footerView(_ footer: String) -> some View {
        let label = Text(footer)
            .font(AppFont.footnote)
            .foregroundStyle(Tokens.meta)
            .fixedSize(horizontal: false, vertical: true)
        if let onFooterTap {
            Button(action: onFooterTap) {
                // Drawn at its text height; the hit area is grown to 44 pt (plan 5.9) and the
                // padding pulled back so the card keeps the mockup's rhythm.
                label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                    .padding(.vertical, -13)
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }
}

#Preview("Brief cards") {
    ScrollView {
        VStack(spacing: 12) {
            BriefCard(
                title: Copy.History.dayInBrief,
                text: "Sprint planning over coffee, a broken login and a vendor call, a rainy site visit and a budget review, then dinner and a movie.",
                footer: Copy.History.followUpCount(total: 4, open: 2))
            BriefCard(
                title: Copy.History.monthInBrief,
                text: "The office move: packing and the trip mid-month, then venue hunting and invoices.",
                tagCounts: [.init(name: "apartment", days: 14), .init(name: "travel", days: 9)])
            BriefCard(title: Copy.History.dayInBrief, text: nil, note: Copy.History.topicsPreparing)
        }
        .padding(16)
    }
    .background(Tokens.ground)
}
