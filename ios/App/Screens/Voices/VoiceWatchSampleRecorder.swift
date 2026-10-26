import AVFoundation
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
    private(set) var window: ClosedRange<Int64>?
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
         pollInterval: Duration = .seconds(1), arrivalTimeout: TimeInterval = 20) {
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
        var audio = await source.watchSampleAudio(fromWallMs: start, toWallMs: end)
        while token == generation, (audio?.receivedThroughWallMs ?? .min) < end, Date() < deadline {
            try? await Task.sleep(for: pollInterval)
            guard token == generation else { return }
            audio = await source.watchSampleAudio(fromWallMs: start, toWallMs: end)
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
        elapsed = 0
        errorMessage = nil
        phase = .idle
    }

    private func fail(_ message: String) {
        reset()
        errorMessage = message
    }

    /// 16 kHz mono 16-bit PCM in a WAV container, for playback only.
    static func wav(_ pcm: Data) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var data = Data("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8)
        data += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(16_000)) + le(UInt32(32_000))
        data += le(UInt16(2)) + le(UInt16(16)) + Data("data".utf8) + le(UInt32(pcm.count))
        return data + pcm
    }
}
