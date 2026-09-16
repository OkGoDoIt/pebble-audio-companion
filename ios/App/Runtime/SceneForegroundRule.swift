import SwiftUI

/// What a scene phase says about whether a person is looking at this app — the one input the
/// runtime's foreground/background policy is allowed to trust.
///
/// "A window exists" is not it. A launch on a locked phone (Xcode, `devicectl`, a Lock Screen
/// tap that is never followed by an unlock) builds the whole view hierarchy — so the root view's
/// `.task` fires — with the scene in `.background`. The app never becomes active, so UIKit never
/// posts `didEnterBackground` either, and a runtime promoted on "a window came on screen" has
/// nothing left that can ever demote it. On 2026-09-16 that ran the foreground pass — 1 s cadence,
/// live preview, AI stages every time — for the life of the process, at 7–13 CPU-s/min, while
/// `UIApplication.applicationState` said `.background` the whole time.
///
/// `.inactive` deliberately says nothing: every foreground launch passes through it on the way
/// to `.active`, and the app switcher, a notification banner and Control Center all put an app
/// the person is still looking at into `.inactive` for a moment.
enum SceneForegroundRule {
    /// `true`: a person is looking — promote. `false`: nobody is — demote. `nil`: no opinion.
    static func foreground(for phase: ScenePhase) -> Bool? {
        switch phase {
        case .active: return true
        case .background: return false
        case .inactive: return nil
        @unknown default: return nil
        }
    }
}
