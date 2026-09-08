import Foundation

// The capture control's vocabulary (session: "is that doing exactly the same thing as turning
// it on and off on the today screen? … The current phrasing implies it's something different
// that makes it work differently in the background").
//
// The bug was a naming one. Settings called the master switch "Background audio", which reads
// as a MODE — some second way of recording that behaves differently when the app is not on
// screen — when it is simply the on/off switch for the one thing this app does. Today, meanwhile,
// offered a text link called "Pause". Two surfaces, two words, one operation.
//
// So there is exactly one name for the switch and one sentence per state, and both surfaces
// render them from `CaptureStatus`. Rules that apply to everything below:
//
//   • The switch is named for what it DOES ("Record from your Pebble"), not for a state, so it
//     stays true in all three of on / paused / off.
//   • Nothing here ever says "background". Recording continues while the app is away because
//     that is what the product is; naming it as a mode invites the question of what the other
//     mode would be.
//   • The off sentence says plainly that nothing is being captured. On a product that carries a
//     microphone all day, "off" is the state that has to be unambiguous.

extension Copy {
    enum Capture {
        /// The switch, on both surfaces. Names the action, so it reads correctly whether the
        /// current state is recording, paused or off.
        static let title = "Record from your Pebble"

        // ── One sentence per state ──────────────────────────────────────────
        static let onLine = "Capturing audio from your Pebble."
        /// A pause with no timer — what a widget's Pause button, or a "pause until I say so",
        /// leaves behind. Says how it ends, because nothing else will end it.
        static let pausedLine = "Paused. Nothing is being captured until you turn it back on."
        /// A pause the person asked to end by itself.
        static func pausedResumingLine(_ time: String) -> String {
            "Paused · recording resumes at \(time)"
        }
        /// A pause with a reminder instead of an automatic resume — recording does NOT come
        /// back on its own, and the sentence must not imply it does.
        static func pausedReminderLine(_ time: String) -> String {
            "Paused · we'll ask you at \(time) whether to turn it back on"
        }
        static let offLine = "Off. Your Pebble isn't capturing anything."

        // ── The opt-in timed pause ──────────────────────────────────────────
        //
        // Deliberately a secondary affordance: a long-press on the control, and one quiet row in
        // Settings. Flipping the switch off is still exactly what it was — off until you turn it
        // back on, no timer, no notification.
        static let pauseMenu = "Pause for a while…"
        static let pauseResumeSection = "Pause, then resume by itself"
        static let pauseRemindSection = "Pause and remind me"
        static let pause15Minutes = "For 15 minutes"
        static let pauseOneHour = "For 1 hour"
        static let pauseTwoHours = "For 2 hours"
        static let remindInAnHour = "In an hour"

        static let resumeNow = "Resume now"
        /// Drops the timer without resuming — the pause stays, it just stops ending by itself.
        static let cancelTimer = "Keep it paused (cancel the timer)"

        /// Shown once, in place, when the reminder could not be scheduled. The pause still
        /// happened; only the reminder did not, and saying so is the whole point.
        static let reminderUnavailable =
            "Paused — but notifications are off in iOS Settings, so we can't remind you."

        // ── Notification (opt-in only; see `CapturePauseReminder`) ──────────
        static let reminderTitle = "Still paused"
        static let reminderBody = "Recording from your Pebble is still paused. Turn it back on?"

        // ── Accessibility ───────────────────────────────────────────────────
        static let pauseMenuHint = "Pause for a set time instead of turning recording off"
    }
}
