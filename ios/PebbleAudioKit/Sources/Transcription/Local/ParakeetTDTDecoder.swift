import Accelerate
import CAccelerateBLAS
import Foundation

// The half of Parakeet TDT that is not the encoder: the prediction network (a 2-layer LSTM), the
// joint network, and the greedy token-and-duration search over them.
//
// It runs here, in Accelerate, rather than as two more Core ML models. A 15 s window is 188 encoder
// frames and at least one joint evaluation for every frame the decoder stops at; as Core ML calls
// each one is a dispatch, and on the phone that dispatching was most of the work (2026-11-25,
// iPhone 17: 18-45 CPU-seconds per 15-minute segment, slowest on the QUIET ones, where the search
// walks nearly every frame). As matrix products, with a block of frames joined at once while the
// prediction is unchanged, it is about a tenth of that.

/// The weights of the prediction and joint networks, read from a bundle's `decoder.f16`.
///
/// Layout: little-endian float16, row-major, in this order — embedding [V+1, H]; for each of two
/// LSTM layers weight_ih [4H, H], weight_hh [4H, H], bias_ih [4H], bias_hh [4H] (PyTorch gate order
/// input, forget, cell, output); the decoder projection [H, H] and its bias; the encoder projection
/// [H, E] and its bias; the joint head [V+1+D, H] and its bias.
public struct ParakeetTDTWeights: Sendable {
    /// Word pieces, without the blank.
    static let pieces = 8_192
    static let hidden = 640
    static let encoder = 1_024
    /// Frames a step may advance, in the order the head scores them.
    static let durations = [0, 1, 2, 3, 4]
    static let blank = pieces
    /// Pieces + blank + durations.
    static let logits = pieces + 1 + durations.count

    let embedding: [Float]
    let inputWeights: [[Float]]
    let recurrentWeights: [[Float]]
    let lstmBias: [[Float]]
    let decoderWeight: [Float]
    let decoderBias: [Float]
    let encoderWeight: [Float]
    let encoderBias: [Float]
    let headWeight: [Float]
    let headBias: [Float]

    static let parameterCount =
        (pieces + 1) * hidden
        + 2 * (2 * 4 * hidden * hidden + 2 * 4 * hidden)
        + hidden * hidden + hidden
        + hidden * encoder + hidden
        + logits * hidden + logits

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == Self.parameterCount * 2 else {
            throw ParakeetEngineError.modelLoadFailed(
                "decoder weights are \(data.count) bytes, expected \(Self.parameterCount * 2)")
        }
        let all = [Float](unsafeUninitializedCapacity: Self.parameterCount) { out, count in
            data.withUnsafeBytes { raw in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: raw.baseAddress!), height: 1,
                    width: vImagePixelCount(Self.parameterCount), rowBytes: data.count)
                var destination = vImage_Buffer(
                    data: out.baseAddress!, height: 1, width: vImagePixelCount(Self.parameterCount),
                    rowBytes: Self.parameterCount * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
            }
            count = Self.parameterCount
        }
        self.init(values: all)
    }

    /// Splits one flat run of values (`parameterCount` of them) into the matrices.
    init(values: [Float]) {
        precondition(values.count == Self.parameterCount)
        var offset = 0
        func take(_ count: Int) -> [Float] {
            defer { offset += count }
            return Array(values[offset..<offset + count])
        }
        let h = Self.hidden
        embedding = take((Self.pieces + 1) * h)
        var input: [[Float]] = [], recurrent: [[Float]] = [], bias: [[Float]] = []
        for _ in 0..<2 {
            input.append(take(4 * h * h))
            recurrent.append(take(4 * h * h))
            // The two biases are only ever added together.
            bias.append(vDSP.add(take(4 * h), take(4 * h)))
        }
        inputWeights = input
        recurrentWeights = recurrent
        lstmBias = bias
        decoderWeight = take(h * h)
        decoderBias = take(h)
        encoderWeight = take(h * Self.encoder)
        encoderBias = take(h)
        headWeight = take(Self.logits * h)
        headBias = take(Self.logits)
    }
}

