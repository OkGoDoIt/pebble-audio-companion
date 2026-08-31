import Foundation
import Observation
import Receiver
import SwiftUI
import Transcription

// View-model data seams for the Settings screens. Screens observe these protocols; the mock
// implementations carry the artboard sample values until the receiver/storage/transcription
// services wire in (they swap via `SettingsDataSources.current`).

// MARK: - Capture (the Background Audio master switch)

/// The runtime half of a capture change, for the Settings screens.
///
/// Writing `AppSettings.captureIntent` records a PREFERENCE and nothing more. The receiver keeps
/// its own intent and only observes the link rather than dialling it, so a bare write leaves the
/// watch uncontacted when the switch goes on (the app, the widget and Control Center all say
/// "Recording" while nothing is captured) and leaves the receiver running when it goes off (the
/// user switches recording off and is still recorded). Every other surface pairs the write with a
/// runtime call — Today's Start/Stop, onboarding, Control Center (`aa2a934`, `8ecace0`) — and
/// this seam is that same call, reachable from Settings. There is no second sequence: the live
/// implementation is `LiveTodayDataSource`, which routes into `CompanionRuntime`.
@MainActor
protocol CaptureControlling: AnyObject {
    /// `.active` arms the one-shot on-watch enable prompt and dials the link; `.off` stops the
    /// receiver and closes any open pause interval, so coverage reads "off" rather than a pause
    /// that never ended. Call it AFTER writing `AppSettings.captureIntent`, so the row flips at
    /// once rather than waiting on a watch that may not be in range.
    func applyCaptureIntent(_ intent: CaptureIntent)
}

/// Previews and `-demo-data`: records what was asked for, since there is no runtime to ask.
@MainActor
@Observable
final class MockCaptureControl: CaptureControlling {
    private(set) var applied: [CaptureIntent] = []

    func applyCaptureIntent(_ intent: CaptureIntent) { applied.append(intent) }
}

// MARK: - Watch

@MainActor
protocol WatchStatusSource: AnyObject {
    var deviceName: String { get }
    /// Nil until the watch reports one — an unknown battery renders as nothing, never as 0%.
    var batteryPercent: Int? { get }
    var firmwareVersion: String? { get }
    /// The watch's own reported state — approved vocabulary ("Recording", "Paused", …).
    var watchReports: String { get }
    var isConnected: Bool { get }
    /// Attempts a connection. NO capture side effects (anti-B3).
    func findWatch()
    /// Drops the receiver binding so the next connection re-consents on the watch.
    func forget()
}

@MainActor
@Observable
final class MockWatchStatusSource: WatchStatusSource {
    var deviceName = "Pebble Time 2"
    var batteryPercent: Int? = 78
    var firmwareVersion: String? = "v4.36"
    var watchReports = Copy.Status.recording
    var isConnected = true

    func findWatch() {}
    func forget() { isConnected = false }
}

// MARK: - Storage

@MainActor
protocol StorageStatsSource: AnyObject {
    var recordingCount: Int { get }
    var recordingsSize: String { get }
    var freeSpace: String { get }
    func deleteAllRecordings()
    /// Writes WAV copies of every closed recording. Returns how many files were written.
    func exportAllAudio() async -> Int
}

@MainActor
@Observable
final class MockStorageStatsSource: StorageStatsSource {
    var recordingCount = 383
    var recordingsSize = "1.2 GB"

    /// Real free space — an honest stat surface even in the mock stage.
    var freeSpace: String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard
            let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return "—" }
        return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
    }

    func deleteAllRecordings() {
        recordingCount = 0
        recordingsSize = "0 KB"
    }

    func exportAllAudio() async -> Int {
        try? await Task.sleep(for: .seconds(2.2))
        return recordingCount
    }
}

// MARK: - Local transcription models (Part 6.7 row states)

/// One selectable on-device engine, in the shape the Settings picker needs.
///
/// Everything here is shown to the user before they commit to a download, so nothing in it may
/// be guessed: `downloadBytes` is what will actually be fetched, and `nil` means the engine
/// ships with iOS and downloads no weights of its own (Apple Speech, whose language assets the
/// system manages).
struct LocalModelOption: Identifiable, Hashable {
    /// Persisted in `AppSettings.localTranscriptionModelId` ("apple-speech",
    /// "parakeet-tdt-0.6b-v3-int8", …).
    let id: String
    /// e.g. "Parakeet TDT 0.6B, high quality".
    let displayName: String
    /// Standing in one or two words: "Recommended" · "Small" · "Experimental" · "Built in".
    let shortLabel: String
    /// One or two calm sentences about the tradeoff.
    let description: String
    /// Bytes fetched on install; nil for an engine iOS already ships.
    let downloadBytes: Int64?
    var isRecommended = false

