import AppDB
import Foundation

// Port of `app/src/commonMain/.../LocalTranscriptionModels.kt` — the downloadable on-device
// speech models the user can pick in Settings, alongside Apple's SpeechAnalyzer.
//
// Every field is carried across verbatim from the KMP catalog: the ids are persisted in
// `local_transcription_model`, the byte counts are what the download row promises before a
// ~700 MB transfer, and `installDirectoryName` decides whether an already-downloaded model is
// found or re-fetched. `Tests/TranscriptionTests/ParakeetCatalogTests.swift` pins all of it.
//
// Since the iOS 27 build-out the catalog also carries the Core AI export of the same Parakeet
// checkpoint (`runtime: .coreAI`), which installs and is selected through the same rows but runs
// on `CoreAIParakeetEngine` and needs a one-time prepare step after extraction.

/// One downloadable Parakeet speech model (a Cactus-Compute conversion or a Core AI export).
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
    /// The native runtime that loads this model. Decides the engine, the install marker and
    /// version file names, and whether a prepare step follows extraction.
    public let runtime: LocalEngineRuntime

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
        recommended: Bool = false,
        runtime: LocalEngineRuntime = .cactus
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
        self.runtime = runtime
    }

    /// The Hugging Face archive URL (`{base}/{repository}/resolve/{revision}/{archivePath}`)
    /// as the catalog states it.
    public var catalogDownloadURL: URL {
        URL(
            string:
                "\(ParakeetModelCatalog.huggingFaceBase)/\(repository)/resolve/\(revision)/\(archivePath)"
        )!
    }

    /// The URL the store actually downloads from: `catalogDownloadURL` unless the App Group
    /// defaults carry `local_model_url_override.<id>` (a development affordance for serving an
    /// archive from a LAN HTTP server; nothing in the app writes the key).
    public var downloadURL: URL {
        downloadURL(resolvingOverride: ParakeetModelCatalog.downloadURLOverride)
    }

    /// `downloadURL` with the override lookup injected, so the rule is testable without
    /// touching the real defaults suite. An override that is not a usable absolute URL is
    /// ignored rather than turned into a download that can only fail.
    public func downloadURL(resolvingOverride override: (_ modelId: String) -> String?) -> URL {
        guard let raw = override(id)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty, let url = URL(string: raw), url.scheme != nil, url.host != nil
        else { return catalogDownloadURL }
        return url
    }

    /// Provenance string recorded on every transcript this model produces.
    public var modelUsed: String { "\(modelNameForProvenance):\(modelVersionForProvenance)" }

    /// The file whose presence means "the archive unpacked": what the runtime itself needs first.
    public var installMarkerFileName: String {
        switch runtime {
        case .cactus: return "config.txt"
        case .coreAI: return "metadata.json"
        }
    }

    /// Written after a successful extraction with the spec revision it was installed from.
    public var versionFileName: String {
        switch runtime {
        case .cactus: return ".cactus_version"
        case .coreAI: return ".coreai_version"
        }
    }

    /// True when the model needs a foreground prepare pass (Core AI's specialization) before
    /// its first use; `preparedMarkerFileName` records that it has happened.
    public var requiresPreparation: Bool { runtime == .coreAI }

    /// Written next to the version file once the prepare pass completed.
    public var preparedMarkerFileName: String { ".prepared" }
}

public enum ParakeetModelCatalog {
    public static let huggingFaceBase = "https://huggingface.co"
    /// The int8 TDT model — the one the old app shipped as the default download.
    public static let defaultModelId = "parakeet-tdt-0.6b-v3-int8"
    /// The Core AI export of the same checkpoint — the iOS 27 experiment.
    public static let coreAIModelId = "parakeet-tdt-0.6b-v3-coreai"

    /// App Group defaults key prefix for a per-model download URL override; see
    /// `ParakeetModelSpec.downloadURL`.
    public static let downloadURLOverrideKeyPrefix = "local_model_url_override."

    /// The override for `modelId` from the App Group defaults, or nil.
    public static func downloadURLOverride(for modelId: String) -> String? {
        UserDefaults(suiteName: AppDatabase.appGroupIdentifier)?
            .string(forKey: downloadURLOverrideKeyPrefix + modelId)
    }

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
        // The Core AI export (apple/coreai-models `export.py --streaming`, float16, 150-frame
        // window) of the same Parakeet TDT v3 checkpoint. NOT published anywhere yet: the
        // repository/archive path below is a placeholder under a clearly-named path, and until a
        // release exists the model is installed from `Documents/models-inbox/<id>.zip` (Files) or
        // from a URL override — see `ParakeetModelStore` and `downloadURL`. The byte count is the
        // measured size of a stored (`zip -0`) archive of the exported bundle; the ~1.1 GB
        // specialization cache Core AI writes on first load comes on top and is what the
        // description warns about.
        ParakeetModelSpec(
            id: coreAIModelId,
            displayName: "Parakeet TDT 0.6B · Core AI",
            shortLabel: "iOS 27 experiment",
            modelDescription: "The same Parakeet model on Apple's Core AI runtime, to compare "
                + "against the built-in engine. iPhone with iOS 27 only. Downloads 1.2 GB and "
                + "uses about 1.1 GB more the first time it runs.",
            repository: "pebble-audio-companion/parakeet-tdt-0.6b-v3-coreai-UNPUBLISHED",
            revision: "v1",
            archivePath: "bundles/parakeet-tdt-0.6b-v3_float16_streaming150.zip",
            installDirectoryName: "parakeet-tdt-0.6b-v3-coreai",
            modelNameForProvenance: "parakeet-tdt-0.6b-v3-coreai",
            modelVersionForProvenance: "v1",
            downloadBytes: 1_256_163_783,
            runtime: .coreAI
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
