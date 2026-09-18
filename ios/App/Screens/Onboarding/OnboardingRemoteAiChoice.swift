import Intelligence
import SwiftUI

/// The sub-choice under "In the cloud" on iOS 27: which cloud writes the notes.
///
/// Two compact rows in one bordered group rather than two more `OptionCard`s — nested full
/// cards would read as a second question, and this is a detail of the answer already given.
/// It appears only while the cloud card (or the AI axis's cloud option) is selected, directly
/// under it, so what the choice does is part of the choice, the same way the consequences
/// block is. On iOS 26 it does not exist and the flow is exactly what it was.
struct OnboardingRemoteAiChoice: View {
    @Binding var selection: RemoteAiProvider

    /// Whether this OS offers the choice at all.
    static var isOffered: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.OnboardingProcessing.remoteModelChoice)
                .font(AppFont.sectionHeader)
                .textCase(.uppercase)
                .kerning(0.4)
                .foregroundStyle(Tokens.meta)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                row(
                    .openAi,
                    title: Copy.Privacy.remoteAi,
                    body: Copy.OnboardingProcessing.remoteOpenAiBody)
                Divider().padding(.leading, 14)
                row(
                    .applePrivateCloud,
                    title: Copy.Privacy.applePrivateCloud,
                    body: Copy.OnboardingProcessing.remoteApplePrivateCloudBody)
            }
            .background(Tokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.optionCardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.optionCardRadius)
                    .strokeBorder(Tokens.cardBorder, lineWidth: 1)
            )
        }
    }

    private func row(_ provider: RemoteAiProvider, title: String, body: String) -> some View {
        let isSelected = selection == provider
        return Button {
            selection = provider
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppFont.callout)
                        .foregroundStyle(Tokens.label)
                    Text(body)
                        .font(AppFont.caption)
                        .foregroundStyle(Tokens.tertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Tokens.tint : Tokens.chevron)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Remote AI choice") {
    @Previewable @State var selection: RemoteAiProvider = .openAi
    OnboardingRemoteAiChoice(selection: $selection)
        .padding(24)
        .background(Tokens.ground)
        .tint(Tokens.tint)
}
