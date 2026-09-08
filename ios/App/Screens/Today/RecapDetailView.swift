import SwiftUI

/// The full recap — the Saved-Notes pattern (extraction §2.16) applied to the daily digest:
/// title, provenance line, the recap itself, moments footer. Pushed from the recap card; no tab
/// bar (conventions §3).
///
/// This screen is the reason the Today card may show a shortened form at all: everything the
/// digest said is HERE, whole, and the card's chevron points at it. Two consequences the code
/// below is careful about:
///
///   • It renders `recap.digest` — the full digest — never `recap.cardText`. A "full recap"
///     that turned out to be the same short paragraph would make the tap pointless.
///   • When the card WAS showing a short form, the provenance block says so, so a person
///     arriving here can tell this is the same recap read at length rather than a second one.
struct RecapDetailView: View {
    let recap: RecapDisplay?

    private var detail: RecapDetailDisplay? { recap?.detail }

    var body: some View {
        ScrollView {
            if let recap, let detail {
                VStack(alignment: .leading, spacing: Tokens.blockGap) {
                    Text(detail.title)
                        .font(AppFont.detailTitle)
                        .foregroundStyle(Tokens.label)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detail.generatedLine)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                            .fixedSize(horizontal: false, vertical: true)
                        if recap.isCondensed {
                            Text(Copy.Recap.cardShowsShortVersion)
                                .font(AppFont.footnote)
                                .foregroundStyle(Tokens.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            recapBody(of: recap, detail: detail)

                            if !detail.momentsFooter.isEmpty {
                                Rectangle()
                                    .fill(Tokens.hairline)
                                    .frame(height: 0.5)

                                // No chevron here. There used to be one, and nothing was
                                // behind it — a caret that opens nothing teaches people not to
                                // trust the one on the card, which does.
                                Text(detail.momentsFooter)
                                    .font(AppFont.footnote)
                                    .foregroundStyle(Tokens.meta)
                                    .fixedSize(horizontal: false, vertical: true)
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

    /// Bullets when the recap came back as a list, paragraphs when it came back as prose.
    ///
    /// `AiPromptTemplates.dailySummary` asks for plain sentences, so on a real device the
    /// digest is usually ONE block — and rendering that block behind a single "•" made a
    /// paragraph look like a stray list item. The bullet path is still here because the
    /// artboards (and any template that answers in lines) use it.
    @ViewBuilder
    private func recapBody(of recap: RecapDisplay, detail: RecapDetailDisplay) -> some View {
        if detail.bullets.count > 1 {
            ForEach(detail.bullets) { bullet in
                bulletView(bullet)
            }
        } else {
            ForEach(paragraphs(of: recap.digest), id: \.self) { text in
                Text(text)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.label)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The digest split on blank lines. A digest with no blank lines is one paragraph, which is
    /// the normal case.
    private func paragraphs(of digest: String) -> [String] {
        digest
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

#Preview("Recap detail · cited bullets") {
    NavigationStack {
        RecapDetailView(
            recap: RecapDisplay(
                updatedText: Copy.Today.updatedAt("12:40 PM"),
                digest: "Quiet morning until coffee with Dana.\nDecision: rebuild the app in Swift.",
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
        )
    }
    .tint(Tokens.tint)
}

#Preview("Recap detail · condensed on Today") {
    NavigationStack {
        RecapDetailView(
            recap: RecapDisplay(
                updatedText: Copy.Today.updatedAt("12:40 PM"),
                digest: "A quiet morning at home — mostly the radio and one short call about "
                    + "the delivery window. Coffee with Dana at 9:12; she takes the new firmware "
                    + "build and wants the studio walkthrough moved to Tuesday before the slot "
                    + "goes. Around noon you worked through the app redesign for the best part "
                    + "of an hour, and the decision at the end of it was to rebuild the app in "
                    + "Swift rather than keep patching the shared layer.",
                condensed: "Quiet morning. Redesign work around noon; decision to rebuild in Swift.",
                detail: RecapDetailDisplay(
                    id: "day-2026-08-30",
                    title: Copy.Today.recapTitle,
                    generatedLine: "Generated 12:40 PM · GPT-5.6 Luna · from today",
                    bullets: [],
                    momentsFooter: "2 moments · Coffee with Dana, App redesign session"
                )
            )
        )
    }
    .tint(Tokens.tint)
}
