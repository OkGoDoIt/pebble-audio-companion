import SwiftUI
import UIKit

// MARK: - Action

/// One button behind a swiped row.
///
/// Deliberately the same vocabulary as SwiftUI's own `swipeActions` builder: the FIRST action
/// on an edge is the edge-most one, and the one a full swipe triggers. Declaring
/// `[delete, snooze]` on the trailing edge therefore draws Snooze then Delete, left to right,
/// and a full swipe deletes — exactly what the Follow-ups list already does with a real `List`.
struct SwipeAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color
    /// Fires a warning haptic before the handler, and is what a full swipe commits to.
    var isDestructive: Bool = false
    let handler: () -> Void
}

// MARK: - Row

/// Swipe-to-act for a row that is NOT in a `List`.
///
/// Today is a `ScrollView` of cards, so `swipeActions` — which only exists on `List` rows — was
/// never available to it. That left the same follow-up swipeable on the Follow-ups tab and inert
/// on Today, which reads as the gesture being broken rather than absent: people do not know
/// which of two identical-looking rows is inside a `List`.
///
/// The gesture is a UIKit pan rather than a SwiftUI `DragGesture` for one reason: a
/// `DragGesture` inside a `ScrollView` fights the scroll. This recognizer declares itself
/// simultaneous (which UIKit honours unconditionally when either delegate says yes) and then
/// cancels itself the moment the drag turns out to be vertical, so a scroll never leaves rows
/// half-open behind it.
struct SwipeRow<Content: View>: View {
    /// Identity for the "only one row open at a time" rule, shared through `openRow`.
    let rowID: String
    var leading: [SwipeAction] = []
    var trailing: [SwipeAction] = []
    /// The open row across the whole card. Swiping one closes whichever was open.
    @Binding var openRow: String?
    @ViewBuilder var content: Content

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var offset: CGFloat = 0
    /// Where the row sat when the current pan began, so a second swipe continues the first.
    @State private var startOffset: CGFloat = 0
    @State private var rowWidth: CGFloat = 1
    /// Past the full-swipe threshold: the edge-most action has taken over the whole row.
    @State private var isArmed = false

    private var buttonWidth: CGFloat { typeSize.isAccessibilitySize ? 112 : 76 }
    private var leadingWidth: CGFloat { CGFloat(leading.count) * buttonWidth }
    private var trailingWidth: CGFloat { CGFloat(trailing.count) * buttonWidth }
    /// Same feel as UIKit's: a little past half the row commits.
    private var fullSwipeThreshold: CGFloat { max(rowWidth * 0.55, buttonWidth * 1.6) }

