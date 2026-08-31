import Foundation

// Port of `app/.../SegmentPlayback.kt`.

/// Platform PCM playback sink: 16 kHz mono signed 16-bit. `write` provides pacing — it must not
/// return until the device can accept more audio, which is what bounds decode-ahead memory.
public protocol PcmAudioPlayer: Sendable {
    func start(sampleRateHz: Int)
    func write(_ pcm: [Int16]) async
    func setSpeed(_ speed: Float)
    func stop()
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
public final class SegmentPlaybackController: @unchecked Sendable {
    /// 25 frames = 500 ms of audio decoded per batch.
    public static let batchFrames = 25

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
    private var seekFrameRequest: Int = -1
    private var currentPlayer: PcmAudioPlayer?

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
        stopLoop()
        updateState { $0.playing = false }
    }

    public func stop() {
        stopLoop()
        updateState { $0 = PlaybackUiState(speed: $0.speed) }
    }

    public func seekTo(_ segmentId: String, positionMs: Int64) {
        let frame = max(Int(positionMs / frameDurationMs), 0)
        let current = state
        if current.playing && current.segmentId == segmentId {
            lock.withLock { seekFrameRequest = frame }
        } else {
            updateState {
                $0.segmentId = segmentId
                $0.positionMs = Int64(frame) * frameDurationMs
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
        updateState { $0.speed = next }
        lock.withLock { currentPlayer }?.setSpeed(next)
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
        lock.withLock { seekFrameRequest = -1 }
        loopTask = Task { [weak self] in
            guard let self else { return }
            let player = self.playerFactory()
            self.lock.withLock { self.currentPlayer = player }
            player.start(sampleRateHz: self.sampleRateHz)
            player.setSpeed(self.state.speed)
            var completed = false
            defer {
                self.lock.withLock { self.currentPlayer = nil }
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
                }
                let end = min(index + Self.batchFrames, currentFrames.count)
                let pcm = await decoder.decode(Array(currentFrames[index..<end]))
                if Task.isCancelled { return }
                await player.write(pcm)
                if Task.isCancelled { return }
                index = end
                self.updateState { $0.positionMs = Int64(index) * self.frameDurationMs }
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

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
        let player = lock.withLock { () -> PcmAudioPlayer? in
            let value = currentPlayer
            currentPlayer = nil
            return value
        }
        player?.stop()
    }
}
