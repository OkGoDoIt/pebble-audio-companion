import AppDB
import CompanionRuntime
import Contacts
import EventKit
import Foundation
import Intelligence
import Observation
import Receiver
import SegmentStore
import StatusUI
import Transcription
import UIKit
import WireProtocol

// The real Settings sources. Every value here is measured, not decorated: storage is the actual
// spool on disk, diagnostics are the runtime's own counters, and the local-model row reflects
// what `Speech.AssetInventory` actually reports.

@MainActor
enum LiveSettingsDataSources {
    /// `capture` is the live Today source: the Settings master switch and Today's Start/Stop
    /// must be the same object, so the two can never drift into separate capture sequences.
    static func make(
        composition: AppComposition, capture: any CaptureControlling
    ) -> SettingsDataSources {
        SettingsDataSources(
            capture: capture,
            watch: LiveWatchStatusSource(composition: composition),
            storage: LiveStorageStatsSource(composition: composition),
            localModel: LiveLocalModelManager(composition: composition),
            aboutYou: LiveAboutYouSource(composition: composition),
            diagnostics: LiveDiagnosticsSource(composition: composition),
            cloudHealth: LiveCloudHealthSource(composition: composition),
            processing: LiveProcessingModeSource(composition: composition),
            apiKeys: LiveApiKeyChecker(composition: composition),
            aiModels: AiModels.all.map {
                AiModelOption(id: $0.id, displayName: $0.displayName)
            }
        )
    }
}

// MARK: - Watch

@MainActor
@Observable
final class LiveWatchStatusSource: WatchStatusSource {
    @ObservationIgnored private let composition: AppComposition
    private(set) var deviceName = StatusCopy.genericDeviceName
    private(set) var batteryPercent: Int?
    private(set) var firmwareVersion: String?
    private(set) var watchReports = watchServiceStateLabel(nil)
    private(set) var isConnected = false

    init(composition: AppComposition) {
        self.composition = composition
        observe()
    }

    private func observe() {
        let runtime = composition.runtime
        Task { [weak self] in
            for await state in runtime.receiverState.stream() {
                guard let self else { return }
                switch state {
                case .streaming, .authorized:
                    isConnected = true
                default:
                    isConnected = false
                }
            }
        }
        Task { [weak self] in
            for await raw in runtime.watchServiceState.stream() {
                self?.watchReports = watchServiceStateLabel(raw)
            }
        }
        Task { [weak self] in
            let receiver = await runtime.environment.receiver
            for await info in receiver.watchInfo.stream() {
                guard let self, let info else { continue }
                firmwareVersion = Self.firmwareLabel(info.fwVersionPacked)
            }
        }
        // The watch's own advertised name ("Pebble Time 2 4F21"), so someone with two watches
        // can tell which one is bound. It falls back to the generic word only while no watch
        // has ever been seen — never as a stand-in for one that has.
        Task { [weak self] in
            let receiver = await runtime.environment.receiver
            for await name in receiver.deviceName.stream() {
                guard let self else { return }
                deviceName = Self.label(advertisedName: name)
            }
        }
    }

    /// Attempts a connection. No capture-intent side effects — connecting must never silently
    /// enable recording (anti-B3).
    func findWatch() {
        Task { [composition] in await composition.runtime.reconnect() }
    }

    /// Forgets the binding locally, so the next connection re-consents on the watch.
    func forget() {
        Task { [composition] in
            let receiver = await composition.runtime.environment.receiver
            await receiver.revokeReceiverLocally()
        }
    }

    /// The watch's own advertised name, or the generic word when no watch has ever been seen.
    ///
    /// The generic word is a placeholder for "we do not know yet" and never a stand-in for a
    /// watch we DO know: someone with two Pebbles has to be able to tell from this row which one
    /// is bound. An advertised name that is blank or whitespace is no name at all.
    static func label(advertisedName name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? StatusCopy.genericDeviceName : trimmed
    }

    /// The watch's firmware version, unpacked from the Info characteristic's `fw_version_packed`
    /// word; battery is not part of the audio-companion service, so it stays unknown until the
    /// watch reports one.
    ///
    /// The layout is the wire contract's, `(major << 24) | (minor << 16) | patch` — spec §3 offset
    /// 12, and the shared fixture `info_streaming.json` (`67698690` == `0x04090002` == "fw 4.9.2",
    /// which the firmware's own `test_audio_companion_protocol.c` builds as
    /// `(4u << 24) | (9u << 16) | 2u`). This used to shift by 16/8/0, which read that same word
    /// back as **v9.0.2**: major came out of the minor's byte and the patch's high byte was
    /// dropped entirely. Nothing caught it because no shipped firmware fills the field at all
    /// (see `SettingsWatchScreen.infoCard`), so the wrong answer has never been on screen — it
    /// would simply have been wrong on the first day it was.
    ///
    /// `patch` is the low SIXTEEN bits, not a byte: the contract leaves bits 8–15 to it.
    static func firmwareLabel(_ packed: UInt32) -> String? {
        guard packed != 0 else { return nil }
        let major = (packed >> 24) & 0xFF
        let minor = (packed >> 16) & 0xFF
        let patch = packed & 0xFFFF
        return patch == 0 ? "v\(major).\(minor)" : "v\(major).\(minor).\(patch)"
    }
}

// MARK: - Storage

/// Storage numbers that keep themselves honest.
///
/// These used to be read once during bootstrap and never again: `refresh()` is not on
/// `StorageStatsSource`, so no screen could ask for one. On a fresh launch the store has not
/// finished recovering yet, so Settings claimed "0 recordings · 0 KB" — while the watch was
/// recording and the Library was full — and stayed there for the whole session. Nothing about
/// the numbers is expensive to recompute, so the source now watches for the moments they can
/// change instead of waiting to be asked.
@MainActor
@Observable
final class LiveStorageStatsSource: StorageStatsSource {
    @ObservationIgnored private let composition: AppComposition
    private(set) var recordingCount = 0
    private(set) var recordingsSize = "0 KB"
    private(set) var recordingsBytes: Int64 = 0
    /// Stored, not computed: a computed property has no observable state behind it, so SwiftUI
    /// never re-read it and the free-space line was frozen at whatever it said on first draw.
    private(set) var freeSpace = "—"

    init(composition: AppComposition) {
        self.composition = composition
        refresh()
        observe()
    }

    /// The three moments the numbers move: a library write (a segment closed, a conversation
    /// was deleted, recovery finished populating the store), returning to the app after
    /// recording in the background, and a delete/export this screen just performed.
    private func observe() {
        let library = composition.runtime.library
        Task { [weak self] in
            for await _ in library.observeLibrary() {
                guard let self else { return }
                refresh()
            }
        }
        Task { [weak self] in
            let active = NotificationCenter.default.notifications(
                named: UIApplication.didBecomeActiveNotification
            )
            for await _ in active {
                guard let self else { return }
                refresh()
            }
        }
    }

