import AudioCodec
import Foundation
import SegmentStore

// Port of `core/transcription/.../TranscriptionProcessor.kt`.

/// Durable transcription worker for closed audio segments.
///
/// This class owns queue state transitions only. Audio decode and provider selection are
/// injected so platform/app layers can supply real Speex→PCM sources and real local/cloud
/// providers.
public final class TranscriptionProcessor: Sendable {
    /// Produces the decoded PCM chunk stream for one segment. Called once per provider
    /// attempt (the stream is single-use, unlike the KMP cold Flow).
    public typealias PcmSource =
        @Sendable (_ segmentId: String) async throws -> AsyncThrowingStream<Data, Error>

    private let queue: TranscriptionQueue
    private let router: TranscriptionModeRouter
    private let pcmSource: PcmSource
    private let sampleRateHz: Int
    private let onStateChanged: @Sendable (_ segmentId: String, _ state: TaskState) -> Void

    /// Persists transcript text durably before the task is marked Complete.
    private let transcriptStore: FileTranscriptStore?

    /// True while the segment is open (recording). A RESUME reattach can reopen a segment that
    /// was briefly closed and even already transcribed; an open segment must never be
    /// transcribed (the result would cover a stale prefix and terminally mask the audio
    /// appended after reattach).
    private let isSegmentOpen: @Sendable (_ segmentId: String) async -> Bool

    /// Loudest-second RMS below which a segment is not handed to a provider at all, or nil to
    /// disable the check. See `SegmentEnergy.provableSilenceFloorRms` for the derivation.
    private let silenceFloorRms: Double?

    public init(
        queue: TranscriptionQueue,
        router: TranscriptionModeRouter,
        pcmSource: @escaping PcmSource,
        sampleRateHz: Int = 16_000,
        onStateChanged: @escaping @Sendable (String, TaskState) -> Void = { _, _ in },
        transcriptStore: FileTranscriptStore? = nil,
        isSegmentOpen: @escaping @Sendable (String) async -> Bool = { _ in false },
        silenceFloorRms: Double? = SegmentEnergy.provableSilenceFloorRms
    ) {
        self.queue = queue
        self.router = router
        self.pcmSource = pcmSource
        self.sampleRateHz = sampleRateHz
        self.onStateChanged = onStateChanged
        self.transcriptStore = transcriptStore
        self.isSegmentOpen = isSegmentOpen
        self.silenceFloorRms = silenceFloorRms
    }

    /// `segmentIds` are the closed, not-fully-transcribed segments. One with a terminal-success
    /// task is a reattached segment that grew after transcription — requeue it; the rest
    /// enqueue idempotently.
    /// Enqueues closed segments the segment store believes are not transcribed.
    ///
    /// The interesting case is a segment whose META says untranscribed while its TASK says
    /// complete, because that disagreement is the one that can spin. The metadata write is
    /// best-effort — a detached `Task` with a `try?`, and `updateTranscriptionState` returns
    /// silently when the sidecar cannot be read — so if it ever fails the segment reappears here
    /// on every pass. Requeuing it unconditionally would re-transcribe, and for a cloud user
    /// re-UPLOAD, the same audio forever: real money, on a loop, with nothing said anywhere.
    ///
    /// So ask what is actually missing before deciding what to repair. If the transcript is on
    /// disk the work was already done and only the bookkeeping was lost, which is repaired by
    /// re-announcing the terminal state — cheap, and it terminates. Only a genuinely absent
    /// transcript is worth doing again.
    public func enqueueClosedSegments(_ segmentIds: some Sequence<String>) throws {
        for segmentId in segmentIds {
            let existing = try queue.load(segmentId)
            guard let existing, existing.state == .complete || existing.state == .noSpeech else {
                try queue.enqueue(segmentId)
                continue
            }
            // `.noSpeech` is terminal with no transcript to check: there was nothing to write.
            let workSurvives = existing.state == .noSpeech || transcriptStore?.load(segmentId) != nil
            if workSurvives {
                onStateChanged(segmentId, existing.state)
            } else {
                try queue.requeue(segmentId)
                onStateChanged(segmentId, .pending)
            }
        }
    }

    public func isTranscriptionAvailable() async -> Bool {
        await router.isAvailable()
    }

    /// Re-queues tasks that were parked as Disabled while no provider was usable. Call when
    /// transcription availability may have changed (model downloaded, key/consent added, mode
    /// switched). Returns the segment ids reset to Pending.
    public func reconsiderDisabled() async throws -> [String] {
        guard await router.isAvailable() else { return [] }
        let reset = try queue.resetDisabled()
        for segmentId in reset {
            onStateChanged(segmentId, .pending)
        }
        return reset
    }

    /// Soonest time a failed task becomes retryable, or nil when none is waiting.
    public func nextRetryAtMs() throws -> Int64? {
        try queue.nextRetryAtMs()
    }

