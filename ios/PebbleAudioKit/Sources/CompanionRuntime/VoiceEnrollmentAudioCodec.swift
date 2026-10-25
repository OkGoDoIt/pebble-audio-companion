import AudioCodec
import Foundation

/// Phone enrollment retains the original crop plus an acoustic variant through the recorder's
/// actual codec. Encode one continuous stream before cropping, so each variant has the same
/// codec history as watch audio. This creates no extra independent enrollment examples.
enum VoiceEnrollmentAudioCodec {
    static let recipe = "speex-wb-16000-9800-cbr-q6-complexity1-v1"

    static func watchVariant(_ pcm: Data) throws -> Data {
        guard pcm.count.isMultiple(of: 2), (64_000...960_000).contains(pcm.count) else {
            throw VoiceEnrollmentError.invalidRange
        }
        let samples: [Int16] = pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            stride(from: 0, to: pcm.count, by: 2).map {
                Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
            }
        }
        let encoder = try SpeexFrameEncoder()
        var frames: [Data] = []
        frames.reserveCapacity((samples.count + encoder.frameSamples - 1) / encoder.frameSamples)
        for start in stride(from: 0, to: samples.count, by: encoder.frameSamples) {
            try Task.checkCancellation()
            var frame = Array(samples[start..<min(samples.count, start + encoder.frameSamples)])
            if frame.count < encoder.frameSamples {
                frame += Array(repeating: 0, count: encoder.frameSamples - frame.count)
            }
            frames.append(try encoder.encodeFrame(frame))
        }
        return try SpeexFrameDecoder().decodeAll(frames: frames).prefix(pcm.count)
    }
}
