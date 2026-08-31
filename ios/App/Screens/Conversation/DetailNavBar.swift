import SwiftUI

/// Content-detail nav row (Conversation / Saved Notes artboards): back chevron + the ACTUAL
/// parent's label (B15), trailing Share + ⋯ (+ optional extras). Screens using it hide the
/// system navigation bar.
struct DetailNavBar<TrailingExtras: View, MenuContent: View>: View {
    let backLabel: String
    let onBack: () -> Void
    var shareText: String?
    @ViewBuilder var trailingExtras: TrailingExtras
    @ViewBuilder var menu: MenuContent

    init(
        backLabel: String,
        onBack: @escaping () -> Void,
        shareText: String? = nil,
        @ViewBuilder trailingExtras: () -> TrailingExtras = { EmptyView() },
        @ViewBuilder menu: () -> MenuContent = { EmptyView() }
    ) {
        self.backLabel = backLabel
        self.onBack = onBack
        self.shareText = shareText
        self.trailingExtras = trailingExtras()
        self.menu = menu()
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text(backLabel)
                        .font(AppFont.bodyPlain)
                        .lineLimit(1)
                }
                .foregroundStyle(Tokens.tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to \(backLabel)")

            Spacer(minLength: 8)

            trailingExtras

            if let shareText {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Tokens.tint)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }

            // ⋯ sits last, per the Conversation/Saved Notes artboards.
            menu
        }
        .padding(.horizontal, Tokens.screenMargin)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

/// The ⋯ trailing button carrying a menu.
struct EllipsisMenu<Items: View>: View {
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Tokens.tint)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }
}
