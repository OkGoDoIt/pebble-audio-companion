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

@MainActor
@Observable
final class LiveStorageStatsSource: StorageStatsSource {
    @ObservationIgnored private let composition: AppComposition
    private(set) var recordingCount = 0
    private(set) var recordingsSize = "0 KB"

    var freeSpace: String {
        ByteCountFormatter.string(
            fromByteCount: VolumeFreeSpace().freeBytes(), countStyle: .file
        )
    }

    init(composition: AppComposition) {
        self.composition = composition
        refresh()
    }

    func refresh() {
        let composition = self.composition
        Task { [weak self] in
            let store = composition.store
            let metas = await store.listSegments()
            var bytes: Int64 = 0
            for meta in metas { bytes += await store.logSizeBytes(meta.segmentId) }
            guard let self else { return }
            recordingCount = metas.count
            recordingsSize = Formatting.storageSize(bytes)
        }
    }

    /// Real WAV copies into `Documents/PebbleAudioExports`, visible in Files.
    func exportAllAudio() async -> Int {
        let live = await composition.runtime.environment.live
        let result = try? await live.exportAll()
        return result?.fileCount ?? 0
    }

    /// Deletes every recording and everything derived from it — the full cascade, not just the
    /// audio files, so no orphan transcript or note survives the "delete all".
    func deleteAllRecordings() {
        let composition = self.composition
        Task { [weak self] in
            for meta in await composition.store.listSegments() {
                await composition.runtime.deleteSegment(meta.segmentId)
            }
            self?.refresh()
        }
    }
}

// MARK: - Local transcription models

/// The local-model catalog as this build can honestly offer it.
///
/// Today that is exactly one engine — Apple Speech over `LocalModelManager`/`AssetInventory`.
/// The Parakeet entries join `models` when their engine lands in the kit; listing a model the
/// app cannot actually fetch would be a placebo row, which is the pattern this app keeps
/// removing.
@MainActor
@Observable
final class LiveLocalModelManager: LocalModelManaging {
    @ObservationIgnored private let composition: AppComposition
    let models: [LocalModelOption] = [LocalModelCatalog.appleSpeech]

    private var states: [String: LocalModelState] = [:]
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    init(composition: AppComposition) {
        self.composition = composition
        Task { [weak self] in
            for await kitState in await composition.localModel.states() {
                self?.states[LocalModelCatalog.appleSpeechId] = Self.map(kitState)
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
    }

    func download(_ modelId: String) {
        guard modelId == LocalModelCatalog.appleSpeechId, downloadTask == nil else { return }
        let composition = self.composition
        downloadTask = Task { [weak self] in
            let result = await composition.localModel.requestInstall()
            self?.states[modelId] = Self.map(result)
            self?.downloadTask = nil
        }
    }

    /// The system asset installer owns the transfer; cancelling only stops us watching it.
    func cancelDownload(_ modelId: String) {
        downloadTask?.cancel()
        downloadTask = nil
        refresh()
    }

    func delete(_ modelId: String) {
        guard modelId == LocalModelCatalog.appleSpeechId else { return }
        downloadTask?.cancel()
        downloadTask = nil
        let composition = self.composition
        Task { [weak self] in
            self?.states[modelId] = Self.map(await composition.localModel.uninstall())
        }
    }

    #if DEBUG
        func debugFailDownload(_ modelId: String) { states[modelId] = .failed }
    #endif

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
    private(set) var queueWaiting = 0
    private(set) var queueFailed = 0
    private(set) var enrichmentWaiting = 0
    private(set) var enrichmentRunning = false
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
        enrichmentWaiting = diagnostics.conversationsAwaitingEnrichment
        enrichmentRunning = diagnostics.enrichmentRunning
        watchReports = watchServiceStateLabel(composition.runtime.watchServiceState.value)
        receiverStatus = Self.receiverLine(composition.runtime.receiverState.value)
        recentSegments = Self.segments(
            composition.files.listSegments(), openId: diagnostics.openSegmentId
        )
        let report = await composition.runtime.supportReport()
        supportReportText = Self.report(report, segments: recentSegments)
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
        _ report: SupportReport, segments: [DiagnosticSegment]
    ) -> String {
        """
        Audio Companion support report
        Generated: \(Date(timeIntervalSince1970: Double(report.generatedAtMs) / 1000))
        Receiver: \(report.receiverState)
        Capture intent: \(report.captureIntent)
        Segments stored: \(report.diagnostics.segmentCount)
        Transcription queue: \(report.diagnostics.queuedTranscriptionTasks) waiting · \
        \(report.diagnostics.failedTranscriptionTasks) failed
        AI titles & summaries: \(report.diagnostics.conversationsAwaitingEnrichment) waiting · \
        running: \(report.diagnostics.enrichmentRunning)
        Low storage: \(report.diagnostics.lowStorage)
        Recent segments:
        \(segments.map { "  \($0.title) — \($0.detail)" }.joined(separator: "\n"))
        (Counters and gap metadata only — never audio or transcript text.)
        """
    }
}
