// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause
// Vendored into PebbleAudioKit from apple/coreai-models @ 1ff17c3 (2026-09-17); the changes
// against upstream are listed in ../VENDORING.md.

#if canImport(CoreAI)
import AVFoundation
import CoreAI
import Foundation

// MARK: - SpeechRecognitionBundle

/// Locates and loads the assets inside a CoreAISpeech model bundle directory.
///
/// Two layouts are supported:
///
/// **Whisper (legacy)**: directory contains `encoder.aimodel` + `decoder.aimodel`,
/// optional `generation_config.json`, and an optional `tokenizer.json` (else loaded
/// from the local Hugging Face cache).
///
/// **Parakeet TDT**: directory contains `metadata.json` (with `kind:
/// "speech_recognizer"` and `config.architecture: "parakeet_tdt"`, an `assets`
/// map for `encoder` / `decoder_step` / `joint`, and a TDT `config` block), the
/// three `.aimodel` assets, and a `processor/` subdirectory carrying the tokenizer.
@available(iOS 27, macOS 27, *)
public struct SpeechRecognitionBundle: Sendable {
    public let kind: Kind
    /// Vendoring change: upstream holds a swift-transformers `Tokenizer`; this copy decodes with
    /// `ParakeetTokenizer`, which reads the bundle's `processor/tokenizer.json` directly.
    /// Whisper bundles therefore load without a tokenizer (see `loadWhisperTokenizer`).
    public let tokenizer: ParakeetTokenizer?

    public enum Kind: Sendable {
        case whisper(WhisperAssets)
        case parakeetTDT(ParakeetTDTAssets)
    }

    /// Speech-recognizer architecture, read from the `architecture` field of the
    /// metadata's `config` block. Absent ⇒ `.whisper` (legacy bundles predate the
    /// field and only ever carried Whisper assets).
    package enum Architecture: String, Sendable, Decodable {
        case whisper
        case parakeetTDT = "parakeet_tdt"
    }

    public struct WhisperAssets: Sendable {
        public let encoder: AIModel
        public let decoder: AIModel
        public let generationConfig: GenerationConfig
        public let melConfig: MelConfig
    }

    public struct ParakeetTDTAssets: Sendable {
        public let encoder: AIModel
        public let decoderStep: AIModel
        public let joint: AIModel
        public let config: ParakeetTDTConfig
        public let melConfig: MelConfig
        /// Non-nil only for bundles from `export.py --streaming`, which record the
        /// window geometry they were traced for.
        public let streamingConfig: StreamingConfig?
    }

