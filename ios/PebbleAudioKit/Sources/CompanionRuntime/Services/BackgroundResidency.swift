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
///   - Audio that keeps playing. An active session that stops producing samples is torn down by
///     the system, so a tiny buffer loops forever. It is an `AVAudioPlayer`, NOT an
///     `AVAudioEngine`: an engine runs a real-time render thread inside THIS process, waking about
///     two hundred times a second for as long as residency is held, and that is what made the
///     phone hot. A looping player hands the work to the media server instead.
///   - Interruption, route-change and media-services-reset handling. Each of these silently kills
///     the session, and a dead session means silent re-suspension with nothing to notice it. After
///     a media-services reset every audio object is invalid and must be rebuilt from scratch
///     (Apple QA1749), which is why the reset handler rebuilds rather than restarts.
///
/// Honest about the limits, because the status UI must not overclaim:
///   - This does not survive a user force-quit; nothing does except AccessorySetupKit on iOS 26.
///   - This does not prevent a memory jettison; Bluetooth state restoration relaunches us after
///     one.
///   - It costs battery, so it is held as narrowly as possible: only while the watch is ACTUALLY
///     STREAMING, not merely while capture is enabled. See `ReceiverService.syncResidency` — the
///     watch's liveness watchdog runs only in its Streaming state, so any other state is one where
///     being suspended costs nothing and a BLE notification wakes us again.
public final class BackgroundResidency: @unchecked Sendable {
    /// Why residency is or is not held — surfaced in Diagnostics so a silent failure is visible.
    public enum State: String, Sendable, Equatable {
        /// Nothing is streaming; residency is deliberately not held.
        case notNeeded
        /// Session active and audio is playing: the process will not be suspended.
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
        private var player: AVAudioPlayer?
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
            guard startPlayer() else {
                state.value = .failed
                return
            }
            state.value = .held
            log.write("background residency held (playback + mixWithOthers)")
        }

        private func release() {
            stopPlayer()
            // Deactivating tells the system we are done; `.notifyOthersOnDeactivation` lets a
            // paused app resume. Failing here is not worth surfacing: the engine is already down,
            // so we are no longer resident either way.
            try? AVAudioSession.sharedInstance().setActive(
                false, options: [.notifyOthersOnDeactivation]
            )
            state.value = .notNeeded
            log.write("background residency released")
        }

        /// Starts the keep-alive audio. Returns false if the audio stack refused.
        ///
        /// An `AVAudioPlayer` looping a tiny buffer, NOT an `AVAudioEngine` graph. The first
        /// version used an engine with a player node wired to the main mixer, and that is what
        /// made the phone hot: an engine runs a real-time render thread INSIDE THIS PROCESS,
        /// waking at the hardware buffer period — roughly two hundred times a second — for as long
        /// as residency is held. Rendering silence is not free when you render it yourself.
        ///
        /// `AVAudioPlayer` hands a looping buffer to the media server and our process does nothing
        /// at all between BLE events. The audio session stays active, which is the entire
        /// requirement for not being suspended.
        private func startPlayer() -> Bool {
            stopPlayer()
            do {
                let player = try AVAudioPlayer(data: BackgroundResidency.keepAliveWave)
                player.numberOfLoops = -1
                // The samples are already ~-90 dBFS, which is inaudible under `.mixWithOthers`.
                // Deliberately not zero: a stream of digital silence at zero volume is the shape
                // most likely to be treated as "not really playing audio".
                player.volume = 1
                guard player.play() else {
                    log.write("background residency player refused to start")
                    return false
                }
                lock.withLock { self.player = player }
                return true
            } catch {
                log.write("background residency player failed: \(error)")
                return false
            }
        }

        private func stopPlayer() {
            let player: AVAudioPlayer? = lock.withLock {
                let held = self.player
                self.player = nil
                return held
            }
            player?.stop()
        }

        /// One second of near-silence as a WAV, built once.
        ///
        /// 8 kHz mono is a deliberate choice: the media server resamples it to whatever the route
        /// wants, and the smaller the source the less there is to do. A dither one LSB wide is
        /// about -90 dBFS — below the noise floor of any speaker, and unambiguously a running
        /// audio stream rather than digital silence.
        private static let keepAliveWave: Data = {
            let sampleRate = 8_000
            let sampleCount = sampleRate
            var samples = Data(capacity: sampleCount * 2)
            for index in 0..<sampleCount {
                let value: Int16 = index % 2 == 0 ? 1 : -1
                withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
            }
            return BackgroundResidency.wav(pcm16: samples, sampleRate: sampleRate)
        }()

        private static func wav(pcm16: Data, sampleRate: Int) -> Data {
            var out = Data()
            func append32(_ value: UInt32) {
                withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
            }
            func append16(_ value: UInt16) {
                withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
            }
            out.append(contentsOf: Array("RIFF".utf8))
            append32(UInt32(36 + pcm16.count))
            out.append(contentsOf: Array("WAVE".utf8))
            out.append(contentsOf: Array("fmt ".utf8))
            append32(16)
            append16(1)  // PCM
            append16(1)  // mono
            append32(UInt32(sampleRate))
            append32(UInt32(sampleRate * 2))  // byte rate
            append16(2)  // block align
            append16(16)  // bits per sample
            out.append(contentsOf: Array("data".utf8))
            append32(UInt32(pcm16.count))
            out.append(pcm16)
            return out
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
                    let playing = self.lock.withLock { self.player?.isPlaying ?? false }
                    if !playing {
                        self.log.write("background residency: route change stopped playback")
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
