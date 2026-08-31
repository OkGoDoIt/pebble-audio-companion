#if canImport(AVFoundation)
    import AVFoundation
    import Foundation

    /// AVFoundation-backed `PcmAudioPlayer`: an `AVAudioEngine` graph of
    /// player node → time-pitch (rate control, pitch preserved) → main mixer, fed with decoded
    /// PCM16 chunks converted to the engine's float format.
    ///
    /// Pacing contract: at most `maxBuffersInFlight` scheduled buffers; `write` suspends until a
    /// slot frees (each slot is ~500 ms of audio from the controller's decode batch), which is
    /// what bounds decode-ahead memory.
    public final class AVFoundationPcmPlayer: PcmAudioPlayer, @unchecked Sendable {
        private let lock = NSLock()
        private var engine: AVAudioEngine?
        private var node: AVAudioPlayerNode?
        private var timePitch: AVAudioUnitTimePitch?
        private var format: AVAudioFormat?
        private var pendingSpeed: Float = 1
        private var inFlight = 0
        private var slotWaiters: [CheckedContinuation<Void, Never>] = []
        private var stopped = true
        private let maxBuffersInFlight: Int

        public init(maxBuffersInFlight: Int = 4) {
            self.maxBuffersInFlight = max(maxBuffersInFlight, 1)
        }

        public func start(sampleRateHz: Int) {
            stop()
            guard
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(sampleRateHz),
                    channels: 1,
                    interleaved: false)
            else { return }
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            let timePitch = AVAudioUnitTimePitch()
            engine.attach(node)
            engine.attach(timePitch)
            engine.connect(node, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            #if os(iOS)
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            do {
                try engine.start()
            } catch {
                return  // write() stays a no-op; the controller finishes without audio.
            }
            node.play()
            lock.withLock {
                self.engine = engine
                self.node = node
                self.timePitch = timePitch
                self.format = format
                timePitch.rate = pendingSpeed
                inFlight = 0
                stopped = false
            }
        }

        public func write(_ pcm: [Int16]) async {
            guard !pcm.isEmpty else { return }
            let (node, format): (AVAudioPlayerNode?, AVAudioFormat?) = lock.withLock {
                (self.node, self.format)
            }
            guard let node, let format,
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count))
            else { return }
            buffer.frameLength = AVAudioFrameCount(pcm.count)
            if let channel = buffer.floatChannelData?[0] {
                for i in 0..<pcm.count {
                    channel[i] = Float(pcm[i]) / Float(Int16.max)
                }
            }

            await waitForSlot()
            let shouldSchedule = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                inFlight += 1
                return true
            }
            guard shouldSchedule else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                    self?.releaseSlot()
                }
                continuation.resume()
            }
        }

        private func waitForSlot() async {
            while true {
                let mustWait = lock.withLock { !stopped && inFlight >= maxBuffersInFlight }
                guard mustWait else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if stopped || inFlight < maxBuffersInFlight {
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    slotWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        private func releaseSlot() {
            let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                inFlight = max(inFlight - 1, 0)
                let value = slotWaiters
                slotWaiters = []
                return value
            }
            for waiter in waiters { waiter.resume() }
        }

        public func setSpeed(_ speed: Float) {
            lock.withLock {
                pendingSpeed = speed
                timePitch?.rate = speed
            }
        }

        public func stop() {
            let (engine, node, waiters): (AVAudioEngine?, AVAudioPlayerNode?, [CheckedContinuation<Void, Never>]) =
                lock.withLock {
                    stopped = true
                    let value = (self.engine, self.node, slotWaiters)
                    self.engine = nil
                    self.node = nil
                    self.timePitch = nil
                    self.format = nil
                    slotWaiters = []
                    inFlight = 0
                    return value
                }
            node?.stop()
            engine?.stop()
            for waiter in waiters { waiter.resume() }
        }
    }
#endif
