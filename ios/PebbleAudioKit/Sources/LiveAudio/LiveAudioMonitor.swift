import Foundation
import SegmentStore

// Port of `app/.../LiveAudioMonitor.kt` (the monitor half; TeeSegmentSink lives in its own file).

public enum WaveformBarState: Sendable, Equatable {
    case recorded
    case silence

    /// Voice-activity silence the watch skipped sending: known-quiet, rendered as a subtle tick.
    case suppressedSilence
    case gap
}

/// One ~250 ms bar of the live waveform.
public struct WaveformBar: Sendable, Equatable {
    public let timeMs: Int64
    /// 0..1 display amplitude.
    public let amplitude: Float
    public let state: WaveformBarState
    /// Segment the audio belongs to, for transcribed-state coloring in the UI.
    public let segmentId: String?
    /// Highest stream sample index in this bucket; compares against the live-transcribed boundary.
    public let maxSampleIndex: UInt64?

    public init(
        timeMs: Int64,
        amplitude: Float,
        state: WaveformBarState,
        segmentId: String?,
        maxSampleIndex: UInt64? = nil
    ) {
        self.timeMs = timeMs
        self.amplitude = amplitude
        self.state = state
        self.segmentId = segmentId
        self.maxSampleIndex = maxSampleIndex
    }
}

