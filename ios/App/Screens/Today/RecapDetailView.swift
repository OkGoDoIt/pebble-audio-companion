import SwiftUI

/// The cited recap detail — the Saved-Notes pattern (extraction §2.16) applied to the daily
/// digest: title, provenance line, cited bullets with inline numeric chips, moments footer.
/// Pushed from the recap card; no tab bar (conventions §3).
struct RecapDetailView: View {
    let detail: RecapDetailDisplay?

    var body: some View {
        ScrollView {
            if let detail {
                VStack(alignment: .leading, spacing: Tokens.blockGap) {
                    Text(detail.title)
                        .font(AppFont.detailTitle)
                        .foregroundStyle(Tokens.label)
                    Text(detail.generatedLine)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(detail.bullets) { bullet in
                                bulletView(bullet)
                            }

                            Rectangle()
                                .fill(Tokens.hairline)
                                .frame(height: 0.5)

                            HStack(spacing: 10) {
                                Text(detail.momentsFooter)
                                    .font(AppFont.footnote)
                                    .foregroundStyle(Tokens.meta)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Tokens.chevron)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                .padding(Tokens.screenMargin)
            }
        }
        .background(Tokens.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private func bulletView(_ bullet: RecapBullet) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.tertiary)
            citedText(bullet)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Bullet text with trailing citation chips — [n] after the statement, rendered as
    /// small tint chips (11/600 on 12% fill).
    private func citedText(_ bullet: RecapBullet) -> Text {
        var result = Text(bullet.text)
            .font(AppFont.subBody)
            .foregroundStyle(Tokens.label)
        for number in bullet.citations {
            var chip = AttributedString(" \(number) ")
            chip.font = .system(size: 11, weight: .semibold)
            chip.foregroundColor = Tokens.tint
            chip.backgroundColor = Tokens.tintFill12
            result = result + Text(" ") + Text(chip)
        }
        return result
    }
}

#Preview("Recap detail") {
    NavigationStack {
        RecapDetailView(
            detail: RecapDetailDisplay(
                id: "day-2026-08-30",
                title: Copy.Today.recapTitle,
                generatedLine: "Generated 12:40 PM · GPT-5.6 Luna · from today",
                bullets: [
                    RecapBullet(id: 1, text: "Quiet morning until coffee with Dana.", citations: [1]),
                    RecapBullet(id: 2, text: "Decision: rebuild the app in Swift.", citations: [2]),
                ],
                momentsFooter: "2 moments · Coffee with Dana, App redesign session"
            )
        )
    }
    .tint(Tokens.tint)
}
