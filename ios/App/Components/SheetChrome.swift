import SwiftUI

/// Sheet grabber: 36×5 r2.5 in the `chevron` color, centered.
struct SheetGrabber: View {
    var body: some View {
        Capsule()
            .fill(Tokens.chevron)
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .accessibilityHidden(true)
    }
}

/// Sheet title row: 20/700 title with an optional trailing accessory
/// ("Done" on Tags, the scope pill on Ask).
struct SheetTitleRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(AppFont.sectionTitle)
                .foregroundStyle(Tokens.label)
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension SheetTitleRow where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

#Preview("Sheet chrome") {
    VStack(alignment: .leading, spacing: 16) {
        SheetGrabber()
        SheetTitleRow(title: Copy.Tags.title) {
            Button(Copy.Common.done) {}
                .font(AppFont.headline)
                .foregroundStyle(Tokens.tint)
        }
        SheetTitleRow(title: Copy.Ask.title) {
            FilterChip(text: "\(Copy.Ask.scopeLastDays(2)) ⌄") {}
        }
        SheetTitleRow(title: "No trailing")
        Spacer()
    }
    .padding(.horizontal, Tokens.screenMargin)
    .background(Tokens.surface)
}
