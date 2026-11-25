import AudioCodec
import Foundation
import Testing

@testable import Transcription

@Suite struct CoreMLParakeetTests {
    private typealias W = ParakeetTDTWeights

    /// Weights that ignore the prediction network and score pieces straight from the encoder: with
    /// `encoderWeight` passing units 0..<640 through and the head picking a row per unit, a test
    /// writes its own "encoder output".
    private static func passThrough(blankBias: Float, duration: Int) -> ParakeetTDTWeights {
        var values = [Float](repeating: 0, count: W.parameterCount)
        let h = W.hidden
        let embeddingEnd = (W.pieces + 1) * h
        let lstmEnd = embeddingEnd + 2 * (2 * 4 * h * h + 2 * 4 * h)
        let decoderEnd = lstmEnd + h * h + h
        for unit in 0..<h { values[decoderEnd + unit * W.encoder + unit] = 1 }
        let headStart = decoderEnd + h * W.encoder + h
        for piece in 0..<h { values[headStart + piece * h + piece] = 1 }
        let headBias = headStart + W.logits * h
        values[headBias + W.blank] = blankBias
        values[headBias + W.pieces + 1 + duration] = 1
        return ParakeetTDTWeights(values: values)
    }

    private static func encoded(_ frames: [Int?]) -> [Float] {
        var out = [Float](repeating: 0, count: frames.count * W.encoder)
        for (frame, piece) in frames.enumerated() {
            if let piece { out[frame * W.encoder + piece] = 4 }
        }
        return out
    }

    @Test func blanksAreWalkedAndPiecesAreEmittedAtTheirFrame() {
        let decoder = ParakeetTDTDecoder(weights: Self.passThrough(blankBias: 1, duration: 1))
        let frames: [Int?] = [nil, 7, nil, nil, nil, nil, nil, nil, nil, 12, 13, nil]
        let tokens = decoder.decode(encoded: Self.encoded(frames), frames: frames.count)
        #expect(tokens.map(\.id) == [7, 12, 13])
        #expect(tokens.map(\.frame) == [1, 9, 10])
    }

    @Test func aFrameThatNeverAdvancesIsLeftAfterTenPieces() {
        let decoder = ParakeetTDTDecoder(weights: Self.passThrough(blankBias: 1, duration: 0))
        let tokens = decoder.decode(encoded: Self.encoded([5, nil]), frames: 2)
        #expect(tokens.count == 10)
        #expect(tokens.allSatisfy { $0.id == 5 && $0.frame == 0 })
    }

    @Test func silenceAndACancelledSearchEmitNothing() {
        let decoder = ParakeetTDTDecoder(weights: Self.passThrough(blankBias: 1, duration: 1))
        #expect(decoder.decode(encoded: Self.encoded([nil, nil, nil]), frames: 3).isEmpty)
        #expect(decoder.decode(encoded: Self.encoded([5]), frames: 1, isCancelled: { true }).isEmpty)
        #expect(decoder.decode(encoded: [], frames: 0).isEmpty)
    }

    @Test(arguments: ["▁", " "]) func piecesBecomeTimedWords(mark: String) {
        var pieces = [String](repeating: "", count: W.pieces)
        pieces[1] = mark + "hel"
        pieces[2] = "lo"
        pieces[3] = mark + "there"
        pieces[4] = "."
        pieces[5] = "<unk>"
        let words = ParakeetVocabulary(pieces: pieces).words([
            .init(id: 1, frame: 10, duration: 2), .init(id: 2, frame: 12, duration: 4),
            .init(id: 5, frame: 13, duration: 1), .init(id: 3, frame: 14, duration: 1),
            .init(id: 4, frame: 15, duration: 1),
        ])
        #expect(words.map(\.text) == ["hello", "there."])
        // "hello" would run to frame 16; it ends where "there." starts.
        #expect(words[0].startMs == 800 && words[0].endMs == 1_120)
        #expect(words[1].startMs == 1_120 && words[1].endMs == 1_280)
    }

