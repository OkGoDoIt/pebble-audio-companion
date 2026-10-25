import Intelligence
import SwiftUI

/// Settings · About You: the text you write about yourself, and the two phone sources that
/// add to it.
///
/// **The editor is the page.** It used to be read-only text with a small purple "Edit" link at
/// the bottom of the card, which opened a modal with Cancel and Save — so writing a sentence
/// cost a scroll, a tap, a modal, and a second tap, and every one of those was a place to lose
/// what you had written. It is now what Notes is: tap the text, a caret appears, type, and it
/// is saved. There is no Save button and no edit mode, so there is no state to be in and no
/// state to get wrong.
///
/// **Nothing says "Saved."** Deliberately. A confirmation that appears every time you pause
/// typing is noise, and it is noise about the thing that is supposed to be unremarkable — the
/// promise is that the text is always saved, and a promise you have to re-read every few
/// seconds is not a promise. What this screen does report is the one thing the person cannot
/// see for themselves: whether the imports are still working. See `DebouncedTextSaver` for the
/// four moments a write is forced, which is what makes the silence honest.
struct SettingsAboutYouScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    private var aboutYou: AboutYouSource { SettingsDataSources.current.aboutYou }

    @State private var draft = ""
    @State private var saver: DebouncedTextSaver?
    @State private var confirmClear = false
    @FocusState private var editing: Bool

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private var sourceStates: [ImportSourceState] {
        ContextImportKind.allCases.map { aboutYou.state(for: $0) }
    }

    var body: some View {
        SettingsScroll {
            SettingsFooter(
                text: Copy.Settings.AboutYou.explainer(
                    destinations: settings.cloudDestinations
                )
            )

            Card {
                BioEditor(
                    text: $draft,
                    placeholder: Copy.Settings.AboutYou.bioPlaceholder,
                    focused: $editing
                )
            }

            ListCard {
                NavigationLink { VoiceSettingsScreen() } label: {
                    HStack {
                        Label(Copy.Voices.yourVoice, systemImage: "person.wave.2")
                            .font(AppFont.rowTitle).foregroundStyle(Tokens.label)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Tokens.chevron)
                    }
                }.buttonStyle(.plain)
            }

            SettingsSectionHeader(title: Copy.Settings.AboutYou.sourcesSection)
            ListCard {
                ForEach(ContextImportKind.allCases, id: \.self) { kind in
                    sourceRow(aboutYou.state(for: kind))
                }
            }
            if let line = Copy.Settings.AboutYou.freshnessLine(sourceStates, nowMs: nowMs) {
                SettingsFooter(text: line)
            }

            ListCard {
                DestructiveRow(title: Copy.Settings.AboutYou.clearImported) {
                    confirmClear = true
                }
            }
            // Anchored to the card that raises it. Attached to `SettingsScroll` the source rect
            // is the whole screen and iOS 26 places the panel against the top of it, far from
            // the row that was tapped — and this row is at the very bottom of a long screen.
            // Same fix as `SettingsWatchScreen` and `SettingsStorageScreen`.
            .confirmationDialog(
                Copy.Settings.AboutYou.clearImported,
                isPresented: $confirmClear,
                titleVisibility: .hidden
            ) {
                Button("Clear Imported Context", role: .destructive) {
                    aboutYou.clearImported()
                }
            }
        }
        // The keyboard follows your finger down, matching the Ask composer. Without it the only
        // way out of a full-screen editor is the Done bar.
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(Copy.Settings.AboutYou.title)
        .onAppear {
            guard saver == nil else { return }
            let source = aboutYou
            draft = source.bio
            let saver = DebouncedTextSaver { source.bio = $0 }
            saver.adopt(draft)
            self.saver = saver
        }
        .onChange(of: draft) { _, text in saver?.edited(text) }
        // Losing focus, leaving the screen, and the app going away are the three ways typing
        // stops without the debounce having fired. All three write.
        .onChange(of: editing) { _, focused in
            if !focused { saver?.flush() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saver?.flush() }
        }
        .onDisappear { saver?.flush() }
    }

    /// One source. The chevron now goes somewhere: a screen that can turn the source off,
    /// narrow what it reads, and say when it last worked.
    private func sourceRow(_ state: ImportSourceState) -> some View {
        NavigationLink {
            SettingsAboutYouSourceScreen(kind: state.kind)
        } label: {
            HStack(spacing: 10) {
                Text(Copy.Settings.AboutYou.sourceName(state.kind))
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                Spacer(minLength: 10)
                if state.isRefreshing {
                    ProgressView().controlSize(.small)
                } else if let value = Copy.Settings.AboutYou.rowValue(state) {
                    Text(value)
                        .font(AppFont.subBody)
                        .foregroundStyle(
                            state.access == .denied || state.lastFailure != nil
                                ? Tokens.attention : Tokens.meta
                        )
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The editor

/// A text editor that is the size of what you wrote.
///
/// The person this is for writes over a thousand words here, and a `TextEditor` with its own
/// scroll view inside the screen's scroll view is the standard way to make that miserable:
/// two scrollers fighting, a caret that disappears under the keyboard, and no way to reach the
/// rows below. So the editor does not scroll — the page does. Its height follows the text,
/// measured by laying the same string out in a hidden `Text` with the editor's own insets, and
/// UIKit then asks the enclosing scroll view to keep the caret visible, which is exactly the
/// behaviour Notes has.
///
/// The measurement carries deliberate slack: `Text` and the editor's `UITextView` can disagree
/// by a line on where a long paragraph wraps, and a height that is one line short would clip
/// the line being typed with no way to scroll to it. Slack costs a little blank space at the
/// bottom, which reads as somewhere to tap — and does exactly that.
private struct BioEditor: View {
    @Binding var text: String
    let placeholder: String
    @FocusState.Binding var focused: Bool

    @State private var measured: CGFloat = 0

    /// `UITextView`'s own text container insets, which the sizer has to reproduce for its
    /// measurement to mean anything: 8 vertical, and 5 of line-fragment padding either side.
    private let insetV: CGFloat = 8
    private let insetH: CGFloat = 5
    /// Roughly two lines. See the note above on why this is not zero.
    private let slack: CGFloat = 28
    /// An empty bio still looks like a page to write on rather than a one-line field.
    private let minHeight: CGFloat = 128

    var body: some View {
        ZStack(alignment: .topLeading) {
            sizer
            if text.isEmpty {
                Text(placeholder)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.faint)
                    .padding(.vertical, insetV)
                    .padding(.horizontal, insetH)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.secondaryBody)
                .lineSpacing(3)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: max(minHeight, measured + slack))
                .accessibilityLabel(Copy.Settings.AboutYou.bioAccessibilityLabel)
                .toolbar {
                    // The standard way out of the keyboard. A plain text button, not a
                    // `Label`: iOS 26 renders a `Label` in a bar icon-only.
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(Copy.Common.done) { focused = false }
                    }
                }
        }
        // No tap gesture of our own: the editor's frame already includes the slack, so tapping
        // the blank space under the last line lands in the text view and puts the caret at the
        // end — exactly like a note. A gesture on the container would have to compete with the
        // text view's own, and losing that race means every tap jumps the caret to the end.
    }

    /// Never drawn. Its only job is to report how tall this string is at this width.
    private var sizer: some View {
        Text(text.isEmpty ? " " : text)
            .font(AppFont.subBody)
            .lineSpacing(3)
            .padding(.vertical, insetV)
            .padding(.horizontal, insetH)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { measured = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in measured = height }
                }
            )
    }
}

#Preview("About You") {
    NavigationStack {
        SettingsAboutYouScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
