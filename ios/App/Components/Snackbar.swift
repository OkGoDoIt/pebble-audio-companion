import SwiftUI

// MARK: - Model

/// The dark undo snackbar's content ("Conversation deleted" / "Undo", 5 s).
struct SnackbarItem: Equatable {
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    /// When it was posted. The five seconds run from here, not from whenever a view happened to
    /// start showing it: the app-wide host moves with the selected tab, and restarting the
    /// clock on every tab switch kept "Undo" on screen after the delete it offers to undo had
    /// already been committed (`DeferredDeleteBuffer.windowMs` is also five seconds). Part of
    /// equality, so posting the same message twice is two snackbars with two clocks.
    let postedAt = Date()

    /// How long a snackbar stays up.
    static let lifetime: Duration = .seconds(5)

    static func == (lhs: SnackbarItem, rhs: SnackbarItem) -> Bool {
        lhs.message == rhs.message && lhs.actionTitle == rhs.actionTitle
            && lhs.postedAt == rhs.postedAt
    }
}

// MARK: - Modifier

extension View {
    /// Presents the dark snackbar (label bg, r12, message + tinted action) above the
    /// bottom edge; auto-dismisses after 5 seconds.
    ///
    /// For a screen's own snackbar. App-wide ones — undo, which may be posted from a screen that
    /// is about to be popped — go through `UndoCenter.shared`, which `RootView` hosts.
    func snackbar(item: Binding<SnackbarItem?>) -> some View {
        modifier(SnackbarModifier(item: item))
    }
}

private struct SnackbarModifier: ViewModifier {
    @Binding var item: SnackbarItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                SnackbarSlot(item: $item)
            }
    }
}

/// The snackbar itself, with its transition and its clock, as a view that can be placed — the
/// overlay above uses it, and so does the app-wide host in `RootView`, which has to sit in a
/// `ZStack` rather than an overlay to land above the tab bar (see `NoteJobDock`).
struct SnackbarSlot: View {
    @Binding var item: SnackbarItem?

    var body: some View {
        Group {
            if let current = item {
                SnackbarView(item: current) { item = nil }
                    .padding(.horizontal, Tokens.screenMargin)
                    .padding(.bottom, 8)
                    .transition(Motion.transition(.move(edge: .bottom).combined(with: .opacity)))
                    .task(id: current) {
                        let shown = Duration.seconds(Date().timeIntervalSince(current.postedAt))
                        try? await Task.sleep(for: max(SnackbarItem.lifetime - shown, .zero))
                        if !Task.isCancelled, item == current { item = nil }
                    }
            }
        }
        .motionAware(.snappy(duration: 0.25), value: item)
    }
}

private struct SnackbarView: View {
    let item: SnackbarItem
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(item.message)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.onTint)
            Spacer(minLength: 0)
            if let title = item.actionTitle {
                Button {
                    item.action?()
                    dismiss()
                } label: {
                    Text(title)
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.tintOnDark)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, item.actionTitle == nil ? 12 : 0)
        .frame(minHeight: 44)
        .background(Tokens.snackbarBg)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
    }
}

// MARK: - Preview

#Preview("Snackbar") {
    @Previewable @State var item: SnackbarItem? = SnackbarItem(
        message: Copy.Conversation.deleted,
        actionTitle: Copy.Common.undo,
        action: {}
    )

    VStack {
        Spacer()
        Button("Show snackbar") {
            item = SnackbarItem(
                message: Copy.Conversation.deleted,
                actionTitle: Copy.Common.undo,
                action: {}
            )
        }
        .buttonStyle(.borderedTint)
        .padding(Tokens.screenMargin)
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Tokens.ground)
    .snackbar(item: $item)
}
