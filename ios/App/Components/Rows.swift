import SwiftUI

// MARK: - Settings-style row

/// Settings row: 16/400 title + trailing 15/400 meta value + chevron. Value-only rows
/// (pure information, no navigation) omit the chevron. Designed to sit inside `ListCard`,
/// which supplies the 12/0 row padding and hairlines.
struct SettingsRow: View {
    let title: String
    var value: String? = nil
    var valueColor: Color = Tokens.meta
    var showsChevron: Bool = true
    var action: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if let action {
            Button(action: action) { rowContent.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // At accessibility sizes a side-by-side row squeezes the title into
                // hyphenated fragments and truncates the value. Stack instead, and let
                // both halves wrap in full (M10).
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        titleText
                        Spacer(minLength: 10)
                        chevron
                    }
                    valueText(alignment: .leading, wraps: true)
                }
            } else {
                HStack(spacing: 10) {
                    titleText
                    Spacer(minLength: 10)
                    valueText(alignment: .trailing, wraps: false)
                    chevron
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(title)
            .font(AppFont.callout)
            .foregroundStyle(Tokens.label)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func valueText(alignment: TextAlignment, wraps: Bool) -> some View {
        if let value {
            // One-line values at the default sizes per the artboards ("30 days · 383
            // recordings" never wraps); scale slightly before truncating.
            Text(value)
                .font(AppFont.subBody)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(alignment)
                .lineLimit(wraps ? nil : 1)
                .minimumScaleFactor(wraps ? 1 : 0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if showsChevron {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.chevron)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Destructive row

/// Red text row in its own single-row card ("Forget This Watch…"). Trailing ellipsis in
/// the title signals a confirmation step; destructive is never a filled red button.
struct DestructiveRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppFont.callout)
                .foregroundStyle(Tokens.destructive)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("Rows") {
    ScrollView {
        VStack(spacing: Tokens.blockGap) {
            ListCard {
                SettingsRow(
                    title: Copy.Settings.TranscriptionAI.mode,
                    value: Copy.Settings.TranscriptionAI.cloudFirst
                ) {}
                SettingsRow(
                    title: Copy.Settings.TranscriptionAI.localModel,
                    value: "Parakeet TDT 0.6B · 706 MB"
                ) {}
                SettingsRow(
                    title: Copy.Settings.TranscriptionAI.keyRow(provider: "Soniox"),
                    value: Copy.Settings.TranscriptionAI.savedInKeychain
                ) {}
            }
            ListCard {
                SettingsRow(
                    title: Copy.Settings.Watch.firmware,
                    value: Copy.Settings.Watch.firmwareValue("v4.36"),
                    showsChevron: false
                )
                SettingsRow(
                    title: Copy.Settings.Watch.watchReports,
                    value: Copy.Status.recording,
                    showsChevron: false
                )
            }
            ListCard {
                DestructiveRow(title: Copy.Settings.Watch.forgetWatch) {}
            }
            Text(Copy.Settings.Watch.footer)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.meta)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Tokens.screenMargin)
    }
    .background(Tokens.ground)
}
