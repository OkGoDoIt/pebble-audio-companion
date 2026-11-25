import AudioCodec
import Foundation

/// Brings a stream of quiet watch PCM up to the level a speech recognizer expects
/// (`VoiceNoteLevel`), a block at a time, for an engine that takes a stream rather than files.
///
/// Apple Speech is the engine this is for. On 60 English segments (14.6 h, 2026-11-25) it heard
/// 21.7% more words with this stage than without it and went from six segments it called silent
/// to two; the error rate against the cloud transcript fell from 76.1% to 72.7%. Only the copy the
/// recognizer hears is leveled; the stored audio is untouched.
///
/// Blocks are at most 45 s and end in the quietest 100 ms of their last 10 s, so the gain does not
/// change inside a word.
struct PcmLeveler {
    static let maxBlockSeconds = 45
    static let boundarySearchSeconds = 10
    private let sampleRateHz: Int
    private var pending = Data()

    init(sampleRateHz: Int) { self.sampleRateHz = sampleRateHz }

    private var blockBytes: Int { Self.maxBlockSeconds * sampleRateHz * 2 }

    /// Takes more audio and returns the blocks that are complete.
    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var blocks: [Data] = []
        while pending.count > blockBytes {
            let cut = Self.quietCut(
                pending, limit: blockBytes, search: Self.boundarySearchSeconds * sampleRateHz * 2,
                window: sampleRateHz / 10 * 2)
            blocks.append(leveled(pending.prefix(cut)))
            pending = Data(pending.dropFirst(cut))
        }
        return blocks
    }

    /// What is left at the end of the audio, or nil when there is nothing.
    mutating func finish() -> Data? {
        defer { pending = Data() }
        let whole = pending.prefix(pending.count & ~1)
        return whole.isEmpty ? nil : leveled(whole)
    }

    private func leveled(_ bytes: Data) -> Data {
        let samples: [Int16] = [UInt8](bytes).withUnsafeBytes { raw in
            (0..<raw.count / 2).map { raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self).littleEndian }
        }
        let out = VoiceNoteLevel.prepare(samples, sampleRateHz: sampleRateHz).pcm
        return out.map(\.littleEndian).withUnsafeBytes { Data($0) }
    }

    /// The middle of the quietest `window` bytes before `limit`, sample-aligned.
    static func quietCut(_ data: Data, limit: Int, search: Int, window: Int) -> Int {
        let bytes = [UInt8](data.prefix(limit))
        var best = limit & ~1
        var quietest = Double.infinity
        var start = max(0, limit - search) & ~1
        bytes.withUnsafeBytes { raw in
            while start + window <= raw.count {
                var energy = 0.0
                var offset = start
                while offset < start + window {
                    let sample = Double(raw.loadUnaligned(fromByteOffset: offset, as: Int16.self).littleEndian)
                    energy += sample * sample
                    offset += 2
                }
                if energy < quietest {
                    quietest = energy
                    best = (start + window / 2) & ~1
                }
                start += (window / 2) & ~1
            }
        }
        return max(2, best)
    }
}
