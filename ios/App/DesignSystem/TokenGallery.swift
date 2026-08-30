import SwiftUI

/// M0 gate: the design tokens rendered as a screen gallery.
struct TokenGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                group("Brand") {
                    swatch("tint", Tokens.tint)
                    swatch("tintPressed", Tokens.tintPressed)
                    swatch("captured", Tokens.captured)
                    swatch("tintFill10", Tokens.tintFill10)
                }
                group("Status") {
                    swatch("good", Tokens.good)
                    swatch("missing", Tokens.missing)
                    swatch("attention", Tokens.attention)
                    swatch("destructive", Tokens.destructive)
                    swatch("neutralDot", Tokens.neutralDot)
                }
                group("Audio taxonomy") {
                    swatch("transcribed", Tokens.tint)
                    swatch("captured", Tokens.captured)
                    swatch("quiet", Tokens.quiet)
                    swatch("missing", Tokens.missing)
                    swatch("track (off)", Tokens.track)
                }
                group("Surfaces") {
                    swatch("ground", Tokens.ground)
                    swatch("surface", Tokens.surface)
                    swatch("fieldFill", Tokens.fieldFill)
                    swatch("grayChipFill", Tokens.grayChipFill)
                }
                group("Type scale") {
                    Text("Today").font(AppFont.tabTitle)
                    Text("Confirm on your watch").font(AppFont.screenTitle)
                    Text("Coffee with Dana").font(AppFont.detailTitle)
                    Text("Conversations").font(AppFont.sectionTitle)
                    Text("Recording").font(AppFont.headline)
                    Text("Pebble Time 2 · connected").font(AppFont.footnote)
                        .foregroundStyle(Tokens.tertiary)
                    Text("SECTION HEADER").font(AppFont.sectionHeader)
                        .foregroundStyle(Tokens.meta).kerning(0.4)
                }
            }
            .padding(Tokens.screenMargin)
        }
        .background(Tokens.ground)
        .navigationTitle("Tokens")
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(AppFont.sectionHeader)
                .foregroundStyle(Tokens.meta).kerning(0.4)
            VStack(alignment: .leading, spacing: 6, content: content)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.surface)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: 44, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.hairline))
            Text(name).font(AppFont.footnote).foregroundStyle(Tokens.label)
        }
    }
}

#Preview {
    NavigationStack { TokenGallery() }
}
