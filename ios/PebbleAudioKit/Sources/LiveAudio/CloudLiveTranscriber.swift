import AudioCodec
import Foundation
import Transcription

// Port of the `CloudLiveTranscriber` half of `app/.../CloudLiveTranscriber.kt`
// (LiveAudioEvent/LiveAudioTap live in LiveAudioTap.swift).

/// Outcome of one live-streaming attempt, reported so cloud health stays visible.
///
/// Mirror of the KMP `CloudConnectivityResult` Ok/Failed cases. Deliberately a LiveAudio-local
/// type: the full connectivity vocabulary (incl. NotConfigured) belongs to the Transcription
/// module's cloud-health port; the runtime maps this into it when wiring CloudHealthMonitor.
public enum CloudLiveOutcome: Sendable, Equatable {
    /// Reachable and the credentials were accepted.
    case ok(detail: String? = nil)
    /// Reachable but rejected, or unreachable. `message` is user-facing.
    case failed(message: String)
}

/// Real-time cloud transcription of the currently-open segment (plan: "real-time streaming of
/// live audio"). It decodes the live frame tap into PCM, streams it to a
/// `StreamingTranscriptionProvider` (e.g. Soniox realtime), and publishes a rolling
/// `LiveTranscriptPreview` — the same preview surface the local chunk-based transcriber uses, so
/// the UI need not care which produced it.
///
/// Foreground-only semantics come from the injected `enabled` gate: the runtime composes
/// consent + API key + (on iOS) foregroundedness into it, and a session is only (re)started
/// while the gate allows it. `setForeground` remains the lifecycle hook the runtime calls; it
/// never tears down an in-flight session (matching the KMP behavior pinned by
/// `backgroundingDoesNotStopCloudStreamingProgress`).
public actor CloudLiveTranscriber {
    private let tap: LiveAudioTap
    private let provider: StreamingTranscriptionProvider
    private let enabled: @Sendable () -> Bool
    private let nowMs: @Sendable () -> Int64
    /// Reports live-streaming outcomes so cloud health is visible: `.ok` once a session produces
    /// an update, `.failed` when the socket errors. Without this, a failing live socket silently
    /// falls back to the local preview (as it did before the Soniox audio_format fix).
    private let onOutcome: @Sendable (CloudLiveOutcome) -> Void
    /// How many times a live socket is reconnected after a mid-segment failure before giving up
    /// for that segment. Soniox realtime sees transient timeouts/drops; reconnecting recovers
    /// them without surfacing anything to the user (CloudHealthMonitor debounces the failures).
    private let maxReconnects: Int
    /// Backoff before reconnect attempt N (1-based). Exponential, capped, by default.
    private let reconnectBackoffMs: @Sendable (Int) -> Int64
    private let logFailure: @Sendable (String, Error) -> Void
    private let decodePcm:
        @Sendable (LiveAudioEvent.SegmentOpened, AsyncStream<Data>) -> AsyncThrowingStream<Data, Error>

    public private(set) var previews: [String: LiveTranscriptPreview] = [:]

    private var currentOpenSegment: LiveAudioEvent.SegmentOpened?
    private var activeSegmentId: String?
    private var frameChannel: LiveFrameChannel?
    private var sessionTask: Task<Void, Never>?
    private var activeFrameSamples = 320
    private var streamedFrameCount = 0
    private var lastSampleIndexExclusive: UInt64 = 0
    /// The segment this transcriber is actually carrying text for right now (a session that has
    /// delivered at least one update). See `deliveringSegmentId`.
    private var deliveringSegment: String?
    /// After a session gives up on a segment, the earliest time a new session may be opened for
    /// THAT segment. Without it, the next frame batch would immediately restart the whole
    /// reconnect cycle — a hot loop of failing sockets for the rest of the recording.
    private var retryGate: (segmentId: String, notBeforeMs: Int64)?

    public init(
        tap: LiveAudioTap,
        provider: StreamingTranscriptionProvider,
        enabled: @escaping @Sendable () -> Bool,
        nowMs: @escaping @Sendable () -> Int64,
        onOutcome: @escaping @Sendable (CloudLiveOutcome) -> Void = { _ in },
        maxReconnects: Int = CloudLiveTranscriber.defaultMaxReconnects,
        reconnectBackoffMs: @escaping @Sendable (Int) -> Int64 = { attempt in
            min(
                CloudLiveTranscriber.baseReconnectDelayMs << (attempt - 1),
                CloudLiveTranscriber.maxReconnectDelayMs)
        },
        logFailure: @escaping @Sendable (String, Error) -> Void = { label, error in
            print("audio-companion: \(label) failed: \(error)")
        },
        decodePcm: @escaping @Sendable (LiveAudioEvent.SegmentOpened, AsyncStream<Data>)
            -> AsyncThrowingStream<Data, Error> = { event, encoded in
                SpeexFrameDecoder(
                    sampleRateHz: event.sampleRateHz,
                    bitRateBps: event.bitRateBps,
                    frameSamples: event.frameSamples
                ).decode(frames: encoded)
            }
    ) {
        self.tap = tap
        self.provider = provider
        self.enabled = enabled
        self.nowMs = nowMs
        self.onOutcome = onOutcome
        self.maxReconnects = maxReconnects
        self.reconnectBackoffMs = reconnectBackoffMs
        self.logFailure = logFailure
        self.decodePcm = decodePcm
    }

    /// Starts consuming the tap; cancel the returned task to stop (the Kotlin `start(scope)` Job).
    public func start() -> Task<Void, Never> {
        let events = tap.events()
        return Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    /// The segment whose live text is currently coming off the realtime socket, or nil.
    ///
    /// "Delivering" means a session is running AND it has produced at least one update — a
    /// socket that is merely connecting must not silence the chunk-based fallback, or the first
    /// seconds of a segment would be a hole in the preview. The runtime uses this to keep the
    /// two live paths from transcribing (and billing for) the same audio.
    public func deliveringSegmentId() -> String? { deliveringSegment }

    /// Lifecycle hook; the `enabled` gate decides policy, so this is deliberately a no-op
    /// (an in-flight live socket keeps streaming until its segment closes or the gate stops
    /// the next session).
    public func setForeground(_ value: Bool) {}

    private func handle(_ event: LiveAudioEvent) {
        switch event {
        case .segmentOpened(let opened):
            currentOpenSegment = opened
            maybeStartSession(opened)
        case .framesAppended(let segmentId, let frames):
            if segmentId == currentOpenSegment?.segmentId && activeSegmentId != segmentId {
                if let opened = currentOpenSegment { maybeStartSession(opened) }
            }
            if segmentId == activeSegmentId {
                streamedFrameCount += frames.count
                if let frame = frames.last {
                    lastSampleIndexExclusive = frame.sampleIndex + UInt64(activeFrameSamples)
                }
                for frame in frames { frameChannel?.send(Data(frame.payload)) }
            }
        case .segmentClosed(let segmentId):
            if segmentId == currentOpenSegment?.segmentId { currentOpenSegment = nil }
            if segmentId == activeSegmentId { stopSession() }
        }
    }

    private func maybeStartSession(_ event: LiveAudioEvent.SegmentOpened) {
        guard enabled() else { return }
        if activeSegmentId == event.segmentId && frameChannel != nil { return }
        if let gate = retryGate, gate.segmentId == event.segmentId, nowMs() < gate.notBeforeMs {
            return
        }
        stopSession()
        let channel = LiveFrameChannel()
        activeSegmentId = event.segmentId
        activeFrameSamples = event.frameSamples
        streamedFrameCount = 0
        lastSampleIndexExclusive = 0
        frameChannel = channel
        sessionTask = Task { await self.runSessionLoop(event, channel: channel) }
    }

    private func runSessionLoop(_ event: LiveAudioEvent.SegmentOpened, channel: LiveFrameChannel) async {
        var attempt = 0
        while true {
            do {
                try await streamSession(event, channel: channel)
                releaseSession(event.segmentId)
                return
            } catch is CancellationError {
                return
            } catch let error as CloudLiveUnavailable {
                // No key, no consent, or the selected provider has no realtime backend. Not a
                // cloud FAILURE (nothing was reached), so cloud health is left alone — but the
                // session is released so the chunk-based path takes the segment over instead of
                // frames piling up in a channel nobody reads.
                _ = error
                gaveUp(on: event.segmentId, after: Self.unavailableRetryDelayMs)
                return
            } catch {
                onOutcome(.failed(message: failureMessage(error)))
                logFailure("cloud live transcription", error)
                attempt += 1
                // Reconnect only while this segment is still the active one and the user still
                // wants live cloud transcription; otherwise give up (the banner, if the failure
                // streak crossed the threshold, has already surfaced it).
                if attempt > maxReconnects || !enabled() || activeSegmentId != event.segmentId {
                    gaveUp(on: event.segmentId, after: Self.gaveUpRetryDelayMs)
                    return
                }
                do {
                    let delayMs = max(reconnectBackoffMs(attempt), 0)
                    try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                } catch {
                    releaseSession(event.segmentId)
                    return
                }
            }
        }
    }

    private func streamSession(
        _ event: LiveAudioEvent.SegmentOpened, channel: LiveFrameChannel
    ) async throws {
        guard await provider.isAvailable() else { throw CloudLiveUnavailable() }
        let pcm = decodePcm(event, channel.stream())
        var reportedOk = false
        for try await update in provider.transcribeStream(pcm: pcm, sampleRateHz: event.sampleRateHz) {
            if !reportedOk {
                onOutcome(.ok())
                reportedOk = true
            }
            deliveringSegment = event.segmentId
            previews[event.segmentId] = LiveTranscriptPreview(
                segmentId: event.segmentId,
                text: update.displayText,
                segments: update.segments,
                transcribedFrameCount: streamedFrameCount,
                lastSampleIndexExclusive: lastSampleIndexExclusive,
                updatedAtMs: nowMs(),
                providerId: provider.id
            )
        }
    }

    private func stopSession() {
        frameChannel?.close()
        frameChannel = nil
        sessionTask?.cancel()
        sessionTask = nil
        activeSegmentId = nil
        deliveringSegment = nil
    }

    /// Gives up on a segment: release the session so the chunk-based path takes over, and hold
    /// a retry gate so the next frame batch does not immediately restart the same failure.
    private func gaveUp(on segmentId: String, after delayMs: Int64) {
        retryGate = (segmentId: segmentId, notBeforeMs: nowMs() + delayMs)
        releaseSession(segmentId)
    }

    /// Ends a session from inside its own task: same teardown as `stopSession` minus cancelling
    /// the task we are running on. Load-bearing — without it a session that gave up leaves
    /// `activeSegmentId` pinned, so every later frame is appended to a channel nobody reads and
    /// the chunk-based fallback never learns it owns the segment again.
    private func releaseSession(_ segmentId: String) {
        guard activeSegmentId == segmentId else { return }
        frameChannel?.close()
        frameChannel = nil
        sessionTask = nil
        activeSegmentId = nil
        deliveringSegment = nil
    }

    /// Drops a segment's live preview once its durable transcript supersedes it.
    public func prune(hasDurableTranscript: @Sendable (String) -> Bool) {
        previews = previews.filter { $0.key == activeSegmentId || !hasDurableTranscript($0.key) }
    }

    private func failureMessage(_ error: Error) -> String {
        let text = String(describing: error)
        return text.isEmpty ? "Live cloud transcription failed." : text
    }

    // Test-only visibility into the receive-side counters (mirrors what the KMP tests observed
    // through virtual-time scheduling).
    internal func streamedFrameCountForTesting() -> Int { streamedFrameCount }
    internal func activeSegmentIdForTesting() -> String? { activeSegmentId }

    public static let defaultMaxReconnects = 4
    public static let baseReconnectDelayMs: Int64 = 1_000
    public static let maxReconnectDelayMs: Int64 = 15_000
    /// No key/consent: nothing to reach, so wait a while before touching the keychain again.
    static let unavailableRetryDelayMs: Int64 = 30_000
    /// The reconnect budget is spent; the chunk path owns the segment until this elapses.
    static let gaveUpRetryDelayMs: Int64 = 60_000
}

/// The realtime backend is not configured (no key, no consent). Distinct from a failure: nothing
/// was reached, so it must not be reported as cloud health trouble.
private struct CloudLiveUnavailable: Error {}

/// Unbounded FIFO of encoded frames feeding one live session (the Kotlin
/// `Channel<ByteArray>(UNLIMITED)`). Reconnects re-consume from the current position via a
/// fresh `stream()` over the same FIFO; frames consumed by a failed session are gone, matching
/// the KMP channel semantics.
final class LiveFrameChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Data] = []
    private var closed = false
    private var waiter: CheckedContinuation<Data?, Never>?

    func send(_ data: Data) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: data)
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    private func next() async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            lock.lock()
            // A reconnect abandons the previous `stream()` mid-wait. Finish that consumer
            // instead of overwriting its continuation, which leaks it ("SWIFT TASK CONTINUATION
            // MISUSE" in the reconnect tests) and strands the task awaiting it.
            if let stale = waiter {
                waiter = nil
                lock.unlock()
                stale.resume(returning: nil)
                lock.lock()
            }
            if !buffer.isEmpty {
                let first = buffer.removeFirst()
                lock.unlock()
                continuation.resume(returning: first)
                return
            }
            if closed {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    /// A fresh view over the remaining FIFO contents. One consumer at a time.
    func stream() -> AsyncStream<Data> {
        AsyncStream(unfolding: { await self.next() })
    }
}