    // Vendoring addition: `decoderOptions` places a Parakeet TDT bundle's two small per-step graphs
    // (`decoder_step`, `joint`) apart from the encoder. See VENDORING.md.
    public init(at url: URL, decoderOptions: SpecializationOptions = .default) async throws {
        let metadataURL = url.appending(path: "metadata.json")
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            let bundle = try ModelBundle(at: url)
            switch bundle.kind {
            case .speechRecognizer:
                switch Self.architecture(from: bundle.raw) {
                case .parakeetTDT:
                    let assets = try await Self.loadParakeetTDT(
                        bundle: bundle, decoderOptions: decoderOptions)
                    self.kind = .parakeetTDT(assets)
                    self.tokenizer = try? await Self.loadParakeetTokenizer(bundleURL: url)
                case .whisper:
                    let assets = try await Self.loadWhisper(bundleURL: url)
                    self.kind = .whisper(assets)
                    self.tokenizer = try? await Self.loadWhisperTokenizer(
                        bundleURL: url, config: assets.generationConfig)
                }
            default:
                throw SpeechError.missingModel(
                    "metadata.json kind '\(bundle.kind.rawValue)' is not a speech recognizer")
            }
            return
        }
        // Legacy Whisper bundle (no metadata.json).
        let assets = try await Self.loadWhisper(bundleURL: url)
        self.kind = .whisper(assets)
        self.tokenizer = try? await Self.loadWhisperTokenizer(
            bundleURL: url, config: assets.generationConfig)
    }

    // MARK: - Loaders

    /// Read the speech architecture from the metadata's `config.architecture`
    /// field, defaulting to `.whisper` when the block or field is absent.
    package static func architecture(from raw: Data) -> Architecture {
        struct Payload: Decodable {
            struct Config: Decodable { let architecture: Architecture? }
            let config: Config?
        }
        let payload = try? JSONDecoder().decode(Payload.self, from: raw)
        return payload?.config?.architecture ?? .whisper
    }

    private static func loadWhisper(bundleURL: URL) async throws -> WhisperAssets {
        let encURL = bundleURL.appending(path: "encoder.aimodel")
        let decURL = bundleURL.appending(path: "decoder.aimodel")
        guard FileManager.default.fileExists(atPath: encURL.path),
            FileManager.default.fileExists(atPath: decURL.path)
        else {
            throw SpeechError.missingModel(
                "Whisper bundle at \(bundleURL.lastPathComponent) must contain encoder.aimodel and decoder.aimodel")
        }
        let encoder = try await AIModel(contentsOf: encURL)
        let decoder = try await AIModel(contentsOf: decURL)
        let cfgURL = bundleURL.appending(path: "generation_config.json")
        let generationConfig = (try? GenerationConfig(from: cfgURL)) ?? .whisper
        return WhisperAssets(
            encoder: encoder, decoder: decoder,
            generationConfig: generationConfig, melConfig: .whisper)
    }

    private static func loadParakeetTDT(
        bundle: ModelBundle, decoderOptions: SpecializationOptions
    ) async throws -> ParakeetTDTAssets {
        let encURL = try bundle.requireModelURL(for: "encoder")
        let stepURL = try bundle.requireModelURL(for: "decoder_step")
        let jointURL = try bundle.requireModelURL(for: "joint")
        let encoder = try await AIModel(contentsOf: encURL)
        // Vendoring change: the per-step graphs take `decoderOptions` (upstream: default).
        let decoderStep = try await AIModel(contentsOf: stepURL, options: decoderOptions)
        let joint = try await AIModel(contentsOf: jointURL, options: decoderOptions)
        let config = try ParakeetTDTConfig.decode(fromMetadata: bundle.raw)

        // Auto-detect static encoder shape and bake nFrames into the mel config
        // so that fromPCM pads/truncates to exactly the traced frame count.
        // Dynamic encoders (dim < 0) leave nFrames nil, preserving existing behaviour.
        var melConfig = MelConfig.parakeet
        if let desc = encoder.functionDescriptor(for: "main"),
            case .ndArray(let nd) = desc.inputDescriptor(of: "input_features")
        {
            let tDim = MelConfig.parakeet.layout == .timeMajor ? 1 : 2
            melConfig = Self.melConfig(forEncoderTimeDim: nd.shape[tDim])
        }

        // A streaming export records its geometry; cross-check it against the graph and against
        // itself rather than trusting the JSON, since a one-frame disagreement would misalign
        // every chunk boundary.
        let streamingConfig = try StreamingConfig.decode(fromMetadata: bundle.raw)
        if let streamingConfig {
            try streamingConfig.validate(
                maxDuration: config.durations.max() ?? 0, encoderMelFrames: melConfig.nFrames)
        }

        return ParakeetTDTAssets(
            encoder: encoder, decoderStep: decoderStep, joint: joint,
            config: config, melConfig: melConfig, streamingConfig: streamingConfig)
    }

    /// The mel config for an encoder whose time dimension is `dim`.
    ///
    /// A positive `dim` means a static export, so the traced frame count is baked in; a negative or
    /// zero `dim` marks a dynamic axis and leaves `nFrames` nil.
    package static func melConfig(forEncoderTimeDim dim: Int) -> MelConfig {
        dim > 0 ? MelConfig.parakeet.withNFrames(dim) : .parakeet
    }

    // MARK: - Tokenizer loading

    /// Vendoring change: Whisper's byte-level BPE tokenizer came from swift-transformers
    /// (`AutoTokenizer` over `tokenizer.json`, or the Hugging Face cache on macOS). This copy
    /// carries no Whisper decoder, so a Whisper bundle loads but `detokenize` throws
    /// `SpeechError.missingTokenizer`. The app only ever installs Parakeet bundles.
    private static func loadWhisperTokenizer(
        bundleURL: URL, config: GenerationConfig
    ) async throws -> ParakeetTokenizer? {
        nil
    }

    private static func loadParakeetTokenizer(bundleURL: URL) async throws -> ParakeetTokenizer? {
        // Parakeet bundles ship the tokenizer in `processor/`.
        let processor = bundleURL.appending(path: "processor")
        let tokenizerURL = processor.appending(path: "tokenizer.json")
        if FileManager.default.fileExists(atPath: tokenizerURL.path) {
            do {
                return try ParakeetTokenizer(contentsOf: tokenizerURL)
            } catch {
                fputs("[SpeechRecognitionBundle] Failed to load Parakeet tokenizer: \(error)\n", stderr)
                return nil
            }
        }
        return nil
    }
}

