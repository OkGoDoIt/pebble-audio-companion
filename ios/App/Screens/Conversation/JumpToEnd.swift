import Foundation

/// Whether to offer the ride back to the end of a long conversation — the small ⌄ button in the
/// bottom corner, and the three-part rule it was asked for:
///
///  * **on open**, if the conversation runs on below the fold → offer it;
///  * **while the reader is at the end** and the conversation grows underneath them (a
///    transcript landing, a still-recording conversation appending) → offer it;
///  * **if the reader scrolled up themselves** → do not.
///
/// That last clause is the whole reason this is a type and not a comparison. "Not at the bottom"
/// is the same fact in both of the last two cases, and it means opposite things: a reader who
/// scrolled up is reading something and does not want the screen offering to take it away, while
/// a reader whose conversation grew under them has been left behind without moving. So the offer
/// is *armed* rather than derived — disarmed the moment the reader's finger moves the view,
/// re-armed whenever they are back at the end. Coming back to the end is the only thing that
/// re-arms it: a reader who scrolls up and stays there is not asked again, however much arrives
/// below them.
///
/// `isPlaying` is the fourth input and it exists to keep one corner to one offer. While audio is
/// playing that corner belongs to playback: either the transcript is following the playhead (in
/// which case the end is not where the reader is going) or they have scrolled away from it and
/// "Back to playing" is the offer. Two floating buttons in the same corner, pointing at two
/// different places, is a worse screen than either of them alone.
struct JumpToEndPolicy: Equatable {
    /// The conversation is taller than the screen. Nothing to offer when the whole thing fits:
    /// measured from the content and the viewport rather than from the scroll offset, because
    /// this is the one input that has to be right *before* anybody scrolls.
    private(set) var contentBelowFold = false

    /// The end of the conversation is on screen (near enough — the tail can be growing while a
    /// gesture finishes, so "within a flick" counts).
    private(set) var atEnd = false

    /// The reader has moved the view themselves and has not returned to the end since.
    private(set) var readerScrolled = false

    /// Audio is playing, so the bottom corner belongs to playback.
    private(set) var isPlaying = false

    /// Nothing is offered until the screen has actually been measured. Every default here is
    /// the quiet one — an unmeasured conversation shows no button — which is only safe because
    /// the measurement is guaranteed to arrive: the screen feeds `contentBelowFoldChanged` from
    /// an `onChange(initial: true)`, which always fires once, rather than from
    /// `onScrollGeometryChange`, whose action runs only when its value *changes* and so would
    /// say nothing at all about a conversation that was already long when it opened.
    var shows: Bool {
        contentBelowFold && !atEnd && !readerScrolled && !isPlaying
    }

    // MARK: - Events

    /// The conversation is (or is no longer) taller than the screen.
    mutating func contentBelowFoldChanged(_ belowFold: Bool) {
        contentBelowFold = belowFold
    }

    /// The end of the conversation came into view, or left it. Arriving at the end re-arms the
    /// offer — being there is what earns the ride back when the next turn lands.
    mutating func atEndChanged(_ nowAtEnd: Bool) {
        atEnd = nowAtEnd
        if nowAtEnd { readerScrolled = false }
    }

    /// The reader dragged the view. Their hand wins: no offer until they are back at the end.
    mutating func readerTookOver() {
        readerScrolled = true
    }

    mutating func playbackChanged(_ playing: Bool) {
        isPlaying = playing
    }

    /// The offer was accepted. Taken as arriving straight away so the button does not sit there
    /// through its own scroll animation; the next geometry reading confirms it either way.
    mutating func jumped() {
        atEnd = true
        readerScrolled = false
    }
}
