import AVFoundation
import Foundation
import Observation
import UIKit

/// Foreground-only, explicitly started enrollment. Never used for ambient capture.
@MainActor @Observable
final class VoiceSampleRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0
    private(set) var pcm: Data?
    private(set) var errorMessage: String?
    private(set) var sessionID = UUID().uuidString.lowercased()
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var file: URL?
    private var timer: Task<Void, Never>?
    private var generation = 0
    private var previousSession: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    func start() async {
        guard !isRecording, UIApplication.shared.applicationState == .active else { return }
        cancel()
        generation += 1
        let token = generation
        errorMessage = nil
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard token == generation, !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
        guard allowed else { errorMessage = Copy.Voices.microphoneDenied; return }
        do {
            let session = AVAudioSession.sharedInstance()
            guard session.category != .playAndRecord && session.category != .record else {
                errorMessage = "Another recording is using the microphone. Finish it, then try again."
                return
            }
            previousSession = (session.category, session.mode, session.categoryOptions)
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-enrollment-\(UUID().uuidString).wav")
            self.file = file
            let recorder = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: 25) else { throw CaptureFailure.unavailable }
            self.recorder = recorder
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            isRecording = true
            elapsed = 0
            sessionID = UUID().uuidString.lowercased()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, self.isRecording, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    self.elapsed = recorder.currentTime
                    self.level = min(1, max(0, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
                    if !recorder.isRecording || self.elapsed >= 20 { self.finish(); return }
                }
            }
        } catch {
            errorMessage = Copy.Voices.interrupted
            releaseCapture()
            discardFile()
        }
    }

    func finish() {
        guard isRecording, let file else { return }
        let duration = elapsed
        releaseCapture()
        guard duration >= 10 else {
            errorMessage = Copy.Voices.shortSample
            discardFile()
            return
        }
        do {
            let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatInt16, interleaved: true)
            guard audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
                  audio.length >= 160_000, audio.length <= 480_000,
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                               frameCapacity: AVAudioFrameCount(audio.length)) else {
                throw CaptureFailure.unavailable
            }
            try audio.read(into: buffer)
            guard let samples = buffer.int16ChannelData?[0] else { throw CaptureFailure.unavailable }
            pcm = Data(bytes: samples, count: Int(buffer.frameLength) * 2)
            errorMessage = nil
        } catch {
            pcm = nil
            errorMessage = Copy.Voices.interrupted
            discardFile()
        }
    }

    func play() {
        guard !isRecording, pcm != nil, let file else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: file)
            self.player = player
            player.play()
        } catch { errorMessage = Copy.Voices.actionFailed }
    }

    func interrupt(enteredBackground: Bool = false) {
        player?.stop()
        if isRecording { cancel(); errorMessage = Copy.Voices.interrupted }
        else if enteredBackground { generation += 1 }
    }

    func cancel() {
        generation += 1
        releaseCapture()
        player?.stop()
        player = nil
        pcm = nil
        elapsed = 0
        level = 0
        discardFile()
    }

    private func releaseCapture() {
        timer?.cancel()
        timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let previousSession {
            let session = AVAudioSession.sharedInstance()
            // Restore the app's playback/residency category. Never deactivate the session:
            // the watch receiver may still depend on its existing background audio lease.
            if session.category == .playAndRecord, session.mode == .measurement,
               session.categoryOptions == [.defaultToSpeaker] {
                try? session.setCategory(previousSession.0, mode: previousSession.1, options: previousSession.2)
            }
            self.previousSession = nil
        }
    }
    private func discardFile() {
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
    private enum CaptureFailure: Error { case unavailable }
}
