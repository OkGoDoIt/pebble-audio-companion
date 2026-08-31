import StatusUI

// The app-side seam where a watch refusal becomes words — the third of the trio with
// `ApiKeyCheckOutcome+Copy.swift` and `TranscriptionFailureKind+Copy.swift`, and deliberately
// built the same way: the kit classifies into a taxonomy and never speaks, and one vocabulary
// serves every surface so the status card, Diagnostics and the support report cannot drift.
//
// One difference from its two siblings, forced by where the words are needed: the sentences live
// in `StatusUI.StatusCopy` rather than in `Copy.swift`. The status card is rendered from the kit
// (which cannot import this target), and `Copy.swift` compiles into the widget extension (which
// links nothing from the kit) — so a copy of the strings here would be a second vocabulary, not
// a shared one. This file names them instead.

extension WatchLinkFault {
    /// One sentence: what the watch is doing, and what — if anything — the reader should do.
    var reason: String { detail }

    /// The same verdict in two or three words, for a Diagnostics row's trailing value.
    var rowVerdict: String { shortReason }
}

/// The refusal vocabulary, by name, for any app surface that needs a specific line rather than
/// a classified fault. Re-exports the kit's constants — never retypes them.
enum WatchLinkCopy {
    static let rowTitle = Copy.Settings.Diagnostics.watchLink

    static let boundToAnotherPhone = StatusCopy.boundElsewhere
    static let boundToAnotherPhoneLine = StatusCopy.boundElsewhereLine
    static let authorizationRemoved = StatusCopy.linkAuthorizationRemoved
    static let authorizationRemovedLine = StatusCopy.linkAuthorizationRemovedLine
    static let releasedByThisPhone = StatusCopy.linkReleasedByThisPhone
    static let captureOffOnWatch = StatusCopy.watchAudioOff
    static let appTooOld = StatusCopy.linkAppTooOld
    static let watchTooOld = StatusCopy.linkWatchTooOld
    static let versionMismatch = StatusCopy.linkVersionMismatch
    static let watchTrouble = StatusCopy.watchNeedsAttention
    static let appFault = StatusCopy.linkAppSentSomethingUnexpected
    static let unknownRefusal = StatusCopy.linkUnknownRefusal
}