    func refresh() {
        let composition = self.composition
        Task { [weak self] in
            let store = composition.store
            let metas = await store.listSegments()
            var bytes: Int64 = 0
            for meta in metas { bytes += await store.logSizeBytes(meta.segmentId) }
            guard let self else { return }
            set(count: metas.count, bytes: bytes)
        }
    }

    /// Assigns only on a real change: `@Observable` invalidates on every set, and `refresh()`
    /// now runs on every library tick — re-rendering the whole Settings tree for numbers that
    /// did not move would be a lot of work to display the same string.
    private func set(count: Int, bytes: Int64) {
        let size = Formatting.storageSize(bytes)
        let free = ByteCountFormatter.string(
            fromByteCount: VolumeFreeSpace().freeBytes(), countStyle: .file
        )
        if recordingCount != count { recordingCount = count }
        if recordingsSize != size { recordingsSize = size }
        if recordingsBytes != bytes { recordingsBytes = bytes }
        if freeSpace != free { freeSpace = free }
    }

    /// Real WAV copies into `Documents/PebbleAudioExports`, visible in Files.
    func exportAllAudio() async -> Int {
        let live = await composition.runtime.environment.live
        let result = try? await live.exportAll()
        // Free space just dropped by the size of everything that was written.
        refresh()
        return result?.fileCount ?? 0
    }

    /// Deletes every recording and everything derived from it — the full cascade, not just the
    /// audio files, so no orphan transcript or note survives the "delete all". Delegated to the
    /// runtime, which also closes the recording still in progress (a loop over `listSegments()`
    /// here could not delete it, so it silently came back) and sweeps orphaned transcription
    /// state.
    func deleteAllRecordings() {
        let composition = self.composition
        Task { [weak self] in
            await composition.runtime.deleteAllRecordings()
            self?.refresh()
        }
    }
}

// MARK: - Local transcription models

/// The local-model catalog as this build can honestly offer it: Apple Speech over the system's
/// `AssetInventory`, and the downloadable Parakeet models over `ParakeetModelStore`.
///
/// Two engines, two very different installers, one row vocabulary. Apple Speech's assets belong
/// to iOS (we can ask for them and watch, nothing more); a Parakeet model is a Hugging Face
/// archive this app fetches, unpacks and owns. `models` lists only what this build can genuinely
/// install — a row for a model the app cannot fetch is a placebo, which is what this whole
/// screen keeps removing.
@MainActor
@Observable
final class LiveLocalModelManager: LocalModelManaging {
    @ObservationIgnored private let composition: AppComposition
    /// The shared store, deliberately: a download started here has to keep reporting progress
    /// after the user navigates away and comes back.
    @ObservationIgnored private let parakeet: any ParakeetModelStoring = ParakeetModelStore.shared
    @ObservationIgnored private let isOnWiFi: () -> Bool
    let models: [LocalModelOption] = LocalModelCatalog.installable

    private var states: [String: LocalModelState] = [:]
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// Models the user asked for while off Wi-Fi. They start on their own the next time this
    /// screen refreshes on Wi-Fi — the row says "waiting for Wi-Fi", so it must mean it.
    @ObservationIgnored private var deferredForWiFi: Set<String> = []

    init(composition: AppComposition, isOnWiFi: @escaping () -> Bool = {
        NetworkReachability.shared.isUnmetered
    }) {
        self.composition = composition
        self.isOnWiFi = isOnWiFi
        Task { [weak self] in
            for await kitState in await composition.localModel.states() {
                self?.states[LocalModelCatalog.appleSpeechId] = Self.map(kitState)
            }
        }
        Task { [weak self, parakeet] in
            for await entries in await parakeet.states() {
                self?.apply(entries)
            }
        }
        refresh()
    }

    func state(for modelId: String) -> LocalModelState { states[modelId] ?? .notInstalled }

    func refresh() {
        let composition = self.composition
        Task { [weak self] in
            let state = await composition.localModel.refresh()
            self?.states[LocalModelCatalog.appleSpeechId] = Self.map(state)
        }
        Task { [weak self, parakeet] in
            let entries = await parakeet.refresh()
            self?.apply(entries)
            self?.startDeferredDownloadsIfOnWiFi()
        }
    }

    func download(_ modelId: String) {
        guard ParakeetModelCatalog.isParakeetId(modelId) else {
            downloadAppleSpeech(modelId)
            return
        }
        // Wi-Fi is a promise this screen makes in writing next to a 430 MB–1.2 GB number. The
        // downloader refuses an expensive network anyway, but refusing it here means the row
        // says "waiting for Wi-Fi" instead of "download failed" for something that is not
        // broken.
        guard isOnWiFi() else {
            deferredForWiFi.insert(modelId)
            states[modelId] = .waitingForWiFi
            return
        }
        deferredForWiFi.remove(modelId)
        Task { [parakeet] in await parakeet.install(modelId) }
    }

    func cancelDownload(_ modelId: String) {
        guard ParakeetModelCatalog.isParakeetId(modelId) else {
            // The system asset installer owns that transfer; cancelling only stops us watching.
            downloadTask?.cancel()
            downloadTask = nil
            refresh()
            return
        }
        deferredForWiFi.remove(modelId)
        states[modelId] = .notInstalled
        Task { [parakeet] in await parakeet.cancel(modelId) }
    }

    func delete(_ modelId: String) {
        guard ParakeetModelCatalog.isParakeetId(modelId) else {
            guard modelId == LocalModelCatalog.appleSpeechId else { return }
            downloadTask?.cancel()
            downloadTask = nil
            let composition = self.composition
            Task { [weak self] in
                self?.states[modelId] = Self.map(await composition.localModel.uninstall())
            }
            return
        }
        deferredForWiFi.remove(modelId)
        Task { [parakeet] in await parakeet.uninstall(modelId) }
    }

    #if DEBUG
        func debugFailDownload(_ modelId: String) { states[modelId] = .failed }
    #endif

    private func downloadAppleSpeech(_ modelId: String) {
        guard modelId == LocalModelCatalog.appleSpeechId, downloadTask == nil else { return }
        let composition = self.composition
        downloadTask = Task { [weak self] in
            let result = await composition.localModel.requestInstall()
            self?.states[modelId] = Self.map(result)
            self?.downloadTask = nil
        }
    }

    private func startDeferredDownloadsIfOnWiFi() {
        guard isOnWiFi(), !deferredForWiFi.isEmpty else { return }
        for modelId in deferredForWiFi { download(modelId) }
    }

