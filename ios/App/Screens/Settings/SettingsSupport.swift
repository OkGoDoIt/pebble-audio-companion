import SwiftUI

// Shared building blocks for the Settings screens (2.9–2.14 artboards).

// MARK: - Screen scaffolding

/// Standard pushed-Settings scaffold: grouped ground, block rhythm 12, screen margins 16.
struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.blockGap) {
                content
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.top, 4)
            .padding(.bottom, Tokens.screenMargin)
        }
        .background(Tokens.ground)
    }
}

/// 13/600 UPPERCASE +0.4 section header ("TRANSCRIPTION", "RECENT SEGMENTS").
struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(AppFont.sectionHeader)
            .textCase(.uppercase)
            .kerning(0.4)
            .foregroundStyle(Tokens.meta)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One plain 13/meta footnote sentence below the cards (2-C).
struct SettingsFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppFont.footnote)
            .foregroundStyle(Tokens.meta)
            .lineSpacing(2)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rows

/// Navigation row: SettingsRow content wrapped in a value-based NavigationLink.
struct SettingsNavRow: View {
    let title: String
    var value: String? = nil
    let route: Route

    var body: some View {
        NavigationLink(value: route) {
            SettingsRow(title: title, value: value)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Navigation row pushing a plain destination view (sub-screens that are not deep-link routes:
/// choice lists, key-change screens, detailed logs).
struct SettingsPushRow<Destination: View>: View {
    let title: String
    var value: String? = nil
    var valueColor: Color = Tokens.meta
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            SettingsRow(title: title, value: value, valueColor: valueColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Link-style action row (16/tint text, e.g. "Find Watch", "Test Connection") with an
/// optional trailing accessory (inline progress / result — B10: never fire-and-forget).
struct TintActionRow<Accessory: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder var accessory: Accessory

    init(
        title: String,
        action: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.action = action
        self.accessory = accessory()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.tint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                accessory
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pushed single-choice list

/// Every multi-value setting is a disclosure row into one of these — NO segmented controls
/// or steppers anywhere in Settings (2-A component inventory).
struct ChoiceScreen<Value: Hashable>: View {
    struct Option {
        let value: Value
        let label: String
    }

    let title: String
    let options: [Option]
    @Binding var selection: Value
    var footer: String? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsScroll {
            ListCard {
                ForEach(options, id: \.value) { option in
                    Button {
                        selection = option.value
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Text(option.label)
                                .font(AppFont.callout)
                                .foregroundStyle(Tokens.label)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 10)
                            if option.value == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Tokens.tint)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option.value == selection ? .isSelected : [])
                }
            }
            if let footer {
                SettingsFooter(text: footer)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
