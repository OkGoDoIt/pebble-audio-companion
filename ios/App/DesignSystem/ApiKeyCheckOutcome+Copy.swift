import Transcription

// The one place a key-check outcome becomes words (U9).
//
// The kit deliberately returns a taxonomy and no prose — both providers quote the key back in
// their 401 body, so provider text can never reach the screen. Turning those cases into
// sentences is the app's job, and it happens here rather than in each screen: onboarding and
// Settings → Transcription & AI both show key checks, and when they each owned a copy of this
// switch they had already drifted apart on `.missing`.

extension ApiKeyCheckOutcome {
    /// What went wrong, or nil when there is nothing to report.
    ///
    /// `.valid` and `.missing` both return nil on purpose: a working key is shown as a check
    /// mark rather than a sentence, and an empty field is not a failure — it is a field the user
    /// has not filled in yet. (Settings previously mapped `.missing` onto "The key couldn't be
    /// checked right now.", which told people something had gone wrong when they had simply left
    /// the box blank.)
    var failureReason: String? {
        switch self {
        case .valid, .missing: return nil
        case .rejected: return Copy.KeyCheck.rejected
        case .notPermitted: return Copy.KeyCheck.notPermitted
        case .outOfCredit: return Copy.KeyCheck.outOfCredit
        case .rateLimited: return Copy.KeyCheck.rateLimited
        case .providerUnavailable: return Copy.KeyCheck.providerUnavailable
        case .unreachable: return Copy.KeyCheck.unreachable
        case .unexpected: return Copy.KeyCheck.unexpected
        }
    }

    /// The verdict as a full line, including the success case. Surfaces that announce a result
    /// in words (the Settings key screen) use this; surfaces that show a check mark instead
    /// (onboarding) use `failureReason`.
    var verdict: String {
        if case .valid = self { return Copy.KeyCheck.valid }
        return failureReason ?? ""
    }

    /// After a save: the key is in the Keychain either way — the check is guidance, not a gate —
    /// so the verdict is prefixed with what already happened.
    var savedMessage: String { Copy.KeyCheck.saved(verdict) }

    /// The same verdict in one word, for a key row ("sk-…4f2a · no credit").
    var rowWord: String? {
        switch self {
        case .valid: return Copy.KeyCheck.Row.valid
        case .missing: return nil
        case .rejected: return Copy.KeyCheck.Row.rejected
        case .notPermitted: return Copy.KeyCheck.Row.notPermitted
        case .outOfCredit: return Copy.KeyCheck.Row.outOfCredit
        case .rateLimited: return Copy.KeyCheck.Row.rateLimited
        case .providerUnavailable: return Copy.KeyCheck.Row.providerUnavailable
        case .unreachable: return Copy.KeyCheck.Row.unreachable
        case .unexpected: return Copy.KeyCheck.Row.unexpected
        }
    }
}
