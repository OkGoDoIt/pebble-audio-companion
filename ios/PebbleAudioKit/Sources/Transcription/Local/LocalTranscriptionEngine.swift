import Foundation

// One seam for "which on-device engine runs", so the composition root resolves the persisted
// `local_transcription_model` id once and the rest of the pipeline stays engine-agnostic.
//
// The id space is deliberately open: a Parakeet catalog id selects Parakeet, and ANYTHING else
// is Apple Speech. An id that is a BCP-47 language tag ("en-US") picks the language to run it
// in; the `apple-speech` sentinel, an empty setting, or anything unrecognized means the device
// locale. That keeps Apple Speech the safe default on a fresh install — and for any id we do
// not understand — while a migrated user whose old setting names a Parakeet model keeps it.

public enum LocalTranscriptionEngineChoice: Equatable, Sendable {
    case appleSpeech(locale: Locale)
    case parakeet(ParakeetModelSpec)

    /// Selects Apple Speech in the device language without naming a locale.
    public static let appleSpeechId = "apple-speech"

    public static func resolve(modelId: String) -> LocalTranscriptionEngineChoice {
        if let spec = ParakeetModelCatalog.spec(id: modelId) { return .parakeet(spec) }
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != appleSpeechId, isLanguageTag(trimmed) else {
            return .appleSpeech(locale: .current)
        }
        return .appleSpeech(locale: Locale(identifier: trimmed))
    }

    /// True for something shaped like a BCP-47 tag ("en", "en-US", "zh-Hant-TW"). Anything else
    /// — a sentinel, a model id we do not know, junk — must not become a bogus `Locale`, which
    /// `SpeechTranscriber` would then report as an unsupported language.
    static func isLanguageTag(_ id: String) -> Bool {
        guard let language = id.split(separator: "-", omittingEmptySubsequences: false).first,
            (2...3).contains(language.count),
            language.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return false }
        return true
    }

    /// True when this id selects a downloadable Parakeet model rather than Apple Speech.
    public static func isParakeet(_ modelId: String) -> Bool {
        ParakeetModelCatalog.isParakeetId(modelId)
    }
}

/// The local `TranscriptionProvider` the pipeline holds: it delegates to Apple's
/// `SpeechAnalyzerProvider` or to a `ParakeetTranscriptionProvider`, resolved per call from the
/// persisted selection — so changing the Settings picker takes effect immediately, exactly like
/// `SelectableCloudTranscriptionProvider` does for the cloud backends.
///
/// One Cactus engine is shared across every Parakeet model: switching models reloads it in
/// place instead of leaving a second multi-hundred-MB model resident.
public final class SelectableLocalTranscriptionProvider: TranscriptionProvider,
    LocalTranscriptionLifecycle, @unchecked Sendable
{
    private let selected: @Sendable () -> String
    private let location: any ParakeetModelLocating
    private let engine: any ParakeetNativeEngine
    private let makeAppleSpeech: @Sendable (Locale) -> any TranscriptionProvider

    private let lock = NSLock()
    private var appleByLocale: [String: any TranscriptionProvider] = [:]
    private var parakeetById: [String: ParakeetTranscriptionProvider] = [:]

    public init(
        selected: @escaping @Sendable () -> String,
        location: any ParakeetModelLocating = ParakeetModelLocation(),
        engine: (any ParakeetNativeEngine)? = nil,
        makeAppleSpeech: @escaping @Sendable (Locale) -> any TranscriptionProvider = {
            SpeechAnalyzerProvider(locale: $0)
        }
    ) {
        self.selected = selected
        self.location = location
        self.engine = engine ?? ParakeetEngineFactory.make()
        self.makeAppleSpeech = makeAppleSpeech
    }

    public var choice: LocalTranscriptionEngineChoice {
        LocalTranscriptionEngineChoice.resolve(modelId: selected())
    }

    public var id: String { active().id }

    public func isAvailable() async -> Bool {
        await active().isAvailable()
    }

    public func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        try await active().transcribe(pcmChunks: pcmChunks, sampleRateHz: sampleRateHz)
    }

    /// The provider the current selection resolves to (cached, so the Parakeet engine handle
    /// and the analyzer configuration survive between segments).
    public func active() -> any TranscriptionProvider {
        switch choice {
        case .appleSpeech(let locale):
            let key = locale.identifier
            lock.lock()
            defer { lock.unlock() }
            if let existing = appleByLocale[key] { return existing }
            let created = makeAppleSpeech(locale)
            appleByLocale[key] = created
            return created
        case .parakeet(let spec):
            lock.lock()
            defer { lock.unlock() }
            if let existing = parakeetById[spec.id] { return existing }
            let created = ParakeetTranscriptionProvider(
                spec: spec, location: location, engine: engine
            )
            parakeetById[spec.id] = created
            return created
        }
    }

    // MARK: - LocalTranscriptionLifecycle

    /// Drops the resident Parakeet model. Apple Speech has no long-lived handle to release
    /// (its analyzer sessions are per-transcription), so this is Parakeet-only by nature.
    public func releaseModel(reason: String) async {
        await engine.release()
    }

    public func releaseModelIfIdle(nowMs: Int64, idleTimeoutMs: Int64) async {
        let providers = lock.withLock { Array(parakeetById.values) }
        for provider in providers {
            await provider.releaseModelIfIdle(nowMs: nowMs, idleTimeoutMs: idleTimeoutMs)
        }
    }
}
