import Foundation

// What a failed transcription task actually hit, derived from the message the queue stored in
// `transcription_tasks.lastError`.
//
// The stored string is NOT displayable: it is developer prose written for a log, and the cloud
// paths splice up to 240 bytes of the provider's own response body into it — which for a 401 is
// the request URL and, on some providers, the key itself. Anti-goal B20 bans raw exception copy
// on screen, so every surface that reports a failure classifies it here first and renders the
// app's own sentence for the kind (`TranscriptionFailureKind+Copy.swift` in the app layer).
//
// The split mirrors `ApiKeyCheckOutcome`: the kit returns a taxonomy and no prose, the app owns
// the words, and one vocabulary serves every surface so they cannot drift apart.

/// The reason a transcription task is in `Failed`, in the shape a person can act on.
public enum TranscriptionFailureKind: String, Equatable, Sendable, CaseIterable {
    /// 401 — the provider did not accept the key.
    case keyRejected
    /// 403 — a real key without permission for this API.
    case keyNotPermitted
    /// 429 — throttled, or the account is out of credit.
    case rateLimited
    /// 5xx, or the provider reported an error of its own. Nothing here is the user's to fix.
    case providerTrouble
    /// The provider took the audio but never returned a usable handle for it.
    case providerRefusedAudio
    /// The provider accepted the job and never finished it.
    case timedOut
    /// The recording is larger than the provider's upload limit.
    case recordingTooLong
    /// The request never reached the provider.
    case noConnection
    /// The selected on-device model could not be loaded (not installed, or no room to load it).
    case modelMissing
    /// The on-device engine ran and failed.
    case localEngineFailed
    /// The stored audio could not be read or staged for the provider.
    case audioUnreadable
    /// No provider was usable at all — consent off, no key, or nothing selected.
    case notConfigured
    /// Something we have no better word for. The honest answer, not a guess.
    case unknown

    /// Classifies a stored `lastError`.
    ///
    /// Matching is on OUR OWN literals (the `TranscriptionError` messages thrown across the
    /// kit), which is why this is stable; the system-error phrasings below are a best-effort
    /// extra for rows written before this taxonomy existed, where `URLError.localizedDescription`
    /// is all the queue kept. Anything unrecognised is `.unknown` rather than a guess.
    public static func classify(_ message: String?) -> TranscriptionFailureKind {
        guard let message, !message.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .unknown
        }
        let text = message.lowercased()

        // Config first: "provider unavailable: soniox" means nothing was usable, whatever else
        // the line says.
        if text.contains("provider unavailable") { return .notConfigured }

        // An HTTP status the provider gave us is the most specific thing available, and it maps
        // onto the same advice the key check already gives for the same code.
        if let status = httpStatus(in: message) {
            switch status {
            case 401: return .keyRejected
            case 403: return .keyNotPermitted
            case 429: return .rateLimited
            case 408, 504: return .timedOut
            case 413: return .recordingTooLong
            default: return .providerTrouble
            }
        }

        if text.contains("timed out") || text.contains("timeout") { return .timedOut }
        if text.contains("exceeds") && text.contains("limit") { return .recordingTooLong }
        if text.contains("returned no file id") || text.contains("returned no id")
            || text.contains("no control-plane step") || text.contains("does not support upload")
        {
            return .providerRefusedAudio
        }
        if text.contains("failed to initialize local model") { return .modelMissing }
        if text.contains("local transcription failed") || text.contains("on-device transcription")
            || text.contains("on-device live transcription")
        {
            return .localEngineFailed
        }
        if text.contains("failed to stage local audio") || text.contains("failed to read audio")
            || text.contains("missing metadata for segment")
            || text.contains("unsupported sample rate")
        {
            return .audioUnreadable
        }
        if text.contains("transcription error") || text.contains("realtime error") {
            return .providerTrouble
        }
        // The stable marker `storedFailureMessage` writes for a URLError, plus the system's own
        // prose for rows the queue stored before that marker existed (English-only by nature —
        // which is exactly why new rows carry the code instead).
        if text.contains(Self.networkMarker) {
            return text.contains("\(URLError.Code.timedOut.rawValue)") ? .timedOut : .noConnection
        }
        if text.contains("offline") || text.contains("connection was lost")
            || text.contains("could not connect") || text.contains("network connection")
            || text.contains("no internet")
        {
            return .noConnection
        }
        return .unknown
    }

    /// Prefix `storedFailureMessage` uses for a `URLError`; also what `classify` looks for.
    static let networkMarker = "network request failed"

    /// The `(401)` in "Soniox poll failed (401): …" — a parenthesised 3-digit HTTP status.
    /// Deliberately narrow: byte counts in "exceeds 104857600 byte limit" are not statuses, and
    /// a body spliced into the message can hold any number at all.
    static func httpStatus(in message: String) -> Int? {
        var digits = ""
        var inParens = false
        for character in message {
            if character == "(" {
                inParens = true
                digits = ""
            } else if character == ")" {
                if inParens, digits.count == 3, let value = Int(digits),
                    (100...599).contains(value)
                {
                    return value
                }
                inParens = false
                digits = ""
            } else if inParens {
                if character.isNumber {
                    digits.append(character)
                } else {
                    // Anything else in the parens means this is not a bare status.
                    inParens = false
                    digits = ""
                }
            }
        }
        return nil
    }
}

extension TranscriptionTask {
    /// What this task's stored error means, for any surface that reports it.
    public var failureKind: TranscriptionFailureKind {
        TranscriptionFailureKind.classify(lastError)
    }
}

/// What goes into `transcription_tasks.lastError`.
///
/// `URLError` is special-cased because its only message is `localizedDescription`, which is
/// translated into the phone's language — so a queue row written on a French phone could never
/// be classified by matching English text. Recording the numeric code alongside makes the row
/// self-describing forever; the localized wording is kept after it because that is the sentence
/// a support report reader recognises.
func storedFailureMessage(_ error: Error) -> String {
    if let urlError = error as? URLError {
        return "\(TranscriptionFailureKind.networkMarker) (\(urlError.code.rawValue)): "
            + urlError.localizedDescription
    }
    return transcriptionErrorMessage(error) ?? String(describing: type(of: error))
}
