import SwiftUI

// MARK: - Content card

/// Standard content card: padding 14/16, radius 12, surface background (Part 2-A).
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(Tokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
    }
}

// MARK: - List card

/// List card: `0 16` card padding, rows padded `12 0`, hairline dividers between rows —
/// never after the last row (the divider rule is enforced here, not by callers).
struct ListCard<Content: View>: View {
    var rowVerticalPadding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews.indices, id: \.self) { index in
                    subviews[index]
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, rowVerticalPadding)
                    if index < subviews.count - 1 {
                        Rectangle().fill(Tokens.hairline).frame(height: 0.5)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
    }
}

// MARK: - Option card

/// Single-select option card (onboarding Transcripts, Q14): radius 14; selected = 2px tint
/// border + filled check circle; unselected = 1px `cardBorder` + empty circle.
struct OptionCard: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                    Text(subtitle)
                        .font(AppFont.caption)
                        .foregroundStyle(Tokens.tertiary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Tokens.tint : Tokens.chevron)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(Tokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.optionCardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.optionCardRadius)
                    .strokeBorder(
                        isSelected ? Tokens.tint : Tokens.cardBorder,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Previews

#Preview("Cards") {
    ScrollView {
        VStack(spacing: Tokens.blockGap) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Copy.Today.recapTitle).font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)
                    Text("Quiet morning. Around noon you worked through the app redesign.")
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.secondaryBody)
                }
            }

            ListCard {
                Text("Row one").font(AppFont.callout).foregroundStyle(Tokens.label)
                Text("Row two").font(AppFont.callout).foregroundStyle(Tokens.label)
                Text("Row three — no divider after me")
                    .font(AppFont.callout).foregroundStyle(Tokens.label)
            }

            OptionCard(
                title: Copy.Onboarding.inCloudTitle,
                subtitle: Copy.Onboarding.inCloudBody,
                isSelected: true
            ) {}
            OptionCard(
                title: Copy.Onboarding.onPhoneTitle,
                subtitle: Copy.Onboarding.onPhoneBody,
                isSelected: false
            ) {}
        }
        .padding(Tokens.screenMargin)
    }
    .background(Tokens.ground)
}
