import SwiftUI

/// The app-wide report on notes being written — one calm card docked at the bottom of whatever
/// the user is looking at.
///
/// Placement, and why it is a safe-area inset rather than an overlay: the user is free to be
/// anywhere while a note is written, and "anywhere" includes three screens with something of
/// their own already at the bottom edge — the tab bar on every tab root, the
/// [Ask][Notes][Follow-ups] bar on the conversation screen they almost certainly started from,
/// and the home indicator. An overlay would float on top of one of them and hide it. An inset
/// stacks instead: the dock takes its own strip and everything else moves up by exactly that
/// much, so nothing is ever covered and there is no tab-bar height to guess at.
///
/// One card at a time, on purpose. `NoteJobCenter.focused` picks the job with something for the
/// user to do; the rest are counted, and each surfaces in turn as the one in front of it is
/// opened, dismissed or stopped. A stack of cards at the bottom of the screen would be a second
/// inbox, and this is a background-microphone app — the bottom of the screen is not the place to
/// pile things up.
///
/// Deliberately not the snackbar (`UndoCenter.shared.snackbar`): that one auto-dismisses after
/// five seconds, which is right for "Conversation deleted · Undo" and wrong for the one thing
/// this has to do. A note the user walked away from may finish while they are reading something
/// else, and a card that takes itself away before they look up has lost the result.
struct NoteJobDock: View {
    @Environment(AppRouter.self) private var router
    @State private var center = NoteJobCenter.shared

    var body: some View {
        Group {
            if let job = center.focused {
                card(job)
                    .padding(.horizontal, Tokens.screenMargin)
                    .padding(.bottom, 8)
                    .transition(
                        Motion.transition(.move(edge: .bottom).combined(with: .opacity)))
            }
        }
        .motionAware(.snappy(duration: 0.25), value: center.focused)
    }

    // MARK: - The card

    private func card(_ job: NoteJobCenter.Job) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                glyph(job)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(headline(job))
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    // Omitted rather than rendered empty: a finished job whose conversation title
                    // we never learned has nothing to put here, and a blank second line reads as
                    // something that failed to load.
                    let sub = subline(job)
                    if !sub.isEmpty {
                        Text(sub)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // One spoken element for the status, so VoiceOver does not read the glyph, the
            // headline and the sub-line as three separate stops before reaching the button that
            // actually does something.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(job))

            Spacer(minLength: 4)

            action(job)

            // Only the resolved states get a way to say "not now". A running job's way out is
            // Stop, which is a different promise and must not be one tap away from it by
            // accident.
            if job.state.isTerminal {
                Button {
                    center.dismiss(job.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.meta)
                        .hitTarget(36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.NoteJobs.dismiss)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, job.state.isTerminal ? 4 : 14)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.cardRadius)
                .strokeBorder(Tokens.cardBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 3)
    }

    @ViewBuilder
    private func glyph(_ job: NoteJobCenter.Job) -> some View {
        switch job.state {
        case .running:
            ProgressView().controlSize(.small)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Tokens.good)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17))
                .foregroundStyle(Tokens.attention)
        }
    }

    @ViewBuilder
    private func action(_ job: NoteJobCenter.Job) -> some View {
        switch job.state {
        case .running:
            dockButton(Copy.NoteJobs.stop, prominent: false) { center.stop(job.id) }
        case .finished:
            dockButton(Copy.NoteJobs.view, prominent: true) { center.open(job.id, router: router) }
        case .failed:
            dockButton(Copy.Common.retry, prominent: true) { center.retry(job.id) }
        }
    }

    private func dockButton(
        _ title: String, prominent: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppFont.cardHead)
                .foregroundStyle(prominent ? Tokens.tint : Tokens.tertiary)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Words

    private func headline(_ job: NoteJobCenter.Job) -> String {
        switch job.state {
        case .running: return Copy.NoteJobs.writing(job.templateTitle)
        case .finished: return Copy.NoteJobs.ready(job.templateTitle)
        case .failed: return Copy.NoteJobs.didNotFinish(job.templateTitle)
        }
    }

    /// Where it came from. Nothing when we were never told the conversation's title: the dock
    /// staying put while the user walks around the app is what says "this does not hold you
    /// up", and it says it better than a line claiming so.
    private func subline(_ job: NoteJobCenter.Job) -> String {
        var parts: [String] = []
        switch job.state {
        case .running:
            if let title = job.conversationTitle { parts.append(title) }
        case .finished:
            if let title = job.conversationTitle { parts.append(title) }
        case .failed(let reason):
            parts.append(reason)
        }
        let behind = center.queuedBehind
        if behind > 0 { parts.append(Copy.NoteJobs.more(behind)) }
        return parts.joined(separator: " · ")
    }

    private func accessibilityLabel(_ job: NoteJobCenter.Job) -> String {
        switch job.state {
        case .running:
            return Copy.NoteJobs.writingLabel(job.templateTitle)
        case .finished:
            return Copy.NoteJobs.readyLabel(job.templateTitle)
        case .failed(let reason):
            return Copy.NoteJobs.failedLabel(job.templateTitle, reason: reason)
        }
    }
}

// MARK: - Mounting

extension View {
    /// Docks the note-job card under this view. Applied to each tab's `NavigationStack` in
    /// `RootView` — inside the tab, so on a tab root it lands above the tab bar, and on a pushed
    /// screen that hides the tab bar it lands above the home indicator instead. Either way the
    /// content, including a screen's own bottom bar, is inset above it rather than covered by it.
    func noteJobDock() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { NoteJobDock() }
    }
}

// MARK: - Preview

#Preview("Note job dock") {
    let center = NoteJobCenter.shared
    center.reset()
    center.holdsBackgroundAssertion = false
    // A generation that takes ten minutes: the preview wants the running card, not a model call.
    center.generate = { _, _, _ in
        try await Task.sleep(for: .seconds(600))
        return NoteDisplay(
            id: "note-preview", conversationId: "c1", conversationTitle: "Dinner with Sam",
            title: Copy.Notes.templateExtendedSummary, provenance: "", body: "",
            momentsLabel: "", citations: [])
    }
    center.enqueue(
        conversationId: "c1",
        conversationTitle: "Dinner with Sam",
        template: NoteTemplate(id: "extended-summary", title: Copy.Notes.templateExtendedSummary)
    )

    return VStack {
        Spacer()
        Text("Anything at all")
            .font(AppFont.callout)
            .foregroundStyle(Tokens.meta)
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Tokens.ground)
    .noteJobDock()
    .environment(AppRouter())
    .tint(Tokens.tint)
}
