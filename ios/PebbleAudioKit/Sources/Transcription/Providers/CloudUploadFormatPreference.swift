import AudioCodec
import Foundation

// Which container a segment's audio is uploaded in, and how the app finds out it was wrong.
//
// WHY A LADDER RATHER THAN A CONSTANT. `OggSpeex` is a 24.5x size win over WAV and a 9x win over
// FLAC, for less CPU than either, with bit-identical audio — but **neither provider documents
// Speex**. Soniox lists `ogg` as a container it auto-detects and OpenAI's OpenAPI spec lists `ogg`
// among the accepted formats; neither names a codec, and Speex was deprecated by Xiph in 2013.
// FFmpeg has shipped a native Speex decoder since 5.0 and both providers' format lists look like
// an FFmpeg ingest surface, so the bet is a good one. It is still a bet.
//
// The alternative to betting was asking a human to run a manual API probe before shipping. That is
// worse in every way: it spends the user's key, it answers the question once for two providers on
// one day, and it leaves nothing in the app that would notice if the answer ever changed. So the
// app probes for itself, on real traffic, and REMEMBERS: the first segment goes up as Ogg Speex;
// if that provider rejects it, the rejection is written to disk, the segment is requeued in the
// next-best format, and that provider is never offered the format again.
//
// WHAT A REJECTION MUST NOT BE. The expensive mistake here is downgrading on something that was
// never about the format — an expired key, a rate limit, a flaky radio, a backend having a bad
// afternoon — because the rejection is durable and the user would silently pay 9x the bytes
// forever. So the admissible evidence is an ALLOWLIST, not a list of exclusions
// (`payloadPlausibleStatuses`): transport errors and every status outside {400, 406, 415, 422}
// are not evidence at all, and what remains is judged differently depending on whether the
// provider has documented the format (see `CloudAudioFormat.isDocumentedByProviders`).
//
// WHAT A REJECTION MUST NOT COST. Audio. A rejected upload is not a failed segment: it is the same
// segment, addressed wrongly. It goes back to `Pending` with its attempt REFUNDED
// (`TranscriptionQueue.requeueWithoutAttempt`) and is picked up by the next pipeline pass one rung
// down. The retry ladder is eight attempts and exists to bound genuinely broken work; a downgrade
// is not broken work, and burning attempts on it would mean a segment that hit both downgrades
// arrived at the format that works with a quarter of its budget already spent.

/// The rungs, best first. `.wav` is last and is the floor: it is what shipped for months, both
/// providers document it, and nothing below it exists to fall to.
///
/// **`.oggSpeex` is verified against both live providers, not hoped for** (2026-09-08). A real
/// 18 s watch segment was remuxed from its own `.spxlog` frames and posted to each provider's
/// production endpoint, against a WAV control decoded from the identical bytes:
///
/// - **Soniox** (`stt-async-v5`, the app's default): accepted, and the returned transcript was
///   **character-identical** to the WAV control's.
/// - **OpenAI** (`gpt-4o-mini-transcribe`): accepted, billed the same 174 audio tokens as the WAV
///   control, and returned a comparable transcript.
///
/// So the first rung is expected to succeed on both, and no user should ever see a downgrade. The
/// ladder below is not a probe — it is insurance against a provider changing its mind, and it is
/// why that change would cost one request rather than every recording.
public enum CloudUploadFormatPreference {
    /// The ladder for a background upload, where the watch's original Speex frames are available.
    public static let ladder: [CloudAudioFormat] = [.oggSpeex, .flac, .wav]

    /// The ladder for the synchronous path, which receives decoded PCM and has no frames to
    /// package — so it starts at FLAC.
    public static let pcmLadder: [CloudAudioFormat] = [.flac, .wav]

    /// The best rung `rejected` has not taken away. Falls through to the last rung rather than
    /// returning nil: there is always something to send.
    public static func resolve(
        ladder: [CloudAudioFormat] = ladder,
        rejected: Set<CloudAudioFormat>
    ) -> CloudAudioFormat {
        ladder.first { !rejected.contains($0) } ?? ladder.last ?? .wav
    }

