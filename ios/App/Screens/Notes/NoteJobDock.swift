import SwiftUI

/// The app-wide report on notes being written — one calm card docked at the bottom of whatever
/// the user is looking at.
///
/// Placement. The user is free to be anywhere while a note is written, and "anywhere" includes
/// three screens with something of their own already at the bottom edge — the tab bar on every
/// tab root, the [Ask][Notes][Follow-ups] bar on the conversation screen they almost certainly
/// started from, and the home indicator. None of them may be covered.
///
/// This was a `safeAreaInset(edge: .bottom)` on each tab's `NavigationStack`, on the reasoning
/// that an inset "stacks" — the dock takes its own strip and everything else moves up by
/// exactly that much. On a device it did neither (reported with screenshots): the card sat ON
/// the tab bar on Today and ON the conversation screen's own bar. `safeAreaInset` anchors its
/// content to the **frame** edge of the view it modifies, and a `NavigationStack` deliberately
/// spans the whole tab — under the tab bar, under whatever a pushed screen has inset at the
/// bottom — so the strip it freed was a strip somebody else was already drawing in. The safe
/// area it granted in exchange never reached the pushed screen either: a pushed screen's insets
/// come up through UIKit's navigation controller, which does not know about an inset a SwiftUI
/// ancestor added outside it. So the conversation's bar never moved up, and the card landed on
/// top of it.
///
/// What replaces it is two halves, each of which can be reasoned about on its own:
///
///  * **Where the card sits** is a `ZStack` sibling of the navigation stack (`noteJobDock()`).
///    A plain view in a `ZStack` is laid out inside the safe area even when a sibling expands
///    past it, so the card lands above the tab bar on a tab root and above the home indicator
///    on a pushed screen, without a tab-bar height to guess at. (An `overlay` would not do:
///    overlay content inherits the modified view's frame *and* its safe area, which is exactly
///    the full-bleed frame that put the card on the tab bar.)
///  * **Room for the card** is the screen's job, because only the screen knows what it keeps at
///    its own bottom edge — and that is not always a bar (Ask keeps a composer down there in a
///    plain stack). The mount publishes the card's measured height as `\.noteJobDockInset`, and
///    `noteJobDockClearance()` is the one line that spends it. Anything permanently parked at a
///    screen's bottom edge should carry it; scrolling content should not.
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

/// How tall the note-job dock is at this moment — the card plus the gap under it, or zero when
/// no note is being written. A screen with a bottom bar of its own reads this and grows that bar
/// by it, so the bar (and the scrollable content the bar is already insetting) rides above the
/// card instead of underneath it.
///
/// Published downwards through the environment on purpose. The environment is the one channel in
/// this app that provably crosses a `NavigationStack` into a pushed screen — `AppRouter` has been
/// injected at the app root and read inside pushed detail screens since day one — whereas the
/// safe area does not (see `NoteJobDock`), and a `PreferenceKey` travelling the other way would
/// have to survive the same boundary in reverse and would report every screen on the stack at
/// once.
private struct NoteJobDockInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var noteJobDockInset: CGFloat {
        get { self[NoteJobDockInsetKey.self] }
        set { self[NoteJobDockInsetKey.self] = newValue }
    }
}

extension View {
    /// Docks the note-job card under this view. Applied to each tab's `NavigationStack` in
    /// `RootView` — inside the tab, so it can never be a card floating over the tab bar.
    func noteJobDock() -> some View {
        modifier(NoteJobDockMount())
    }

    /// Leaves room at this view's bottom edge for the note-job card, which is drawn over the
    /// bottom of every screen in the app.
    ///
    /// **Apply this to anything a screen keeps at its own bottom edge** — the conversation's
    /// [Ask][Notes][Follow-ups] bar, the live screen's transport, Ask's composer. Those are the
    /// controls a card at the bottom of the screen can hide, and the screen is the only thing
    /// that knows they are there. Scrolling content does not need it: the card covers the last
    /// inch of a scroll view, which a flick recovers, and a permanent inset on every list in the
    /// app to hold a card that is not usually there would cost more than it saves.
    ///
    /// Costs nothing when no note is being written — the inset is zero and this is a no-op.
    func noteJobDockClearance() -> some View {
        modifier(NoteJobDockClearance())
    }
}

private struct NoteJobDockClearance: ViewModifier {
    @Environment(\.noteJobDockInset) private var inset

    func body(content: Content) -> some View {
        content
            .padding(.bottom, inset)
            .motionAware(.snappy(duration: 0.25), value: inset)
    }
}

private struct NoteJobDockMount: ViewModifier {
    /// The dock's rendered height, republished to everything under it. Measured rather than
    /// assumed: the card is one or two lines depending on the job, and it grows with Dynamic
    /// Type. `onGeometryChange` here costs nothing to scroll past — the value only changes when
    /// a job starts, finishes or is dismissed, not on every frame.
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content
                .environment(\.noteJobDockInset, height)
            NoteJobDock()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    height = newHeight
                }
        }
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
