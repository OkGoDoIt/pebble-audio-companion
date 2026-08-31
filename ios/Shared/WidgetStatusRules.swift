import Foundation

// The widgets' status derivation, lifted out of the views so it can be tested.
//
// Everything here is PURE. Its two inputs are the only two things a widget extension may read
// (plan 6.8): the snapshot the app wrote into the App Group, and the capture intent the user
// last asked for. No I/O, no SwiftUI, no `Copy` — the words and colors are applied by the view,
// which is why `Word` is a decision rather than a string.
//
// This file lives in `Shared/` but is EXCLUDED from the app target (see `ios/project.yml`),
// exactly like `CoverageSnapshot.swift`: it speaks the widget's dependency-free snapshot mirror,
// and the app compiles the kit's writer type of the same name.

/// What a widget should say and offer, given what it can see.
struct WidgetStatusRules: Equatable {
    /// The status word to render, as a decision. `observed` and `lastSeen` carry the snapshot's
    /// own headline — the one approved status vocabulary (U9), never re-derived here.
    enum Word: Equatable {
        /// The user asked for a change the app has not confirmed yet.
        case resuming
        case pausing
        /// A fresh snapshot's headline, rendered verbatim.
        case observed(String)
        /// A snapshot too old to assert. Says what it LAST said, in the past tense, because
        /// "Recording" printed from a half-hour-old file is a claim about a microphone that
        /// nothing has checked.
        case lastSeen(String)
        /// Nothing has been written yet, so nothing is claimed beyond the user's own preference.
        /// `off` and `paused` stay distinct all the way down: "not recording" and "paused" are
        /// different promises about whether audio resumes on its own.
        case paused
        case notRecording
    }

    var word: Word
    /// True only when the app last observed real capture AND the snapshot is fresh enough to
    /// still stand behind that.
    var isRecording: Bool
    /// Start of the running stretch, for the self-ticking elapsed timer. Nil whenever we would
    /// otherwise be counting up from a number the app has not confirmed recently.
    var startedAtMs: Int64?
    /// The control to offer: pausing what is running, or resuming what is not.
    var offersPause: Bool
    /// Capture is OFF rather than paused — the button says "Start Recording", not "Resume", and
    /// the Control Center toggle's off position is called "Not recording", not "Paused".
    var isOff: Bool
    var isStale: Bool
    var hasData: Bool
    /// The write time to quote in an "as of …" hedge, or nil when the file is fresh or absent.
    var asOfMs: Int64?

    init(
        snapshot: CoverageSnapshot?,
        pending: SharedCaptureIntent?,
        applied: SharedCaptureIntent,
        nowMs: Int64
    ) {
        hasData = snapshot != nil
        let stale = snapshot?.isStale(atMs: nowMs) ?? false
        isStale = stale
        asOfMs = stale ? snapshot?.generatedAtMs : nil

        let claimsRecording = snapshot?.state == .recording && !stale
        isRecording = claimsRecording
        startedAtMs = claimsRecording ? snapshot?.currentStartedAtMs : nil

        // Which control to offer, in order of what is most certainly true:
        //   1. an unconfirmed request — the user just pressed this button, honour their aim;
        //   2. a fresh snapshot that says capture IS running — then the action is Pause, no
        //      matter what the preference says. The two can legitimately disagree (a watch-side
        //      stop, a preference written but not yet applied), and a widget that says
        //      "Recording" above a "Resume" button is incoherent whichever half is right;
        //   3. otherwise the applied preference, which is always current even when the snapshot
        //      is stale, because an intent writes it synchronously.
        if let pending {
            offersPause = pending == .active
        } else if claimsRecording {
            offersPause = true
        } else {
            offersPause = applied == .active
        }

        let effective = pending ?? applied
        isOff = !offersPause && effective == .off

        // What the user asked for wins the WORD while it is unconfirmed — the switch moved, so
        // the widget must not keep showing the old state as if the tap never happened — but it
        // is spelled with an ellipsis, because the watch has not answered yet.
        let headline = snapshot?.headline.nonBlank
        switch (pending, snapshot?.state) {
        case (.active, let state) where state != .recording:
            word = .resuming
        case (.paused, .recording):
            word = .pausing
        default:
            if let headline {
                word = stale ? .lastSeen(headline) : .observed(headline)
            } else {
                word = effective == .paused ? .paused : .notRecording
            }
        }
    }
}

extension String {
    /// Blank strings are absent strings: a title of spaces must fall back to the honest
    /// placeholder rather than render as an empty row that looks like a layout bug.
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
