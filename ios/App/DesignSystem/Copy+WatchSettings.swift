import Foundation

// Settings · Watch strings added after real-device use of artboard 2.10.
//
// `Copy.swift` is the approved catalog and stays as it is; this is the same `Copy.Settings.Watch`
// namespace extended in place, so there is still exactly one place to look for these words.

extension Copy.Settings.Watch {
    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Reconnect (was "Find Watch")
    // ─────────────────────────────────────────────────────────────────────────

    /// The row used to be called "Find Watch", which reads as Find My — tap it and your watch
    /// rings. It never could: the action is `CompanionRuntime.reconnect()` →
    /// `AudioGattLink.resync()`, which tears down and rebuilds the phone's GATT connection, and
    /// the audio-companion service has no buzz/alert opcode at all (there is nothing in
    /// `PROTOCOL.md` §4.1 to send). So the row is named for what it does.
    ///
    /// The status card on Today used to keep the old "Find Watch" label for the same action, on
    /// the grounds that its detail line had already explained the situation. One action with two
    /// names is still two names, so the card now says "Reconnect" too (`Copy.Status.findWatch`).
    /// This row keeps its own subline because, unlike the card, it has no detail line to lean on.
    static let reconnect = "Reconnect"
    static let reconnectSub =
        "Rebuilds the Bluetooth link when nothing is arriving. It does not ring the watch."
    /// Result line after a successful rebuild (B10: an action never ends in silence).
    static let reconnected = "Connected"

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Info rows
    // ─────────────────────────────────────────────────────────────────────────
    //
    // `reportsFooter` ("What the watch itself reports, which can differ from the switch on this
    // phone.") sat under the info card. The row inside it is already labelled "Watch reports",
    // which is the same sentence in two words.

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Forget confirmation
    // ─────────────────────────────────────────────────────────────────────────

    /// The confirmation used to be an untitled, unexplained sheet whose one button repeated the
    /// row's own label. Forgetting the watch is the largest action on this screen — it stops
    /// recording, drops the authorization and reopens the setup flow — and none of that was
    /// stated anywhere. It is also the reassurance that matters most: nothing recorded is lost.
    static let forgetTitle = "Forget this watch?"
    static let forgetMessage =
        "Recording stops and this phone is no longer authorized to receive audio. Your "
        + "recordings and transcripts are kept. You will be asked to set the watch up again."
    /// The button. No ellipsis: this one IS the destructive step, not the way to reach it.
    static let forgetConfirm = "Forget This Watch"
}
