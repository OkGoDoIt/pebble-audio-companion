import AVFoundation
import AudioCodec
import CompanionRuntime
import Foundation
import Observation

/// Records a voice sample through the watch. The phone notes when the person starts and stops
/// speaking; the watch's own audio for that window is what gets learned, because that is the
/// microphone recognition will hear them through. Its last seconds arrive over Bluetooth a
/// little after they are spoken, so stopping waits for them before offering playback.
@MainActor @Observable
final class VoiceWatchSampleRecorder {
    enum Phase: Equatable { case idle, recording, collecting, ready }

    static let length: TimeInterval = 20
    /// Less speech than this is not worth learning from.
    static let minimumSeconds: Double = 6

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var errorMessage: String?
    /// Start and stop on this phone's clock.
    private(set) var window: ClosedRange<Int64>?
    /// The same window on the watch's sample clock, once its audio has arrived: what is learned.
    private(set) var watchWindow: ClosedRange<Int64>?
    private(set) var sessionID = UUID().uuidString.lowercased()
    private var pcm: Data?
    private var player: AVAudioPlayer?
    private var timer: Task<Void, Never>?
    private var generation = 0
    private let injectedSource: (any VoiceRecognitionDataSource)?
    private var source: (any VoiceRecognitionDataSource)? { injectedSource ?? VoiceSources.current }
    private let now: () -> Int64
    private let pollInterval: Duration
    /// How long the watch's audio may take to arrive before the sample is given up on.
    private let arrivalTimeout: TimeInterval

    init(source: (any VoiceRecognitionDataSource)? = nil,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
         pollInterval: Duration = .seconds(1), arrivalTimeout: TimeInterval = 45) {
        injectedSource = source
        self.now = now
        self.pollInterval = pollInterval
        self.arrivalTimeout = arrivalTimeout
    }

    func start() async {
        guard phase == .idle, let source else { return }
        reset()
        let token = generation
        guard await source.watchIsStreaming() else {
            errorMessage = "Your watch isn’t recording right now. Start recording on the watch, then try again."
            return
        }
        guard token == generation else { return }
        sessionID = UUID().uuidString.lowercased()
        let started = now()
        window = started...started
        phase = .recording
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, token == self.generation, self.phase == .recording else { return }
                self.elapsed = Double(self.now() - started) / 1_000
                if self.elapsed >= Self.length { await self.finish(); return }
            }
        }
    }

    func finish() async {
        guard phase == .recording, let start = window?.lowerBound, let source else { return }
        timer?.cancel()
        let token = generation
        let end = now()
        window = start...end
        phase = .collecting
        let deadline = Date().addingTimeInterval(arrivalTimeout)
        var audio = await source.watchSampleAudio(phoneStartMs: start, phoneEndMs: end)
        while token == generation, (audio?.receivedThroughWallMs ?? .min) < end, Date() < deadline {
            try? await Task.sleep(for: pollInterval)
            guard token == generation else { return }
            audio = await source.watchSampleAudio(phoneStartMs: start, phoneEndMs: end)
        }
        guard token == generation else { return }
        guard let audio else {
            fail("Your watch’s audio didn’t reach the phone. Check that the watch is connected, then try again.")
            return
        }
        guard audio.seconds >= Self.minimumSeconds else {
            fail("There wasn’t enough speech in that sample. Try again, and keep talking until it finishes.")
            return
        }
        pcm = audio.pcm16LE
        watchWindow = audio.watchFromMs...max(audio.watchFromMs, audio.watchToMs)
        phase = .ready
    }

    func play() {
        guard let pcm else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            player = try AVAudioPlayer(data: Self.wav(pcm))
            player?.play()
        } catch {
            errorMessage = "Couldn’t play the sample. You can still save it."
        }
    }

    /// Back to the start: nothing recorded, nothing kept.
    func cancel() { reset() }

    private func reset() {
        generation += 1
        timer?.cancel()
        player?.stop()
        player = nil
        pcm = nil
        window = nil
        watchWindow = nil
        elapsed = 0
        errorMessage = nil
        phase = .idle
    }

    private func fail(_ message: String) {
        reset()
        errorMessage = message
    }

    /// 16 kHz mono 16-bit PCM in a WAV container, for playback only.
    /// The clip as a WAV for listening, brought up to a comfortable level: watch speech sits
    /// 20-25 dB below it. Only what is played is leveled; the stored audio is untouched.
    static func wav(_ stored: Data) -> Data {
        let samples = stored.withUnsafeBytes { raw in
            (0..<raw.count / 2).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        let pcm = VoiceNoteLevel.prepare(samples).pcm.withUnsafeBufferPointer { buffer in
            Data(buffer: UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
        }
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var data = Data("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8)
        data += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(16_000)) + le(UInt32(32_000))
        data += le(UInt16(2)) + le(UInt16(16)) + Data("data".utf8) + le(UInt32(pcm.count))
        return data + pcm
    }
}
