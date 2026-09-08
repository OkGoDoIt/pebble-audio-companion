import Foundation

// Port of `app/.../SegmentPlayback.kt`.

/// Platform PCM playback sink: 16 kHz mono signed 16-bit. `write` provides pacing — it must not
/// return until the device can accept more audio, which is what bounds decode-ahead memory.
public protocol PcmAudioPlayer: Sendable {
    func start(sampleRateHz: Int)
    func write(_ pcm: [Int16]) async
    func setSpeed(_ speed: Float)
    func stop()
    /// Drops audio already handed over but not yet heard, without ending playback.
    ///
    /// The pacing contract means the player is holding up to `maxBuffersInFlight` batches — a
    /// couple of seconds — at any moment. Seeking without dropping them plays those seconds of
    /// the OLD position first, which is why tapping a word used to arrive somewhere else.
    func flush()
}

extension PcmAudioPlayer {
    /// A player with no queue of its own has nothing to drop.
    public func flush() {}
}

public struct PlaybackUiState: Sendable, Equatable {
    public var segmentId: String?
    public var playing: Bool
    /// Media position within the stored audio (gaps excluded), not wall time.
    public var positionMs: Int64
    public var durationMs: Int64
    public var speed: Float

    public init(
        segmentId: String? = nil,
        playing: Bool = false,
        positionMs: Int64 = 0,
        durationMs: Int64 = 0,
        speed: Float = 1
    ) {
        self.segmentId = segmentId
        self.playing = playing
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.speed = speed
    }
}

/// Segment playback with scrubbing and speed control (MVP requirement; ux plan Section 9).
///
/// Decode is chunked — `batchFrames` encoded frames at a time — never the whole segment in
/// memory. Seeking is frame-accurate because the firmware resets the Speex bitstream per frame,
/// so any frame is independently decodable.
///
/// The Kotlin class guarded state with `StateFlow` + `@Volatile`; here a lock guards the same
/// fields and the playback loop runs in one Task.
///
/// ## The position it publishes is what you can HEAR
///
/// This used to publish the decode position — the end of the batch it had just handed to the
/// player — which is not where the audio is. The player holds four 500 ms batches, so the
/// published position ran a full **two seconds** ahead of the speaker, and it only moved once
/// per batch. That is invisible on a scrubber and fatal to a transcript that highlights the word
/// being spoken: the highlight would sit two sentences ahead of the voice, which is worse than
/// no highlight at all.
///
/// So the position is now anchored: when the first batch after a start or a seek is handed over,
/// the media position of that batch and the wall-clock instant are recorded, and the position is
/// read off a monotonic clock from there (times `speed`, because the rate unit pulls source
/// audio proportionally faster). It is clamped to what has actually been scheduled, so a decoder
/// that falls behind stalls the position instead of running away from the audio. Accuracy is
/// then the engine's own start latency, tens of milliseconds rather than two seconds.
public final class SegmentPlaybackController: @unchecked Sendable {
    /// 25 frames = 500 ms of audio decoded per batch.
    public static let batchFrames = 25
    /// How often the position is republished while playing. Fast enough to follow individual
    /// words, slow enough that a transcript is not re-diffed on every display frame.
    static let tickIntervalMs = 80

    private let playerFactory: @Sendable () -> PcmAudioPlayer
    private let decoder: LiveFrameDecoder?
    /// Encoded frame payloads of a segment, in order (from the durable frame log).
    private let frameSource: @Sendable (String) -> [[UInt8]]
    private let frameDurationMs: Int64
    private let sampleRateHz: Int

    private let lock = NSLock()
    private var _state = PlaybackUiState()
    private var stateContinuations: [UUID: AsyncStream<PlaybackUiState>.Continuation] = [:]
    private var loopTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var seekFrameRequest: Int = -1
    private var currentPlayer: PcmAudioPlayer?
    /// Media time handed to the player so far — the ceiling on what can possibly be audible.
    private var scheduledMs: Int64 = 0
    /// Media position of the first sample the player started playing after the last start or
    /// seek, and the instant it went in. Nil until that first batch is accepted.
    private var anchorMediaMs: Int64 = 0
    private var anchorAt: ContinuousClock.Instant?

    public init(
        playerFactory: @escaping @Sendable () -> PcmAudioPlayer,
        decoder: LiveFrameDecoder?,
        frameSource: @escaping @Sendable (String) -> [[UInt8]],
        frameDurationMs: Int64 = 20,
        sampleRateHz: Int = 16_000
    ) {
        self.playerFactory = playerFactory
        self.decoder = decoder
        self.frameSource = frameSource
        self.frameDurationMs = frameDurationMs
        self.sampleRateHz = sampleRateHz
    }