// MARK: - GenerationConfig (Whisper)

/// Whisper-style generation parameters, read from `generation_config.json` in the bundle.
@available(iOS 27, macOS 27, *)
public struct GenerationConfig: Sendable {
    /// Tokens prepended to every decode sequence before free generation.
    public let forcedPrefix: [Int32]
    /// Token that signals end of transcription.
    public let eotToken: Int32
    /// Maximum tokens to generate per call.
    public let maxDecodeSteps: Int
    /// HuggingFace model name for loading the tokenizer from cache.
    public let tokenizerName: String?

    /// Whisper large-v3-turbo defaults.
    public static let whisper = GenerationConfig(
        forcedPrefix: [50258, 50259, 50360, 50364],  // BOS <|en|> <|transcribe|> <|notimestamps|>
        eotToken: 50257,
        maxDecodeSteps: 50,
        tokenizerName: "openai/whisper-large-v3-turbo"
    )

    init(forcedPrefix: [Int32], eotToken: Int32, maxDecodeSteps: Int, tokenizerName: String?) {
        self.forcedPrefix = forcedPrefix
        self.eotToken = eotToken
        self.maxDecodeSteps = maxDecodeSteps
        self.tokenizerName = tokenizerName
    }

    init(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let rawPairs = json["forced_decoder_ids"] as? [[Any]] {
            // HF format: [[position, token_id], ...] where token_id can be null
            var tokens: [(pos: Int, id: Int32)] = []
            for pair in rawPairs {
                guard pair.count >= 2,
                    let pos = pair[0] as? Int,
                    let id = pair[1] as? Int
                else { continue }
                tokens.append((pos: pos, id: Int32(id)))
            }
            forcedPrefix = tokens.sorted { $0.pos < $1.pos }.map(\.id)
        } else {
            forcedPrefix = Self.whisper.forcedPrefix
        }
        eotToken = (json["eos_token_id"] as? Int).map { Int32($0) } ?? Self.whisper.eotToken
        maxDecodeSteps = (json["max_new_tokens"] as? Int) ?? Self.whisper.maxDecodeSteps
        tokenizerName = json["tokenizer_name"] as? String ?? Self.whisper.tokenizerName
    }
}

// MARK: - ParakeetTDTConfig

/// Parakeet TDT decoder configuration, decoded from the `config` block of a
/// `speech_recognizer` bundle whose `config.architecture` is `"parakeet_tdt"`.
@available(iOS 27, macOS 27, *)
public struct ParakeetTDTConfig: Sendable {
    public let vocabSize: Int
    public let blankTokenId: Int32
    public let decoderHiddenSize: Int
    public let numDecoderLayers: Int
    public let maxSymbolsPerStep: Int
    public let durations: [Int]
    public let encoderNumMelBins: Int
    public let encoderSubsamplingFactor: Int

