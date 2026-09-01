import SwiftUI

/// One quiet line above a live transcript that has stopped growing, saying why.
///
/// Deliberately NOT a warning box: none of the things it says is an error — a quiet room, a
/// link that dropped and will re-deliver, an engine that is retrying. It reads as an
/// explanation, in the same register as the transcript's own quiet/missing markers, and it
/// disappears the moment words are arriving normally again.
struct LiveStatusNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Tokens.meta)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(text)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.meta)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        .accessibilityElement(children: .combine)
    }
}