    /// Compact identity for the Settings row, e.g. "Parakeet TDT 0.6B".
    var compactName: String {
        displayName.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
            ?? displayName
    }

    /// True when choosing this engine means fetching weights. Apple Speech does not.
    var isDownloadable: Bool { downloadBytes != nil }

    /// e.g. "706 MB" / "1.18 GB" — nil when there is nothing to download. Whole megabytes
    /// below a gigabyte: a download size is a decision aid, not a measurement.
    var sizeText: String? {
        guard let bytes = downloadBytes else { return nil }
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 1000 {
            return String(format: "%.2f GB", megabytes / 1000)
        }
        return "\(Int(megabytes.rounded())) MB"
    }
}

extension LocalModelOption {
    /// One catalog model, in the picker's shape. The fields map 1:1 — this exists so the
    /// catalog is written once, in the kit that owns the download, and the picker cannot drift
    /// from what the app can actually install. (In an extension so the memberwise init the
    /// mocks use survives.)
    init(_ spec: ParakeetModelSpec) {
        self.init(
            id: spec.id,
            displayName: spec.displayName,
            shortLabel: spec.shortLabel,
            description: spec.modelDescription,
            downloadBytes: spec.downloadBytes,
            isRecommended: spec.recommended
        )
    }
}

/// The four Part 6.7 states, per model, plus the two the engines can genuinely report.
enum LocalModelState: Equatable {
    case notInstalled
    /// Deferred until the phone is on Wi-Fi. Not a failure — nothing is wrong.
    case waitingForWiFi
    case downloading(progress: Double)
    /// The archive is down and unpacking. Real work with no byte progress to report — showing
    /// "100%" for the ~20 s a 700 MB model takes to extract would read as a stall.
    case installing
    case installed
    case failed
    /// This engine cannot run here at all (e.g. Apple Speech has no model for the phone's
    /// language). Offering a download would be offering something that can never finish.
    case unavailable

    /// A transfer or an unpack is in flight, so the row shows progress and a Cancel.
    var isBusy: Bool {
        switch self {
        case .downloading, .installing: return true
        case .notInstalled, .waitingForWiFi, .installed, .failed, .unavailable: return false
        }
    }
}

@MainActor
protocol LocalModelManaging: AnyObject {
    /// The models THIS build can actually install — never an aspirational catalog.
    var models: [LocalModelOption] { get }
    /// What the engine reports for one model. Unknown ids read `.notInstalled`.
    func state(for modelId: String) -> LocalModelState
    /// Re-reads install state for every model (cheap; safe to call on appear).
    func refresh()
    func download(_ modelId: String)
    func cancelDownload(_ modelId: String)
    func delete(_ modelId: String)
    #if DEBUG
    func debugFailDownload(_ modelId: String)
    #endif
}

extension LocalModelManaging {
    func model(_ id: String) -> LocalModelOption? { models.first { $0.id == id } }

    /// The entry a persisted id names, falling back to the first the build has — a choice
    /// migrated from the old app can name an engine this build does not carry yet.
    func selectedModel(_ id: String) -> LocalModelOption? { model(id) ?? models.first }

    /// True when the persisted selection names a model that has to be downloaded and is not
    /// here yet — so the kit is transcribing with Apple Speech in the meantime
    /// (`SelectableLocalTranscriptionProvider.resolution`). Every surface that shows the
    /// selection has to say this rather than name an engine that is not running.
    func fallsBackToAppleSpeech(_ id: String) -> Bool {
        guard let option = model(id), option.isDownloadable else { return false }
        return state(for: id) != .installed
    }
}

/// Catalog constants shared by `AppSettings` and the live source. The engine side owns the real
/// catalog; this holds the id that a fresh install starts on.
enum LocalModelCatalog {
    /// Present on every iOS 26 phone with nothing to download.
    static let appleSpeechId = "apple-speech"
    static let defaultModelId = appleSpeechId

    /// The Apple Speech entry — the one engine that is always available.
    static let appleSpeech = LocalModelOption(
        id: appleSpeechId,
        displayName: "Apple Speech",
        shortLabel: "Built in",
        description: "Transcribes in your phone's language, using the models iOS manages.",
        downloadBytes: nil
    )

