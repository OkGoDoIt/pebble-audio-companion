import AudioCodec
import Foundation
import SegmentStore
import Testing

@testable import Transcription

// A MEASUREMENT, not a unit test: how much real speech does the on-device path's voice gate
// (`ParakeetPcm.speechRanges`) leave out? It runs only when `PEBBLE_VAD_MEASURE_ROOT` points at an
// app-container backup (`segments/` + `transcription/transcripts/`, as the deploy script writes
// under ~/Desktop/PebbleAudioBackup), and it only prints.
//
// Method: every segment a CLOUD provider transcribed carries word timings on the same decoded
// timeline the on-device path spools. Decode the segment exactly as `segmentPcmSource` does, run
// the production gate over it, and count the cloud's words whose midpoint falls outside every
// range the gate would hand the engine. A segment whose gate finds no ranges at all is
// transcribed whole by the provider, so it loses nothing and is counted separately.
@Suite struct VadCoverageMeasurement {
    private struct Transcript: Decodable {
        struct Word: Decodable {
            let text: String
            let startMs: Int64
            let endMs: Int64
        }
        let segmentId: String
        let providerId: String
        let words: [Word]?
    }

    /// Candidate gates, evaluated through the production range builder on the same levels.
    private static let candidates: [(name: String, gate: VoiceGate?)] = [
        ("production rms45/peak240", .production),
        ("rms30/peak180", VoiceGate(minRms: 30, minPeak: 180)),
        ("rms20/peak120", VoiceGate(minRms: 20, minPeak: 120)),
        ("rms14/peak90", VoiceGate(minRms: 14, minPeak: 90)),
        ("rms10/peak60", VoiceGate(minRms: 10, minPeak: 60)),
        ("floor x2.0 (min rms8/peak60)", VoiceGate(minRms: 8, minPeak: 60, floorFactor: 2.0)),
        ("floor x1.5 (min rms6/peak50)", VoiceGate(minRms: 6, minPeak: 50, floorFactor: 1.5)),
        ("everything (45 s chunks)", nil),
    ]

    @Test func cloudWordsOutsideTheLocalVoiceGate() throws {
        guard let rootPath = ProcessInfo.processInfo.environment["PEBBLE_VAD_MEASURE_ROOT"] else {
            return
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let reader = SegmentFileReader(root: root)
        let dir = root.appendingPathComponent("transcription/transcripts", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".transcript.json") }.sorted()

        var segments = 0, missingAudio = 0, words = 0
        var audioMs: Int64 = 0
        var outside = Array(repeating: 0, count: Self.candidates.count)
        var handedMs = Array(repeating: Int64(0), count: Self.candidates.count)
        var worstSegmentLoss = Array(repeating: 0.0, count: Self.candidates.count)

        for file in files {
            let data = try Data(contentsOf: dir.appendingPathComponent(file))
            guard let transcript = try? JSONDecoder().decode(Transcript.self, from: data),
                !transcript.providerId.hasSuffix("-local"), transcript.providerId != "speechanalyzer",
                let timed = transcript.words, !timed.isEmpty
            else { continue }
            guard let meta = reader.readMeta(transcript.segmentId) else {
                missingAudio += 1
                continue
            }
            let frames = reader.readFrames(transcript.segmentId)
            guard !frames.isEmpty else {
                missingAudio += 1
                continue
            }
            let rate = Int(meta.sampleRateHz)
            let decoder = SpeexFrameDecoder(
                sampleRateHz: rate, bitRateBps: Int(meta.bitRateBps), frameSamples: meta.frameSamples)
            let pcm = try decoder.decodeAll(frames: frames.map { Data($0.payload) })
            let levels = ParakeetPcm.windowLevels(byteCount: pcm.count, sampleRateHz: rate) {
                offset, length in
                pcm.subdata(in: offset..<min(pcm.count, offset + length))
            }
            segments += 1
            words += timed.count
            audioMs += Int64(pcm.count / 2) * 1_000 / Int64(rate)
            for (index, candidate) in Self.candidates.enumerated() {
                var ranges: [PcmSpeechRange]
                if let gate = candidate.gate {
                    ranges = ParakeetPcm.speechRanges(
                        levels: levels, gate: gate, byteCount: pcm.count, sampleRateHz: rate)
                } else {
                    ranges = []
                }
                // No ranges: the provider transcribes the whole segment in 45 s chunks.
                if ranges.isEmpty {
                    ranges = ParakeetPcm.splitLong(
                        [PcmSpeechRange(startByte: 0, endByte: ParakeetPcm.align(pcm.count))],
                        sampleRateHz: rate)
                }
                handedMs[index] += ranges.reduce(0) {
                    $0 + $1.endMs(sampleRateHz: rate) - $1.startMs(sampleRateHz: rate)
                }
                var missed = 0
                for word in timed {
                    let mid = (word.startMs + word.endMs) / 2
                    if !ranges.contains(where: {
                        mid >= $0.startMs(sampleRateHz: rate) && mid < $0.endMs(sampleRateHz: rate)
                    }) {
                        missed += 1
                    }
                }
                outside[index] += missed
                worstSegmentLoss[index] = max(
                    worstSegmentLoss[index], Double(missed) / Double(timed.count))
            }
        }

        print("VAD coverage over \(segments) cloud-transcribed segments (\(missingAudio) without audio), \(words) words, \(audioMs / 60_000) min of audio")
        for (index, candidate) in Self.candidates.enumerated() {
            let share = words > 0 ? Double(outside[index]) / Double(words) * 100 : 0
            print(
                "  \(candidate.name.padding(toLength: 30, withPad: " ", startingAt: 0)) missed \(String(format: "%6.2f", share))% of words"
                    + " | handed \(handedMs[index] / 60_000) min (\(String(format: "%.0f", Double(handedMs[index]) / Double(max(1, audioMs)) * 100))% of audio)"
                    + " | worst segment \(String(format: "%.0f", worstSegmentLoss[index] * 100))% missed")
        }
    }

    private static func rms(_ bytes: Data) -> Double {
        var sum = 0.0
        var count = 0
        bytes.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let value = Double(Int16(littleEndian: sample))
                sum += value * value
                count += 1
            }
        }
        return count > 0 ? (sum / Double(count)).squareRoot() : 0
    }
}
