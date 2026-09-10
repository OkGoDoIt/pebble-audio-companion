import AudioCodec
import Foundation

// Which container a segment's audio is uploaded in. One constant per provider, decided here.
//
// WHY OGG SPEEX. It is a 24.5x size win over WAV and a 9x win over FLAC, for less CPU than either,
// with bit-identical audio — the watch already sends Speex frames, so the passthrough path packages
// the bytes it was given instead of decoding and re-encoding them.
//
// WHY A CONSTANT AND NOT A LADDER. Which containers a provider accepts is a fact about that
// provider, established once by measurement, not a property of a running phone — so it belongs in
// the source, next to the evidence, where it is reviewable and changes through a commit.
//
// This was a runtime ladder until 2026-09-10: the app uploaded as Ogg Speex, watched for a
// rejection, and durably recorded "this provider will not take this container" so later uploads
// stepped down a rung. The mechanism was carefully built — an allowlist of admissible HTTP
// statuses, phrase matching on the body, a three-strike backstop for wording nobody anticipated —
// and in production it fired exactly once, wrongly. A Soniox balance ran dry; three consecutive
// uploads failed with "Organization balance exhausted"; the backstop read three unexplained
// failures and permanently retired Ogg Speex. The evidence string it wrote to disk was, verbatim,
// the billing message. Nothing about the audio had changed.
//
// That is the shape of the trade. The upside of learning at runtime was covering a provider that
// silently changes its ingest surface — rare, identical for every user, and a one-line code change
// when it happens. The downside was a mechanism that can be fooled by any failure it cannot
// classify, whose mistakes are silent, durable, and cost 9x the bytes forever. The downside
// happened first.
//
// WHAT REPLACES IT. Nothing adaptive. If a provider ever does refuse this container, the upload
// fails like any other failure: the audio is untouched on disk, the segment is retried on the
// ordinary ladder, and Diagnostics says "the provider didn't accept the recording" — a loud,
// visible, correctly-attributed failure that asks a human to change the constant below. Slower
// than self-healing, and honest, which the self-healing version turned out not to be.
public enum CloudUploadFormats {
    /// The container for a background upload, where the watch's own Speex frames are available.
    ///
    /// **Verified against both live providers, not hoped for** (2026-09-08). A real 18 s watch
    /// segment was remuxed from its own `.spxlog` frames and posted to each provider's production
    /// endpoint, against a WAV control decoded from the identical bytes:
    ///
    /// - **Soniox** (`stt-async-v5`): accepted, and the returned transcript was **character-
    ///   identical** to the WAV control's.
    /// - **OpenAI** (`gpt-4o-mini-transcribe`): accepted, billed the same 174 audio tokens as the
    ///   WAV control, and returned a comparable transcript.
    ///
    /// Both providers document `ogg` as a container they auto-detect; neither names a codec, and
    /// both format lists look like an FFmpeg ingest surface (FFmpeg has decoded Speex natively
    /// since 5.0). The measurement above is what makes that inference safe to ship.
    public static let passthrough: CloudAudioFormat = .oggSpeex

    /// The container for the synchronous path, which is handed decoded PCM and so has no frames to
    /// package. FLAC because it is lossless and both providers document it.
    public static let fromPcm: CloudAudioFormat = .flac
}

/// A provider response that means "I cannot read these bytes", carried structurally so the
/// coordinator does not have to sniff a rendered error string.
///
/// It no longer changes what the app uploads — it makes the failure legible. Classified as
/// `providerRefusedAudio`, which is the one kind that stops retrying and stays visible in
/// Diagnostics, because a container this provider cannot read is not going to become readable on
/// the ninth attempt.
///
/// `httpStatus` is 0 when the complaint arrived in a body rather than as a status — Soniox's async
/// flow accepts the file first and reports a decode problem later, as `status: "error"` with a
/// message, so that path has no status of its own.
public struct CloudFormatComplaint: Error, Sendable, Equatable {
    public let httpStatus: Int
    public let evidence: String

    public init(httpStatus: Int, evidence: String) {
        self.httpStatus = httpStatus
        self.evidence = String(evidence.prefix(240))
    }

    /// Pulls a `CloudFormatComplaint` out of an error chain, if one is in there.
    public static func complaint(in error: Error) -> CloudFormatComplaint? {
        if let complaint = error as? CloudFormatComplaint { return complaint }
        if case TranscriptionError.transcriptionFailed(_, let underlying) = error,
            let underlying
        {
            return complaint(in: underlying)
        }
        return nil
    }
}
