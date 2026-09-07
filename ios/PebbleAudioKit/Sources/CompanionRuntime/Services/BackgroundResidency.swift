import Foundation
import Receiver

#if canImport(AVFoundation) && os(iOS)
    import AVFoundation
#endif

/// Keeps the process resident while the user has capture turned on.
///
/// WHY THIS EXISTS — the single defect behind "it barely records anything unless I'm in the app".
///
/// With only `bluetooth-central` declared, iOS suspends this app between Core Bluetooth events and
/// grants it roughly ten seconds of runtime per wake. Suspension freezes every timer in the
/// process: the session's 5 s keepalive, its 20 s stream-verify, the link's reconnect backoff, the
/// checkpoint stall-breaker. That would merely delay recovery — except the watch is not passive
/// about it. `RECEIVER_LIVENESS_TIMEOUT_MS` in the firmware is 15 s: a streaming watch that hears
/// no control message from us for fifteen seconds concludes the receiver is gone, STOPS THE
/// MICROPHONE and falls back to AuthorizedIdle. A suspended app cannot send that message, so the
/// two ends deadlock — the watch is silent because it stopped capturing, and we stay suspended
/// because a suspended `bluetooth-central` app is only ever woken BY the traffic that stopped.
/// Nothing breaks the tie until the user opens the app, which is exactly what they observed.
///
/// The fix is residency, not a faster timer: an app holding an active `AVAudioSession` under the
/// `audio` background mode is not suspended at all. It stays in the background *running*, so every
/// existing timer keeps its cadence and the keepalive re-arms the watch's watchdog on time.
///
/// The recipe, and why each part is load-bearing:
///   - Category `.playback`. The only category that keeps running with the screen locked.
///     `.playAndRecord` would work too but demands microphone permission and lights the orange
///     recording indicator — for audio this app never records on the phone.
///   - Option `.mixWithOthers`. Without it, activating the session pauses the user's music the
///     moment capture is enabled, forever. With it we are inaudible and harmless.
///   - A continuously rendering graph. An active session that stops producing samples is torn down
///     by the system; the buffer below is scheduled on a loop so the graph never runs dry.
///   - Interruption, route-change and media-services-reset handling. Each of these silently kills
///     the session, and a dead session means silent re-suspension with nothing to notice it. After
///     a media-services reset every audio object is invalid and must be rebuilt from scratch
///     (Apple QA1749), which is why `restart()` discards the engine rather than restarting it.
///
/// Honest about the limits, because the status UI must not overclaim:
///   - This does not survive a user force-quit; nothing does except AccessorySetupKit on iOS 26.
///   - This does not prevent a memory jettison; Bluetooth state restoration relaunches us after
///     one.
///   - It costs battery. That is why it is tied to capture intent and released the moment the
///     user turns Background Audio off.
public final class BackgroundResidency: @unchecked Sendable {
    /// Why residency is or is not held — surfaced in Diagnostics so a silent failure is visible.
    public enum State: String, Sendable, Equatable {
        /// The user has capture off; residency is deliberately not held.
        case notNeeded
        /// Session active and the graph is rendering: the process will not be suspended.
        case held
        /// Wanted, but the audio stack refused. The app will be suspended between BLE wakes.
        case failed
        /// Wanted, and temporarily surrendered to a phone call or another interruption.
        case interrupted
    }

    public let state = StateSubject<State>(.notNeeded)

    private let log: RuntimeLog
    private let lock = NSLock()
    private var wanted = false
    private var observing = false

    #if canImport(AVFoundation) && os(iOS)
        private var engine: AVAudioEngine?
        private var player: AVAudioPlayerNode?
        private var tokens: [NSObjectProtocol] = []
    #endif

    public init(log: RuntimeLog = .silent) {
        self.log = log
    }

    /// The user's capture intent, mapped onto residency. Idempotent, and safe from any thread.
    public func setWanted(_ value: Bool) {
        let changed: Bool = lock.withLock {
            guard wanted != value else { return false }
            wanted = value
            return true
        }
        guard changed else { return }
        log.write("background residency \(value ? "requested" : "released")")
        if value {
            startObserving()
            acquire()
        } else {
            release()
        }
    }

    /// Re-asserts the session after something else in the app reconfigured it.
    ///
    /// `AVFoundationPcmPlayer` sets its own category for segment playback and never puts it back.
    /// Without this, playing one recording would drop `.mixWithOthers` for the rest of the process
    /// — every later launch of the user's music would be silenced by us.
    public func reassertAfterForeignSessionUse() {
        guard lock.withLock({ wanted }) else { return }
        acquire()
    }

    // MARK: - AVAudioSession