    public init(
        vocabSize: Int, blankTokenId: Int32, decoderHiddenSize: Int,
        numDecoderLayers: Int, maxSymbolsPerStep: Int, durations: [Int],
        encoderNumMelBins: Int, encoderSubsamplingFactor: Int
    ) {
        self.vocabSize = vocabSize
        self.blankTokenId = blankTokenId
        self.decoderHiddenSize = decoderHiddenSize
        self.numDecoderLayers = numDecoderLayers
        self.maxSymbolsPerStep = maxSymbolsPerStep
        self.durations = durations
        self.encoderNumMelBins = encoderNumMelBins
        self.encoderSubsamplingFactor = encoderSubsamplingFactor
    }

    static func decode(fromMetadata raw: Data) throws -> ParakeetTDTConfig {
        let payload = try JSONDecoder().decode(MetadataPayload.self, from: raw)
        guard let cfg = payload.config else {
            throw ModelBundle.BundleError.missingField("config")
        }
        // `encoderFrameCount` derives every valid-frame count by halving, so a factor that
        // isn't a power of two would trip its precondition on the first decode.
        guard isValidSubsamplingFactor(cfg.encoder.subsamplingFactor) else {
            throw SpeechError.missingModel(
                "config.encoder.subsampling_factor must be a power of two, got "
                    + "\(cfg.encoder.subsamplingFactor)")
        }
        return ParakeetTDTConfig(
            vocabSize: cfg.vocabSize,
            blankTokenId: Int32(cfg.blankTokenId),
            decoderHiddenSize: cfg.decoderHiddenSize,
            numDecoderLayers: cfg.numDecoderLayers,
            maxSymbolsPerStep: cfg.maxSymbolsPerStep,
            durations: cfg.durations,
            encoderNumMelBins: cfg.encoder.numMelBins,
            encoderSubsamplingFactor: cfg.encoder.subsamplingFactor)
    }

    fileprivate struct MetadataPayload: Decodable {
        let config: ConfigBlock?
    }

    fileprivate struct ConfigBlock: Decodable {
        let vocabSize: Int
        let blankTokenId: Int
        let decoderHiddenSize: Int
        let numDecoderLayers: Int
        let maxSymbolsPerStep: Int
        let durations: [Int]
        let encoder: EncoderBlock

        enum CodingKeys: String, CodingKey {
            case vocabSize = "vocab_size"
            case blankTokenId = "blank_token_id"
            case decoderHiddenSize = "decoder_hidden_size"
            case numDecoderLayers = "num_decoder_layers"
            case maxSymbolsPerStep = "max_symbols_per_step"
            case durations
            case encoder
        }
    }

    fileprivate struct EncoderBlock: Decodable {
        let numMelBins: Int
        let subsamplingFactor: Int

        enum CodingKeys: String, CodingKey {
            case numMelBins = "num_mel_bins"
            case subsamplingFactor = "subsampling_factor"
        }
    }
}

// MARK: - SpeechError

@available(iOS 27, macOS 27, *)
public enum SpeechError: Error, CustomStringConvertible, LocalizedError {
    case missingModel(String)
    case missingTokenizer
    case invalidAudio(String)
    case incompatibleResources(String)
    case invalidStreamingConfig(String)

    public var description: String {
        switch self {
        case .missingModel(let msg): return "Missing model: \(msg)"
        case .missingTokenizer:
            return "Tokenizer not found — ensure the model bundle includes a tokenizer or the HF cache is populated"
        case .invalidAudio(let msg): return "Invalid audio: \(msg)"
        case .incompatibleResources(let msg): return "Incompatible decoder resources: \(msg)"
        case .invalidStreamingConfig(let msg): return "Invalid streaming config: \(msg)"
        }
    }

    /// Without this, `error.localizedDescription` — what a SwiftUI host app naturally shows a
    /// user — bridges through `NSError` and reports an opaque error number instead.
    public var errorDescription: String? { description }
}
#endif