    /// Everything this build can genuinely run on device: the built-in engine, then the
    /// downloadable Parakeet models in `ParakeetModelCatalog` order. One list, from the kit
    /// that owns both the download and the transcription — never an aspirational catalog.
    static let installable: [LocalModelOption] =
        [appleSpeech] + ParakeetModelCatalog.all.map(LocalModelOption.init)
}

@MainActor
@Observable
final class MockLocalModelManager: LocalModelManaging {
    /// The same catalog the live source lists — read from the kit rather than transcribed by
    /// hand, so a preview can never advertise a model (or a size) the app cannot install.
    let models: [LocalModelOption] = LocalModelCatalog.installable

    private var states: [String: LocalModelState] = [LocalModelCatalog.appleSpeechId: .installed]
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    func state(for modelId: String) -> LocalModelState { states[modelId] ?? .notInstalled }

    func refresh() {}

    func download(_ modelId: String) {
        states[modelId] = .downloading(progress: 0)
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            var progress = 0.0
            while progress < 1 {
                try? await Task.sleep(for: .milliseconds(140))
                guard let self, !Task.isCancelled else { return }
                progress = min(progress + 0.02, 1)
                self.states[modelId] = .downloading(progress: progress)
            }
            // The real store unpacks the archive after the transfer; the mock spends a beat
            // there too so previews show the same four states the device does.
            self?.states[modelId] = .installing
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.states[modelId] = .installed
        }
    }

    func cancelDownload(_ modelId: String) {
        downloadTask?.cancel()
        states[modelId] = .notInstalled
    }

    func delete(_ modelId: String) {
        downloadTask?.cancel()
        states[modelId] = .notInstalled
    }

    #if DEBUG
    func debugFailDownload(_ modelId: String) {
        downloadTask?.cancel()
        states[modelId] = .failed
    }
    #endif
}

// MARK: - AI model catalog

struct AiModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String

    /// Compact form for the Settings-root preview ("GPT-5.6 Luna" → "GPT-5.6").
    var shortName: String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }
}

// MARK: - About You

@MainActor
protocol AboutYouSource: AnyObject {
    var bio: String { get set }
    var contactsSummary: String? { get }
    var calendarSummary: String? { get }
    var contactsImporting: Bool { get }
    var calendarImporting: Bool { get }
    func importContacts()
    func importCalendar()
    func clearImported()
}

@MainActor
@Observable
final class MockAboutYouSource: AboutYouSource {
    var bio =
        "Roger — software engineer, former CTO. Planning long-term travel in Asia. "
        + "Business partners at the Great Star Theater: Paul Nathan, Red Bettie…"
    private(set) var contactsSummary: String? = Copy.Settings.AboutYou.peopleImported(142)
    private(set) var calendarSummary: String? = Copy.Settings.AboutYou.nextWeeks(3)
    private(set) var contactsImporting = false
    private(set) var calendarImporting = false

    func importContacts() {
        guard !contactsImporting else { return }
        contactsImporting = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            self?.contactsSummary = Copy.Settings.AboutYou.peopleImported(142)
            self?.contactsImporting = false
        }
    }

    func importCalendar() {
        guard !calendarImporting else { return }
        calendarImporting = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            self?.calendarSummary = Copy.Settings.AboutYou.nextWeeks(3)
            self?.calendarImporting = false
        }
    }

    func clearImported() {
        contactsSummary = nil
        calendarSummary = nil
    }
}

// MARK: - Cloud API keys (checked, not just stored)

/// Where a provider key stands right now. `checking` is a real in-flight request, and the
/// outcomes come from the kit's `CloudKeyValidator` taxonomy — never from provider prose, whose
/// 401 bodies quote the key itself back.
enum ApiKeyStatus: Equatable {
    /// A key exists but nothing has asked the provider about it yet.
    case unchecked
    case checking
    case checked(ApiKeyCheckOutcome)
}

@MainActor
protocol ApiKeyChecking: AnyObject {
    func status(for provider: CloudProvider) -> ApiKeyStatus
    /// Checks a key the user has typed (it may already be saved; saving never waits on this).
    func check(_ key: String, for provider: CloudProvider) async
    /// Re-checks the key already in the Keychain. No-op when there isn't one.
    func recheckSaved(_ provider: CloudProvider) async
}

@MainActor
@Observable
final class MockApiKeyChecker: ApiKeyChecking {
    private var statuses: [CloudProvider: ApiKeyStatus] = [
        .soniox: .checked(.valid), .openAi: .unchecked,
    ]

    func status(for provider: CloudProvider) -> ApiKeyStatus { statuses[provider] ?? .unchecked }