/// One emitted word piece: which, and the encoder frame (80 ms) it was emitted at.
struct ParakeetToken: Equatable, Sendable {
    var id: Int
    var frame: Int
    /// Frames the model advanced on emitting it.
    var duration: Int
}

/// Greedy TDT search. Not thread-safe: it reuses its scratch buffers between calls.
final class ParakeetTDTDecoder {
    private typealias W = ParakeetTDTWeights
    private let weights: ParakeetTDTWeights
    /// Encoder frames joined per matrix product. While the prediction has not changed (a run of
    /// blanks) one product answers for several frames; on an emission the rest of the block is
    /// thrown away, so a larger block buys nothing on dense speech.
    private static let block = 8
    /// Tokens the model may emit without advancing, before the search moves on by itself.
    private static let maxSymbolsPerFrame = 10
    private var joined: [Float]
    private var scores: [Float]
    private var gates: [Float]

    init(weights: ParakeetTDTWeights) {
        self.weights = weights
        joined = [Float](repeating: 0, count: Self.block * W.hidden)
        scores = [Float](repeating: 0, count: Self.block * W.logits)
        gates = [Float](repeating: 0, count: 4 * W.hidden)
    }

    private struct State {
        var hidden = [[Float]](repeating: [Float](repeating: 0, count: W.hidden), count: 2)
        var cell = [[Float]](repeating: [Float](repeating: 0, count: W.hidden), count: 2)
    }

    /// `encoded` is `frames × 1024`, row-major.
    func decode(
        encoded: [Float], frames: Int, isCancelled: () -> Bool = { false }
    ) -> [ParakeetToken] {
        let h = W.hidden
        guard frames > 0, encoded.count >= frames * W.encoder else { return [] }
        var projected = [Float](repeating: 0, count: frames * h)
        cacc_sgemm_row_major_bt(
            Int32(frames), Int32(h), Int32(W.encoder), encoded, Int32(W.encoder),
            weights.encoderWeight, Int32(W.encoder), &projected, Int32(h))
        projected.withUnsafeMutableBufferPointer { out in
            for frame in 0..<frames {
                let row = out.baseAddress! + frame * h
                vDSP_vadd(row, 1, weights.encoderBias, 1, row, 1, vDSP_Length(h))
            }
        }

        var state = State()
        var prediction = predict(W.blank, &state)
        var tokens: [ParakeetToken] = []
        var frame = 0
        var symbolsHere = 0
        while frame < frames {
            if isCancelled() { break }
            let count = min(Self.block, frames - frame)
            join(projected, from: frame, count: count, with: prediction)
            var offset = 0
            while offset < count {
                let (token, duration) = best(row: offset)
                if token == W.blank {
                    let advance = max(1, duration)
                    offset += advance
                    frame += advance
                    symbolsHere = 0
                    continue
                }
                tokens.append(ParakeetToken(id: token, frame: frame, duration: duration))
                prediction = predict(token, &state)
                frame += duration
                if duration == 0 {
                    symbolsHere += 1
                    if symbolsHere >= Self.maxSymbolsPerFrame {
                        frame += 1
                        symbolsHere = 0
                    }
                } else {
                    symbolsHere = 0
                }
                // The prediction changed, so the rest of this block was joined with the wrong one.
                break
            }
        }
        return tokens
    }

    private func join(_ projected: [Float], from frame: Int, count: Int, with prediction: [Float]) {
        let h = W.hidden
        projected.withUnsafeBufferPointer { source in
            joined.withUnsafeMutableBufferPointer { out in
                var zero: Float = 0
                for index in 0..<count {
                    let row = out.baseAddress! + index * h
                    vDSP_vadd(
                        source.baseAddress! + (frame + index) * h, 1, prediction, 1, row, 1,
                        vDSP_Length(h))
                    vDSP_vthres(row, 1, &zero, row, 1, vDSP_Length(h))
                }
            }
        }
        cacc_sgemm_row_major_bt(
            Int32(count), Int32(W.logits), Int32(h), joined, Int32(h), weights.headWeight, Int32(h),
            &scores, Int32(W.logits))
    }

