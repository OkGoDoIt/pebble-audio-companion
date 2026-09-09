import SwiftUI

// The floating ⌄ that takes a reader to the bottom of a long conversation, and the one reading
// it needs: are we at the bottom or not.
//
// This used to be a policy object with four inputs, a pair of `GeometryReader` height probes
// measuring the content against the viewport, and a suite of tests pinning the interactions
// between them — and it still showed up at the wrong moments. The scroll view already knows
// everything the question needs; the whole feature is one derived Bool and an overlay.

extension View {
    /// Calls `action` whenever "the scroll view is at its bottom" changes.
    ///
    /// Within `slack` points counts as at the bottom, because a tail that grows while a gesture
    /// finishes should not read as the reader having scrolled away.
    ///
    /// The arithmetic is the whole of the fix this file exists for, so it is worth stating what
    /// each term actually is — measured, on an iPhone 17 Pro with a navigation bar and the
    /// [Ask][Notes][Follow-ups] bar (874 pt tall, 116 pt of top inset, 104 pt of bottom):
    ///
    ///  * `containerSize.height` is the VISIBLE area, 654 — both insets already taken out;
    ///  * `contentOffset.y` is the RAW scroll offset, which reads −116 at the very top;
    ///  * so the furthest it can travel is content − visible − top inset. For a 1092 pt
    ///    conversation: 322, and 322 is exactly where scrolling to the bottom by hand stops.
    ///
    /// The version this replaces computed `content + insets.bottom − container`, which for the
    /// same conversation put the finish line at 542 — 220 pt (both insets) past anywhere the
    /// scroll view could go. The answer was "not at the bottom" at every offset including the
    /// last one, so the button never withdrew on its own; and because the derived value
    /// therefore never changed, the action stopped firing after the first reading and the
    /// button never came back either, once tapping it had hidden it.
    func onAtBottomChange(slack: CGFloat = 48, _ action: @escaping (Bool) -> Void) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            let maxOffset =
                geometry.contentSize.height - geometry.containerSize.height
                - geometry.contentInsets.top
            return geometry.contentOffset.y >= maxOffset - slack
        } action: { _, atBottom in
            action(atBottom)
        }
    }
}

/// The button, shared by the finished Conversation and the live one so the two cannot drift
/// into being two different-looking controls doing the same thing.
///
/// Deliberately quiet: it reports nothing, it is a shortcut for a gesture the reader could
/// already perform, so it is a plain surface circle in the same card material as the rest of
/// the screen. Round rather than a capsule for the same reason it carries no label — it is one
/// direction, not a sentence.
///
/// It floats in an overlay rather than a `safeAreaInset`. An inset would keep the last line
/// clear of it, but it also makes the button's own appearance change the scroll geometry that
/// decides whether to show it, and a control that moves the thing it is measuring is a control
/// that flickers.
struct ScrollToBottomButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tokens.tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Tokens.surface))
                .overlay { Circle().strokeBorder(Tokens.cardBorder, lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
                .hitTarget(44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.Reading.scrollToBottom)
        .accessibilityHint(Copy.Reading.scrollToBottomHint)
        .padding(.trailing, Tokens.screenMargin)
        .padding(.bottom, 12)
        .transition(Motion.transition(.scale(scale: 0.8).combined(with: .opacity)))
    }
}
