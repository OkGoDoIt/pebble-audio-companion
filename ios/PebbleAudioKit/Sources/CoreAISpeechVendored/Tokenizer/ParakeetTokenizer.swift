import Foundation

// NOT vendored — written for PebbleAudioKit. Replaces the one thing the upstream CoreAISpeech
// package used swift-transformers for: turning the decoder's token ids back into text.
//
// Upstream calls `Tokenizer.decode(tokens:)` on an `AutoTokenizer` built from the bundle's
// `processor/tokenizer.json`. For a Parakeet bundle that tokenizer is a BPE model with a
// `Metaspace` decoder, and swift-transformers' decode path is small enough to reproduce exactly:
//
//   1. id → piece through the model vocab merged with `added_tokens` (added tokens win);
//      an id with no piece is dropped (`compactMap`).
//   2. `MetaspaceDecoder`: every occurrence of `replacement` ("▁") in every piece becomes a
//      space; when `add_prefix_space` is true and the first piece starts with a space, that one
//      space is removed. The pieces are then joined with nothing between them.
//   3. `clean_up_tokenization_spaces` (from `tokenizer_config.json`, default TRUE in
//      swift-transformers) applies the fixed list of English punctuation fix-ups.
//
// The vendored `SpeechRecognitionModel.detokenize` then trims surrounding whitespace, exactly as
// upstream does. `CoreAISpeechVendoredTests` proves the whole chain byte-identical to the
// upstream CLI on real watch audio.
//
// Encoding is deliberately absent: nothing in the kit needs text → ids.

/// Decodes Parakeet token ids to text from a Hugging Face `tokenizer.json`.
public struct ParakeetTokenizer: Sendable, Equatable {
    public enum LoadError: Error, Equatable, Sendable {
        case malformed(String)
        /// A `decoder` block this decoder does not implement; `Metaspace` (or none) is what
        /// Parakeet bundles ship.
        case unsupportedDecoder(String)
    }

    /// Piece for each id, indexed by id. Sparse ids leave `nil` holes.
    private let pieces: [String?]
    private let replacement: String
    private let addPrefixSpace: Bool
    private let cleanUpTokenizationSpaces: Bool

    /// Reads `tokenizer.json`, and `tokenizer_config.json` beside it when present (for
    /// `clean_up_tokenization_spaces`; absent means true, as in swift-transformers).
    public init(contentsOf tokenizerURL: URL) throws {
        let data = try Data(contentsOf: tokenizerURL)
        let configURL = tokenizerURL.deletingLastPathComponent()
            .appendingPathComponent("tokenizer_config.json")
        let configData = try? Data(contentsOf: configURL)
        try self.init(tokenizerJSON: data, tokenizerConfigJSON: configData)
    }

    public init(tokenizerJSON: Data, tokenizerConfigJSON: Data? = nil) throws {
        guard let root = try? JSONSerialization.jsonObject(with: tokenizerJSON) as? [String: Any]
        else { throw LoadError.malformed("tokenizer.json is not a JSON object") }
        guard let model = root["model"] as? [String: Any],
            let vocab = model["vocab"] as? [String: Any]
        else { throw LoadError.malformed("tokenizer.json has no model.vocab") }

        var table: [Int: String] = [:]
        table.reserveCapacity(vocab.count)
        for (piece, rawId) in vocab {
            guard let id = Self.int(rawId) else {
                throw LoadError.malformed("vocab id for \(piece) is not an integer")
            }
            table[id] = piece
        }
        // Added tokens override the model vocab, as `vocab.merging(addedTokens) { $1 }` does.
        for case let entry as [String: Any] in root["added_tokens"] as? [Any] ?? [] {
            guard let id = Self.int(entry["id"]), let content = entry["content"] as? String
            else { throw LoadError.malformed("added_tokens entry without id/content") }
            table[id] = content
        }
        guard let maxId = table.keys.max(), maxId >= 0 else {
            throw LoadError.malformed("tokenizer.json has an empty vocab")
        }
        var pieces = [String?](repeating: nil, count: maxId + 1)
        for (id, piece) in table where id >= 0 { pieces[id] = piece }
        self.pieces = pieces

        switch root["decoder"] {
        case nil, is NSNull:
            self.replacement = ""
            self.addPrefixSpace = false
        case let decoder as [String: Any]:
            let type = decoder["type"] as? String ?? ""
            guard type == "Metaspace" else { throw LoadError.unsupportedDecoder(type) }
            // swift-transformers' defaults: `replacement` "_" and `add_prefix_space` false.
            self.replacement = decoder["replacement"] as? String ?? "_"
            self.addPrefixSpace = decoder["add_prefix_space"] as? Bool ?? false
        default:
            throw LoadError.malformed("decoder is not an object")
        }

        var cleanUp = true
        if let configData = tokenizerConfigJSON,
            let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
            let flag = config["clean_up_tokenization_spaces"] as? Bool
        {
            cleanUp = flag
        }
        self.cleanUpTokenizationSpaces = cleanUp
    }

    /// Number of ids the table covers (the highest id + 1).
    public var count: Int { pieces.count }

    /// The piece for `id`, or nil when the vocab has no such id.
    public func piece(for id: Int) -> String? {
        guard id >= 0, id < pieces.count else { return nil }
        return pieces[id]
    }

    /// Text for `tokens`, reproducing swift-transformers' `decode(tokens:skipSpecialTokens:
    /// false)` for a Metaspace-decoded tokenizer. Special tokens are NOT skipped, because
    /// upstream never asked for that either.
    public func decode(tokens: [Int]) -> String {
        var decoded: [String] = []
        decoded.reserveCapacity(tokens.count)
        for id in tokens {
            guard let piece = piece(for: id) else { continue }
            decoded.append(
                replacement.isEmpty ? piece : piece.replacingOccurrences(of: replacement, with: " ")
            )
        }
        if addPrefixSpace, decoded.first?.hasPrefix(" ") == true {
            decoded[0].removeFirst()
        }
        let text = decoded.joined()
        return cleanUpTokenizationSpaces ? Self.cleanUp(text) : text
    }

    /// swift-transformers `PreTrainedTokenizer.cleanUp(text:)`, verbatim order.
    static func cleanUp(_ text: String) -> String {
        text
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " ' ", with: "'")
            .replacingOccurrences(of: " n't", with: "n't")
            .replacingOccurrences(of: " 'm", with: "'m")
            .replacingOccurrences(of: " 's", with: "'s")
            .replacingOccurrences(of: " 've", with: "'ve")
            .replacingOccurrences(of: " 're", with: "'re")
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return number.intValue
    }
}
