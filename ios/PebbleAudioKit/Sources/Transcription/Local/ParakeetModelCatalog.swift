import Foundation

// Port of `app/src/commonMain/.../LocalTranscriptionModels.kt` — the downloadable on-device
// speech models the user can pick in Settings, alongside Apple's SpeechAnalyzer.
//
// Every field is carried across verbatim from the KMP catalog: the ids are persisted in
// `local_transcription_model`, the byte counts are what the download row promises before a
// ~700 MB transfer, and `installDirectoryName` decides whether an already-downloaded model is
// found or re-fetched. `Tests/TranscriptionTests/ParakeetCatalogTests.swift` pins all of it.

/// One downloadable Parakeet (Cactus-Compute conversion) speech model.
public struct ParakeetModelSpec: Sendable, Equatable, Identifiable {
    public let id: String
    /// Full name for the Settings row ("Parakeet TDT 0.6B, high quality").
    public let displayName: String
    /// One-word badge ("Recommended", "Small", "Experimental").
    public let shortLabel: String
    /// Sentence explaining the tradeoff, shown under the row.
    public let modelDescription: String
    public let repository: String
    public let revision: String
    public let archivePath: String
    /// Directory under `Caches/models` the archive installs into.
    public let installDirectoryName: String
    public let modelNameForProvenance: String
    public let modelVersionForProvenance: String
    /// Archive size in bytes, for the "this will download N GB" copy and progress totals.
    public let downloadBytes: Int64
    public let recommended: Bool

    public init(
        id: String,
        displayName: String,
        shortLabel: String,
        modelDescription: String,
        repository: String,
        revision: String,
        archivePath: String,
        installDirectoryName: String,
        modelNameForProvenance: String,
        modelVersionForProvenance: String,
        downloadBytes: Int64,
        recommended: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.shortLabel = shortLabel
        self.modelDescription = modelDescription
        self.repository = repository
        self.revision = revision
        self.archivePath = archivePath
        self.installDirectoryName = installDirectoryName
        self.modelNameForProvenance = modelNameForProvenance
        self.modelVersionForProvenance = modelVersionForProvenance
        self.downloadBytes = downloadBytes
        self.recommended = recommended
    }

    /// The Hugging Face archive URL (`{base}/{repository}/resolve/{revision}/{archivePath}`).
    public var downloadURL: URL {
        URL(
            string:
                "\(ParakeetModelCatalog.huggingFaceBase)/\(repository)/resolve/\(revision)/\(archivePath)"
        )!
    }

    /// Provenance string recorded on every transcript this model produces.
    public var modelUsed: String { "\(modelNameForProvenance):\(modelVersionForProvenance)" }
}

public enum ParakeetModelCatalog {
    public static let huggingFaceBase = "https://huggingface.co"
    /// The int8 TDT model — the one the old app shipped as the default download.
    public static let defaultModelId = "parakeet-tdt-0.6b-v3-int8"

    public static let all: [ParakeetModelSpec] = [
        ParakeetModelSpec(
            id: "parakeet-tdt-0.6b-v3-int4",
            displayName: "Parakeet TDT 0.6B, small",
            shortLabel: "Small",
            modelDescription: "Smallest download. Good for testing or tight storage, with lower "
                + "quantization precision than the recommended model.",
            repository: "Cactus-Compute/parakeet-tdt-0.6b-v3",
            revision: "v1.10",
            archivePath: "weights/parakeet-tdt-0.6b-v3-int4.zip",
            installDirectoryName: "parakeet-tdt-0.6b-v3-int4",
            modelNameForProvenance: "parakeet-tdt-0.6b-v3-int4",
            modelVersionForProvenance: "v1.10",
            downloadBytes: 430_744_371
        ),
        ParakeetModelSpec(
            id: defaultModelId,
            displayName: "Parakeet TDT 0.6B, high quality",
            shortLabel: "Recommended",
            modelDescription: "Best default for this app: multilingual Parakeet TDT v3 with int8 "
                + "weights for better local accuracy than the small quantized option.",
            repository: "Cactus-Compute/parakeet-tdt-0.6b-v3",
            revision: "v1.10",
            archivePath: "weights/parakeet-tdt-0.6b-v3-int8.zip",
            // Preserve the directory used by the first hardware-test builds so users who
            // already downloaded the original single model do not have to fetch it again.
            installDirectoryName: "parakeet-tdt-0.6b-v3",
            modelNameForProvenance: "parakeet-tdt-0.6b-v3-int8",
            modelVersionForProvenance: "v1.10",
            downloadBytes: 706_097_687,
            recommended: true
        ),
        ParakeetModelSpec(
            id: "parakeet-ctc-1.1b-int8",
            displayName: "Parakeet CTC 1.1B, experimental",
            shortLabel: "Experimental",
            modelDescription: "Fast English-only CTC model for comparison. It can over-interpret "
                + "quiet or noisy watch audio, so the recommended TDT model is the safer default.",
            repository: "Cactus-Compute/parakeet-ctc-1.1b",
            revision: "v1.14",
            archivePath: "weights/parakeet-ctc-1.1b-int8.zip",
            installDirectoryName: "parakeet-ctc-1.1b-int8",
            modelNameForProvenance: "parakeet-ctc-1.1b-int8",
            modelVersionForProvenance: "v1.14",
            downloadBytes: 1_184_422_635
        ),
    ]

    /// The spec with this id, or nil when the id is not a Parakeet model (e.g. it names the
    /// Apple Speech engine or a locale).
    public static func spec(id: String) -> ParakeetModelSpec? {
        all.first { $0.id == id }
    }

    /// Kotlin `LocalTranscriptionModels.byId` parity: an unknown id resolves to the default.
    /// Use `spec(id:)` when an unknown id must NOT silently become a Parakeet selection.
    public static func byId(_ id: String) -> ParakeetModelSpec {
        spec(id: id) ?? all.first { $0.id == defaultModelId }!
    }

    public static func isParakeetId(_ id: String) -> Bool { spec(id: id) != nil }
}
