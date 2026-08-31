import Transcription

// The one place a transcription failure becomes words (U9) — the twin of
// `ApiKeyCheckOutcome+Copy.swift`, and deliberately built the same way.
//
// The kit stores `transcription_tasks.lastError` for a log: developer prose with up to 240 bytes
// of the provider's own response body spliced into it. That body is the request URL on a 4xx and
// can contain the key itself, which is why it never reaches a screen (B20). `TranscriptionFailureKind`
// classifies it in the kit, and the sentence lives here so Diagnostics, the conversation's state
// card and the Support Report all say the same thing about the same failure.

extension TranscriptionFailureKind {
    /// One sentence: what happened, and what — if anything — the reader should do about it.
    var reason: String {
        switch self {
        case .keyRejected: return Copy.TranscriptionFailure.keyRejected
        case .keyNotPermitted: return Copy.TranscriptionFailure.keyNotPermitted
        case .rateLimited: return Copy.TranscriptionFailure.rateLimited
        case .providerTrouble: return Copy.TranscriptionFailure.providerTrouble
        case .providerRefusedAudio: return Copy.TranscriptionFailure.providerRefusedAudio
        case .timedOut: return Copy.TranscriptionFailure.timedOut
        case .recordingTooLong: return Copy.TranscriptionFailure.recordingTooLong
        case .noConnection: return Copy.TranscriptionFailure.noConnection
        case .modelMissing: return Copy.TranscriptionFailure.modelMissing
        case .localEngineFailed: return Copy.TranscriptionFailure.localEngineFailed
        case .audioUnreadable: return Copy.TranscriptionFailure.audioUnreadable
        case .notConfigured: return Copy.TranscriptionFailure.notConfigured
        case .unknown: return Copy.TranscriptionFailure.unknown
        }
    }

    /// The same verdict in two or three words, for a row that has a sentence beneath it already.
    var shortReason: String {
        switch self {
        case .keyRejected: return Copy.TranscriptionFailure.Row.keyRejected
        case .keyNotPermitted: return Copy.TranscriptionFailure.Row.keyNotPermitted
        case .rateLimited: return Copy.TranscriptionFailure.Row.rateLimited
        case .providerTrouble: return Copy.TranscriptionFailure.Row.providerTrouble
        case .providerRefusedAudio: return Copy.TranscriptionFailure.Row.providerRefusedAudio
        case .timedOut: return Copy.TranscriptionFailure.Row.timedOut
        case .recordingTooLong: return Copy.TranscriptionFailure.Row.recordingTooLong
        case .noConnection: return Copy.TranscriptionFailure.Row.noConnection
        case .modelMissing: return Copy.TranscriptionFailure.Row.modelMissing
        case .localEngineFailed: return Copy.TranscriptionFailure.Row.localEngineFailed
        case .audioUnreadable: return Copy.TranscriptionFailure.Row.audioUnreadable
        case .notConfigured: return Copy.TranscriptionFailure.Row.notConfigured
        case .unknown: return Copy.TranscriptionFailure.Row.unknown
        }
    }
}