    func check(_ key: String, for provider: CloudProvider) async {
        statuses[provider] = .checking
        try? await Task.sleep(for: .seconds(1.1))
        statuses[provider] = .checked(key.count < 12 ? .rejected : .valid)
    }

    func recheckSaved(_ provider: CloudProvider) async {
        statuses[provider] = .checking
        try? await Task.sleep(for: .seconds(1.1))
        statuses[provider] = .checked(.valid)
    }
}

// MARK: - Cloud connectivity (Test Connection)

/// What the Test Connection row has to say. `untested` is honest silence — the row shows no
/// verdict until someone has actually asked.
enum CloudTestState: Equatable {
    case untested
    case testing
    /// e.g. "just now" / "2 min ago".
    case connected(ago: String)
    case problem(String)
}

@MainActor
protocol CloudHealthSource: AnyObject {
    var testState: CloudTestState { get }
    func test()
}

@MainActor
@Observable
final class MockCloudHealthSource: CloudHealthSource {
    private(set) var testState: CloudTestState = .connected(ago: "2 min ago")

    func test() {
        guard testState != .testing else { return }
        testState = .testing
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.testState = .connected(ago: "just now")
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticSegment: Identifiable {
    let id = UUID()
    /// Plain-language head, e.g. "1:12 PM · continued".
    let title: String
    /// Trailing detail, e.g. "reattached after a blip".
    let detail: String
}

/// The failure block of the Support Report, shared by the live and mock sources — the report is
/// what gets sent when something is wrong, so the reasons have to travel with it.
enum SupportReportText {
    /// Empty string when nothing failed (no header over an empty list), otherwise one
    /// classified line per failure, newline-terminated so it drops into the report as a block.
    static func failures(_ items: [DiagnosticFailure]) -> String {
        guard !items.isEmpty else { return "" }
        let lines = items.map { "  \($0.title) — \($0.reason) [\($0.attemptsLine)]" }
        return "Failed transcriptions:\n" + lines.joined(separator: "\n") + "\n"
    }
}

/// One transcription task that is sitting in Failed, and WHY.
///
/// The reason is always a sentence from `Copy.TranscriptionFailure` — the stored `lastError` is
/// developer prose with up to 240 bytes of the provider's response body spliced into it, which
/// can hold the request URL and the key (B20). It is classified, never quoted.
struct DiagnosticFailure: Identifiable, Equatable {
    /// The segment id — the row key, not something the screen prints.
    let id: String
    /// When the recording was made, e.g. "Tue 1:12 PM". A person recognises a failure by the
    /// conversation it belongs to, not by a UUID.
    let title: String
    /// The plain-language reason, one sentence.
    let reason: String
    /// e.g. "3 tries · will retry" / "gave up after 8 tries".
    let attemptsLine: String
}

/// The watch's own refusal, in the app's words — nil when the watch has not refused anything.
///
/// The wire protocol names its refusals precisely (`AuthStatus`, `RevokeReason`,
/// `ProtocolErrorCode`, the version range in the Info snapshot) and the phone used to decode all
/// of it and show none of it. `StatusUI.WatchLinkFault` classifies; these are the words.
struct DiagnosticLinkFault: Equatable {
    /// Two or three words for the row's trailing value, e.g. "another phone".
    let short: String
    /// The sentence underneath: what happened and what to do about it.
    let reason: String
    /// The raw code, for the support report's technical tail and Detailed Logs ONLY. Protocol
    /// vocabulary is allowed there and nowhere else (B20).
    let trace: String?
}

/// Where a search-index rebuild has got to. `.done` carries what it actually did, so the row
/// reports a result rather than just stopping.
enum IndexRebuildState: Equatable {
    case idle
    case running
    case done(String)
    case failed
}

@MainActor
protocol DiagnosticsSource: AnyObject {
    var receiverStatus: String { get }
    var watchReports: String { get }
    /// Why the watch is turning this phone away, when it is. Nil is the calm case: the row
    /// simply is not there.
    var watchLink: DiagnosticLinkFault? { get }
    /// Rebuild-index progress, and a way to start one. The index is derived data, so this
    /// throws nothing away that cannot be written again from the database.
    var indexRebuild: IndexRebuildState { get }
    func rebuildSearchIndex() async
    var queueWaiting: Int { get }
    var queueFailed: Int { get }
    /// The failed tasks with their reasons — the answer to "6 failed, but why?", which until
    /// now was persisted in `transcription_tasks.lastError` and shown nowhere.
    var failedItems: [DiagnosticFailure] { get }
    /// Conversations transcribed but still owed an AI title/summary/tags, and whether a pass
    /// is running right now. The enrichment counterpart of the transcription queue.
    var enrichmentWaiting: Int { get }
    var enrichmentRunning: Bool { get }
    var recentSegments: [DiagnosticSegment] { get }
    /// Raw technical lines — counters and gap metadata only, never audio or transcript text.
    var detailedLogLines: [String] { get }
    var supportReportText: String { get }
}

@MainActor
@Observable
final class MockDiagnosticsSource: DiagnosticsSource {
    var receiverStatus = Copy.Settings.Diagnostics.receiverRecording
    var watchReports = Copy.Status.recording
    var watchLink: DiagnosticLinkFault?
    var indexRebuild: IndexRebuildState = .idle
    var queueWaiting = 0
    var queueFailed = 0
    var enrichmentWaiting = 0
    var enrichmentRunning = false
    var failedItems: [DiagnosticFailure] = []

    func rebuildSearchIndex() async {
        indexRebuild = .running
        indexRebuild = .done(Copy.Settings.Diagnostics.rebuildIndexDone(recentSegments.count))
    }

    var recentSegments: [DiagnosticSegment] = [
        .init(title: "1:42 PM · recording now", detail: "12 min · quiet 2 min"),
        .init(title: "1:12 PM · continued", detail: "reattached after a blip"),
        .init(title: "12:40 PM · stopped", detail: "30 min · 2 sec missing"),
    ]

    // Protocol vocabulary is allowed here and only here (diagnostics-only word list).
    var detailedLogLines: [String] = [
        "13:42:01.204 receiver  session attached · stream 4821 · base seq 18240",
        "13:42:01.371 receiver  checkpoint ack · 2 s audio / 500 ms wall cadence",
        "13:41:58.900 spool     segment continued in place · gap shrink 1.8 s",
        "13:12:14.552 receiver  reattach · relaxed identity match · refill 41 frames",
        "13:12:12.030 link      keepalive missed ×2 · resync issued",
        "12:40:44.719 spool     segment closed · 30 min · loss gaps 1 (2.1 s)",
        "12:40:44.801 queue     enqueue transcription · position 0",
        "12:40:47.112 queue     task complete · provider soniox",
    ]

    var supportReportText: String {
        """
        Audio Companion support report
        Receiver: \(receiverStatus)
        Watch reports: \(watchReports)
        Transcription queue: \(queueWaiting) waiting · \(queueFailed) failed
        \(SupportReportText.failures(failedItems))Recent segments:
        \(recentSegments.map { "  \($0.title) — \($0.detail)" }.joined(separator: "\n"))
        (Counters and gap metadata only — never audio or transcript text.)
        """
    }
}

// MARK: - Holder

/// Swap point for the real services; screens resolve through `current` (defaults to mocks).
@MainActor
final class SettingsDataSources {
    static var current = SettingsDataSources()

    let capture: CaptureControlling
    let watch: WatchStatusSource
    let storage: StorageStatsSource
    let localModel: LocalModelManaging
    let aboutYou: AboutYouSource
    let diagnostics: DiagnosticsSource
    let cloudHealth: CloudHealthSource
    let apiKeys: ApiKeyChecking
    let aiModels: [AiModelOption]

    init(
        capture: CaptureControlling? = nil,
        watch: WatchStatusSource? = nil,
        storage: StorageStatsSource? = nil,
        localModel: LocalModelManaging? = nil,
        aboutYou: AboutYouSource? = nil,
        diagnostics: DiagnosticsSource? = nil,
        cloudHealth: CloudHealthSource? = nil,
        apiKeys: ApiKeyChecking? = nil,
        aiModels: [AiModelOption]? = nil
    ) {
        self.capture = capture ?? MockCaptureControl()
        self.watch = watch ?? MockWatchStatusSource()
        self.storage = storage ?? MockStorageStatsSource()
        self.localModel = localModel ?? MockLocalModelManager()
        self.aboutYou = aboutYou ?? MockAboutYouSource()
        self.diagnostics = diagnostics ?? MockDiagnosticsSource()
        self.cloudHealth = cloudHealth ?? MockCloudHealthSource()
        self.apiKeys = apiKeys ?? MockApiKeyChecker()
        self.aiModels = aiModels ?? [
            .init(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
            .init(id: "gpt-5.6-mini", displayName: "GPT-5.6 Mini"),
        ]
    }

    func aiModelName(for id: String) -> String {
        aiModels.first(where: { $0.id == id })?.displayName ?? id
    }

    func aiModelShortName(for id: String) -> String {
        aiModels.first(where: { $0.id == id })?.shortName ?? id
    }
}
