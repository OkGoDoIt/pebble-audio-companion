import CompanionRuntime
import Foundation
import Intelligence
import Testing
import Transcription

// Settings · Transcription & AI shows only the rows the chosen modes actually use, and says
// whether this phone can run the local half at all.
//
// The table below is the point of this suite. Sixteen combinations (four transcription modes ×
// four AI modes, each axis independent) is more than anyone checks by hand, so the failure this
// pins is silent: a row that quietly comes back in a configuration that never reads it. That is
// what was reported — "AI · Mode · Local only" sitting above "OpenAI key · not set", asking for
// a credential nothing in that configuration would ever send.
//
// It is written as an EXPLICIT expectation per pair rather than as `mode != .localOnly`, on
// purpose: a test that re-derives the rule from the same predicate the code uses would pass
// however the predicate changed.
@Suite("TS · transcription & AI row visibility") @MainActor
struct TSTranscriptionRowVisibilityTests {

    // MARK: - Helpers

    /// The non-key rows, named the way the screen names them.
    private enum Row: String, CaseIterable, Comparable {
        case localModel
        case cloudProvider
        case uploadNetwork
        case backgroundCatchUp
        case onDeviceAi
        case cloudModel

        static func < (a: Row, b: Row) -> Bool { a.rawValue < b.rawValue }
    }

    private func rows(_ plan: TranscriptionAiRowPlan) -> Set<Row> {
        var shown: Set<Row> = []
        if plan.showsLocalModel { shown.insert(.localModel) }
        if plan.showsCloudProvider { shown.insert(.cloudProvider) }
        if plan.showsUploadNetwork { shown.insert(.uploadNetwork) }
        if plan.showsBackgroundCatchUp { shown.insert(.backgroundCatchUp) }
        if plan.showsOnDeviceAi { shown.insert(.onDeviceAi) }
        if plan.showsCloudModel { shown.insert(.cloudModel) }
        return shown
    }

    private func makePlan(
        _ transcription: TranscriptionMode,
        _ ai: AiProcessingMode,
        provider: CloudProvider = .soniox
    ) -> TranscriptionAiRowPlan {
        TranscriptionAiRowPlan(
            transcriptionMode: transcription, aiMode: ai, cloudTranscriptionProvider: provider
        )
    }

    /// Every transcription × AI pair. Sixteen, because the two axes are configured separately
    /// and each has four modes — the same enumeration `PrivacyStanceTests` walks.
    private static let allModePairs: [(TranscriptionMode, AiProcessingMode)] = {
        var pairs: [(TranscriptionMode, AiProcessingMode)] = []
        for transcription in TranscriptionMode.allCases {
            for ai in AiProcessingMode.allCases { pairs.append((transcription, ai)) }
        }
        return pairs
    }()

