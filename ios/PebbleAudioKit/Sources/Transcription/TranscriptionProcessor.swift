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

    public init(
        queue: TranscriptionQueue,
        router: TranscriptionModeRouter,
        pcmSource: @escaping PcmSource,
        sampleRateHz: Int = 16_000,
        onStateChanged: @escaping @Sendable (String, TaskState) -> Void = { _, _ in },
        transcriptStore: FileTranscriptStore? = nil,
        isSegmentOpen: @escaping @Sendable (String) async -> Bool = { _ in false }
    ) {
        self.queue = queue
        self.router = router
        self.pcmSource = pcmSource
        self.sampleRateHz = sampleRateHz
        self.onStateChanged = onStateChanged
        self.transcriptStore = transcriptStore
        self.isSegmentOpen = isSegmentOpen
    }

    /// `segmentIds` are the closed, not-fully-transcribed segments. One with a terminal-success
    /// task is a reattached segment that grew after transcription — requeue it; the rest
    /// enqueue idempotently.
    public func enqueueClosedSegments(_ segmentIds: some Sequence<String>) throws {
        for segmentId in segmentIds {
            let existing = try queue.load(segmentId)
            if let existing, existing.state == .complete || existing.state == .noSpeech {
                try queue.requeue(segmentId)
                onStateChanged(segmentId, .pending)
            } else {
                try queue.enqueue(segmentId)
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
