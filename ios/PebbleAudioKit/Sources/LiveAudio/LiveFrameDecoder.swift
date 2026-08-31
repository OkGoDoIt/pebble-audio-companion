import AudioCodec
import Foundation

// Port of the `LiveFrameDecoder` seam from `app/.../LiveAudioMonitor.kt`.

/// Decodes encoded Speex frames to one concatenated PCM16 sample array, in order.
/// Kotlin `fun interface LiveFrameDecoder`; display-path decoding is best-effort, so failures
/// surface as a shorter (possibly empty) sample array, never as thrown errors.
public protocol LiveFrameDecoder: Sendable {
    func decode(_ frames: [[UInt8]]) async -> [Int16]
}

/// Default decoder over the vendored Speex codec (port of `SpeexLiveFrameDecoder`).
public struct SpeexLiveFrameDecoder: LiveFrameDecoder, Sendable {
    public let frameSamples: Int

    public init(frameSamples: Int = 320) {
        self.frameSamples = frameSamples
    }

    public func decode(_ frames: [[UInt8]]) async -> [Int16] {
        guard !frames.isEmpty else { return [] }
        let decoder = SpeexFrameDecoder(frameSamples: frameSamples)
        guard let pcm = try? decoder.decodeAll(frames: frames.map { Data($0) }) else {
            return []
        }
        var out = [Int16](repeating: 0, count: pcm.count / 2)
        pcm.withUnsafeBytes { raw in
            for i in 0..<out.count {
                out[i] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
            }
        }
        return out
    }
}
