import SwiftUI
import Testing

// The runtime's foreground flag follows the SCENE PHASE, in both directions. Pinned because the
// 2026-09-16 regression was a missing direction: a launch behind the lock screen built the view
// hierarchy (so "a window exists" fired) with the scene in `.background`, nothing ever demoted
// the runtime, and the foreground pass ran at 1 s cadence for the life of the process.
struct SceneForegroundRuleTests {
    @Test("an active scene means a person is looking")
    func activePromotes() {
        #expect(SceneForegroundRule.foreground(for: .active) == true)
    }

    @Test("a background scene means nobody is — a window existing is not enough")
    func backgroundDemotes() {
        #expect(SceneForegroundRule.foreground(for: .background) == false)
    }

    @Test("inactive is transient (launch, app switcher, a banner) and says nothing")
    func inactiveIsSilent() {
        #expect(SceneForegroundRule.foreground(for: .inactive) == nil)
    }
}
