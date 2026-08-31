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

    /// The watch packs its firmware version as major/minor/patch bytes; battery is not part of
    /// the audio-companion service, so it stays unknown until the watch reports one.
    private static func firmwareLabel(_ packed: UInt32) -> String? {
        guard packed != 0 else { return nil }
        let major = (packed >> 16) & 0xFF
        let minor = (packed >> 8) & 0xFF
        let patch = packed & 0xFF
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

@MainActor
@Observable
final class LiveAboutYouSource: AboutYouSource {
    @ObservationIgnored private let composition: AppComposition

    var bio: String {
        didSet { persist() }
    }
    private(set) var contactsSummary: String?
    private(set) var calendarSummary: String?
    private(set) var contactsImporting = false
    private(set) var calendarImporting = false

    init(composition: AppComposition) {
        self.composition = composition
        let context = composition.personalContext.load()
        bio = context.profileText ?? ""
        contactsSummary =
            context.people.isEmpty
            ? nil : Copy.Settings.AboutYou.peopleImported(context.people.count)
        calendarSummary = context.sources.first { $0.kind == .calendar }.map { _ in
            Copy.Settings.AboutYou.nextWeeks(3)
        }
    }

    private func persist() {
        var context = composition.personalContext.load()
        context.profileText = bio
        _ = try? composition.personalContext.save(context)
    }

    /// Names only, and only on an explicit tap — the permission prompt is the user's decision
    /// point, never a side effect of opening Settings.
    func importContacts() {
        guard !contactsImporting else { return }
        contactsImporting = true
        let composition = self.composition
        Task { [weak self] in
            let people = await Self.fetchContacts()
            var context = composition.personalContext.load()
            context.people = people
            if !people.isEmpty {
                context.sources.removeAll { $0.kind == .contacts }
                context.sources.append(
                    ContextSource(
                        id: "contacts", kind: .contacts, label: "Contacts",
                        importedAtMs: composition.clock.nowMs
                    ))
            }
            _ = try? composition.personalContext.save(context)
            guard let self else { return }
            contactsSummary =
                people.isEmpty ? nil : Copy.Settings.AboutYou.peopleImported(people.count)
            contactsImporting = false
        }
    }

    func importCalendar() {
        guard !calendarImporting else { return }
        calendarImporting = true
        let composition = self.composition
        Task { [weak self] in
            let weeks = 3
            let titles = await Self.fetchCalendarTitles(weeks: weeks)
            var context = composition.personalContext.load()
            context.orgs = Array(Set(context.orgs + titles)).sorted()
            if !titles.isEmpty {
                context.sources.removeAll { $0.kind == .calendar }
                context.sources.append(
                    ContextSource(
                        id: "calendar", kind: .calendar, label: "Calendar",
                        importedAtMs: composition.clock.nowMs
                    ))
            }
            _ = try? composition.personalContext.save(context)
            guard let self else { return }
            calendarSummary = titles.isEmpty ? nil : Copy.Settings.AboutYou.nextWeeks(weeks)
            calendarImporting = false
        }
    }

    func clearImported() {
        var context = composition.personalContext.load()
        context.people = []
        context.orgs = []
        context.sources = []
        _ = try? composition.personalContext.save(context)
        contactsSummary = nil
        calendarSummary = nil
    }

    private static func fetchContacts() async -> [KnownPerson] {
        let store = CNContactStore()
        guard (try? await store.requestAccess(for: .contacts)) == true else { return [] }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey]
        let request = CNContactFetchRequest(keysToFetch: keys as [CNKeyDescriptor])
        var people: [KnownPerson] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            let name = "\(contact.givenName) \(contact.familyName)"
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            people.append(
                KnownPerson(
                    id: contact.identifier,
                    name: name,
                    aliases: contact.givenName.isEmpty ? [] : [contact.givenName],
                    organization: contact.organizationName.isEmpty
                        ? nil : contact.organizationName
                ))
        }
        return people
    }

    private static func fetchCalendarTitles(weeks: Int) async -> [String] {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { return [] }
        let start = Date()
        let end = start.addingTimeInterval(Double(weeks) * 7 * 24 * 60 * 60)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { $0.title }.filter { !$0.isEmpty }
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

    /// Counters and gap metadata only — never audio or transcript text.
    var detailedLogLines: [String] { AppRuntimeLog.shared.recent }

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
        receiverStatus = Self.receiverLine(composition.runtime.receiverState.value)
        watchLink = Self.linkFault(composition)
        let metas = composition.files.listSegments()
        recentSegments = Self.segments(metas, openId: diagnostics.openSegmentId)
        failedItems = Self.failures(
            (try? composition.queue.all()) ?? [], segments: metas
        )
        let report = await composition.runtime.supportReport()
        supportReportText = Self.report(
            report, segments: recentSegments, failures: failedItems, link: watchLink
        )
    }

    /// The failed tasks, newest first, each classified into the app's own vocabulary.
    ///
    /// `lastError` never leaves this function: it is developer prose that splices in up to 240
    /// bytes of the provider's response body, which on a 4xx is the request URL and can be the
    /// key. Only the classified reason and the attempt count reach the screen (B20).
    private static func failures(
        _ tasks: [TranscriptionTask], segments: [SegmentMeta]
    ) -> [DiagnosticFailure] {
        let startById = Dictionary(
            segments.map { ($0.segmentId, $0.startTimeMs) }, uniquingKeysWith: { first, _ in first }
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
                let stampMs = startById[task.segmentId].map(Int64.init) ?? task.updatedAtMs
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
    private static func receiverLine(_ state: ReceiverSessionState) -> String {
        switch state {
        case .streaming: return Copy.Settings.Diagnostics.receiverRecording
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
            let start = Date(timeIntervalSince1970: Double(meta.startTimeMs) / 1000)
            let isOpen = meta.segmentId == openId
            let head =
                "\(TimeFmt.time(start)) · "
                + (isOpen
                    ? Copy.Settings.Diagnostics.segmentRecordingNow
                    : Copy.Settings.Diagnostics.segmentStopped)
            var detail = Formatting.duration(segmentDurationMs(meta))
            let missing = displayGapMs(meta)
            if missing > 0 { detail += " · \(Formatting.duration(missing)) missing" }
            return DiagnosticSegment(title: head, detail: detail)
        }
    }

    private static func report(
        _ report: SupportReport,
        segments: [DiagnosticSegment],
        failures: [DiagnosticFailure],
        link: DiagnosticLinkFault?
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
        Segments stored: \(report.diagnostics.segmentCount)
        Transcription queue: \(Copy.Settings.Diagnostics.queueValue(
            waiting: report.diagnostics.queuedTranscriptionTasks,
            failed: report.diagnostics.failedTranscriptionTasks,
            heldInBackground: report.diagnostics.transcriptionDeferredInBackground))
        \(SupportReportText.failures(failures))AI titles & summaries: \(report.diagnostics.conversationsAwaitingEnrichment) waiting · \
        running: \(report.diagnostics.enrichmentRunning)
        Low storage: \(report.diagnostics.lowStorage)
        Recent segments:
        \(segments.map { "  \($0.title) — \($0.detail)" }.joined(separator: "\n"))
        (Counters and gap metadata only — never audio or transcript text.)
        """
    }
}