    @discardableResult
    public func processNext() async throws -> TranscriptionTask? {
        guard let task = try queue.nextRunnable() else { return nil }
        // A segment that reattached (RESUME) while its task waited is recording again: leave
        // the task Pending; it runs after the segment's final close.
        if await isSegmentOpen(task.segmentId) { return nil }
        guard await router.isAvailable() else {
            let disabled = try queue.markDisabled(task.segmentId)
            onStateChanged(task.segmentId, .disabled)
            return disabled
        }

        // Nothing is sent anywhere — cloud or local — until the audio has been shown to contain
        // something. See `provablySilent` for what "shown" costs and what it is allowed to mean.
        if try await provablySilent(task.segmentId) {
            let terminal = try queue.markNoSpeech(task.segmentId)
            onStateChanged(task.segmentId, .noSpeech)
            return terminal
        }

        try queue.markRunning(task.segmentId)
        onStateChanged(task.segmentId, .running)
        let segmentId = task.segmentId
        do {
            let result = try await router.transcribe(
                pcmChunks: { [pcmSource] in try await pcmSource(segmentId) },
                sampleRateHz: sampleRateHz
            )
            if await isSegmentOpen(segmentId) {
                // The segment reattached mid-transcription; this result covers a stale prefix.
                // Discard it and re-run after the final close.
                let requeued = try queue.requeue(segmentId)
                onStateChanged(segmentId, .pending)
                return requeued
            }
            // Durability order matters: the transcript text is on disk before the task goes
            // terminal, so a crash in between re-runs transcription instead of losing text.
            try transcriptStore?.save(segmentId, result: result)
            let complete = try queue.markComplete(segmentId, result: result)
            onStateChanged(segmentId, .complete)
            return complete
        } catch let error where error is CancellationError {
            throw error
        } catch TranscriptionError.noSpeechDetected {
            let terminal = try queue.markNoSpeech(segmentId)
            onStateChanged(segmentId, .noSpeech)
            return terminal
        } catch TranscriptionError.providerUnavailable {
            let disabled = try queue.markDisabled(segmentId)
            onStateChanged(segmentId, .disabled)
            return disabled
        } catch {
            let failed = try queue.markFailed(
                segmentId, error: storedFailureMessage(error), retryable: true
            )
            onStateChanged(segmentId, .failed)
            return failed
        }
    }

    /// Decodes the segment once and asks whether it demonstrably contains no voice.
    ///
    /// Placed here, before `markRunning`, for three reasons.
    ///
    /// 1. **It is the only point that can prevent the send.** Measuring the stream *while* a
    ///    provider drains it would learn the same thing one round trip too late — the audio has
    ///    already left. Running first is what buys the outcome: no upload, no charge, and — the
    ///    reason this work exists — no opportunity for a provider to invent sentences out of room
    ///    tone.
    /// 2. **It is the same PCM.** `pcmSource` is the production factory the router would call, so
    ///    what is measured is byte-for-byte what would have been transcribed, not an approximation
    ///    read off the spool.
    /// 3. **It costs a decode, and only a decode.** Measured with this code over the real spool:
    ///    116 hours of audio decoded and profiled in 130 s of CPU, ~3200× realtime, 170 ms for an
    ///    average nine-minute segment. It replaces either a multi-megabyte cloud upload or an ASR
    ///    pass. The stream is single-use, so the router builds a fresh one for the real attempt —
    ///    that second decode is the price, and it is the smaller half of the trade.
    ///
    /// Fails OPEN. Any error decoding — a truncated spool, a store that has moved on — leaves the
    /// segment to the normal path, where the providers' own empty/short-audio handling and the
    /// retry ladder already apply. A gate that cannot measure must never claim silence.
    ///
    /// The outcome is `.noSpeech`: terminal, not a failure, never retried, and already the state
    /// this pipeline uses for "settled, nothing was said" — `SegmentSpeechEvidence` treats it as
    /// settled-with-no-speech and the transcript view renders the span as quiet rather than as
    /// missing audio. The spool file is untouched; a user-requested re-transcribe requeues it like
    /// any other segment.
    private func provablySilent(_ segmentId: String) async throws -> Bool {
        guard let silenceFloorRms else { return false }
        do {
            var meter = SegmentEnergyMeter(sampleRateHz: sampleRateHz, floorRms: silenceFloorRms)
            for try await chunk in try await pcmSource(segmentId) {
                meter.consume(chunk)
            }
            return meter.finish().isProvablySilent(floorRms: silenceFloorRms)
        } catch let error where error is CancellationError {
            throw error
        } catch {
            return false
        }
    }
}

extension TranscriptionProcessor {
    /// The production `pcmSource` wiring (port of the runtime factories): read the segment's
    /// frames from the store and Speex-decode them into bounded PCM chunks.
    public static func segmentPcmSource(store: SegmentStore) -> PcmSource {
        { segmentId in
            guard let meta = await store.readMeta(segmentId) else {
                throw TranscriptionError.transcriptionFailed(
                    "missing metadata for segment \(segmentId)")
            }
            let decoder = SpeexFrameDecoder(
                sampleRateHz: Int(meta.sampleRateHz),
                bitRateBps: Int(meta.bitRateBps),
                frameSamples: meta.frameSamples
            )
            let records = await store.readFrames(segmentId)
            let frames = AsyncThrowingStream<Data, Error> { continuation in
                for record in records {
                    continuation.yield(Data(record.payload))
                }
                continuation.finish()
            }
            return decoder.decode(frames: frames)
        }
    }
}
