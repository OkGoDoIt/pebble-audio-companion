import Testing

// The rule behind the ⌄ button at the bottom of a long conversation. It is three lines of state
// and it is exactly the kind of thing that rots: every one of these cases is a moment where the
// scroll view is "not at the bottom", and the right answer is different in each of them.
//
// The distinction the whole thing turns on: WHY are we not at the end? Because the conversation
// is longer than the screen and nobody has moved yet (offer the ride), because it grew under a
// reader who was sitting at the end (offer the ride), or because the reader scrolled up to read
// something (leave them alone). A naive `!atBottom` test passes the first two and fails the
// third, which is the one that would make the button feel like it was arguing with you.

@Suite("jump to the end")
struct JumpToEndPolicyTests {

    /// A conversation longer than the screen, freshly opened, nothing playing.
    private func opened(belowFold: Bool = true) -> JumpToEndPolicy {
        var policy = JumpToEndPolicy()
        policy.contentBelowFoldChanged(belowFold)
        return policy
    }

    // MARK: - On open

    @Test("nothing is offered until the screen has been measured")
    func silentUntilMeasured() {
        #expect(JumpToEndPolicy().shows == false)
    }

    @Test("a conversation that runs on below the fold offers the ride on open")
    func offeredOnOpen() {
        #expect(opened().shows)
    }

    @Test("a conversation that fits on the screen never offers it")
    func notOfferedWhenItFits() {
        var policy = opened(belowFold: false)
        #expect(policy.shows == false)
        // ...and not after it is scrolled about either: there is nowhere to go.
        policy.readerTookOver()
        policy.atEndChanged(false)
        #expect(policy.shows == false)
    }

    @Test("arriving at the end withdraws the offer")
    func withdrawnAtTheEnd() {
        var policy = opened()
        policy.atEndChanged(true)
        #expect(policy.shows == false)
    }

    // MARK: - The conversation grows

    @Test("content arriving under a reader who was at the end offers the ride")
    func offeredWhenContentGrowsAtTheEnd() {
        var policy = opened()
        policy.atEndChanged(true)
        // A transcript lands, or a live recording appends: the end moves below the fold without
        // the reader touching anything.
        policy.atEndChanged(false)
        #expect(policy.shows)
    }

    @Test("content arriving under a reader who scrolled up does NOT offer the ride")
    func notOfferedWhenContentGrowsAfterScrollingUp() {
        var policy = opened()
        policy.atEndChanged(true)
        policy.readerTookOver()
        policy.atEndChanged(false)
        #expect(policy.shows == false)
        // Still nothing however much else arrives — the reader is reading.
        policy.atEndChanged(false)
        #expect(policy.shows == false)
    }

    // MARK: - The reader's hand

    @Test("scrolling up withdraws the offer")
    func scrollingUpWithdrawsIt() {
        var policy = opened()
        #expect(policy.shows)
        policy.readerTookOver()
        #expect(policy.shows == false)
    }

    @Test("a drag that starts at the end still counts as the reader leaving")
    func dragFromTheEndCounts() {
        var policy = opened()
        policy.atEndChanged(true)
        // The finger goes down while we are still inside the at-the-end threshold, and only
        // then does the view move away from it. Order matters here: re-arming on `atEnd` must
        // not undo the disarm that has already happened.
        policy.readerTookOver()
        policy.atEndChanged(false)
        #expect(policy.shows == false)
    }

    @Test("scrolling back to the end re-arms it for the next thing that arrives")
    func returningToTheEndRearms() {
        var policy = opened()
        policy.readerTookOver()
        policy.atEndChanged(false)
        #expect(policy.shows == false)

        policy.atEndChanged(true)          // the reader scrolled back down themselves
        #expect(policy.shows == false)     // nothing to offer while they are there
        policy.atEndChanged(false)         // ...and then more of the conversation lands
        #expect(policy.shows)
    }

    // MARK: - One corner, one offer

    @Test("nothing is offered while audio is playing")
    func silentDuringPlayback() {
        var policy = opened()
        #expect(policy.shows)
        policy.playbackChanged(true)
        #expect(policy.shows == false)
        // Including the case "Back to playing" is for: the reader has scrolled off the playhead.
        policy.readerTookOver()
        #expect(policy.shows == false)
        policy.playbackChanged(false)
        // Still nothing, because now the reason is their own hand rather than the audio.
        #expect(policy.shows == false)
    }

    @Test("the offer comes back when playback stops, if the reader never moved")
    func returnsWhenPlaybackStops() {
        var policy = opened()
        policy.playbackChanged(true)
        #expect(policy.shows == false)
        policy.playbackChanged(false)
        #expect(policy.shows)
    }

    // MARK: - Taking the offer

    @Test("taking the ride withdraws the offer and leaves it armed for the next arrival")
    func takingItWithdrawsIt() {
        var policy = opened()
        policy.jumped()
        #expect(policy.shows == false)
        policy.atEndChanged(false)     // more of the conversation lands right after
        #expect(policy.shows)
    }

    // MARK: - The conversation shrinks back onto one screen

    @Test("a re-transcribe that shortens the conversation withdraws the offer")
    func withdrawnWhenItStopsOverflowing() {
        var policy = opened()
        #expect(policy.shows)
        policy.contentBelowFoldChanged(false)
        #expect(policy.shows == false)
    }
}