    var body: some View {
        ZStack {
            buttons
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                // Opaque, or the buttons show through the row that is supposed to be covering
                // them. This is the card's own surface, so a closed row looks like every other.
                .background(Tokens.surface)
                .overlay {
                    // While something is revealed, a tap on the row puts it away instead of
                    // opening the follow-up — the same thing a `List` row does, and the only
                    // way out of an open row that does not require guessing.
                    if offset != 0 {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                    }
                }
                .offset(x: offset)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { rowWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in rowWidth = new }
            }
        }
        .gesture(
            HorizontalPan(
                onBegan: began,
                onChanged: changed,
                onEnded: ended
            )
        )
        .onChange(of: openRow) { _, open in
            if open != rowID && offset != 0 { close() }
        }
        // VoiceOver never gets the gesture, so it gets the actions directly. Without this the
        // swipe-only actions would be unreachable, which is the failure mode `swipeActions`
        // avoids for free on the Follow-ups tab.
        .accessibilityActions {
            ForEach(leading + trailing) { action in
                Button(action.title) { action.handler() }
            }
        }
    }

    // MARK: Buttons

    /// Edge-most first in the data, so the trailing edge draws in reverse.
    private var trailingDisplay: [SwipeAction] {
        isArmed && offset < 0 ? Array(trailing.prefix(1)) : trailing.reversed()
    }

    private var leadingDisplay: [SwipeAction] {
        isArmed && offset > 0 ? Array(leading.prefix(1)) : leading
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            ForEach(leadingDisplay) { action in
                button(action, width: isArmed && offset > 0 ? max(offset, buttonWidth) : buttonWidth)
            }
            Spacer(minLength: 0)
            ForEach(trailingDisplay) { action in
                button(
                    action, width: isArmed && offset < 0 ? max(-offset, buttonWidth) : buttonWidth)
            }
        }
    }

    private func button(_ action: SwipeAction, width: CGFloat) -> some View {
        Button {
            perform(action)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 19, weight: .semibold))
                Text(action.title)
                    .font(AppFont.microBold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(Tokens.onTint)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(action.tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    // MARK: Gesture

    private func began() {
        startOffset = offset
        openRow = rowID
    }

    private func changed(_ translation: CGFloat) {
        let proposed = startOffset + translation
        offset = clamped(proposed)
        let side = offset < 0 ? trailing : leading
        let armed = !side.isEmpty && abs(offset) > fullSwipeThreshold
        if armed != isArmed {
            // The one haptic in the gesture, and it earns its place: it is the only signal that
            // letting go now will act rather than just open the row.
            if armed { Haptics.impact(.light) }
            withAnimation(Motion.animation(.snappy(duration: 0.2))) { isArmed = armed }
        }
    }

    private func ended(_ translation: CGFloat, velocity: CGFloat) {
        let side = offset < 0 ? trailing : leading
        if isArmed, let primary = side.first {
            isArmed = false
            withAnimation(Motion.animation(.snappy(duration: 0.25))) { offset = 0 }
            openRow = nil
            perform(primary, closing: false)
            return
        }
        // A flick opens or closes on intent rather than on distance alone.
        let projected = offset + velocity * 0.1
        let target: CGFloat
        if offset < 0 && !trailing.isEmpty {
            target = -projected > trailingWidth / 2 ? -trailingWidth : 0
        } else if offset > 0 && !leading.isEmpty {
            target = projected > leadingWidth / 2 ? leadingWidth : 0
        } else {
            target = 0
        }
        withAnimation(Motion.animation(.snappy(duration: 0.28))) { offset = target }
        openRow = target == 0 ? nil : rowID
    }

    /// Past the actions on that edge the row keeps moving 1:1 so a full swipe is possible; an
    /// edge with no actions gets a short rubber band instead of nothing, which is what tells
    /// you the gesture was seen and there is simply nothing there.
    private func clamped(_ proposed: CGFloat) -> CGFloat {
        if proposed < 0 {
            guard !trailing.isEmpty else { return max(proposed / 4, -30) }
            return max(proposed, -rowWidth)
        }
        if proposed > 0 {
            guard !leading.isEmpty else { return min(proposed / 4, 30) }
            return min(proposed, rowWidth)
        }
        return 0
    }

    private func perform(_ action: SwipeAction, closing: Bool = true) {
        if action.isDestructive { Haptics.destructiveConfirmed() }
        if closing { close() }
        action.handler()
    }

    private func close() {
        withAnimation(Motion.animation(.snappy(duration: 0.25))) {
            offset = 0
            isArmed = false
        }
        if openRow == rowID { openRow = nil }
    }
}

// MARK: - The recognizer

/// A pan that runs alongside the enclosing scroll view and bows out of vertical drags.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = HorizontalPanRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began:
            onBegan()
            onChanged(translation)
        case .changed:
            onChanged(translation)
        case .ended, .cancelled, .failed:
            onEnded(translation, recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Simultaneous with the enclosing scroll view's pan — that is what keeps the list
        /// scrolling while a row is being swiped — and with nothing else. Everything else it
        /// shares a touch with is the row's own tap handling, which a `List` cancels when its
        /// swipe takes over and which has to be cancelled here too: otherwise letting go at the
        /// end of a swipe also opens the row.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer
        }
    }
}

/// Cancels itself as soon as the drag reads as a scroll rather than a swipe.
///
/// `.cancelled` and not `.failed`: `.failed` is only a legal transition out of `.possible`, and
/// by the time the direction is knowable the recognizer has already begun.
private final class HorizontalPanRecognizer: UIPanGestureRecognizer {
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard state == .began else { return }
        let velocity = velocity(in: view)
        if abs(velocity.y) > abs(velocity.x) { state = .cancelled }
    }
}