    /// Folds a store snapshot into the row states.
    ///
    /// Progress is quantised to whole percent on purpose: `URLSession` reports bytes on every
    /// chunk, which is thousands of updates across a 700 MB archive, and the row renders one
    /// integer. Without this the whole Settings tree would recompose for changes it cannot show.
    private func apply(_ entries: [ParakeetModelEntry]) {
        for entry in entries {
            let next = Self.map(entry.state)
            if case .downloading(let progress) = next,
                case .downloading(let shown)? = states[entry.id],
                Int(progress * 100) == Int(shown * 100)
            {
                continue
            }
            // A model the user is waiting on Wi-Fi for has no store state of its own yet; the
            // store would report it as plain "not installed" and erase the row's explanation.
            if deferredForWiFi.contains(entry.id), next == .notInstalled { continue }
            states[entry.id] = next
        }
    }

    private static func map(_ state: Transcription.LocalModelState) -> LocalModelState {
        switch state {
        case .notInstalled: return .notInstalled
        // The phone's language is one `SpeechTranscriber` has no model for. Saying "not
        // installed" would offer a download that can never finish.
        case .unsupported: return .unavailable
        case .waitingForWiFi: return .waitingForWiFi
        case .downloading(let progress): return .downloading(progress: progress)
        case .installed: return .installed
        case .failed: return .failed
        }
    }

    private static func map(_ state: ParakeetInstallState) -> LocalModelState {
        switch state {
        case .notInstalled: return .notInstalled
        case .downloading:
            return .downloading(progress: state.fractionCompleted ?? 0)
        case .installing: return .installing
        case .installed: return .installed
        case .failed: return .failed
        }
    }
}

// MARK: - About You

/// What one import produced, or why it produced nothing. File scope and `Sendable` so the
/// framework reads can happen on a detached task rather than on the main actor.
private struct ImportOutcome: Sendable {
    var people: [KnownPerson] = []
    var terms: [String] = []
    /// The ids the source actually offers, when they were listed. Nil means "not listed",
    /// which must not be read as "the source has none": pruning a selection against an empty
    /// list would silently unselect everything the user had chosen.
    var availableIds: [String]?
    var failure: ContextImportFailure?
}

/// About You's live half: the bio file, and the two phone imports with per-source control.
///
/// Four things are true here that were not before this screen was rebuilt (AY):
///
/// - **Only a switch can ask for permission.** `setEnabled(true, …)` is the ONE call site of
///   `requestAccess` in the app. Opening the screen, refreshing, listing groups and every
///   automatic refresh are all incapable of provoking a prompt, by construction.
/// - **Each source owns its own contribution.** What Calendar last put into
///   `PersonalContext.orgs` is recorded in `ContextSourceSettings.contributedTerms`, so a
///   re-import replaces it and switching the source off removes it — where the old import
///   unioned titles in and could only be undone by wiping the whole context.
/// - **Off means off.** Turning a source off removes its data from the context immediately,
///   rather than leaving names in every prompt behind a switch that says they are not in use.
/// - **Imports keep themselves current**, on the two Contacts/EventKit change notifications and
///   on foreground, and the screen says when that last worked.
///
/// The framework reads happen on a detached task: `enumerateContacts` over a large address
/// book, and an EventKit query over a year of events, are both long enough to be visible as a
/// hitch if they run where the old code ran them, which was the main actor.
@MainActor
@Observable
final class LiveAboutYouSource: AboutYouSource {
    /// How stale an import may be before returning to the app re-runs it. The calendar window
    /// rolls with the clock, so "nothing changed" is not the same as "nothing to do".
    private static let foregroundStaleMs: Int64 = 6 * 60 * 60 * 1000
    /// Contacts and EventKit both post change notifications in bursts (a sync, a device
    /// restore). This is the floor between two automatic re-imports.
    private static let changeCoalesceMs: Int64 = 60 * 1000

    @ObservationIgnored private let composition: AppComposition
    @ObservationIgnored private let importStore: FileContextImportSettingsStore
    /// EventKit posts `EKEventStoreChanged` only to a process that is holding an
    /// `EKEventStore`, and Contacts behaves the same way in practice — so a store is kept alive
    /// for exactly as long as its source is switched on. Constructing one prompts for nothing.
    @ObservationIgnored private var contactObserverStore: CNContactStore?
    @ObservationIgnored private var eventObserverStore: EKEventStore?
    /// Context writes happen HERE, not on the main actor. `personal_context.json` holds every
    /// imported name, so on a phone with a large address book loading and re-encoding it is
    /// tens of milliseconds — and the bio now writes on a debounce while the person is still
    /// typing, which is exactly where a hitch of that size is felt. The store's own lock makes
    /// the writes safe; the queue being serial keeps two bio writes in the order they were
    /// typed.
    @ObservationIgnored private let contextWrites = DispatchQueue(
        label: "dev.audiocompanion.about-you.context", qos: .utility)

    var bio: String {
        didSet { persist() }
    }
    private var settings: ContextImportSettings
    private var refreshing: Set<ContextImportKind> = []
    /// A change made while an import was in flight. Without this, tapping three groups in a row
    /// would drop two of them and leave the imported data disagreeing with the selection.
    private var rerunWanted: Set<ContextImportKind> = []
    /// Re-read on every foreground and after every attempt: iOS can revoke access while the app
    /// is in the background and tells us nothing when it does.
    private var access: [ContextImportKind: ImportSourceState.Access] = [:]

    init(composition: AppComposition) {
        self.composition = composition
        self.importStore = FileContextImportSettingsStore(root: composition.containerRoot)
        let context = composition.personalContext.load()
        bio = context.profileText ?? ""
        if let stored = importStore.load() {
            settings = stored
        } else {
            // First launch under per-source control. Adopt whatever the old one-shot import
            // left behind, so the screen never reports "Off" about names that are still going
            // out with every prompt.
            let adopted = ContextImportSettings.adopting(context)
            settings = adopted
            try? importStore.save(adopted)
        }
        readAccess()
        observe()
        // NOT `syncObserverStores()`: this runs inside `AppComposition.bootstrap`, on the main
        // actor, before the first frame. Constructing an `EKEventStore` there costs launch time
        // for a notification that cannot matter until the app is in front, so the stores are
        // created on the first foreground instead.
    }

    private var nowMs: Int64 { composition.clock.nowMs }

    private func persist() {
        let text = bio
        let store = composition.personalContext
        // The bio is the input to `derivedTerms`, which is what biases the OpenAI STT prompt.
        // Asking for a refresh here means a sentence typed now steers the next recording rather
        // than the one after that. Hash-guarded, so an unchanged bio costs nothing.
        let refresher = composition.personalContextTerms
        contextWrites.async {
            // A write that fails has to leave a trace somewhere: this screen deliberately shows
            // no "Saved", so a silent `try?` would make a full disk look exactly like a success.
            do {
                try store.mutate { $0.profileText = text }
            } catch {
                AppRuntimeLog.shared.record("about you: bio save failed: \(error)")
            }
            // After the write, never before: the refresher reads the file, and asking it first
            // would have it cache terms for the previous sentence and record them as current.
            Task { await refresher.refreshIfNeeded() }
        }
    }

