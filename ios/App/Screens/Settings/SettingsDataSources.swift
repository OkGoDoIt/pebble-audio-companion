import Foundation
import Observation
import SwiftUI

// View-model data seams for the Settings screens. Screens observe these protocols; the mock
// implementations carry the artboard sample values until the receiver/storage/transcription
// services wire in (they swap via `SettingsDataSources.current`).

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

// MARK: - Local speech language (Part 6.7 row states, M3 engine)

/// One installable on-device speech language.
///
/// M3: the local engine is Apple's SpeechAnalyzer, and its "models" are per-locale system
/// speech assets — iOS downloads, shares, updates and reclaims them. So the choice this
/// product can honestly offer is *which language*, not which third-party model.
struct LocalSpeechLanguage: Identifiable, Hashable {
    /// BCP-47 identifier, e.g. "en-US".
    let id: String
    /// Full localized name for the picker, e.g. "English (United States)".
    let name: String
    /// Compact name for the Settings row, e.g. "English (US)".
    let shortName: String
}

enum LocalModelState: Equatable {
    case notInstalled
    /// Deferred until the phone is on Wi-Fi. Not a failure — nothing is wrong.
    case waitingForWiFi
    case downloading(progress: Double)
    case installed
    case failed
}

@MainActor
protocol LocalModelManaging: AnyObject {
    /// Every language the on-device engine supports, this phone's own language first.
    var languages: [LocalSpeechLanguage] { get }
    /// What iOS reports for one language. Unknown/unqueried languages read `.notInstalled`.
    func state(for languageId: String) -> LocalModelState
    /// Re-reads iOS's inventory for every language (cheap; safe to call on appear).
    func refresh()
    func download(_ languageId: String)
    func cancelDownload(_ languageId: String)
    func delete(_ languageId: String)
    #if DEBUG
    func debugFailDownload(_ languageId: String)
    #endif
}

extension LocalModelManaging {
    func language(_ id: String) -> LocalSpeechLanguage? { languages.first { $0.id == id } }
}

@MainActor
@Observable
final class MockLocalModelManager: LocalModelManaging {
    let languages: [LocalSpeechLanguage] = [
        .init(id: "en-US", name: "English (United States)", shortName: "English (US)"),
        .init(id: "en-GB", name: "English (United Kingdom)", shortName: "English (UK)"),
        .init(id: "de-DE", name: "German (Germany)", shortName: "German (DE)"),
        .init(id: "es-ES", name: "Spanish (Spain)", shortName: "Spanish (ES)"),
        .init(id: "fr-FR", name: "French (France)", shortName: "French (FR)"),
        .init(id: "ja-JP", name: "Japanese (Japan)", shortName: "Japanese (JP)"),
    ]

    private var states: [String: LocalModelState] = ["en-US": .installed]
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    func state(for languageId: String) -> LocalModelState { states[languageId] ?? .notInstalled }

    func refresh() {}

    func download(_ languageId: String) {
        guard state(for: languageId) != .downloading(progress: 0) else { return }
        states[languageId] = .downloading(progress: 0)
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            var progress = 0.0
            while progress < 1 {
                try? await Task.sleep(for: .milliseconds(140))
                guard let self, !Task.isCancelled else { return }
                progress = min(progress + 0.025, 1)
                self.states[languageId] = .downloading(progress: progress)
            }
            self?.states[languageId] = .installed
        }
    }

    func cancelDownload(_ languageId: String) {
        downloadTask?.cancel()
        states[languageId] = .notInstalled
    }

    func delete(_ languageId: String) {
        downloadTask?.cancel()
        states[languageId] = .notInstalled
    }

    #if DEBUG
    func debugFailDownload(_ languageId: String) {
        downloadTask?.cancel()
        states[languageId] = .failed
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

@MainActor
protocol DiagnosticsSource: AnyObject {
    var receiverStatus: String { get }
    var watchReports: String { get }
    var queueWaiting: Int { get }
    var queueFailed: Int { get }
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
    var queueWaiting = 0
    var queueFailed = 0

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
        Recent segments:
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

    let watch: WatchStatusSource
    let storage: StorageStatsSource
    let localModel: LocalModelManaging
    let aboutYou: AboutYouSource
    let diagnostics: DiagnosticsSource
    let cloudHealth: CloudHealthSource
    let aiModels: [AiModelOption]

    init(
        watch: WatchStatusSource? = nil,
        storage: StorageStatsSource? = nil,
        localModel: LocalModelManaging? = nil,
        aboutYou: AboutYouSource? = nil,
        diagnostics: DiagnosticsSource? = nil,
        cloudHealth: CloudHealthSource? = nil,
        aiModels: [AiModelOption]? = nil
    ) {
        self.watch = watch ?? MockWatchStatusSource()
        self.storage = storage ?? MockStorageStatsSource()
        self.localModel = localModel ?? MockLocalModelManager()
        self.aboutYou = aboutYou ?? MockAboutYouSource()
        self.diagnostics = diagnostics ?? MockDiagnosticsSource()
        self.cloudHealth = cloudHealth ?? MockCloudHealthSource()
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
