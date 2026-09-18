import Foundation
import Testing

@testable import CoreAISpeechVendored

// The decoder's contract is "what swift-transformers produced for this tokenizer.json"; each
// rule below is one line of that library's decode path, exercised on a synthetic vocabulary so
// the tests run on every platform (the real-bundle parity test needs macOS 27 and a bundle).

private func tokenizerJSON(
    vocab: [String: Int],
    addedTokens: [(Int, String)] = [],
    decoder: [String: Any]? = ["type": "Metaspace", "replacement": "▁", "prepend_scheme": "always"]
) -> Data {
    var root: [String: Any] = [
        "model": ["type": "BPE", "vocab": vocab, "merges": []] as [String: Any],
        "added_tokens": addedTokens.map { ["id": $0.0, "content": $0.1] as [String: Any] },
    ]
    if let decoder { root["decoder"] = decoder }
    return try! JSONSerialization.data(withJSONObject: root)
}

private let vocab: [String: Int] = [
    "<unk>": 0, "▁hello": 1, "▁world": 2, "▁don": 3, "'": 4, "t": 5, "▁.": 6, "ing": 7,
    "▁": 8, "s": 9,
]

@Suite struct ParakeetTokenizerTests {
    @Test func piecesJoinWithMetaspaceAsSpace() throws {
        let tokenizer = try ParakeetTokenizer(
            tokenizerJSON: tokenizerJSON(vocab: vocab),
            tokenizerConfigJSON: Data(#"{"clean_up_tokenization_spaces": false}"#.utf8)
        )
        // Leading "▁" stays a leading space: `add_prefix_space` is absent (false), exactly as
        // swift-transformers reads this decoder block. The model trims afterwards.
        #expect(tokenizer.decode(tokens: [1, 2]) == " hello world")
        #expect(tokenizer.decode(tokens: [3, 4, 5, 6]) == " don't .")
        #expect(tokenizer.decode(tokens: [1, 7, 8, 9]) == " helloing s")
        #expect(tokenizer.decode(tokens: []) == "")
    }

    @Test func unknownIdsAreDroppedNotSubstituted() throws {
        let tokenizer = try ParakeetTokenizer(
            tokenizerJSON: tokenizerJSON(vocab: vocab),
            tokenizerConfigJSON: Data(#"{"clean_up_tokenization_spaces": false}"#.utf8)
        )
        #expect(tokenizer.decode(tokens: [1, 9_999, 2, -1]) == " hello world")
        #expect(tokenizer.piece(for: 9_999) == nil)
        #expect(tokenizer.piece(for: -1) == nil)
        #expect(tokenizer.count == 10)
    }

    @Test func addedTokensOverrideTheModelVocab() throws {
        let tokenizer = try ParakeetTokenizer(
            tokenizerJSON: tokenizerJSON(vocab: vocab, addedTokens: [(0, "<unk>"), (2, "<|spk|>"), (8_192, "<blank>")]),
            tokenizerConfigJSON: Data(#"{"clean_up_tokenization_spaces": false}"#.utf8)
        )
        #expect(tokenizer.count == 8_193)
        #expect(tokenizer.decode(tokens: [1, 2, 8_192]) == " hello<|spk|><blank>")
    }

    @Test func cleanUpDefaultsOnAndFollowsTheConfigFlag() throws {
        let json = tokenizerJSON(vocab: vocab)
        // No tokenizer_config.json ⇒ swift-transformers' default (true).
        let defaulted = try ParakeetTokenizer(tokenizerJSON: json)
        #expect(defaulted.decode(tokens: [3, 4, 5, 6]) == " don't.")
        let on = try ParakeetTokenizer(
            tokenizerJSON: json, tokenizerConfigJSON: Data(#"{"clean_up_tokenization_spaces": true}"#.utf8)
        )
        #expect(on.decode(tokens: [3, 4, 5, 6]) == " don't.")
        #expect(ParakeetTokenizer.cleanUp("hi , there ? yes 's ok") == "hi, there? yes's ok")
    }

    @Test func prefixSpaceIsRemovedOnlyWhenTheDecoderAsksForIt() throws {
        let tokenizer = try ParakeetTokenizer(
            tokenizerJSON: tokenizerJSON(
                vocab: vocab,
                decoder: ["type": "Metaspace", "replacement": "▁", "add_prefix_space": true]
            ),
            tokenizerConfigJSON: Data(#"{"clean_up_tokenization_spaces": false}"#.utf8)
        )
        #expect(tokenizer.decode(tokens: [1, 2]) == "hello world")
        // Only the very first piece's leading space goes; a later one is a word boundary.
        #expect(tokenizer.decode(tokens: [7, 2]) == "ing world")
    }

    @Test func aMissingDecoderJoinsPiecesVerbatim() throws {
        let tokenizer = try ParakeetTokenizer(
            tokenizerJSON: tokenizerJSON(vocab: vocab, decoder: nil),
            tokenizerConfigJSON: Data(#"{"clean_up_tokenization_spaces": false}"#.utf8)
        )
        #expect(tokenizer.decode(tokens: [1, 2]) == "▁hello▁world")
    }

    @Test func malformedAndUnsupportedFilesAreRejected() {
        #expect(throws: ParakeetTokenizer.LoadError.self) {
            _ = try ParakeetTokenizer(tokenizerJSON: Data("[]".utf8))
        }
        #expect(throws: ParakeetTokenizer.LoadError.malformed("tokenizer.json has no model.vocab")) {
            _ = try ParakeetTokenizer(tokenizerJSON: Data(#"{"model":{}}"#.utf8))
        }
        #expect(throws: ParakeetTokenizer.LoadError.unsupportedDecoder("ByteLevel")) {
            _ = try ParakeetTokenizer(
                tokenizerJSON: tokenizerJSON(vocab: vocab, decoder: ["type": "ByteLevel"])
            )
        }
    }

    @Test func readsTheConfigBesideTheTokenizerFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-tokenizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try tokenizerJSON(vocab: vocab).write(to: dir.appendingPathComponent("tokenizer.json"))
        try Data(#"{"clean_up_tokenization_spaces": false}"#.utf8)
            .write(to: dir.appendingPathComponent("tokenizer_config.json"))
        let tokenizer = try ParakeetTokenizer(contentsOf: dir.appendingPathComponent("tokenizer.json"))
        #expect(tokenizer.decode(tokens: [3, 4, 5, 6]) == " don't .")
    }
}

@Suite struct CoreAISpeechVendoredModuleTests {
    @Test func reportsWhetherCoreAIIsCompiledIn() {
        #if canImport(CoreAI)
            #expect(CoreAISpeechVendoredModule.isCompiledIn)
        #else
            #expect(!CoreAISpeechVendoredModule.isCompiledIn)
        #endif
    }
}
