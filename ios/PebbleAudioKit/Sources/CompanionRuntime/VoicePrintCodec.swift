import Foundation
import SpeakerRecognition

/// A voice print as saved: each value in half precision, little-endian (half a kilobyte for the
/// 256-value model). The saved values are what every name is matched from, the first time too,
/// so the rounding never makes a later reading disagree with the first.
enum VoicePrintCodec {
    static func save(_ embedding: SpeakerEmbedding) throws -> (bytes: Data, embedding: SpeakerEmbedding) {
        let halves = embedding.values.map { Float16($0) }
        var bytes = Data(capacity: halves.count * 2)
        for half in halves {
            let bits = half.bitPattern
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return (bytes, try SpeakerEmbedding(recipe: embedding.recipe, values: halves.map(Float.init)))
    }

    static func open(_ bytes: Data, recipe: SpeakerEmbeddingRecipe) throws -> SpeakerEmbedding {
        guard bytes.count == recipe.dimensions * 2 else { throw SpeakerRecognitionError.invalidEmbedding }
        let raw = [UInt8](bytes)
        let values = stride(from: 0, to: raw.count, by: 2).map {
            Float(Float16(bitPattern: UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8))
        }
        return try SpeakerEmbedding(recipe: recipe, values: values)
    }
}