/// Live waveform source (MVP requirement; ux plan Section 8 "Visual Waveform"): keeps a bounded
/// ring of the last `windowMs` of *encoded* frames and decodes them to RMS bars only while the
/// UI is visible (`setActive`). Nothing is decoded on the BLE receive path; when the view is
/// hidden, frames just accumulate (bounded by the window) and are decoded in one catch-up batch
/// on the next activation.
///
/// The Kotlin class serialized state behind a Mutex; the actor provides the same discipline
/// (decode happens outside isolation, exactly like the Kotlin code decoding outside the lock).
public actor LiveAudioMonitor {
    private let decoder: LiveFrameDecoder?
    private let nowMs: @Sendable () -> Int64
    private let frameSamples: Int
    private let frameDurationMs: Int64
    public nonisolated let barMs: Int64
    public nonisolated let windowMs: Int64
    private let maxDecodeFramesPerPass: Int
    private let maxActivationCatchUpFrames: Int

    public init(
        decoder: LiveFrameDecoder?,
        nowMs: @escaping @Sendable () -> Int64,
        frameSamples: Int = 320,
        frameDurationMs: Int64 = 20,
        barMs: Int64 = 250,
        windowMs: Int64 = 60_000,
        maxDecodeFramesPerPass: Int = 250,
        maxActivationCatchUpFrames: Int = 500
    ) {
        precondition(maxDecodeFramesPerPass > 0)
        precondition(maxActivationCatchUpFrames >= maxDecodeFramesPerPass)
        self.decoder = decoder
        self.nowMs = nowMs
        self.frameSamples = frameSamples
        self.frameDurationMs = frameDurationMs
        self.barMs = barMs
        self.windowMs = windowMs
        self.maxDecodeFramesPerPass = maxDecodeFramesPerPass
        self.maxActivationCatchUpFrames = maxActivationCatchUpFrames
    }

    private struct Entry {
        let timeMs: Int64
        let segmentId: String?
        let payload: [UInt8]?
        let gapDurationMs: Int64
        var sampleIndex: UInt64?
        /// True for voice-activity silence the watch skipped: render as quiet, not as a gap.
        var silenceFill: Bool = false
    }

    private final class BarAccum {
        let timeMs: Int64
        var segmentId: String?
        var sumSquares: Double = 0.0
        var sampleCount: Int = 0
        var hasGap = false
        var suppressed = false
        var maxSampleIndex: UInt64?

        init(timeMs: Int64, segmentId: String?) {
            self.timeMs = timeMs
            self.segmentId = segmentId
        }
    }

    private var pending: [Entry] = []
    private var buckets: [Int64: BarAccum] = [:]
    private var activeTask: Task<Void, Never>?
    private var idleTickTask: Task<Void, Never>?
    private var wakeups: AsyncStream<Void>.Continuation?

    /// Whether the phone currently believes the watch is capturing — the same claim the status
    /// card makes. While it holds, seconds with no audio in them are the silence the watch
    /// deliberately skipped, so they are drawn (faintly) rather than left blank.
    private var streamLive = false
    /// How far the live-silence fill has been laid down. nil = nothing filled yet, so the fill
    /// starts at NOW and never invents a past nobody was watching.
    private var silenceFillCursorMs: Int64?

    /// Latest published bars, oldest first (the Kotlin `StateFlow.value`).
    public private(set) var bars: [WaveformBar] = []
    private var barsContinuations: [UUID: AsyncStream<[WaveformBar]>.Continuation] = [:]

    /// Live updates for the UI; each subscriber immediately receives the current value.
    public func barsUpdates() -> AsyncStream<[WaveformBar]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            barsContinuations[id] = continuation
            continuation.yield(bars)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeBarsContinuation(id) }
            }
        }
    }

    private func removeBarsContinuation(_ id: UUID) {
        barsContinuations.removeValue(forKey: id)
    }

    /// Called from the receive path; cheap (no decode).
    ///
    /// A notification carries audio the watch had ALREADY captured, so the batch is laid out
    /// backwards from its arrival: the last frame is "now" and the earlier ones sit behind it.
    /// Laying it forwards instead dated audio into the future, which pushed `trimBuckets`'
    /// edge past now and quietly shortened the window — and during a catch-up drain (the watch
    /// clears a spool at up to ~8x real time) it dated a whole minute of audio minutes ahead,
    /// collapsing it all into the newest slot. Backwards is also the convention gaps already
    /// follow, so a gap and the frames around it land on one consistent axis.
    public func onFrames(segmentId: String?, frames: [SegmentFrame], receivedAtMs: Int64) {
        let last = frames.count - 1
        for (index, frame) in frames.enumerated() {
            pending.append(
                Entry(
                    timeMs: receivedAtMs - Int64(last - index) * frameDurationMs,
                    segmentId: segmentId,
                    payload: frame.payload,
                    gapDurationMs: 0,
                    sampleIndex: frame.sampleIndex
                )
            )
        }
        trimPending()
        wakeups?.yield(())
    }

    /// Records a span with no received audio. `silence` = true marks voice-activity silence the
    /// watch withheld to save power: it renders as quiet (flat) bars, never as an amber gap,
    /// because no audio was lost. `silence` = false marks a genuine gap (audio that should have
    /// arrived but did not).
    public func onGap(receivedAtMs: Int64, approxDurationMs: Int64, silence: Bool = false) {
        pending.append(
            Entry(
                timeMs: receivedAtMs,
                segmentId: nil,
                payload: nil,
                gapDurationMs: min(max(approxDurationMs, barMs), windowMs),
                silenceFill: silence
            )
        )
        trimPending()
        wakeups?.yield(())
    }

    /// The Today screen activates the monitor while the waveform is visible.
    public func setActive(_ active: Bool) {
        if active {
            guard activeTask == nil else { return }
            var continuation: AsyncStream<Void>.Continuation!
            let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
            wakeups = continuation
            activeTask = Task { [weak self] in
                guard let self else { return }
                await self.trimActivationBacklog()
                await self.processPending()
                for await _ in stream {
                    if Task.isCancelled { return }
                    await self.processPending()
                }
            }
            continuation.yield(())
            // Ageing is time-driven, not data-driven: without a tick the last pass before the
            // audio stopped would be the last frame ever published, and the frozen window would
            // keep drawing as if it were the present. Only runs while the waveform is on screen.
            idleTickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: LiveAudioMonitor.idleTickMs * 1_000_000)
                    if Task.isCancelled { return }
                    await self?.wake()
                }
            }
        } else {
            wakeups?.finish()
            wakeups = nil
            activeTask?.cancel()
            activeTask = nil
            idleTickTask?.cancel()
            idleTickTask = nil
        }
    }

    /// Asks the active pass to run again. No-op when the waveform is not on screen.
    public func wake() {
        wakeups?.yield(())
    }

    /// Tells the monitor whether the stream is believed live (caller passes the same verdict the
    /// status card draws, so the row and the headline can never disagree).
    ///
    /// THIS IS WHAT MAKES THE ROW ADVANCE IN A QUIET ROOM. The watch stops sending entirely while
    /// it suppresses voice-activity silence and only reports the skipped span when speech resumes
    /// — minutes or hours later. Until then the receive path delivers nothing, so without this the
    /// waveform simply stopped growing and the person watching saw a frozen picture. While the
    /// stream is live, every bar-width with no audio in it is laid down as `suppressedSilence`:
    /// known-quiet, drawn as a faint tick, and upgraded to a gap if the watch later reports that
    /// the span was actually lost.
    public func setStreamLive(_ live: Bool) {
        guard live != streamLive else { return }
        streamLive = live
        // Restart the cursor at NOW on both edges: going live must not backfill the stretch
        // before we believed anything, and going dark must not resume where it left off.
        silenceFillCursorMs = nil
        wakeups?.yield(())
    }

    public func processPending() async {
        let batch = drainPendingBatch()
        if batch.isEmpty {
            // Extend, trim and publish even with nothing new: this is the pass that runs on the
            // idle tick, and moving the window's two edges is the whole reason that tick exists.
            settleAndPublish()
            return
        }

        let framePayloads = batch.compactMap(\.payload)
        let pcm: [Int16]
        if framePayloads.isEmpty {
            pcm = []
        } else {
            pcm = await decoder?.decode(framePayloads) ?? []
        }

        var sampleOffset = 0
        for entry in batch {
            if let payload = entry.payload {
                _ = payload
                let available = min(frameSamples, max(pcm.count - sampleOffset, 0))
                var sumSquares = 0.0
                for i in sampleOffset..<(sampleOffset + available) {
                    let sample = Double(pcm[i])
                    sumSquares += sample * sample
                }
                sampleOffset += available
                let bucket = bucket(timeMs: entry.timeMs, segmentId: entry.segmentId)
                bucket.sumSquares += sumSquares
                // When no decoder exists, count the frame anyway so presence still renders.
                bucket.sampleCount += available > 0 ? available : frameSamples
                if let sample = entry.sampleIndex {
                    bucket.maxSampleIndex = max(bucket.maxSampleIndex ?? sample, sample)
                }
            } else {
                // Gaps and skipped-silence spans are reported at their trailing edge (the
                // moment audio resumes), so fill backward across the span that just ended.
                // Filling forward would place the bars past "now", where the view — which
                // skips any bar with age < 0 — never draws them, leaving the span blank.
                var t = entry.timeMs - entry.gapDurationMs
                while t < entry.timeMs {
                    let bucket = bucket(timeMs: t, segmentId: nil)
                    // Skipped silence reads as a quiet tick; only genuine gaps get amber.
                    if entry.silenceFill { bucket.suppressed = true } else { bucket.hasGap = true }
                    t += barMs
                }
            }
        }
        settleAndPublish()
        if !pending.isEmpty { wakeups?.yield(()) }
    }

    /// One pass over the window's edges: fill the live trailing silence, drop what has aged out,
    /// publish. Every path that changes the buckets ends here so the row always spans the same
    /// `windowMs` ending at NOW.
    private func settleAndPublish() {
        extendLiveSilence()
        trimBuckets()
        publishBars()
    }

    /// Lays `suppressedSilence` over every bar-width from the fill cursor up to NOW that no audio
    /// has landed in. Buckets, not display-time synthesis: a span we believed was quiet stays
    /// drawn as quiet after the link drops, and a gap record arriving later for the same span
    /// still overrides it (`hasGap` outranks `suppressed` in `publishBars`).
    private func extendLiveSilence() {
        guard streamLive else { return }
        let now = nowMs()
        // Clamped to the window: a long stretch off-screen backfills one window at most, never a
        // whole afternoon of ticks nobody could have seen.
        var t = max(silenceFillCursorMs ?? now, now - windowMs)
        while t <= now {
            bucket(timeMs: t, segmentId: nil).suppressed = true
            t += barMs
        }
        silenceFillCursorMs = now
    }

    private func drainPendingBatch() -> [Entry] {
        var snapshot: [Entry] = []
        var decodeFrames = 0
        while let entry = pending.first {
            if !snapshot.isEmpty {
                if snapshot.count >= maxDecodeFramesPerPass * 2 { break }
                if entry.payload != nil && decodeFrames >= maxDecodeFramesPerPass { break }
            }
            let removed = pending.removeFirst()
            snapshot.append(removed)
            if removed.payload != nil { decodeFrames += 1 }
        }
        return snapshot
    }

    private func bucket(timeMs: Int64, segmentId: String?) -> BarAccum {
        let key = timeMs / barMs
        let accum: BarAccum
        if let existing = buckets[key] {
            accum = existing
        } else {
            accum = BarAccum(timeMs: key * barMs, segmentId: segmentId)
            buckets[key] = accum
        }
        if segmentId != nil { accum.segmentId = segmentId }
        return accum
    }

    private func trimPending() {
        guard let newest = pending.last?.timeMs else { return }
        while let first = pending.first, first.timeMs < newest - windowMs {
            pending.removeFirst()
        }
    }

    private func trimActivationBacklog() {
        var payloadCount = pending.lazy.filter { $0.payload != nil }.count
        while payloadCount > maxActivationCatchUpFrames && !pending.isEmpty {
            if pending.removeFirst().payload != nil {
                payloadCount -= 1
            }
        }
    }

    /// Drops everything older than one window before NOW.
    ///
    /// This used to trim relative to the newest bucket, which meant the window moved only when
    /// audio arrived: the moment the watch stopped sending, the last minute of bars froze in place
    /// and kept drawing — a still, green, minute-old waveform sitting under the word "Recording"
    /// for as long as the screen was open. Wall-clock now is the honest edge, so a stream that
    /// stops drains instead of freezing.
    ///
    /// `max` with the newest bucket, not `nowMs()` alone, because received-at timestamps and the
    /// injected clock are allowed to run slightly apart (and in tests deliberately do); audio we
    /// have actually been given must never be trimmed for arriving "in the future".
    private func trimBuckets() {
        let newest = buckets.values.map(\.timeMs).max()
        guard let edge = [nowMs(), newest].compactMap({ $0 }).max() else { return }
        buckets = buckets.filter { $0.value.timeMs >= edge - windowMs }
    }

    private func publishBars() {
        let snapshot = buckets.values.sorted { $0.timeMs < $1.timeMs }
        bars = snapshot.map { accum in
            let rms = accum.sampleCount > 0 ? (accum.sumSquares / Double(accum.sampleCount)).squareRoot() : 0.0
            let state: WaveformBarState
            if accum.hasGap {
                state = .gap
            } else if accum.suppressed && accum.sampleCount == 0 {
                // Skipped silence, but only if no real audio also landed in this bucket.
                state = .suppressedSilence
            } else if rms < Self.silenceRMS {
                state = .silence
            } else {
                state = .recorded
            }
            return WaveformBar(
                timeMs: accum.timeMs,
                amplitude: Self.displayAmplitude(rms),
                state: state,
                segmentId: accum.segmentId,
                maxSampleIndex: accum.maxSampleIndex
            )
        }
        for continuation in barsContinuations.values {
            continuation.yield(bars)
        }
    }

    // MARK: - Display mapping (Kotlin companion object)

    /// How often the active monitor re-publishes with nothing new, so the window ages against
    /// wall-clock now. One bar's worth: the drain is smooth and costs one trim + one publish.
    static let idleTickMs: UInt64 = 250

    /// Below this RMS (16-bit full scale 32767) a bar renders as detected silence.
    public static let silenceRMS = 90.0

    private static let displayLoudRMS = 8_000.0
    private static let displayMinRecordedAmplitude = 0.08

    /// Watch speech can decode to low PCM levels after Speex. Map RMS on a dB-like curve so
    /// speech just above quiet is visible without flattening quiet, normal, and loud speech
    /// into nearly the same bar height.
    public static func displayAmplitude(_ rms: Double) -> Float {
        if rms <= 0.0 { return 0 }
        var normalized = log(max(rms, silenceRMS) / silenceRMS) / log(displayLoudRMS / silenceRMS)
        normalized = min(max(normalized, 0.0), 1.0)
        return Float(displayMinRecordedAmplitude + (1.0 - displayMinRecordedAmplitude) * pow(normalized, 1.5))
    }
}
