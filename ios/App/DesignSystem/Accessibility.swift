import SwiftUI
import UIKit

// MARK: - Hit targets (U10: ≥44 pt)

extension View {
    /// Grows the *hit* area to the 44 pt HIG minimum without changing what is drawn.
    /// Apply to the `label:` of a button whose glyph is smaller than 44 pt.
    func hitTarget(_ side: CGFloat = 44) -> some View {
        frame(minWidth: side, minHeight: side)
            .contentShape(Rectangle())
    }
}

// MARK: - Reduce Motion

/// `.animation(_:value:)` that becomes a no-op when Reduce Motion is on.
private struct MotionAwareAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    func motionAware<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionAwareAnimation(animation: animation, value: value))
    }
}

enum Motion {
    /// For imperative `withAnimation` call sites — `nil` disables the animation.
    static func animation(_ animation: Animation) -> Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : animation
    }

    /// Slides/moves degrade to a plain cross-fade under Reduce Motion.
    static func transition(_ transition: AnyTransition) -> AnyTransition {
        UIAccessibility.isReduceMotionEnabled ? .opacity : transition
    }
}

// MARK: - Haptics

/// Restrained haptics: capture transport, destructive confirmation, check-off, Ask send.
/// Never on navigation or scrolling — this app is meant to feel calm.
enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if !targetEnvironment(macCatalyst)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }

    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    /// Capture started / resumed.
    static func captureStarted() { impact(.medium) }
    /// Capture paused or stopped — the heavier of the pair, because it ends a recording.
    static func captureEnded() { impact(.heavy) }
    /// A follow-up was ticked off.
    static func checkedOff() { impact(.light) }
    /// A question was sent to Ask.
    static func sent() { impact(.light) }
    /// A destructive action was confirmed.
    static func destructiveConfirmed() { notify(.warning) }
}