    /// A real `AppSettings` on a throwaway defaults suite, so the cross-check against the
    /// privacy stance exercises the REAL mode → destination derivation rather than a second copy
    /// of it written here. One suite name per call: Swift Testing runs these in parallel.
    private func makeSettings() -> AppSettings {
        let suite = "ts-row-visibility-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults, keychain: KeychainStore(service: "tests.unused"))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - The table
    // ─────────────────────────────────────────────────────────────────────────

    /// One row of the expectation, with the cloud transcription provider fixed at Soniox so the
    /// two key rows are distinguishable. The OpenAI-as-both case is pinned separately below.
    private struct Expectation {
        let transcription: TranscriptionMode
        let ai: AiProcessingMode
        let rows: Set<Row>
        /// In screen order: transcription first, then AI.
        let keyRows: [CloudProvider]
        let testConnection: Bool
        let fullyLocal: Bool
    }

    private static let table: [Expectation] = [
        // ── Transcription: Local only — no provider, no key, no upload choice, no test ───────
        Expectation(
            transcription: .localOnly, ai: .localOnly,
            rows: [.localModel, .backgroundCatchUp, .onDeviceAi],
            keyRows: [], testConnection: false, fullyLocal: true),
        Expectation(
            transcription: .localOnly, ai: .localFirst,
            rows: [.localModel, .backgroundCatchUp, .onDeviceAi, .cloudModel],
            keyRows: [.openAi], testConnection: false, fullyLocal: false),
        Expectation(
            transcription: .localOnly, ai: .remoteFirst,
            rows: [.localModel, .backgroundCatchUp, .onDeviceAi, .cloudModel],
            keyRows: [.openAi], testConnection: false, fullyLocal: false),
        Expectation(
            transcription: .localOnly, ai: .remoteOnly,
            rows: [.localModel, .backgroundCatchUp, .cloudModel],
            keyRows: [.openAi], testConnection: false, fullyLocal: false),

        // ── Transcription: Local first — the fallback is what needs the key ─────────────────
        Expectation(
            transcription: .localFirst, ai: .localOnly,
            rows: [.localModel, .cloudProvider, .uploadNetwork, .backgroundCatchUp, .onDeviceAi],
            keyRows: [.soniox], testConnection: true, fullyLocal: false),
        Expectation(
            transcription: .localFirst, ai: .localFirst,
            rows: [
                .localModel, .cloudProvider, .uploadNetwork, .backgroundCatchUp, .onDeviceAi,
                .cloudModel,
            ],
            keyRows: [.soniox, .openAi], testConnection: true, fullyLocal: false),
        Expectation(
            transcription: .localFirst, ai: .remoteFirst,
            rows: [
                .localModel, .cloudProvider, .uploadNetwork, .backgroundCatchUp, .onDeviceAi,
                .cloudModel,
            ],
            keyRows: [.soniox, .openAi], testConnection: true, fullyLocal: false),
        Expectation(
            transcription: .localFirst, ai: .remoteOnly,
            rows: [.localModel, .cloudProvider, .uploadNetwork, .backgroundCatchUp, .cloudModel],
            keyRows: [.soniox, .openAi], testConnection: true, fullyLocal: false),

        // ── Transcription: Cloud first — cloud is primary, local is the fallback ────────────
        Expectation(
            transcription: .remoteFirst, ai: .localOnly,
            rows: [.localModel, .cloudProvider, .uploadNetwork, .backgroundCatchUp, .onDeviceAi],
            keyRows: [.soniox], testConnection: true, fullyLocal: false),
        Expectation(
            transcription: .remoteFirst, ai: .localFirst,
            rows: [
                .localModel, .cloudProvider, .uploadNetwork, .backgroundCatchUp, .onDeviceAi,
                .cloudModel,
            ],
            keyRows: [.soniox, .openAi], testConnection: true, fullyLocal: false),
        Expectation(
            transcription: .remoteFirst, ai: .remoteFirst,
            rows: [
                .localModel, .cloudProvider, .uploadNetwork, .backgroundCatchUp, .onDeviceAi,
                .cloudModel,
            ],
            keyRows: [.soniox, .openAi], testConnection: true, fullyLocal: false),
        Expectation(
            transcription: .remoteFirst, ai: .remoteOnly,
            rows: [.localModel, .cloudProvider, .uploadNetwork, .backgroundCatchUp, .cloudModel],
            keyRows: [.soniox, .openAi], testConnection: true, fullyLocal: false),

        // ── Transcription: Cloud only — the inverse case: no local engine picker ────────────
        Expectation(
            transcription: .remoteOnly, ai: .localOnly,
            rows: [.cloudProvider, .uploadNetwork, .backgroundCatchUp, .onDeviceAi],
            keyRows: [.soniox], testConnection: true, fullyLocal: false),
        Expectation(
            transcription: .remoteOnly, ai: .localFirst,
            rows: [.cloudProvider, .uploadNetwork, .backgroundCatchUp, .onDeviceAi, .cloudModel],
            keyRows: [.soniox, .openAi], testConnection: true, fullyLocal: false),
        Expectation(
            transcription: .remoteOnly, ai: .remoteFirst,
            rows: [.cloudProvider, .uploadNetwork, .backgroundCatchUp, .onDeviceAi, .cloudModel],
            keyRows: [.soniox, .openAi], testConnection: true, fullyLocal: false),
        Expectation(
            transcription: .remoteOnly, ai: .remoteOnly,
            rows: [.cloudProvider, .uploadNetwork, .backgroundCatchUp, .cloudModel],
            keyRows: [.soniox, .openAi], testConnection: true, fullyLocal: false),
    ]

    @Test("the table covers all sixteen combinations exactly once")
    func tableIsComplete() {
        #expect(Self.table.count == 16)
        let covered = Set(Self.table.map { "\($0.transcription.rawValue)/\($0.ai.rawValue)" })
        let expected = Set(Self.allModePairs.map { "\($0.0.rawValue)/\($0.1.rawValue)" })
        #expect(covered == expected)
    }

    @Test("each combination shows exactly the rows it uses")
    func rowsPerCombination() {
        for entry in Self.table {
            let plan = makePlan(entry.transcription, entry.ai)
            let label = "\(entry.transcription.rawValue) + \(entry.ai.rawValue)"
            #expect(
                rows(plan) == entry.rows,
                "\(label): expected \(entry.rows.sorted()), got \(rows(plan).sorted())")
            #expect(plan.keyRows == entry.keyRows, "\(label): key rows")
            #expect(plan.showsTestConnection == entry.testConnection, "\(label): test connection")
            #expect(plan.isFullyLocal == entry.fullyLocal, "\(label): fully local")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - The two halves of the reported bug
    // ─────────────────────────────────────────────────────────────────────────

    /// The screenshot: AI Mode "Local only" with an "OpenAI key — not set" row under it, and a
    /// row called "Model" naming a cloud model.
    @Test("AI Local only asks for no key and offers no cloud model")
    func aiLocalOnlyHidesCloudSettings() {
        for transcription in TranscriptionMode.allCases {
            let plan = makePlan(transcription, .localOnly)
            #expect(plan.aiKey == nil, "\(transcription.rawValue)")
            #expect(!plan.showsCloudModel, "\(transcription.rawValue)")
            // ... and it still says whether this phone can do the local half.
            #expect(plan.showsOnDeviceAi, "\(transcription.rawValue)")
        }
    }

    /// The inverse the brief calls out: an "only" mode must not offer rows for the side it never
    /// runs, on either axis.
    @Test("cloud-only modes offer nothing local")
    func remoteOnlyModesHideLocalRows() {
        for ai in AiProcessingMode.allCases {
            #expect(!makePlan(.remoteOnly, ai).showsLocalModel, "\(ai.rawValue)")
        }
        for transcription in TranscriptionMode.allCases {
            #expect(
                !makePlan(transcription, .remoteOnly).showsOnDeviceAi,
                "\(transcription.rawValue)")
        }
    }

    /// A "first" mode is a preference, not a guarantee: both routers fall back to the other
    /// provider, so both halves of a "first" configuration need what that fallback uses. Getting
    /// this backwards would hide the key row from exactly the person most likely to be surprised
    /// by an upload.
    @Test("both first modes are cloud-capable AND on-device-capable")
    func firstModesUseBothSides() {
        for mode in [TranscriptionMode.localFirst, .remoteFirst] {
            #expect(mode.usesCloudProvider)
            #expect(mode.usesOnDeviceEngine)
        }
        for mode in [AiProcessingMode.localFirst, .remoteFirst] {
            #expect(mode.usesCloudProvider)
            #expect(mode.usesOnDeviceModel)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Provider choice on each axis
    // ─────────────────────────────────────────────────────────────────────────

    @Test("the key row follows the chosen transcription provider")
    func keyRowFollowsProvider() {
        for provider in CloudProvider.allCases {
            #expect(
                makePlan(.remoteOnly, .remoteOnly, provider: provider).transcriptionKey == provider)
            #expect(makePlan(.localOnly, .remoteOnly, provider: provider).transcriptionKey == nil)
        }
    }

    /// OpenAI on both axes is ONE key, so it is one row — but it is still a provider in use, so
    /// the pre-check and Test Connection still know about it.
    @Test("OpenAI as both provider and AI shows one key row")
    func openAiOnBothAxesIsOneRow() {
        for ai in [AiProcessingMode.localFirst, .remoteFirst, .remoteOnly] {
            let plan = makePlan(.remoteFirst, ai, provider: .openAi)
            #expect(plan.keyRows == [.openAi], "\(ai.rawValue)")
            #expect(plan.aiKey == nil, "deduplicated away from the AI card")
            #expect(plan.providersInUse == [.openAi], "\(ai.rawValue)")
        }
        // Soniox for audio and OpenAI for text: two providers, two rows, in screen order.
        let split = makePlan(.remoteFirst, .remoteFirst, provider: .soniox)
        #expect(split.keyRows == [.soniox, .openAi])
        #expect(split.providersInUse == [.soniox, .openAi])
    }

    /// Local transcripts + cloud AI: OpenAI is the only provider involved, and its row comes
    /// from the AI half even when it is also the (unused) selected transcription provider.
    @Test("local transcription with cloud AI still shows the OpenAI key")
    func localTranscriptionWithCloudAi() {
        for provider in CloudProvider.allCases {
            let plan = makePlan(.localOnly, .remoteOnly, provider: provider)
            #expect(plan.keyRows == [.openAi])
            #expect(plan.providersInUse == [.openAi])
            #expect(!plan.showsCloudProvider)
            #expect(!plan.showsUploadNetwork)
            #expect(!plan.showsTestConnection)
        }
    }

    /// No configuration may draw a key row for a provider it does not use, and none may use a
    /// provider it draws no row for (the OpenAI-twice case is the one deliberate exception, and
    /// it is covered above).
    @Test("key rows and providers in use agree in every combination")
    func keyRowsMatchProvidersInUse() {
        for (transcription, ai) in Self.allModePairs {
            for provider in CloudProvider.allCases {
                let plan = makePlan(transcription, ai, provider: provider)
                let label = "\(transcription.rawValue) + \(ai.rawValue) via \(provider.rawValue)"
                for row in plan.keyRows {
                    #expect(plan.providersInUse.contains(row), "\(label)")
                }
                #expect(plan.providersInUse.isEmpty == plan.isFullyLocal, "\(label)")
                #expect(plan.keyRows.isEmpty == plan.isFullyLocal, "\(label)")
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - The rule cannot drift from the pipeline or from Storage & Privacy
    // ─────────────────────────────────────────────────────────────────────────

    /// The cloud half of the rule IS the predicate the providers are gated on. If someone
    /// changes what `localFirst` means to the router, this fails rather than the screen quietly
    /// hiding a key an upload still needs.
    @Test("cloud-capable matches the runtime's own gate")
    func matchesRuntimeGate() {
        for (transcription, ai) in Self.allModePairs {
            let runtime = RuntimeSettingsSnapshot(transcriptionMode: transcription, aiMode: ai)
            #expect(transcription.usesCloudProvider == runtime.cloudTranscriptionEnabled)
            #expect(ai.usesCloudProvider == runtime.remoteAiEnabled)
        }
    }

    /// Storage & Privacy derives its stance from these same modes. Nothing this screen shows may
    /// contradict it, and the sharpest version of that is: the two must agree about whether
    /// anything leaves the phone at all.
    @Test("fully local agrees with the privacy stance")
    func agreesWithPrivacyStance() {
        let settings = makeSettings()
        for (transcription, ai) in Self.allModePairs {
            settings.transcriptionMode = transcription
            settings.aiMode = ai
            let plan = makePlan(
                transcription, ai, provider: settings.cloudTranscriptionProvider)
            #expect(
                plan.isFullyLocal == settings.privacyStance.isFullyLocal,
                "\(transcription.rawValue) + \(ai.rawValue)")
        }
    }

    /// The footer swaps to a statement of the result once the advice it used to give has been
    /// taken — and states only what this screen controls. "Everything stays on this phone" was
    /// false here whenever older audio moves to iCloud Drive, which this screen does not set.
    @Test("the footer states the result once both modes are local, and no more")
    func footerMatchesStance() {
        let settings = makeSettings()
        settings.transcriptionMode = .localOnly
        settings.aiMode = .localOnly
        #expect(settings.privacyStance.headline == "Everything stays on this phone")
        settings.coldStorageEnabled = true
        #expect(!settings.privacyStance.isFullyLocal)
        #expect(settings.privacyStance.headline.contains("iCloud Drive"))
        #expect(!Copy.Settings.TranscriptionAI.everythingLocalFooter.contains("Everything"))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Can this phone run the local half?
    // ─────────────────────────────────────────────────────────────────────────

    @Test("the three unavailable reasons read differently")
    func aiReadinessValuesAreDistinct() {
        let values = OnDeviceAiReadiness.allCases.map {
            Copy.Settings.TranscriptionAI.onDeviceAiValue($0)
        }
        #expect(Set(values).count == OnDeviceAiReadiness.allCases.count)
        #expect(OnDeviceAiReadiness.ready.isReady)
        for readiness in OnDeviceAiReadiness.allCases where readiness != .ready {
            #expect(!readiness.isReady)
        }
    }

    /// Only where it matters: a phone that cannot run Apple Intelligence, in a mode that never
    /// asks it to, is told nothing — there is nothing missing there.
    @Test("the on-device AI note appears only where the mode depends on it")
    func aiNoteOnlyWhereItMatters() {
        for readiness in OnDeviceAiReadiness.allCases {
            #expect(
                Copy.Settings.TranscriptionAI.onDeviceAiNote(mode: .remoteOnly, readiness: readiness)
                    == nil)
        }
        for mode in AiProcessingMode.allCases {
            #expect(
                Copy.Settings.TranscriptionAI.onDeviceAiNote(mode: mode, readiness: .ready) == nil)
        }
        // Remote first has the cloud as its primary path, so an absent fallback is information
        // the row already carries — not a sentence under the card.
        for readiness in OnDeviceAiReadiness.allCases {
            #expect(
                Copy.Settings.TranscriptionAI.onDeviceAiNote(
                    mode: .remoteFirst, readiness: readiness) == nil)
        }
    }

    /// Local only is the configuration where the router has nowhere else to go, so every
    /// unavailable reason has to say what happens — and say something different, because the
    /// three have different remedies.
    @Test("Local-only AI explains each unavailable reason separately")
    func aiNoteExplainsEachReason() {
        var notes: [String] = []
        for readiness in OnDeviceAiReadiness.allCases where readiness != .ready {
            let note = Copy.Settings.TranscriptionAI.onDeviceAiNote(
                mode: .localOnly, readiness: readiness)
            #expect(note != nil, "\(readiness)")
            if let note { notes.append(note) }
        }
        #expect(Set(notes).count == 3)
        // Local first still runs on the cloud, so it gets its own single sentence rather than
        // the "stays empty" ones.
        for readiness in OnDeviceAiReadiness.allCases where readiness != .ready {
            let note = Copy.Settings.TranscriptionAI.onDeviceAiNote(
                mode: .localFirst, readiness: readiness)
            #expect(note != nil)
            #expect(!notes.contains(note ?? ""))
        }
    }

    /// The picker warns at the moment of choosing, and only then — the mode is never prevented,
    /// because two of the three reasons are fixable and "everything stays on this phone" is a
    /// legitimate thing to want.
    @Test("the AI mode picker explains only when this phone cannot do it")
    func aiModePickerFooter() {
        #expect(Copy.Settings.TranscriptionAI.aiModeChoiceFooter(.ready) == nil)
        var footers: [String] = []
        for readiness in OnDeviceAiReadiness.allCases where readiness != .ready {
            let footer = Copy.Settings.TranscriptionAI.aiModeChoiceFooter(readiness)
            #expect(footer != nil, "\(readiness)")
            if let footer { footers.append(footer) }
        }
        #expect(Set(footers).count == 3)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Can this phone transcribe on its own?
    // ─────────────────────────────────────────────────────────────────────────

    /// `SelectableLocalTranscriptionProvider` falls back to Apple Speech for any selection that
    /// is not installed, and `SpeechAnalyzerProvider` transcribes only when its assets are
    /// installed — so these two states decide the whole answer.
    @Test("local transcription readiness follows the engine that would actually run")
    func transcriptionReadiness() {
        typealias Readiness = OnDeviceTranscriptionReadiness
        // The chosen engine is here.
        #expect(Readiness.resolve(selected: .installed, appleSpeech: .unavailable) == .ready)
        // The chosen engine is not, but the fallback is.
        #expect(Readiness.resolve(selected: .notInstalled, appleSpeech: .installed) == .ready)
        #expect(Readiness.resolve(selected: .failed, appleSpeech: .installed) == .ready)
        // Something is on its way.
        #expect(
            Readiness.resolve(selected: .downloading(progress: 0.4), appleSpeech: .notInstalled)
                == .preparing)
        #expect(Readiness.resolve(selected: .installing, appleSpeech: .notInstalled) == .preparing)
        // Installed but not yet set up (Core AI specialization pending): still getting ready.
        #expect(Readiness.resolve(selected: .preparing, appleSpeech: .notInstalled) == .preparing)
        #expect(
            Readiness.resolve(selected: .notInstalled, appleSpeech: .waitingForWiFi) == .preparing)
        // Nothing installed, nothing coming.
        #expect(
            Readiness.resolve(selected: .notInstalled, appleSpeech: .notInstalled)
                == .needsModel(appleSpeechUnsupported: false))
        #expect(
            Readiness.resolve(selected: .failed, appleSpeech: .notInstalled)
                == .needsModel(appleSpeechUnsupported: false))
        // ... and iOS has no speech model for this language either, so the free fallback is not
        // an option and only a download can fix it.
        #expect(
            Readiness.resolve(selected: .notInstalled, appleSpeech: .unavailable)
                == .needsModel(appleSpeechUnsupported: true))
        #expect(
            Readiness.resolve(selected: .unavailable, appleSpeech: .unavailable)
                == .needsModel(appleSpeechUnsupported: true))
    }

    @Test("the transcription note appears only where nothing would be transcribed")
    func transcriptionNoteOnlyWhereItMatters() {
        typealias Copywriting = Copy.Settings.TranscriptionAI
        let stuck = OnDeviceTranscriptionReadiness.needsModel(appleSpeechUnsupported: false)
        // Cloud only never runs the local engine, so it is never short of one.
        #expect(
            Copywriting.localTranscriptionNote(
                mode: .remoteOnly, readiness: stuck, cloudProvider: "Soniox") == nil)
        // Nothing to say while it is working, or while a download is running (the row shows the
        // progress).
        for mode in TranscriptionMode.allCases {
            #expect(
                Copywriting.localTranscriptionNote(
                    mode: mode, readiness: .ready, cloudProvider: "Soniox") == nil)
            #expect(
                Copywriting.localTranscriptionNote(
                    mode: mode, readiness: .preparing, cloudProvider: "Soniox") == nil)
        }
        // Local only: nothing is transcribed, and the two reasons read differently.
        let plain = Copywriting.localTranscriptionNote(
            mode: .localOnly, readiness: stuck, cloudProvider: "Soniox")
        let noLanguage = Copywriting.localTranscriptionNote(
            mode: .localOnly,
            readiness: .needsModel(appleSpeechUnsupported: true),
            cloudProvider: "Soniox")
        #expect(plain != nil)
        #expect(noLanguage != nil)
        #expect(plain != noLanguage)
        // Local first: it does not go silent, it goes to the cloud — and the sentence names the
        // provider it is actually configured for, so it cannot contradict Storage & Privacy.
        let uploads = Copywriting.localTranscriptionNote(
            mode: .localFirst, readiness: stuck, cloudProvider: "Soniox")
        #expect(uploads?.contains("Soniox") == true)
        #expect(
            Copywriting.localTranscriptionNote(
                mode: .localFirst, readiness: stuck, cloudProvider: "OpenAI")?
                .contains("OpenAI") == true)
    }
}