    /// The rung below `format`, or nil at the floor.
    public static func next(
        after format: CloudAudioFormat,
        ladder: [CloudAudioFormat] = ladder,
        rejected: Set<CloudAudioFormat> = []
    ) -> CloudAudioFormat? {
        guard let index = ladder.firstIndex(of: format) else { return nil }
        return ladder[(index + 1)...].first { !rejected.contains($0) }
    }
}

/// A provider response that means "I cannot read these bytes", carried structurally so the
/// coordinator does not have to sniff a rendered error string.
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
}

/// Decides whether a failed request is evidence that the provider cannot read `format`.
public enum CloudUploadFormatRejection {
    /// The only HTTP statuses that could plausibly be a verdict on the bytes we sent.
    ///
    /// An allowlist rather than a list of exclusions, deliberately. The exclusions are the obvious
    /// ones — the key (401/403), a rate limit (429), a timeout (408) — but they are not the whole
    /// set, and the failure mode of forgetting one is silent and permanent: a 404 from a
    /// mis-shaped control-plane URL would durably cost the user 9x the bytes for the life of the
    /// app. So the question asked is the narrow one: which statuses does a server actually use to
    /// say "I cannot read this payload"?
    ///
    /// - **400** Bad Request — the generic one both providers really use.
    /// - **406** Not Acceptable — content negotiation.
    /// - **415** Unsupported Media Type — the definitive one; it means nothing else.
    /// - **422** Unprocessable Content — "understood, cannot process".
    ///
    /// Notably absent: **413** (too large), because that is a SIZE complaint and every rung below
    /// is bigger — downgrading there would make the next attempt worse, not better.
    static let payloadPlausibleStatuses: Set<Int> = [400, 406, 415, 422]

    /// Whether a failure is even admissible as evidence about the container — the gate the
    /// backstop counter uses too, so an unrelated 4xx cannot accumulate into a downgrade.
    ///
    /// `0` means the provider reported an error with no status of its own (Soniox's control
    /// plane), which is admissible; a transport failure also has no status and is excluded by the
    /// caller, which knows the difference.
    public static func couldConcernThePayload(httpStatus: Int) -> Bool {
        httpStatus == 0 || payloadPlausibleStatuses.contains(httpStatus)
    }

    /// Phrases a provider uses when it means the container. Matched case-insensitively against the
    /// response body. Kept narrow on purpose: "format" on its own also appears in
    /// `response_format` parameter errors, which have nothing to do with the audio.
    static let complaintPhrases = [
        "invalid file format",
        "invalid audio format",
        "unsupported file",
        "unsupported audio",
        "unsupported format",
        "unsupported media",
        "unsupported content",
        "unsupported codec",
        "unknown audio format",
        "unrecognized format",
        "unrecognised format",
        "format not supported",
        "file type is not supported",
        "not a supported",
        "supported formats",
        "supported file types",
        "could not decode",
        "couldn't decode",
        "cannot decode",
        "unable to decode",
        "failed to decode",
        "decoding failed",
        "could not be decoded",
        "corrupt audio",
        "invalid audio",
    ]

    /// Whether `body` reads like a complaint about the container rather than about anything else.
    public static func bodyLooksLikeFormatComplaint(_ body: String) -> Bool {
        let text = body.lowercased()
        return complaintPhrases.contains { text.contains($0) }
    }