    @Test func phrasesBreakAtSentencesAndPausesAndParseBack() throws {
        let words: [ParakeetVocabulary.Word] = [
            .init(text: "We", startMs: 0, endMs: 200), .init(text: "agree.", startMs: 200, endMs: 700),
            .init(text: "Next", startMs: 1_000, endMs: 1_300),
            .init(text: "item", startMs: 2_600, endMs: 2_900),
        ]
        #expect(CoreMLParakeetEngine.phrases(words).map(\.text) == ["We agree.", "Next", "item"])
        let parsed = ParakeetNativeResponse.parse(try CoreMLParakeetEngine.response(words))
        #expect(parsed.text == "We agree. Next item")
        #expect(parsed.words.map(\.startMs) == [0, 200, 1_000, 2_600])
        #expect(parsed.segments.map(\.endMs) == [700, 1_300, 2_900])
    }

    /// The encoder takes 15 s; a range longer than that would lose its tail.
    @Test func everyRangeHandedToCoreMLFitsItsWindow() {
        let seconds = 900
        let levels = (0..<seconds * 10).map { WindowLevel(rms: Double(($0 * 37) % 91), peak: 100) }
        let ranges = ParakeetPcm.chunks(
            levels: levels, byteCount: seconds * 32_000, sampleRateHz: 16_000,
            maxChunkMs: ParakeetTranscriptionProvider.maxRangeMs(for: .coreML))
        #expect(ranges.allSatisfy { $0.byteLength / 2 <= CoreMLParakeetEngine.windowSamples })
        #expect(ranges.first?.startByte == 0 && ranges.last?.endByte == seconds * 32_000)
        for (left, right) in zip(ranges, ranges.dropFirst()) { #expect(left.endByte == right.startByte) }
    }

    @Test func onlyACanonicalWavIsRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = PcmWav.headerMono16(pcmSizeBytes: 4, sampleRateHz: 16_000)
        data.append(contentsOf: [0x00, 0x40, 0x00, 0xC0])
        try data.write(to: url)
        #expect(try CoreMLParakeetEngine.samples(ofWav: url) == [0.5, -0.5])
        try Data("not audio at all, but long enough to have a header's worth".utf8).write(to: url)
        #expect(throws: ParakeetEngineError.self) { try CoreMLParakeetEngine.samples(ofWav: url) }
    }
}

@Suite struct PcmLevelerTests {
    private static func tone(seconds: Int, amplitude: Double) -> Data {
        let samples = (0..<seconds * 16_000).map {
            Int16(amplitude * sin(2 * .pi * 300 * Double($0) / 16_000)).littleEndian
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private static func peak(_ data: Data) -> Int {
        [UInt8](data).withUnsafeBytes { raw in
            (0..<raw.count / 2).map {
                abs(Int(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self).littleEndian))
            }.max() ?? 0
        }
    }

    @Test func quietAudioIsRaisedAndNothingIsLost() {
        var leveler = PcmLeveler(sampleRateHz: 16_000)
        let audio = Self.tone(seconds: 100, amplitude: 120)
        var out = Data()
        for start in stride(from: 0, to: audio.count, by: 32_000) {
            for block in leveler.append(audio.subdata(in: start..<min(start + 32_000, audio.count))) {
                #expect(block.count <= PcmLeveler.maxBlockSeconds * 32_000)
                out.append(block)
            }
        }
        if let rest = leveler.finish() { out.append(rest) }
        #expect(out.count == audio.count)
        #expect(Self.peak(out) > 1_200)
        #expect(leveler.finish() == nil)
    }

    @Test func theCutLandsInTheQuietStretch() {
        var audio = Self.tone(seconds: 4, amplitude: 4_000)
        audio.replaceSubrange(3 * 32_000..<3 * 32_000 + 6_400, with: Data(count: 6_400))
        let cut = PcmLeveler.quietCut(audio, limit: audio.count, search: 2 * 32_000, window: 3_200)
        #expect((3 * 32_000...3 * 32_000 + 6_400).contains(cut))
        #expect(cut % 2 == 0)
    }
}