    private func best(row: Int) -> (token: Int, duration: Int) {
        scores.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress! + row * W.logits
            vDSP_vadd(base, 1, weights.headBias, 1, base, 1, vDSP_Length(W.logits))
            var top: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxvi(base, 1, &top, &index, vDSP_Length(W.pieces + 1))
            var durationTop: Float = 0
            var durationIndex: vDSP_Length = 0
            vDSP_maxvi(
                base + W.pieces + 1, 1, &durationTop, &durationIndex,
                vDSP_Length(W.durations.count))
            return (Int(index), W.durations[Int(durationIndex)])
        }
    }

    private func predict(_ token: Int, _ state: inout State) -> [Float] {
        let h = W.hidden
        var input = Array(weights.embedding[token * h..<(token + 1) * h])
        for layer in 0..<2 {
            gates = weights.lstmBias[layer]
            cacc_sgemv_row_major_add(
                Int32(4 * h), Int32(h), weights.inputWeights[layer], Int32(h), input, &gates)
            cacc_sgemv_row_major_add(
                Int32(4 * h), Int32(h), weights.recurrentWeights[layer], Int32(h),
                state.hidden[layer], &gates)
            for unit in 0..<h {
                let inputGate = sigmoid(gates[unit])
                let forgetGate = sigmoid(gates[h + unit])
                let candidate = tanh(gates[2 * h + unit])
                let outputGate = sigmoid(gates[3 * h + unit])
                let cell = forgetGate * state.cell[layer][unit] + inputGate * candidate
                state.cell[layer][unit] = cell
                state.hidden[layer][unit] = outputGate * tanh(cell)
            }
            input = state.hidden[layer]
        }
        var out = weights.decoderBias
        cacc_sgemv_row_major_add(
            Int32(h), Int32(h), weights.decoderWeight, Int32(h), input, &out)
        return out
    }

    private func sigmoid(_ value: Float) -> Float { 1 / (1 + exp(-value)) }
}

/// Word pieces back into words, with the times their frames give them.
struct ParakeetVocabulary: Sendable {
    static let frameMs = 80
    private let pieces: [String]

    /// `parakeet_vocab.json`: either `{"0": "<unk>", …}` or a plain array of pieces.
    init(contentsOf url: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        var table = [String](repeating: "", count: ParakeetTDTWeights.pieces)
        if let map = json as? [String: String] {
            for (key, piece) in map {
                if let id = Int(key), table.indices.contains(id) { table[id] = piece }
            }
        } else if let list = json as? [String] {
            for (id, piece) in list.enumerated() where table.indices.contains(id) { table[id] = piece }
        }
        self.init(pieces: table)
        guard pieces.contains(where: { $0.hasPrefix(Self.wordStart) }) else {
            throw ParakeetEngineError.modelLoadFailed("the vocabulary has no word pieces")
        }
    }

    /// A piece that starts a word. SentencePiece writes "▁"; the Core ML vocabularies on Hugging
    /// Face have already turned it into a space.
    private static let wordStart = " "

    init(pieces: [String]) {
        self.pieces = pieces.map { $0.replacingOccurrences(of: "▁", with: Self.wordStart) }
    }

    struct Word: Equatable, Sendable {
        var text: String
        var startMs: Int
        var endMs: Int
    }

    /// Control pieces (`<…>`) are not words. A word ends where its last piece's own advance does,
    /// and never after the next word starts.
    func words(_ tokens: [ParakeetToken]) -> [Word] {
        var words: [Word] = []
        for token in tokens {
            guard pieces.indices.contains(token.id) else { continue }
            let piece = pieces[token.id]
            if piece.isEmpty || (piece.hasPrefix("<") && piece.hasSuffix(">")) { continue }
            let startMs = token.frame * Self.frameMs
            let endMs = (token.frame + max(1, token.duration)) * Self.frameMs
            let startsWord = piece.hasPrefix(Self.wordStart) || words.isEmpty
            let text = piece.trimmingCharacters(in: .whitespaces)
            if startsWord {
                if let last = words.indices.last { words[last].endMs = min(words[last].endMs, startMs) }
                words.append(Word(text: text, startMs: startMs, endMs: endMs))
            } else {
                words[words.count - 1].text += text
                words[words.count - 1].endMs = max(words[words.count - 1].endMs, endMs)
            }
        }
        return words.filter { !$0.text.isEmpty }
    }
}
