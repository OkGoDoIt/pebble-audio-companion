import SwiftUI

/// Whether to offer the ride back to the end of a long conversation — the small ⌄ button in the
/// bottom corner.
///
/// The rule is the whole of it: **the conversation runs on below the fold, and you are not at
/// the end of it.** Nothing about how you got there. An earlier version armed and disarmed the
/// offer by tracking whether the reader had scrolled up themselves, on the theory that someone
/// reading halfway up does not want to be offered a way out of it — but the button is a small
/// quiet circle in a corner that costs nothing to ignore, and a control that reasons about your
/// intent is a control that is sometimes wrong about it. Being simply, always there is better
/// than being clever four times out of five.
///
/// `isPlaying` is the one input that is not geometry, and it is not about intent either: it is
/// about which control owns the corner. While audio plays that corner belongs to playback —
/// either the transcript is following the playhead, in which case the end is not where the
/// reader is going, or they have scrolled away from it and "Back to playing" is the offer. Two
/// floating buttons in one corner pointing at two different places is a worse screen than
/// either alone.
struct JumpToEndPolicy: Equatable {
    /// The conversation is taller than the screen. Nothing to offer when the whole thing fits —
    /// and measured from the content and the viewport rather than from the scroll offset,
    /// because it is also what keeps the button off a screen that has not been measured yet.
    private(set) var contentBelowFold = false

    /// The end of the conversation is on screen (near enough — the tail can be growing while a
    /// gesture finishes, so "within a flick" counts).
    private(set) var atEnd = false

    /// Audio is playing, so the bottom corner belongs to playback.
    private(set) var isPlaying = false

    var shows: Bool {
        contentBelowFold && !atEnd && !isPlaying
    }

    // MARK: - Events

    /// The conversation is (or is no longer) taller than the screen.
    mutating func contentBelowFoldChanged(_ belowFold: Bool) {
        contentBelowFold = belowFold
    }

    /// The end of the conversation came into view, or left it.
    mutating func atEndChanged(_ nowAtEnd: Bool) {
        atEnd = nowAtEnd
    }

    mutating func playbackChanged(_ playing: Bool) {
        isPlaying = playing
    }

    /// The offer was accepted. Taken as arriving straight away so the button does not sit there
    /// through its own scroll animation; the next geometry reading confirms it either way.
    mutating func jumped() {
        atEnd = true
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
