import Testing

// The rule behind the ⌄ button at the bottom of a long conversation, and it is now short enough
// to state in one line: the conversation runs on below the fold, and you are not at the end of
// it. These tests exist to keep it that short. An earlier version also tracked WHY the reader
// was away from the end — armed on open, re-armed when the conversation grew under them,
// disarmed by their own scroll — and the whole of that is gone: a small quiet circle in a corner
// costs nothing to ignore, and a control that reasons about your intent is a control that is
// sometimes wrong about it.
//
// What is left worth pinning: the two cases where the button must NOT appear (a conversation
// that fits, and a corner that belongs to playback), and the fact that an unmeasured screen
// stays quiet — the one place a default could put a button on a screen that does not need one.

@Suite("jump to the end")
struct JumpToEndPolicyTests {

    /// A conversation longer than the screen, freshly opened, nothing playing.
    private func opened(belowFold: Bool = true) -> JumpToEndPolicy {
        var policy = JumpToEndPolicy()
        policy.contentBelowFoldChanged(belowFold)
        return policy
    }

    // MARK: - The rule

    @Test("nothing is offered until the screen has been measured")
    func silentUntilMeasured() {
        #expect(JumpToEndPolicy().shows == false)
    }

    @Test("a conversation that runs on below the fold offers the ride")
    func offeredWhenThereIsMoreBelow() {
        #expect(opened().shows)
    }

    @Test("sitting at the end offers nothing")
    func silentAtTheEnd() {
        var policy = opened()
        policy.atEndChanged(true)
        #expect(policy.shows == false)
    }

    @Test("a conversation that fits on one screen offers nothing")
    func silentWhenItFits() {
        #expect(opened(belowFold: false).shows == false)
    }

    @Test("a re-transcribe that shortens the conversation withdraws the offer")
    func withdrawnWhenItStopsOverflowing() {
        var policy = opened()
        #expect(policy.shows)
        policy.contentBelowFoldChanged(false)
        #expect(policy.shows == false)
    }

    // MARK: - How you got here does not matter

    @Test("scrolling up keeps the offer — the reader can ignore it")
    func offeredAfterScrollingUp() {
        var policy = opened()
        policy.atEndChanged(true)      // started at the end
        policy.atEndChanged(false)     // ... and scrolled up off it
        #expect(policy.shows)
    }

    @Test("leaving the end and coming back to it turns the offer off and on again")
    func followsTheViewBothWays() {
        var policy = opened()
        #expect(policy.shows)
        policy.atEndChanged(true)
        #expect(policy.shows == false)
        policy.atEndChanged(false)
        #expect(policy.shows)
    }

    // MARK: - One corner, one offer

    @Test("playback owns the corner, so the ⌄ button stands down")
    func silentWhilePlaying() {
        var policy = opened()
        policy.playbackChanged(true)
        #expect(policy.shows == false)
    }

    @Test("stopping playback hands the corner back")
    func returnsWhenPlaybackStops() {
        var policy = opened()
        policy.playbackChanged(true)
        policy.playbackChanged(false)
        #expect(policy.shows)
    }

    // MARK: - Taking the ride

    @Test("taking the ride withdraws the offer without waiting for the scroll to land")
    func takingItWithdrawsIt() {
        var policy = opened()
        policy.jumped()
        #expect(policy.shows == false)
    }

    @Test("more of the conversation landing below offers the ride again")
    func returnsWhenItGrowsAgain() {
        var policy = opened()
        policy.jumped()
        policy.atEndChanged(false)
        #expect(policy.shows)
    }
}
