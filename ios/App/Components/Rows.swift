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

    var body: some View {
        if let action {
            Button(action: action) { rowContent.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(AppFont.callout)
                .foregroundStyle(Tokens.label)
            Spacer(minLength: 10)
            if let value {
                // One-line values per the artboards ("30 days · 383 recordings" never
                // wraps); scale slightly before truncating.
                Text(value)
                    .font(AppFont.subBody)
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    value: "Parakeet v3 · \(Copy.Settings.TranscriptionAI.installed("706 MB"))"
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
