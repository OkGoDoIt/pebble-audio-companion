import SwiftUI

// MARK: - Model

/// The dark undo snackbar's content ("Conversation deleted" / "Undo", 5 s).
struct SnackbarItem: Equatable {
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    static func == (lhs: SnackbarItem, rhs: SnackbarItem) -> Bool {
        lhs.message == rhs.message && lhs.actionTitle == rhs.actionTitle
    }
}

// MARK: - Modifier

extension View {
    /// Presents the dark snackbar (label bg, r12, message + tinted action) above the
    /// bottom edge; auto-dismisses after 5 seconds.
    func snackbar(item: Binding<SnackbarItem?>) -> some View {
        modifier(SnackbarModifier(item: item))
    }
}

private struct SnackbarModifier: ViewModifier {
    @Binding var item: SnackbarItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let current = item {
                    SnackbarView(item: current) { item = nil }
                        .padding(.horizontal, Tokens.screenMargin)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: current) {
                            try? await Task.sleep(for: .seconds(5))
                            if !Task.isCancelled, item == current { item = nil }
                        }
                }
            }
            .animation(.snappy(duration: 0.25), value: item)
    }
}

private struct SnackbarView: View {
    let item: SnackbarItem
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(item.message)
                .font(AppFont.subBody)
                .foregroundStyle(.white)
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