    #if canImport(AVFoundation) && os(iOS)
        private func acquire() {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true, options: [])
            } catch {
                log.write("background residency session failed: \(error)")
                state.value = .failed
                return
            }
            guard startEngine() else {
                state.value = .failed
                return
            }
            state.value = .held
            log.write("background residency held (playback + mixWithOthers)")
        }

        private func release() {
            stopEngine()
            // Deactivating tells the system we are done; `.notifyOthersOnDeactivation` lets a
            // paused app resume. Failing here is not worth surfacing: the engine is already down,
            // so we are no longer resident either way.
            try? AVAudioSession.sharedInstance().setActive(
                false, options: [.notifyOthersOnDeactivation]
            )
            state.value = .notNeeded
            log.write("background residency released")
        }

        /// Builds the silent graph. Returns false if the audio stack refused to start.
        private func startEngine() -> Bool {
            stopEngine()
            guard
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 48_000,
                    channels: 1,
                    interleaved: false
                ),
                let buffer = Self.makeKeepAliveBuffer(format: format)
            else {
                log.write("background residency could not build its buffer")
                return false
            }
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            // Belt and braces: the buffer is already inaudible, and the mixer takes it to zero.
            engine.mainMixerNode.outputVolume = 0
            do {
                try engine.start()
            } catch {
                log.write("background residency engine failed: \(error)")
                return false
            }
            player.scheduleBuffer(buffer, at: nil, options: [.loops])
            player.play()
            lock.withLock {
                self.engine = engine
                self.player = player
            }
            return true
        }

        private func stopEngine() {
            let (engine, player): (AVAudioEngine?, AVAudioPlayerNode?) = lock.withLock {
                let pair = (self.engine, self.player)
                self.engine = nil
                self.player = nil
                return pair
            }
            player?.stop()
            engine?.stop()
        }

        /// One second of effectively-silent audio.
        ///
        /// Deliberately not pure zeros. A graph rendering nothing but zeros is a shape the system
        /// is free to treat as "not actually playing audio", and the whole mechanism rests on the
        /// session staying alive. A dither one LSB wide at 16-bit scale is ~-90 dBFS: below the
        /// noise floor of any speaker, inaudible under `.mixWithOthers`, and unambiguously a
        /// running audio graph.
        private static func makeKeepAliveBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
            let frames = AVAudioFrameCount(format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                return nil
            }
            buffer.frameLength = frames
            guard let channel = buffer.floatChannelData?[0] else { return nil }
            let amplitude = Float(1) / Float(Int16.max)
            for index in 0..<Int(frames) {
                channel[index] = index % 2 == 0 ? amplitude : -amplitude
            }
            return buffer
        }

        // MARK: - The three ways a session dies silently

        private func startObserving() {
            let first: Bool = lock.withLock {
                guard !observing else { return false }
                observing = true
                return true
            }
            guard first else { return }
            let center = NotificationCenter.default
            let session = AVAudioSession.sharedInstance()
            var registered: [NSObjectProtocol] = []

            registered.append(
                center.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: session, queue: nil
                ) { [weak self] note in
                    self?.handleInterruption(note)
                })

            registered.append(
                center.addObserver(
                    forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                    queue: nil
                ) { [weak self] _ in
                    guard let self else { return }
                    // Every audio object in the process is invalid now (QA1749). Rebuild, do not
                    // restart: a stale engine handed back a running session is a session that is
                    // not actually rendering, and we would be suspended without noticing.
                    self.log.write("background residency: media services were reset; rebuilding")
                    guard self.lock.withLock({ self.wanted }) else { return }
                    self.acquire()
                })

            registered.append(
                center.addObserver(
                    forName: AVAudioSession.routeChangeNotification, object: session, queue: nil
                ) { [weak self] _ in
                    guard let self, self.lock.withLock({ self.wanted }) else { return }
                    // A route change can stop the engine (unplugging, a Bluetooth speaker
                    // leaving). Cheap to re-check, and invisible when nothing is wrong.
                    let running = self.lock.withLock { self.engine?.isRunning ?? false }
                    if !running {
                        self.log.write("background residency: route change stopped the engine")
                        self.acquire()
                    }
                })

            lock.withLock { tokens = registered }
        }

        private func handleInterruption(_ note: Notification) {
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            switch type {
            case .began:
                // A phone call or another app took the session. We are suspendable again until it
                // ends, and the status layer should be able to say so.
                log.write("background residency interrupted")
                state.value = .interrupted
            case .ended:
                guard lock.withLock({ wanted }) else { return }
                // `.shouldResume` is advisory and frequently absent for a mixing session. Residency
                // is not media playback the user asked for, so re-acquire either way.
                log.write("background residency interruption ended; re-acquiring")
                acquire()
            @unknown default:
                break
            }
        }
    #else
        // macOS/test builds: the kit's tests run on the host, where there is nothing to keep
        // resident. The state still moves so the lifecycle tests can assert the wiring.
        private func acquire() { state.value = .held }
        private func release() { state.value = .notNeeded }
        private func startObserving() {}
    #endif
}
