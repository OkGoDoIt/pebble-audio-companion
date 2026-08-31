import Foundation
import Testing

@testable import Transcription

// The catalog is a wire-ish contract: the ids are persisted in `local_transcription_model`, the
// install directory decides whether an already-downloaded model is found again, and the byte
// counts are what the Settings row promises before a multi-hundred-MB transfer. This table is
// transcribed from `app/src/commonMain/.../LocalTranscriptionModels.kt` — the old app's catalog
// — so any drift from it fails here.

@Suite struct ParakeetCatalogTests {
    struct Row {
        let id: String
        let displayName: String
        let shortLabel: String
        let repository: String
        let revision: String
        let archivePath: String
        let installDirectoryName: String
        let modelName: String
        let modelVersion: String
        let downloadBytes: Int64
        let recommended: Bool
    }

    static let kotlinCatalog: [Row] = [
        Row(
            id: "parakeet-tdt-0.6b-v3-int4",
            displayName: "Parakeet TDT 0.6B, small",
            shortLabel: "Small",
            repository: "Cactus-Compute/parakeet-tdt-0.6b-v3",
            revision: "v1.10",
            archivePath: "weights/parakeet-tdt-0.6b-v3-int4.zip",
            installDirectoryName: "parakeet-tdt-0.6b-v3-int4",
            modelName: "parakeet-tdt-0.6b-v3-int4",
            modelVersion: "v1.10",
            downloadBytes: 430_744_371,
            recommended: false
        ),
        Row(
            id: "parakeet-tdt-0.6b-v3-int8",
            displayName: "Parakeet TDT 0.6B, high quality",
            shortLabel: "Recommended",
            repository: "Cactus-Compute/parakeet-tdt-0.6b-v3",
            revision: "v1.10",
            archivePath: "weights/parakeet-tdt-0.6b-v3-int8.zip",
            // Deliberately NOT "…-int8": the first hardware-test builds installed here, and
            // changing it would silently re-download 706 MB for those users.
            installDirectoryName: "parakeet-tdt-0.6b-v3",
            modelName: "parakeet-tdt-0.6b-v3-int8",
            modelVersion: "v1.10",
            downloadBytes: 706_097_687,
            recommended: true
        ),
        Row(
            id: "parakeet-ctc-1.1b-int8",
            displayName: "Parakeet CTC 1.1B, experimental",
            shortLabel: "Experimental",
            repository: "Cactus-Compute/parakeet-ctc-1.1b",
            revision: "v1.14",
            archivePath: "weights/parakeet-ctc-1.1b-int8.zip",
            installDirectoryName: "parakeet-ctc-1.1b-int8",
            modelName: "parakeet-ctc-1.1b-int8",
            modelVersion: "v1.14",
            downloadBytes: 1_184_422_635,
            recommended: false
        ),
    ]

    @Test func catalogMatchesTheKotlinCatalogExactly() throws {
        #expect(ParakeetModelCatalog.all.count == Self.kotlinCatalog.count)
        #expect(ParakeetModelCatalog.all.map(\.id) == Self.kotlinCatalog.map(\.id))
        for row in Self.kotlinCatalog {
            let spec = try #require(ParakeetModelCatalog.spec(id: row.id))
            #expect(spec.displayName == row.displayName)
            #expect(spec.shortLabel == row.shortLabel)
            #expect(spec.repository == row.repository)
            #expect(spec.revision == row.revision)
            #expect(spec.archivePath == row.archivePath)
            #expect(spec.installDirectoryName == row.installDirectoryName)
            #expect(spec.modelNameForProvenance == row.modelName)
            #expect(spec.modelVersionForProvenance == row.modelVersion)
            #expect(spec.downloadBytes == row.downloadBytes)
            #expect(spec.recommended == row.recommended)
            #expect(!spec.modelDescription.isEmpty)
        }
    }

    @Test func exactlyOneModelIsRecommendedAndItIsTheDefault() {
        let recommended = ParakeetModelCatalog.all.filter(\.recommended)
        #expect(recommended.count == 1)
        #expect(recommended.first?.id == ParakeetModelCatalog.defaultModelId)
        #expect(ParakeetModelCatalog.defaultModelId == "parakeet-tdt-0.6b-v3-int8")
    }

    @Test func downloadUrlIsTheHuggingFaceResolveEndpoint() throws {
        let spec = try #require(ParakeetModelCatalog.spec(id: "parakeet-ctc-1.1b-int8"))
        #expect(
            spec.downloadURL.absoluteString
                == "https://huggingface.co/Cactus-Compute/parakeet-ctc-1.1b/resolve/v1.14/weights/parakeet-ctc-1.1b-int8.zip"
        )
        for spec in ParakeetModelCatalog.all {
            #expect(spec.downloadURL.scheme == "https")
            #expect(spec.downloadURL.host == "huggingface.co")
        }
    }

    @Test func provenanceStringPairsNameAndVersion() throws {
        let spec = try #require(ParakeetModelCatalog.spec(id: ParakeetModelCatalog.defaultModelId))
        #expect(spec.modelUsed == "parakeet-tdt-0.6b-v3-int8:v1.10")
    }

    @Test func lookupSeparatesStrictFromKotlinFallback() {
        #expect(ParakeetModelCatalog.spec(id: "en-US") == nil)
        #expect(ParakeetModelCatalog.spec(id: "") == nil)
        #expect(ParakeetModelCatalog.isParakeetId("en-US") == false)
        #expect(ParakeetModelCatalog.isParakeetId("parakeet-ctc-1.1b-int8"))
        // Kotlin `byId` parity: unknown ids resolve to the default model.
        #expect(ParakeetModelCatalog.byId("nope").id == ParakeetModelCatalog.defaultModelId)
    }

    @Test func engineChoiceResolvesParakeetIdsAndTreatsEverythingElseAsAppleSpeech() {
        #expect(
            LocalTranscriptionEngineChoice.resolve(modelId: "parakeet-ctc-1.1b-int8")
                == .parakeet(ParakeetModelCatalog.byId("parakeet-ctc-1.1b-int8"))
        )
        #expect(
            LocalTranscriptionEngineChoice.resolve(modelId: "en-GB")
                == .appleSpeech(locale: Locale(identifier: "en-GB"))
        )
        #expect(
            LocalTranscriptionEngineChoice.resolve(modelId: "zh-Hant-TW")
                == .appleSpeech(locale: Locale(identifier: "zh-Hant-TW"))
        )
        // Fresh install, the explicit sentinel, and anything unrecognized all mean "Apple
        // Speech in the device language" — never a bogus Locale that reads as unsupported.
        for id in ["", "  ", LocalTranscriptionEngineChoice.appleSpeechId, "whisper-tiny", "🙂"] {
            #expect(
                LocalTranscriptionEngineChoice.resolve(modelId: id) == .appleSpeech(locale: .current),
                "\(id) should fall back to the device locale"
            )
        }
        #expect(LocalTranscriptionEngineChoice.isParakeet("en-US") == false)
        #expect(LocalTranscriptionEngineChoice.isLanguageTag("en"))
        #expect(LocalTranscriptionEngineChoice.isLanguageTag("apple-speech") == false)
    }
}
