import SwiftUI

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
/// **Where the live screen differs, and why it is a flag and not a second type.** On a finished
/// conversation nothing arrives, so a reader who scrolled up is reading and is left alone —
/// which is the rule as it was asked for. A live conversation is the same rule against a
/// different world: it goes on being said while they read, so "your hand wins" has to end
/// somewhere, and the honest place is the moment words they cannot see actually arrive. That is
/// `rearmsWhenContentGrows`, and it is keyed on a new turn rather than on the tail being revised
/// — the in-progress line changes several times a second, and re-arming on that would put the
/// button back under the reader's thumb before they had finished the gesture that dismissed it.
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

    /// Whether a new turn landing below the reader overrides their scroll. False on a finished
    /// conversation (nothing is arriving; they scrolled up to read), true on a live one.
    let rearmsWhenContentGrows: Bool

    init(rearmsWhenContentGrows: Bool = false) {
        self.rearmsWhenContentGrows = rearmsWhenContentGrows
    }

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

    /// A new turn was appended. Only the live screen sends this, and only a genuinely new turn:
    /// a reader who has scrolled up while the conversation carried on without them has not
    /// chosen to be behind, they have simply been left there, so the way back is offered again.
    /// Sent from a screen that does not re-arm, or while the reader is still at the end, it
    /// changes nothing.
    mutating func contentGrew() {
        guard rearmsWhenContentGrows else { return }
        readerScrolled = false
    }

    /// The offer was accepted. Taken as arriving straight away so the button does not sit there
    /// through its own scroll animation; the next geometry reading confirms it either way.
    mutating func jumped() {
        atEnd = true
        readerScrolled = false
    }
}


// MARK: - The control

/// The ⌄ button itself, shared by the finished Conversation and the live one so the two cannot
/// drift into being two different-looking controls doing the same thing.
///
/// Deliberately the quieter of the controls that can hold this corner. "Back to playing" is a
/// filled tint capsule because it reports something — the audio has run on out of sight — and it
/// should be noticed. This one reports nothing; it is a shortcut for a gesture the reader could
/// already perform, so it is a plain surface circle that sits in the corner and waits, in the
/// same card material and border the rest of the screen is made of. Round rather than a capsule
/// for the same reason it carries no label: it is one direction, not a sentence.
struct JumpToEndButton: View {
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
        .accessibilityLabel(Copy.Reading.jumpToEnd)
        .accessibilityHint(Copy.Reading.jumpToEndHint)
        // Trailing, in the corner the thumb reaches, while the pill that can share this slot on
        // the finished screen stays centred: they are different offers and should not be
        // mistaken for one another moving.
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, Tokens.screenMargin)
        .padding(.bottom, 10)
        .transition(Motion.transition(.scale(scale: 0.8).combined(with: .opacity)))
    }
}
