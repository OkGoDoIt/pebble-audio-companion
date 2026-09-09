import Foundation

// The Live Conversation screen's additions to the catalog. Kept as an extension on the one
// approved catalog — in its own file only because `Copy.swift` is a large shared surface and
// this is a self-contained vocabulary (the `Copy+Speaker.swift` pattern).
//
// These exist because a live conversation stopped being "a transcript with two buttons under
// it" and became the same conversation the Library shows, still being written: it now carries
// the AI summary, the [Ask][Notes][Stop] actions and a timeline.
//
// Vocabulary rules that apply here:
// - "recording" is what the watch is doing; "conversation" is what is being written.
// - Loss stays explicit and calm (Q6): "missing" is genuine loss, "quiet" is known silence.
// - Say nothing the screen already says. The captions that used to sit under the summary
//   ("Summary so far — it is rewritten as this keeps going") and under the actions ("Ask and
//   Notes read what is already transcribed; follow-ups arrive once this ends") are gone: a
//   screen headed "Recording now" with a Live badge on it is already telling the reader that
//   everything on it is still being written.

extension Copy.Live {

    // ── Timeline card (the growing equivalent of the finished player) ────────

    /// The right-hand axis label. Lowercase because it is a tick opposite a clock time, not a
    /// sentence.
    static let timelineNow = "now"

    // The transport sublines ("ends here · resume anytime" / "ends here · recording off") are
    // gone with the two-button transport they explained: the bar now offers one Stop, so there
    // is no longer a Pause beside it to be told apart from. See `LiveConversationScreen`.

    // ── When the recording ends somewhere other than this screen ────────────
    //
    // The watch goes out of range for long enough, or capture is turned off from Today,
    // Settings, Control Center or a Shortcut. The screen used to carry on announcing
    // "Recording now" with a Live badge missing and a Pause button under it — the one claim on
    // a background-microphone app that has to be true whenever it is on screen.

    static let endedTitle = "Recording ended"
    /// What the button underneath opens is the button's job to say, not this line's.
    static let endedLine = "It is saved."
    static let openConversation = "Open Conversation"

    /// Reached with nothing being recorded at all — a `companion://live` link, or a tap that
    /// landed just as the last conversation closed. The status line below says which of the
    /// reasons applies.
    static let idleTitle = "Nothing is recording"
}

extension Copy.A11y {
    /// The live timeline is the conversation's own span, not the day's — the strip is shared
    /// with Today's day coverage, and the spoken label has to say which one this is.
    static let liveTimelineLabel = "Recording timeline"
    static let liveTimelineHint = "Double tap for what happened at that moment"
    // `transport(_:_:)` went with the transport sublines: a Stop pill with no subline under it
    // is already one spoken phrase.
}