    /// Current state (the Kotlin `StateFlow.value`).
    public var state: PlaybackUiState { lock.withLock { _state } }

    /// Live state updates for the UI; each subscriber immediately receives the current value.
    public func stateUpdates() -> AsyncStream<PlaybackUiState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock {
                stateContinuations[id] = continuation
                continuation.yield(_state)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.stateContinuations.removeValue(forKey: id) }
            }
        }
    }

    private func updateState(_ transform: (inout PlaybackUiState) -> Void) {
        let (snapshot, continuations): (PlaybackUiState, [AsyncStream<PlaybackUiState>.Continuation])
        lock.lock()
        transform(&_state)
        snapshot = _state
        continuations = Array(stateContinuations.values)
        lock.unlock()
        for continuation in continuations { continuation.yield(snapshot) }
    }

    /// Starts (or resumes) playback of `segmentId` from the current position.
    public func play(_ segmentId: String) {
        let current = state
        let startMs = current.segmentId == segmentId ? current.positionMs : 0
        startLoop(segmentId, startMs: startMs)
    }

    public func pause() {
        // Freeze where the AUDIO is, not where decoding got to: resuming used to skip the two
        // seconds the player was still holding, so pause-then-play silently ate a sentence.
        let heard = audiblePositionMs()
        stopLoop()
        updateState {
            $0.playing = false
            $0.positionMs = heard
        }
    }

    public func stop() {
        stopLoop()
        updateState { $0 = PlaybackUiState(speed: $0.speed) }
    }

    public func seekTo(_ segmentId: String, positionMs: Int64) {
        let frame = max(Int(positionMs / frameDurationMs), 0)
        let target = Int64(frame) * frameDurationMs
        let current = state
        if current.playing && current.segmentId == segmentId {
            lock.withLock {
                seekFrameRequest = frame
                // Re-anchor now so the position stops advancing from the OLD point while the
                // loop is still finishing the batch it is on.
                anchorMediaMs = target
                anchorAt = nil
                scheduledMs = target
            }
            // The player is NOT flushed here, deliberately: the scrubber seeks continuously
            // while it is dragged, and `flush()` stops and restarts the player node, so
            // flushing per gesture frame would chop the audio to pieces. The loop flushes once,
            // when it picks the request up — which costs about half a second of the old
            // position before the new one is heard, instead of the two seconds the player was
            // holding before this existed.
            updateState { $0.positionMs = target }
        } else {
            updateState {
                $0.segmentId = segmentId
                $0.positionMs = target
            }
        }
    }

    public func cycleSpeed() {
        let next: Float
        switch state.speed {
        case 1: next = 1.5
        case 1.5: next = 2
        default: next = 1
        }
        // The rate unit applies to audio already queued, so the change is audible immediately;
        // re-anchor at the current position so the clock counts the new rate from here.
        let heard = audiblePositionMs()
        let player = lock.withLock { () -> PcmAudioPlayer? in
            if _state.playing {
                anchorMediaMs = heard
                anchorAt = ContinuousClock.now
            }
            return currentPlayer
        }
        updateState { $0.speed = next }
        player?.setSpeed(next)
    }

    // MARK: - The audible clock

    /// Where the audio actually is, as opposed to where decoding got to.
    private func audiblePositionMs() -> Int64 {
        lock.lock()
        let anchor = anchorMediaMs
        let at = anchorAt
        let scheduled = scheduledMs
        let speed = Double(_state.speed)
        let duration = _state.durationMs
        lock.unlock()
        let ceiling = duration > 0 ? min(scheduled, duration) : scheduled
        guard let at else { return min(max(anchor, 0), max(ceiling, 0)) }
        let advanced = anchor + Int64(Double(Self.elapsedMs(since: at)) * speed)
        return min(max(advanced, 0), max(ceiling, 0))
    }

    private func publishPosition() {
        let position = audiblePositionMs()
        // The still-playing check and the write happen under ONE lock: a tick that raced the
        // end of the loop would otherwise land its position on top of the final state, leaving
        // a stopped player reporting a position it never reached.
        var snapshot: PlaybackUiState?
        var continuations: [AsyncStream<PlaybackUiState>.Continuation] = []
        lock.lock()
        if _state.playing, _state.positionMs != position {
            _state.positionMs = position
            snapshot = _state
            continuations = Array(stateContinuations.values)
        }
        lock.unlock()
        guard let snapshot else { return }
        for continuation in continuations { continuation.yield(snapshot) }
    }

    private static func elapsedMs(since instant: ContinuousClock.Instant) -> Int64 {
        let components = (ContinuousClock.now - instant).components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }

    private func startLoop(_ segmentId: String, startMs: Int64) {
        stopLoop()
        let frames = frameSource(segmentId)
        let durationMs = Int64(frames.count) * frameDurationMs
        guard !frames.isEmpty, let decoder else {
            updateState {
                $0.segmentId = segmentId
                $0.playing = false
                $0.durationMs = durationMs
            }
            return
        }
        let startFrame = min(max(Int(startMs / frameDurationMs), 0), frames.count - 1)
        updateState {
            $0.segmentId = segmentId
            $0.playing = true
            $0.positionMs = Int64(startFrame) * frameDurationMs
            $0.durationMs = durationMs
        }
        lock.withLock {
            seekFrameRequest = -1
            anchorMediaMs = Int64(startFrame) * frameDurationMs
            anchorAt = nil
            scheduledMs = anchorMediaMs
        }
        loopTask = Task { [weak self] in
            guard let self else { return }
            let player = self.playerFactory()
            self.lock.withLock { self.currentPlayer = player }
            player.start(sampleRateHz: self.sampleRateHz)
            player.setSpeed(self.state.speed)
            var completed = false
            defer {
                // Before anything else: the ticker must not republish a position on top of the
                // final state this is about to write.
                self.stopTicker()
                self.lock.withLock {
                    self.currentPlayer = nil
                    self.anchorAt = nil
                }
                player.stop()
                self.updateState {
                    $0.playing = false
                    if completed { $0.positionMs = 0 }
                }
            }
            var currentFrames = frames
            var index = startFrame
            while index < currentFrames.count {
                if Task.isCancelled { return }
                let requested = self.lock.withLock { () -> Int in
                    let value = self.seekFrameRequest
                    if value >= 0 { self.seekFrameRequest = -1 }
                    return value
                }
                if requested >= 0 {
                    index = min(max(requested, 0), currentFrames.count - 1)
                    // Everything the player is still holding belongs to the old position.
                    player.flush()
                    self.lock.withLock {
                        self.anchorMediaMs = Int64(index) * self.frameDurationMs
                        self.anchorAt = nil
                        self.scheduledMs = self.anchorMediaMs
                    }
                }
                let batchStart = index
                let end = min(index + Self.batchFrames, currentFrames.count)
                let pcm = await decoder.decode(Array(currentFrames[index..<end]))
                if Task.isCancelled { return }
                await player.write(pcm)
                if Task.isCancelled { return }
                index = end
                self.lock.withLock {
                    // The first batch accepted after a start or a seek is the one whose first
                    // sample is about to be heard: that is the anchor the clock counts from.
                    if self.anchorAt == nil {
                        self.anchorMediaMs = Int64(batchStart) * self.frameDurationMs
                        self.anchorAt = ContinuousClock.now
                    }
                    self.scheduledMs = Int64(index) * self.frameDurationMs
                }
                self.startTicker()
                self.publishPosition()
                if index >= currentFrames.count {
                    // An open (still recording) segment may have stored more audio while
                    // we played: pick it up so replay can follow the live tail.
                    let refreshed = self.frameSource(segmentId)
                    if refreshed.count > currentFrames.count {
                        currentFrames = refreshed
                        let newDuration = Int64(currentFrames.count) * self.frameDurationMs
                        self.updateState { $0.durationMs = newDuration }
                    }
                }
            }
            completed = true
        }
    }

    /// Republishes the position between batches, so the scrubber and the transcript highlight
    /// move continuously instead of once every 500 ms. Started only once audio is actually
    /// flowing, and idempotent.
    private func startTicker() {
        let alreadyRunning = lock.withLock { tickTask != nil }
        guard !alreadyRunning else { return }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.tickIntervalMs))
                guard let self, !Task.isCancelled else { return }
                self.publishPosition()
            }
        }
        let stale = lock.withLock { () -> Task<Void, Never>? in
            guard tickTask == nil else { return task }
            tickTask = task
            return nil
        }
        stale?.cancel()
    }

    private func stopTicker() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let value = tickTask
            tickTask = nil
            return value
        }
        task?.cancel()
    }

    private func stopLoop() {
        stopTicker()
        loopTask?.cancel()
        loopTask = nil
        let player = lock.withLock { () -> PcmAudioPlayer? in
            let value = currentPlayer
            currentPlayer = nil
            anchorAt = nil
            return value
        }
        player?.stop()
    }
}