    /// Read-modify-write of the personal context, off the main actor. False when it failed.
    private func writeContext(_ body: @escaping (inout PersonalContext) -> Void) async -> Bool {
        let store = composition.personalContext
        return await withCheckedContinuation { continuation in
            contextWrites.async {
                do {
                    try store.mutate(body)
                    continuation.resume(returning: true)
                } catch {
                    AppRuntimeLog.shared.record("about you: context write failed: \(error)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: Reading the state

    func state(for kind: ContextImportKind) -> ImportSourceState {
        let source = settings[kind]
        return ImportSourceState(
            kind: kind,
            isEnabled: source.isEnabled,
            access: access[kind] ?? .notDetermined,
            isRefreshing: refreshing.contains(kind),
            lastImportedAtMs: source.lastImportedAtMs,
            lastFailure: source.lastFailure,
            importedCount: source.importedCount,
            selection: source.selection,
            pastDays: source.pastDays,
            futureDays: source.futureDays
        )
    }

    func choices(for kind: ContextImportKind) async -> [ImportChoice] {
        // No access, no list — and no prompt to get one. The picker is a consequence of having
        // granted access, never the thing that asks for it.
        guard access[kind] == .granted else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [ImportChoice] in
            switch kind {
            case .contacts: return Self.contactChoices()
            case .calendar: return Self.calendarChoices()
            }
        }.value
    }

    // MARK: Changing a source

    /// The switch. Turning it ON is the only permission prompt this app raises for either
    /// framework; turning it OFF takes the data back out of the context there and then.
    func setEnabled(_ enabled: Bool, for kind: ContextImportKind) {
        settings[kind].isEnabled = enabled
        saveSettings()
        syncObserverStores()
        guard enabled else {
            removeImported(kind)
            return
        }
        Task { [weak self] in
            let granted = await Self.requestAccess(kind)
            guard let self else { return }
            readAccess()
            // A refusal leaves the switch on and the row saying "No access", which is both
            // true and actionable, rather than flipping the switch back and leaving the person
            // to work out what happened. `access` is re-read on every foreground, so granting
            // it in iOS Settings clears the row without any further tap here.
            guard granted else { return }
            runImport(kind)
        }
    }

    func setSelection(_ selection: ContextImportSelection, for kind: ContextImportKind) {
        settings[kind].selection = selection
        saveSettings()
        guard settings[kind].isEnabled else { return }
        runImport(kind)
    }

    func setCalendarWindow(pastDays: Int, futureDays: Int) {
        settings.calendar.pastDays = pastDays
        settings.calendar.futureDays = futureDays
        saveSettings()
        guard settings.calendar.isEnabled else { return }
        runImport(.calendar)
    }

    /// A refresh the user asked for. It never prompts: a source whose access has been revoked
    /// records the refusal and says so, because the fix is in iOS Settings, not here.
    func refresh(_ kind: ContextImportKind) {
        readAccess()
        guard settings[kind].isEnabled else { return }
        runImport(kind)
    }

    func clearImported() {
        for kind in ContextImportKind.allCases {
            settings[kind].isEnabled = false
            removeImported(kind)
        }
        syncObserverStores()
    }

    /// Takes one source's contribution back out, leaving the other source's — and anything the
    /// user wrote — exactly as it was.
    private func removeImported(_ kind: ContextImportKind) {
        let contributed = settings[kind].contributedTerms
        let atMs = nowMs
        Task { [weak self] in
            guard let self else { return }
            // The context is changed BEFORE the record of what this source contributed is
            // dropped. The other order loses the record of terms that are still in the file,
            // and nothing would ever be able to find them again.
            let written = await writeContext { context in
                switch kind {
                case .contacts:
                    // `people` has only ever been written by this import, so the source owns it
                    // whole. If anything else ever writes it, this needs the same per-source
                    // record `contributedTerms` gives the calendar.
                    context.people = []
                case .calendar:
                    context.orgs = ContextImportMerge.replacing(
                        contributed, with: [], in: context.orgs)
                }
                ContextImportMerge.setRecord(
                    kind.sourceKind, present: false, atMs: atMs, in: &context)
            }
            guard written else {
                settings[kind].lastFailure = .notSaved
                saveSettings()
                return
            }
            settings[kind].contributedTerms = []
            settings[kind].importedCount = 0
            settings[kind].lastImportedAtMs = nil
            settings[kind].lastFailure = nil
            saveSettings()
        }
    }

    // MARK: Running an import

    private func runImport(_ kind: ContextImportKind) {
        guard !refreshing.contains(kind) else {
            rerunWanted.insert(kind)
            return
        }
        refreshing.insert(kind)
        let selection = settings[kind].selection
        let window = settings.calendar.calendarWindow(nowMs: nowMs)
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> ImportOutcome in
                switch kind {
                case .contacts: return Self.readContacts(selection: selection)
                case .calendar: return Self.readCalendar(selection: selection, window: window)
                }
            }.value
            guard let self else { return }
            await apply(outcome, for: kind)
            refreshing.remove(kind)
            readAccess()
            if rerunWanted.remove(kind) != nil { runImport(kind) }
        }
    }

    private func apply(_ outcome: ImportOutcome, for kind: ContextImportKind) async {
        if let failure = outcome.failure {
            // A failed attempt must not make the data look fresher than it is, so
            // `lastImportedAtMs` is left where it was.
            settings[kind].lastFailure = failure
            saveSettings()
            return
        }
        let contributed = settings[kind].contributedTerms
        let terms = ContextImportMerge.cleanTerms(outcome.terms)
        let importedAtMs = nowMs

        // The context is written FIRST, and the settings only record the import once it has
        // landed. The other order writes down a contribution that never happened, and the next
        // import would then "replace" terms that are not in the file — quietly dropping the
        // ones that are.
        let people = outcome.people
        let written = await writeContext { context in
            switch kind {
            case .contacts:
                context.people = people
            case .calendar:
                context.orgs = ContextImportMerge.replacing(
                    contributed, with: terms, in: context.orgs)
            }
            ContextImportMerge.setRecord(
                kind.sourceKind, present: true, atMs: importedAtMs, in: &context)
        }

        // Everything below re-reads `settings[kind]` rather than writing back a copy taken
        // before the `await`. The user can tap a group, or the switch, while a write is in
        // flight, and putting a pre-tap copy back would silently undo what they just did.
        guard written else {
            settings[kind].lastFailure = .notSaved
            saveSettings()
            return
        }
        settings[kind].lastFailure = nil
        settings[kind].lastImportedAtMs = importedAtMs
        settings[kind].contributedTerms = terms
        settings[kind].importedCount = kind == .contacts ? people.count : terms.count
        if let available = outcome.availableIds {
            settings[kind].selection = settings[kind].selection.pruned(against: available)
        }
        saveSettings()
    }

    private func saveSettings() {
        try? importStore.save(settings)
    }

    // MARK: Staying current

    /// The three moments an import can go stale without anyone touching this screen: the
    /// address book changed, the calendar database changed, and time passed (the calendar
    /// window rolls, so an untouched calendar still needs re-reading).
    private func observe() {
        let center = NotificationCenter.default
        Task { [weak self] in
            for await _ in center.notifications(named: .CNContactStoreDidChange) {
                self?.autoRefresh(.contacts, staleAfterMs: Self.changeCoalesceMs)
            }
        }
        Task { [weak self] in
            for await _ in center.notifications(named: .EKEventStoreChanged) {
                self?.autoRefresh(.calendar, staleAfterMs: Self.changeCoalesceMs)
            }
        }
        Task { [weak self] in
            for await _ in center.notifications(
                named: UIApplication.didBecomeActiveNotification)
            {
                guard let self else { return }
                readAccess()
                syncObserverStores()
                for kind in ContextImportKind.allCases {
                    autoRefresh(kind, staleAfterMs: Self.foregroundStaleMs)
                }
            }
        }
    }

    /// An import nobody asked for. It runs only for a source that is switched on and already
    /// authorized, which is what makes it incapable of raising a prompt.
    private func autoRefresh(_ kind: ContextImportKind, staleAfterMs: Int64) {
        readAccess()
        guard settings[kind].isEnabled else { return }
        guard access[kind] == .granted || access[kind] == .limited else { return }
        guard settings[kind].isDueForAutoRefresh(nowMs: nowMs, staleAfterMs: staleAfterMs)
        else { return }
        runImport(kind)
    }

    private func readAccess() {
        let contacts = Self.contactsAccess()
        let calendar = Self.calendarAccess()
        if access[.contacts] != contacts { access[.contacts] = contacts }
        if access[.calendar] != calendar { access[.calendar] = calendar }
    }

    private func syncObserverStores() {
        contactObserverStore = settings.contacts.isEnabled
            ? (contactObserverStore ?? CNContactStore()) : nil
        eventObserverStore = settings.calendar.isEnabled
            ? (eventObserverStore ?? EKEventStore()) : nil
    }

    // MARK: The framework half (nonisolated: none of it belongs on the main actor)

    private nonisolated static func requestAccess(_ kind: ContextImportKind) async -> Bool {
        switch kind {
        case .contacts:
            return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        case .calendar:
            return (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        }
    }

    private nonisolated static func contactsAccess() -> ImportSourceState.Access {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .granted
        case .limited: return .limited
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Write-only calendar access reads as denied here, and correctly: it permits creating
    /// events and reading none, so there is nothing this import could do with it.
    private nonisolated static func calendarAccess() -> ImportSourceState.Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Accounts and groups in one list. Most phones have no contact groups at all, so the
    /// accounts (iCloud, Exchange, On My iPhone) are what makes the picker useful for them.
    private nonisolated static func contactChoices() -> [ImportChoice] {
        let store = CNContactStore()
        let containers = (try? store.containers(matching: nil)) ?? []
        var choices = containers.map { container in
            ImportChoice(
                id: "container:\(container.identifier)",
                name: containerName(container),
                detail: nil,
                section: .account
            )
        }
        let groups = (try? store.groups(matching: nil)) ?? []
        for group in groups {
            // The account a group belongs to, but only when there is more than one to tell
            // apart — otherwise it is the same word under every row.
            var account: String?
            if containers.count > 1 {
                let predicate = CNContainer.predicateForContainerOfGroup(
                    withIdentifier: group.identifier)
                account = (try? store.containers(matching: predicate)).flatMap {
                    $0.first.map(containerName)
                }
            }
            choices.append(
                ImportChoice(
                    id: "group:\(group.identifier)",
                    name: group.name,
                    detail: account,
                    section: .group
                ))
        }
        return choices
    }

    private nonisolated static func containerName(_ container: CNContainer) -> String {
        if !container.name.isEmpty { return container.name }
        switch container.type {
        case .local: return "On My iPhone"
        case .exchange: return "Exchange"
        case .cardDAV: return "CardDAV"
        default: return "Other"
        }
    }

    private nonisolated static func calendarChoices() -> [ImportChoice] {
        EKEventStore().calendars(for: .event).map { calendar in
            ImportChoice(
                id: calendar.calendarIdentifier,
                name: calendar.title,
                detail: calendar.source?.title,
                section: .calendar
            )
        }
    }

    /// Names, from everything or from the chosen accounts and groups.
    private nonisolated static func readContacts(
        selection: ContextImportSelection
    ) -> ImportOutcome {
        let access = contactsAccess()
        guard access == .granted || access == .limited else {
            return ImportOutcome(failure: .permissionDenied)
        }
        let store = CNContactStore()
        let keyNames = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
        ]
        let keys = keyNames as [CNKeyDescriptor]

        // Under limited access iOS has already done the choosing, and neither groups nor
        // containers are visible — so a selection made back when access was full would resolve
        // to nothing and quietly import zero names. Take what we are given instead.
        if access == .limited || selection == .all {
            var people: [KnownPerson] = []
            let request = CNContactFetchRequest(keysToFetch: keys)
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    if let known = person(from: contact) { people.append(known) }
                }
            } catch {
                return ImportOutcome(failure: .unreadable)
            }
            return ImportOutcome(people: people)
        }

        let available = contactChoices().map(\.id)
        let chosen = selection.resolved(against: available)
        // An empty selection is a real answer — import nothing — and must never fall through
        // to a predicate-free fetch of the entire address book.
        guard !chosen.isEmpty else { return ImportOutcome(availableIds: available) }
        var byIdentifier: [String: KnownPerson] = [:]
        for id in chosen {
            let predicate: NSPredicate
            if let group = id.dropPrefixIfPresent("group:") {
                predicate = CNContact.predicateForContactsInGroup(withIdentifier: group)
            } else if let container = id.dropPrefixIfPresent("container:") {
                predicate = CNContact.predicateForContactsInContainer(withIdentifier: container)
            } else {
                continue
            }
            let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys))
            for contact in contacts ?? [] {
                // Unified contacts merge linked cards, so two chosen groups holding the same
                // person yield the same identifier twice.
                if let known = person(from: contact) { byIdentifier[known.id] = known }
            }
        }
        return ImportOutcome(
            people: Array(byIdentifier.values).sorted { $0.name < $1.name },
            availableIds: available
        )
    }

    private nonisolated static func person(from contact: CNContact) -> KnownPerson? {
        let name = "\(contact.givenName) \(contact.familyName)"
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return KnownPerson(
            id: contact.identifier,
            name: name,
            aliases: contact.givenName.isEmpty ? [] : [contact.givenName],
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName
        )
    }

    /// Event titles from the chosen calendars over the chosen window.
    private nonisolated static func readCalendar(
        selection: ContextImportSelection, window: ContextImportWindow
    ) -> ImportOutcome {
        guard calendarAccess() == .granted else {
            return ImportOutcome(failure: .permissionDenied)
        }
        let store = EKEventStore()
        let calendars = store.calendars(for: .event)
        let available = calendars.map(\.calendarIdentifier)
        let chosen = Set(selection.resolved(against: available))
        let selected = calendars.filter { chosen.contains($0.calendarIdentifier) }
        // `predicateForEvents(calendars:)` treats an empty array the way it treats nil — every
        // calendar — so an empty selection has to return before it is built.
        guard !selected.isEmpty else { return ImportOutcome(availableIds: available) }
        let predicate = store.predicateForEvents(
            withStart: window.start, end: window.end, calendars: selected)
        let titles = store.events(matching: predicate)
            .compactMap { $0.title }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return ImportOutcome(terms: titles, availableIds: available)
    }
}

