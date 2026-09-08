import Foundation

// The Live Conversation screen's additions to the catalog. Kept as an extension on the one
// approved catalog — in its own file only because `Copy.swift` is a large shared surface and
// this is a self-contained vocabulary (the `Copy+Speaker.swift` pattern).
//
// These exist because a live conversation stopped being "a transcript with two buttons under
// it" and became the same conversation the Library shows, still being written: it now carries
// the AI summary, the [Ask][Notes][Follow-ups] actions and a timeline, and each of those needs
// one honest line about what is different while the words are still arriving.
//
// Vocabulary rules that apply here:
// - "recording" is what the watch is doing; "conversation" is what is being written. The
//   transport strings say which one each button ends, because the whole reported confusion was
//   that Pause and Stop read as two names for the same act.
// - Loss stays explicit and calm (Q6): "missing" is genuine loss, "quiet" is known silence.
// - AI on a live conversation is honest about its horizon. Ask, Notes and follow-ups all read
//   DURABLE transcripts (`LiveWorld.ask`/`produce` load `composition.transcripts`, and
//   `FollowUpWorker` skips a conversation while `isOpen`), so they are always a little behind
//   the words on screen. Saying so once beats an answer that looks like the AI missed the
//   point.

extension Copy.Live {

    // ── Timeline card (the growing equivalent of the finished player) ────────

    /// The right-hand axis label. Lowercase because it is a tick opposite a clock time, not a
    /// sentence.
    static let timelineNow = "now"

    // ── Summary ─────────────────────────────────────────────────────────────

    /// Under the provisional summary. The enrichment worker rewrites a live conversation's
    /// summary as it grows (`EnrichmentWorker` live pass), so the card must not read as final.
    static let summarySoFar = "Summary so far — it is rewritten as this keeps going."

    // ── AI actions ──────────────────────────────────────────────────────────

    /// One calm line under [Ask][Notes][Follow-ups]. Names both limits — the transcription lag
    /// and the fact that follow-ups are only extracted from a finished conversation — instead
    /// of letting either look like a failure.
    static let aiHorizon =
        "Ask and Notes read what is already transcribed; follow-ups arrive once this ends."

    // ── Transport ───────────────────────────────────────────────────────────

    /// Both buttons end the conversation (Q13 — the watch mints a fresh stream id on resume),
    /// so both sublines lead with the same three words and differ only in what happens next.
    /// That difference is the whole answer to "what is pause versus stop here".
    static let pauseSubline = "ends here · resume anytime"
    /// `.off` tears the receiver down (`ReceiverService.stopReceiving()`), so nothing is
    /// captured again until Start.
    static let stopSubline = "ends here · recording off"

    // ── When the recording ends somewhere other than this screen ────────────
    //
    // The watch goes out of range for long enough, or capture is turned off from Today,
    // Settings, Control Center or a Shortcut. The screen used to carry on announcing
    // "Recording now" with a Live badge missing and a Pause button under it — the one claim on
    // a background-microphone app that has to be true whenever it is on screen.

    static let endedTitle = "Recording ended"
    static let endedLine = "It is saved. Open it for the player and the final transcript."
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
    /// VoiceOver reads a transport button as one phrase. The visual subline's middle dot is a
    /// typographic separator, not a word, so it becomes a comma on the way to the speech engine.
    static func transport(_ title: String, _ consequence: String) -> String {
        "\(title). \(consequence.replacingOccurrences(of: " · ", with: ", "))"
    }
}