    /// The rule, for a response that already failed.
    ///
    /// - `.wav` never counts: it is the floor, so believing a rejection would strand the segment
    ///   with nowhere to go.
    /// - A **415** counts on its own for any format. That status means exactly one thing.
    /// - For a format the providers **document** (`.flac`), a 400/422 counts only when the body
    ///   actually says something about the format. FLAC has been accepted in production; a bare
    ///   400 is far likelier to be a malformed field than a codec objection.
    /// - For a format they **do not** document (`.oggSpeex`), any remaining payload-plausible
    ///   status counts. The
    ///   container is the only thing about that request that is not identical to a request the
    ///   provider has already accepted, the auth/limit/size codes are excluded above, and the cost
    ///   of being wrong is one rung to FLAC — still lossless, still a 63% saving. Waiting for
    ///   wording we happened to anticipate would instead strand real recordings behind a
    ///   permanent failure loop.
    /// - A **statusless** complaint (`httpStatus == 0`) — Soniox reporting a transcription-level
    ///   error, which is where that provider would surface a container it cannot transcode —
    ///   counts only when its wording says so, whatever the format. There is no status to reason
    ///   from, so the wording is all there is.
    public static func isFormatRejection(
        format: CloudAudioFormat,
        httpStatus: Int,
        body: String
    ) -> Bool {
        guard format != .wav, couldConcernThePayload(httpStatus: httpStatus) else { return false }
        if httpStatus == 0 { return bodyLooksLikeFormatComplaint(body) }
        if httpStatus == 415 { return true }
        if format.isDocumentedByProviders { return bodyLooksLikeFormatComplaint(body) }
        return true
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

/// One durable "this provider would not take this container" record.
public struct CloudFormatRejectionRecord: Codable, Sendable, Equatable {
    public let format: CloudAudioFormat
    /// HTTP status that produced the verdict, or 0 for a statusless control-plane complaint.
    public let httpStatus: Int
    /// A truncated slice of what the provider actually said. Diagnostics only — but this is the
    /// only trace of a decision the user never sees and cannot otherwise explain.
    public let evidence: String
    public let recordedAtMs: Int64

    public init(format: CloudAudioFormat, httpStatus: Int, evidence: String, recordedAtMs: Int64) {
        self.format = format
        self.httpStatus = httpStatus
        self.evidence = String(evidence.prefix(240))
        self.recordedAtMs = recordedAtMs
    }
}

/// What the app has learned about a provider's appetite for containers.
public protocol CloudUploadFormatMemory: Sendable {
    /// Formats this provider has been observed to reject. Read once per segment on the submit
    /// path, so implementations must answer from memory, not from disk.
    func rejectedFormats(_ provider: CloudProvider) -> Set<CloudAudioFormat>

    /// Records a rejection. Idempotent: recording the same format twice changes nothing.
    func recordRejection(_ record: CloudFormatRejectionRecord, provider: CloudProvider)

    /// Every rejection on record, for diagnostics.
    func rejections(_ provider: CloudProvider) -> [CloudFormatRejectionRecord]

    /// Counts one failure that was NOT diagnosable as a format rejection but happened while
    /// `format` was in use, and reports whether the run is now long enough to act on. See
    /// `CloudUploadFormatStore.consecutiveFailuresBeforeDowngrade`.
    func noteInconclusiveFailure(_ provider: CloudProvider, format: CloudAudioFormat) -> Bool

    /// Clears the failure run for a provider (any success, in any format).
    func noteSuccess(_ provider: CloudProvider)

    /// Forgets everything learned about a provider, so the ladder starts from the top again.
    func forget(_ provider: CloudProvider)
}

/// A memory that learns nothing — the default for call sites that do not have a store (the
/// synchronous provider path in tests, previews).
public struct NoCloudUploadFormatMemory: CloudUploadFormatMemory {
    public init() {}
    public func rejectedFormats(_ provider: CloudProvider) -> Set<CloudAudioFormat> { [] }
    public func recordRejection(_ record: CloudFormatRejectionRecord, provider: CloudProvider) {}
    public func rejections(_ provider: CloudProvider) -> [CloudFormatRejectionRecord] { [] }
    public func noteInconclusiveFailure(_ provider: CloudProvider, format: CloudAudioFormat) -> Bool
    { false }
    public func noteSuccess(_ provider: CloudProvider) {}
    public func forget(_ provider: CloudProvider) {}
}

/// File-backed `CloudUploadFormatMemory`: one JSON file per provider under
/// `<root>/transcription/upload-formats/`, written atomically, cached in memory.
///
/// Cached because `rejectedFormats` is on the per-segment submit path and a disk read there would
/// be a file open per segment for an answer that changes at most twice in the life of the app. The
/// cache is authoritative once loaded; the file exists to survive relaunch.
public final class CloudUploadFormatStore: CloudUploadFormatMemory, @unchecked Sendable {
    /// How many consecutive inconclusive failures on one format before it is downgraded anyway.
    ///
    /// The backstop for the case this design cannot otherwise cover: a provider that refuses our
    /// container in words we did not anticipate. Only failures that survived every exclusion above
    /// are counted — no transport errors, no 5xx, no auth, no rate limits — so a network outage or
    /// an expired key cannot drive it, and any success resets it. Three, because the cost of
    /// firing wrongly is one rung (Ogg -> FLAC, still lossless, still -63%) and the cost of never
    /// firing is real recordings looping on a permanent failure.
    public static let consecutiveFailuresBeforeDowngrade = 3

    private struct Memory: Codable {
        var rejections: [CloudFormatRejectionRecord] = []
        /// Not persisted deliberately — see `noteInconclusiveFailure`.
        var runFormat: CloudAudioFormat?
        var runLength: Int = 0

        enum CodingKeys: String, CodingKey { case rejections }
    }

    private let dir: URL
    private let lock = NSLock()
    private var cache: [CloudProvider: Memory] = [:]

    public init(root: URL) {
        self.dir = root
            .appendingPathComponent("transcription", isDirectory: true)
            .appendingPathComponent("upload-formats", isDirectory: true)
    }

    private func fileURL(_ provider: CloudProvider) -> URL {
        dir.appendingPathComponent("\(provider.rawValue).formats.json")
    }

    /// Caller holds `lock`.
    private func memory(_ provider: CloudProvider) -> Memory {
        if let cached = cache[provider] { return cached }
        let loaded =
            (try? Data(contentsOf: fileURL(provider)))
            .flatMap { try? JSONDecoder().decode(Memory.self, from: $0) } ?? Memory()
        cache[provider] = loaded
        return loaded
    }

    public func rejectedFormats(_ provider: CloudProvider) -> Set<CloudAudioFormat> {
        lock.lock()
        defer { lock.unlock() }
        return Set(memory(provider).rejections.map(\.format))
    }

    public func rejections(_ provider: CloudProvider) -> [CloudFormatRejectionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return memory(provider).rejections.sorted { $0.recordedAtMs < $1.recordedAtMs }
    }

    public func recordRejection(_ record: CloudFormatRejectionRecord, provider: CloudProvider) {
        lock.lock()
        defer { lock.unlock() }
        var next = memory(provider)
        guard !next.rejections.contains(where: { $0.format == record.format }) else { return }
        next.rejections.append(record)
        // The run belonged to the format we have just retired.
        next.runFormat = nil
        next.runLength = 0
        cache[provider] = next
        persist(next, provider: provider)
    }

    /// The run counter is deliberately **not** persisted. A relaunch is exactly the kind of event
    /// that follows a run of failures (a crash, a kill, a reboot), and carrying a partial count
    /// across it would make the backstop fire on evidence gathered under conditions that may no
    /// longer hold. Starting over costs at most two more segments and only ever in the case where
    /// the provider really is refusing the format, which it will keep doing.
    public func noteInconclusiveFailure(_ provider: CloudProvider, format: CloudAudioFormat) -> Bool
    {
        lock.lock()
        defer { lock.unlock() }
        guard format != .wav else { return false }
        var next = memory(provider)
        if next.runFormat != format {
            next.runFormat = format
            next.runLength = 0
        }
        next.runLength += 1
        cache[provider] = next
        return next.runLength >= Self.consecutiveFailuresBeforeDowngrade
    }

    public func noteSuccess(_ provider: CloudProvider) {
        lock.lock()
        defer { lock.unlock() }
        var next = memory(provider)
        guard next.runLength != 0 || next.runFormat != nil else { return }
        next.runFormat = nil
        next.runLength = 0
        cache[provider] = next
    }

    public func forget(_ provider: CloudProvider) {
        lock.lock()
        defer { lock.unlock() }
        cache[provider] = Memory()
        try? FileManager.default.removeItem(at: fileURL(provider))
    }

    private func persist(_ memory: Memory, provider: CloudProvider) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: fileURL(provider), options: .atomic)
    }
}