extension String {
    /// `"group:ABC".dropPrefixIfPresent("group:") == "ABC"`, nil when the prefix is absent —
    /// Contacts groups and containers share one selection and are told apart by it.
    fileprivate func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

// MARK: - Cloud API keys

/// Runs the kit's `CloudKeyValidator` — one cheap authenticated GET per check, nothing created
/// and nothing billed — and remembers the outcome for the Settings rows.
///
/// The result lives for the session only: a verdict from three launches ago is not evidence
/// about the key today, and re-checking costs one request.
@MainActor
@Observable
final class LiveApiKeyChecker: ApiKeyChecking {
    @ObservationIgnored private let composition: AppComposition
    @ObservationIgnored private let validator = CloudKeyValidator(
        transport: URLSessionHttpTransport()
    )
    private var statuses: [CloudProvider: ApiKeyStatus] = [:]

    init(composition: AppComposition) {
        self.composition = composition
    }

    func status(for provider: CloudProvider) -> ApiKeyStatus { statuses[provider] ?? .unchecked }

    func check(_ key: String, for provider: CloudProvider) async {
        statuses[provider] = .checking
        let outcome = await validator.validate(key, for: Self.validatorProvider(provider))
        statuses[provider] = .checked(outcome)
    }

    func recheckSaved(_ provider: CloudProvider) async {
        guard let key = composition.settings.keychain.string(for: provider.keychainKey) else {
            statuses[provider] = .checked(.missing)
            return
        }
        await check(key, for: provider)
    }

