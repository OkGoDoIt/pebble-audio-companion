import SwiftUI

/// Every string on this screen comes from one enum, and the qualified name is longer than most
/// of the values. File-private, so it cannot leak the shorthand anywhere else.
private typealias Guide = Copy.FirmwareGuidance

// How the watch gets the firmware this app needs.
//
// Split into a plain content block and a sheet wrapper on purpose. The block is the whole
// guide and carries no chrome, so the same four steps can be shown from onboarding (as the
// sheet below) and from Settings without two copies of the words drifting apart — Settings →
// Firmware embeds `FirmwareSetupGuide()` directly.
//
// It is deliberately not a screen of its own in the onboarding flow. Onboarding has three
// steps; a fourth that most people scroll past would cost every user something to serve the
// one whose watch is on stock firmware. The people who need this are the ones who tapped
// "Requires the custom audio firmware." or hit a failure branch, and the guide meets them there.

/// The four steps, plus where the file comes from and what the official app has to do with it.
struct FirmwareSetupGuide: View {
    /// Where the build actually comes from.
    ///
    /// Defaulted to the newest release page (`Copy.FirmwareGuidance.releaseURL`); a Settings
    /// screen backed by the release feed passes the `.pbz` itself. Nil renders a sentence saying
    /// nothing is published rather than a link that goes nowhere.
    var releaseURL: URL? = Guide.releaseURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Guide.why)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.tertiary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            ListCard {
                StepRow(number: 1, title: Guide.step1Title, line: Guide.step1Line) {
                    // "Where do I get it" belongs to the step that asks for it, not to a row
                    // three steps further down.
                    releaseAffordance
                }
                StepRow(number: 2, title: Guide.step2Title, line: Guide.step2Line)
                StepRow(number: 3, title: Guide.step3Title, line: Guide.step3Line)
                StepRow(number: 4, title: Guide.step4Title, line: Guide.step4Line)
            }

            note(Guide.officialAppNote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A real link once there is one; the honest sentence until then.
    @ViewBuilder
    private var releaseAffordance: some View {
        if let releaseURL {
            Link(Guide.releaseLinkTitle, destination: releaseURL)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.tint)
        } else {
            Text(Guide.releaseUnavailable)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.meta)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(AppFont.footnote)
            .foregroundStyle(Tokens.meta)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One numbered step: the instruction, the single line that makes it doable, and whatever that
/// step needs to offer.
private struct StepRow<Accessory: View>: View {
    let number: Int
    let title: String
    let line: String
    @ViewBuilder var accessory: Accessory

    init(
        number: Int,
        title: String,
        line: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.number = number
        self.title = title
        self.line = line
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(AppFont.cardHead)
                .foregroundStyle(Tokens.tint)
                .frame(width: 16, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.cardHead)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(line)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.secondaryBody)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                accessory
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One step is one statement; a VoiceOver swipe per fragment would make a four-step list
        // read as twelve.
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Onboarding presentation

/// The guide as a sheet, for the two places in onboarding that raise it.
struct FirmwareSetupGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SheetTitleRow(title: Guide.title) {
                    Button(Copy.Common.done) { dismiss() }
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.tint)
                        .buttonStyle(.plain)
                }
                FirmwareSetupGuide()
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(Tokens.ground)
        .presentationDetents([.medium, .large])
    }
}

#Preview("Firmware guide") {
    Color.black.sheet(isPresented: .constant(true)) {
        FirmwareSetupGuideSheet()
            .tint(Tokens.tint)
    }
}
