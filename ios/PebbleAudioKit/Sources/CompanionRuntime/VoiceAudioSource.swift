import AudioCodec
import CryptoKit
import Foundation
import SegmentStore

public enum VoiceEnrollmentError: Error, LocalizedError, Equatable, Sendable {
    case disabled, modelsNotInstalled, audioUnavailable, unsupportedAudio, invalidRange
    case interruptedAudio, notEnoughSpeech, notEnoughExamples, multipleSpeakers, changedDuringProcessing, profileFull

    public var errorDescription: String? {
        switch self {
        case .disabled: return "Turn on voice recognition before adding a voice."
        case .modelsNotInstalled: return "Download the voice models first."
        case .audioUnavailable: return "This recording is not available on this phone."
        case .unsupportedAudio: return "This audio format cannot be used for voice recognition."
        case .invalidRange: return "Choose between 2 and 30 seconds of speech."
        case .interruptedAudio: return "This passage crosses a recording gap. Choose a continuous passage."
        case .notEnoughExamples: return "Add another clear voice sample before checking other recordings."
        case .notEnoughSpeech: return "There is not enough clear speech. Try a longer, quieter passage."
        case .multipleSpeakers: return "More than one voice was detected. Choose a passage with only this person speaking."
        case .changedDuringProcessing: return "The recording or voice settings changed. Try again."
        case .profileFull: return "This voice profile is full. Remove an older saved sample before adding another."
        }
    }
}

/// Stored media offsets count persisted frames, not wall time or the watch's sample clock.
/// Keep discontinuities even though the two sides are adjacent on that stored-media clock.
struct VoiceAudioSource: Sendable {
    let meta: SegmentMeta
    let frames: [FrameRecord]
    let revision: String
    let continuousSampleRanges: [Range<Int>]
    var endMediaMs: Int64 { Int64(frames.count * meta.frameSamples / 16) }

    init(meta: SegmentMeta, frames: [FrameRecord]) throws {
        guard meta.sampleRateHz == 16_000, meta.channels == 1, meta.frameSamples == 320 else {
            throw VoiceEnrollmentError.unsupportedAudio
        }
        guard !frames.isEmpty else { throw VoiceEnrollmentError.audioUnavailable }
        self.meta = meta
        self.frames = frames
        var hash = SHA256()
        hash.update(data: Data("voice-source-v1|16000|320|".utf8))
        var ranges: [Range<Int>] = []
        // Range deletion preserves timestamps by replacing frames with this exact silence
        // packet. Treat it as a boundary too: never train across a deleted passage.
        let redactedSilence = try? SpeexSilence.frame(sampleRateHz: Int(meta.sampleRateHz),
                                                    bitRateBps: Int(meta.bitRateBps))
        var first = 0
        for (index, frame) in frames.enumerated() {
            var sequence = frame.sequence.littleEndian
            var sample = frame.sampleIndex.littleEndian
            withUnsafeBytes(of: &sequence) { hash.update(bufferPointer: $0) }
            withUnsafeBytes(of: &sample) { hash.update(bufferPointer: $0) }
            hash.update(data: Data(frame.payload))
            if frame.payload == redactedSilence {
                if first < index { ranges.append((first * meta.frameSamples)..<(index * meta.frameSamples)) }
                first = index + 1
                continue
            }
            if index > first {
                let previous = frames[index - 1]
                if frame.sequence != previous.sequence &+ 1
                    || frame.sampleIndex != previous.sampleIndex &+ UInt64(meta.frameSamples) {
                    ranges.append((first * meta.frameSamples)..<(index * meta.frameSamples))
                    first = index
                }
            }
        }
        if first < frames.count { ranges.append((first * meta.frameSamples)..<(frames.count * meta.frameSamples)) }
        continuousSampleRanges = ranges
        revision = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Only the next continuous interval is decoded; short fragments are skipped rather than
    /// glued to the following speaker or the other side of a loss/quiet/redaction boundary.
    func nextRange(afterMediaMs cursor: Int64, throughMediaMs end: Int64,
                   maximumMs: Int64 = 10_000) -> Range<Int64>? {
        guard cursor >= 0, end > cursor, maximumMs >= 2_000 else { return nil }
        for samples in continuousSampleRanges {
            let lower = max(cursor, Int64(samples.lowerBound / 16))
            let upper = min(end, Int64(samples.upperBound / 16), lower + maximumMs)
            if upper - lower >= 2_000 { return lower..<upper }
        }
        return nil
    }

    /// The clip widened by `paddingMs` each side, never past the continuous run it sits in
    /// (a quiet, loss or redaction boundary) and never longer than 30 s.
    func contextRange(startMediaMs: Int64, endMediaMs: Int64, paddingMs: Int64) -> Range<Int64> {
        let run = continuousSampleRanges.first { Int64($0.lowerBound / 16) <= startMediaMs && Int64($0.upperBound / 16) > startMediaMs }
        let lower = max(startMediaMs - paddingMs, run.map { Int64($0.lowerBound / 16) } ?? startMediaMs, 0)
        let upper = min(endMediaMs + paddingMs, run.map { Int64($0.upperBound / 16) } ?? endMediaMs, self.endMediaMs,
                        lower + 30_000)
        return lower..<max(upper, lower + 1)
    }

    func pcm(startMediaMs: Int64, endMediaMs: Int64) throws -> Data {
        guard startMediaMs >= 0, endMediaMs > startMediaMs,
              endMediaMs - startMediaMs <= 30_000, endMediaMs <= self.endMediaMs else {
            throw VoiceEnrollmentError.invalidRange
        }
        let start = Int(startMediaMs) * 16
        let end = Int(endMediaMs) * 16
        guard let run = continuousSampleRanges.first(where: {
            $0.lowerBound <= start && $0.upperBound >= end
        }) else { throw VoiceEnrollmentError.interruptedAudio }
        // A little real preceding audio restores Speex state without crossing a discontinuity.
        let firstFrame = max(run.lowerBound / meta.frameSamples, start / meta.frameSamples - 5)
        let lastFrame = (end + meta.frameSamples - 1) / meta.frameSamples
        let decoded = try SpeexFrameDecoder(
            sampleRateHz: Int(meta.sampleRateHz), bitRateBps: Int(meta.bitRateBps),
            frameSamples: meta.frameSamples
        ).decodeAll(frames: frames[firstFrame..<lastFrame].map { Data($0.payload) })
        let offset = (start - firstFrame * meta.frameSamples) * 2
        let count = (end - start) * 2
        guard decoded.count >= offset + count else { throw VoiceEnrollmentError.audioUnavailable }
        return decoded.subdata(in: offset..<(offset + count))
    }
}