    private static func validatorProvider(_ provider: CloudProvider) -> CloudKeyValidator.Provider {
        switch provider {
        case .openAi: return .openAi
        case .soniox: return .soniox
        }
    }
}

// MARK: - Cloud connectivity

/// Test Connection over the REAL `CloudHealthMonitor`, which is also written by every actual
/// transcription attempt — so a silent local fallback can no longer hide a failing provider
/// behind a green row that only an explicit test ever updated.
@MainActor
@Observable
final class LiveCloudHealthSource: CloudHealthSource {
    @ObservationIgnored private let composition: AppComposition
    private(set) var testState: CloudTestState = .untested

    init(composition: AppComposition) {
        self.composition = composition
        let monitor = composition.cloudHealth
        testState = Self.map(monitor.state, nowMs: composition.clock.nowMs)
        Task { [weak self] in
            for await health in monitor.updates() {
                guard let self else { return }
                testState = Self.map(health, nowMs: composition.clock.nowMs)
            }
        }
    }

    func test() {
        guard testState != .testing else { return }
        testState = .testing
        Task { [composition] in await composition.runtime.testCloudConnection() }
    }

    private static func map(_ health: CloudHealth, nowMs: Int64) -> CloudTestState {
        switch health.status {
        case .unknown: return .untested
        case .checking: return .testing
        case .ok:
            let ago = health.checkedAtMs.map {
                TimeFmt.relative(Date(timeIntervalSince1970: Double($0) / 1000))
            }
            return .connected(ago: ago ?? "just now")
        case .failed: return .problem(health.message ?? "Could not reach the provider")
        case .notConfigured: return .problem(Copy.Settings.TranscriptionAI.notSet)
        }
    }
}

// MARK: - Processing modes

/// The two routers, read straight through. Both `lastFallback` properties are a lock-guarded
/// read of one small struct, so this costs nothing to ask and there is nothing to cache, observe
/// or invalidate — the value is by construction whatever the last completed job did.
///
/// Deliberately NOT `@Observable` with a mirrored copy: mirroring would mean either a stream to
/// keep it fresh (a subscription held open all day for a value that changes minutes apart) or a
/// timer (a poll, which the battery rules forbid outright). The reader is a settings screen; it
/// re-reads whenever it redraws, which is exactly often enough.
@MainActor
final class LiveProcessingModeSource: ProcessingModeSource {
    private let composition: AppComposition

    init(composition: AppComposition) {
        self.composition = composition
    }

    var transcriptionFallback: ProcessingFallback? { composition.transcriptionRouter.lastFallback }
    var aiFallback: ProcessingFallback? { composition.aiRouter.lastFallback }
}

// MARK: - Diagnostics

@MainActor
@Observable
final class LiveDiagnosticsSource: DiagnosticsSource {
    @ObservationIgnored private let composition: AppComposition
    private(set) var receiverStatus = ""
    private(set) var watchReports = watchServiceStateLabel(nil)
    /// What the watch said when it refused this phone. Nil while it has not — the row is absent
    /// rather than reassuring, the same way the failed-transcription section is.
    private(set) var watchLink: DiagnosticLinkFault?
    /// Audio the watch could not hand over, from the watch's own counter (Info `flags` bit3).
    private(set) var watchSend: WatchSendHealth = .unknown
    /// Frames the watch sent us while we held no stream to put them in. Always a fault: it is
    /// audio the watch spent battery capturing that this app then had nowhere to store.
    private(set) var orphanedFrames = 0
    private(set) var indexRebuild: IndexRebuildState = .idle
    private(set) var queueWaiting = 0
    private(set) var queueFailed = 0
    private(set) var transcriptionHeldInBackground = false
    /// Latches the runtime's flag across the return to the foreground.
    ///
    /// `RuntimeDiagnostics.transcriptionDeferredInBackground` is literally `!isForeground()`, so
    /// by the time anyone can READ this screen it has already flipped back to false — which is
    /// why surfacing the raw flag would be a row that is never true. What the user needs to know
    /// is why the tasks in front of them did not move, so the observation is held until the
    /// queue that was held actually drains.
    @ObservationIgnored private var sawDeferralWhileQueued = false
    private(set) var enrichmentWaiting = 0
    private(set) var enrichmentRunning = false
    private(set) var failedItems: [DiagnosticFailure] = []
    private(set) var recentSegments: [DiagnosticSegment] = []
    private(set) var pipeline = DiagnosticPipeline(
        summary: Copy.Settings.Diagnostics.pipelineStarting)

    /// Counters and gap metadata only — never audio or transcript text.
    ///
    /// Stored, not computed. A computed property reading `AppRuntimeLog` registers no dependency
    /// with `@Observable`, so this screen froze on whatever the ring held when it was pushed —
    /// during a live reproduction, which is the only time anyone opens it.
    private(set) var detailedLogLines: [String] = AppRuntimeLog.shared.recent

    private(set) var supportReportText = ""

    init(composition: AppComposition) {
        self.composition = composition
        let runtime = composition.runtime
        Task { [weak self] in
            for await _ in runtime.diagnostics.stream() { await self?.refresh() }
        }
        Task { [weak self] in
            for await _ in runtime.receiverState.stream() { await self?.refresh() }
        }
        // The Info snapshot is re-read on every handshake (and after an enable prompt), which is
        // when the watch's send-refusal counter moves for us. Without this the row would only
        // change when something else happened to trigger a refresh.
        Task { [weak self] in
            for await _ in runtime.watchInfo.stream() { await self?.refresh() }
        }
        // The log ring is not part of the runtime's diagnostics, and most of what writes to it
        // (the BLE link, the receiver session, the queue, background tasks) moves none of the
        // streams above. It needs its own subscription or the screen never redraws for it.
        Task { [weak self] in
            for await _ in AppRuntimeLog.shared.generations() {
                await MainActor.run { self?.detailedLogLines = AppRuntimeLog.shared.recent }
                // Coalesce a burst of writes into one redraw.
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func refresh() async {
        let composition = self.composition
        let diagnostics = composition.runtime.diagnostics.value
        queueWaiting = diagnostics.queuedTranscriptionTasks
        queueFailed = diagnostics.failedTranscriptionTasks
        if queueWaiting == 0 {
            sawDeferralWhileQueued = false
        } else if diagnostics.transcriptionDeferredInBackground {
            sawDeferralWhileQueued = true
        }
        transcriptionHeldInBackground = queueWaiting > 0 && sawDeferralWhileQueued
        enrichmentWaiting = diagnostics.conversationsAwaitingEnrichment
        enrichmentRunning = diagnostics.enrichmentRunning
        watchReports = watchServiceStateLabel(composition.runtime.watchServiceState.value)
        receiverStatus = Self.receiverLine(
            composition.runtime.receiverState.value,
            watchServiceStateRaw: composition.runtime.watchServiceState.value
        )
        orphanedFrames = composition.runtime.orphanedFrameCount.value
        watchLink = Self.linkFault(composition)
        watchSend = Self.sendHealth(composition.runtime.watchInfo.value)
        // Off-main: this refreshes on the diagnostics tick while the screen is open, and
        // `listSegments()` decodes every sidecar in the spool.
        let files = composition.files
        let metas = await Task.detached(priority: .userInitiated) { files.listSegments() }.value
        recentSegments = Self.segments(metas, openId: diagnostics.openSegmentId)
        failedItems = Self.failures(
            (try? composition.queue.all()) ?? [], segments: metas
        )
        pipeline = Self.pipeline(
            composition.runtime.pipelineHealth.health, nowMs: composition.clock.nowMs)
        let report = await composition.runtime.supportReport()
        supportReportText = Self.report(
            report, segments: recentSegments, failures: failedItems, link: watchLink,
            watchSend: watchSend, pipeline: pipeline
        )
    }

    /// Whether the processing pass is turning, and which of its steps are not.
    ///
    /// Healthy is ONE row. A screen that lists thirteen steps saying "fine" is a screen people
    /// stop reading, and this one has to be worth reading on the day something is wrong.
    static func pipeline(_ health: PipelineHealth, nowMs: Int64) -> DiagnosticPipeline {
        let failing = health.failingStages.map { stage -> DiagnosticStage in
            let entry = health[stage]
            let nextIn = entry.nextAttemptAtMs
                .map { max(0, $0 - nowMs) }
                .flatMap { $0 > 0 ? Formatting.duration($0) : nil }
            return DiagnosticStage(
                id: stage.rawValue,
                title: Copy.Settings.Diagnostics.stageTitle(stage.rawValue),
                detail: Copy.Settings.Diagnostics.stageDetail(
                    tries: entry.consecutiveFailures, nextIn: nextIn),
                reason: entry.lastFailureSummary
            )
        }
        var summary: String
        if health.passIsStalled(nowMs: nowMs) {
            // A pass that began and never ended. The supervisor is about to restart the loop;
            // this is the window before it does.
            summary = Copy.Settings.Diagnostics.pipelineStalled
        } else if !failing.isEmpty {
            summary = Copy.Settings.Diagnostics.pipelineFailing(failing.count)
        } else if let completed = health.lastPassCompletedAtMs {
            summary = Copy.Settings.Diagnostics.pipelineWorking(
                Formatting.duration(max(0, nowMs - completed)))
        } else {
            summary = Copy.Settings.Diagnostics.pipelineStarting
        }
        if health.loopRestarts > 0 {
            summary += " · " + Copy.Settings.Diagnostics.pipelineRestarts(health.loopRestarts)
        }
        return DiagnosticPipeline(
            summary: summary, failing: failing, loopRestarts: health.loopRestarts)
    }

    /// The failed tasks, newest first, each classified into the app's own vocabulary.
    ///
    /// `lastError` never leaves this function: it is developer prose that splices in up to 240
    /// bytes of the provider's response body, which on a 4xx is the request URL and can be the
    /// key. Only the classified reason and the attempt count reach the screen (B20).
    private static func failures(
        _ tasks: [TranscriptionTask], segments: [SegmentMeta]
    ) -> [DiagnosticFailure] {
        // `startWallMs`, not `startTimeMs`: the raw field anchors sample index 0 of the STREAM,
        // so a reattach or a rotation successor carries the stream's birth clock. Over the
        // 2026-09-08 backup the two differ for 602 of 774 segments, 594 by more than a minute.
        // This row's whole job is to name a moment the reader can place.
        let startById = Dictionary(
            segments.map { ($0.segmentId, $0.startWallMs) }, uniquingKeysWith: { first, _ in first }
        )
        return
            tasks
            .filter { $0.state == .failed }
            .sorted { $0.updatedAtMs > $1.updatedAtMs }
            // The list is a diagnosis, not an inventory: enough rows to see the pattern, and
            // the count above it is already the total.
            .prefix(8)
            .map { task in
                // When the recording was made; failing that, when it last tried. Either way the
                // row names a moment the reader can place, never a segment id.
                let stampMs = startById[task.segmentId] ?? task.updatedAtMs
                let date = Date(timeIntervalSince1970: Double(stampMs) / 1000)
                return DiagnosticFailure(
                    id: task.segmentId,
                    title: "\(TimeFmt.dayLabel(for: date)) \(TimeFmt.time(date))",
                    reason: task.failureKind.reason,
                    attemptsLine: Copy.TranscriptionFailure.tries(
                        task.attempts, retrying: task.retryable
                    )
                )
            }
    }

    /// The watch's refusal, classified once and worded once.
    ///
    /// The "Receiver" row above says "Connecting" for a de-authorized receiver — truthfully,
    /// forever, because the reconnect loop really is connecting. This row is where the reason
    /// lives, and the same sentence goes into the support report so a reader who was not there
    /// can see it too.
    private static func linkFault(_ composition: AppComposition) -> DiagnosticLinkFault? {
        guard let fault = composition.watchLinkFault else { return nil }
        return DiagnosticLinkFault(
            short: fault.rowVerdict,
            reason: fault.reason,
            trace: composition.watchLinkTraceLine
        )
    }

    /// What the watch's own counter says about audio it could not hand over.
    ///
    /// The three cases are deliberately distinct: no snapshot at all (no watch read yet), a
    /// firmware that does not report the counter (`flags` bit3 clear — its zero means nothing),
    /// and a real count. `InfoSnapshot.sendBackpressureEvents` is nil for the middle case, which
    /// is the whole reason the firmware spends a flag bit on it.
    private static func sendHealth(_ info: InfoSnapshot?) -> WatchSendHealth {
        guard let info else { return .unknown }
        guard let count = info.sendBackpressureEvents else { return .notReported }
        return .refusals(count)
    }

    /// Rebuilds the search index from the database. Foreground and awaited — it is a deliberate
    /// recovery action, and the row reports what it did rather than finishing invisibly.
    func rebuildSearchIndex() async {
        guard indexRebuild != .running else { return }
        indexRebuild = .running
        do {
            let count = try await SearchIndexRebuilder(composition: composition).run()
            AppRuntimeLog.shared.record("search    index rebuilt · \(count) conversations")
            indexRebuild = .done(Copy.Settings.Diagnostics.rebuildIndexDone(count))
        } catch {
            AppRuntimeLog.shared.record("search    index rebuild failed: \(error)")
            indexRebuild = .failed
        }
    }

    /// Plain language only — no protocol vocabulary on this row.
    ///
    /// The watch's own report is part of the answer, not a separate row to be read alongside it.
    /// This screen used to show "Connected, waiting for audio" next to "Watch reports: Recording"
    /// and leave the reader to notice that those two cannot both be fine.
    private static func receiverLine(
        _ state: ReceiverSessionState, watchServiceStateRaw: Int?
    ) -> String {
        let watchIsRecording = watchServiceStateRaw
            .flatMap { $0 >= 0 && $0 <= Int(UInt8.max) ? ServiceState(rawValue: UInt8($0)) : nil }
            == .streaming
        switch state {
        case .streaming: return Copy.Settings.Diagnostics.receiverRecording
        case .authorized where watchIsRecording: return "Not receiving — the watch is recording"
        case .authorized: return "Connected, waiting for audio"
        case .authorizing, .connecting: return "Connecting"
        case .pendingConsent, .pendingEnable: return "Waiting for the watch"
        case .connectionFailed: return "Could not connect"
        case .denied, .revoked: return "Not authorized"
        case .disconnected: return "Not connected"
        }
    }

    private static func segments(
        _ metas: [SegmentMeta], openId: String?
    ) -> [DiagnosticSegment] {
        metas.suffix(6).reversed().map { meta in
            // This segment's own start, not the stream's birth (`SegmentMeta.startWallMs`).
            // The support report is read alongside the user's account of when something went
            // wrong, so a row headed with the wrong hour is worse than no row.
            let start = Date(timeIntervalSince1970: Double(meta.startWallMs) / 1000)
            let isOpen = meta.segmentId == openId
            let head =
                "\(TimeFmt.time(start)) · "
                + (isOpen
                    ? Copy.Settings.Diagnostics.segmentRecordingNow
                    : Copy.Settings.Diagnostics.segmentStopped)
            // The honest length, not the wall span: the watch's sample counter keeps running while
            // the link is down, and across the real library that phantom time is 41.4% of what the
            // span claims. `displayGapMs` is clamped to the same number, so the pair agrees.
            var detail = Formatting.duration(displaySegmentDurationMs(meta))
            let missing = displayGapMs(meta)
            if missing > 0 { detail += " · \(Formatting.duration(missing)) missing" }
            return DiagnosticSegment(title: head, detail: detail)
        }
    }

    private static func report(
        _ report: SupportReport,
        segments: [DiagnosticSegment],
        failures: [DiagnosticFailure],
        link: DiagnosticLinkFault?,
        watchSend: WatchSendHealth,
        pipeline: DiagnosticPipeline
    ) -> String {
        // The refusal, if there is one, sits directly under the receiver state it explains —
        // the sentence the user was shown, then the raw code, which is the one thing a reader
        // of this report needs and the one thing the screen must never print.
        let watchLink =
            link.map {
                "Watch link: \($0.reason)\n"
                    + ($0.trace.map { trace in "Watch link (raw): \(trace)\n" } ?? "")
            } ?? ""
        return """
        Audio Companion support report
        Generated: \(Date(timeIntervalSince1970: Double(report.generatedAtMs) / 1000))
        Receiver: \(report.receiverState)
        \(watchLink)Capture intent: \(report.captureIntent)
        \(SupportReportText.watchSend(watchSend))Segments stored: \(report.diagnostics.segmentCount)
        Transcription queue: \(Copy.Settings.Diagnostics.queueValue(
            waiting: report.diagnostics.queuedTranscriptionTasks,
            failed: report.diagnostics.failedTranscriptionTasks,
            heldInBackground: report.diagnostics.transcriptionDeferredInBackground))
        \(SupportReportText.failures(failures))AI titles & summaries: \(report.diagnostics.conversationsAwaitingEnrichment) waiting · \
        running: \(report.diagnostics.enrichmentRunning)
        Processing: \(pipeline.summary)
        \(SupportReportText.pipeline(pipeline))Low storage: \(report.diagnostics.lowStorage)
        Recent segments:
        \(segments.map { "  \($0.title) — \($0.detail)" }.joined(separator: "\n"))
        (Counters and gap metadata only — never audio or transcript text.)
        """
    }
}
