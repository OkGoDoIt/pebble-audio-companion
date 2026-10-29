import AppDB
import CompanionRuntime
import Foundation
import Intelligence
import Observation
import Receiver
import SegmentStore
import StatusUI
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
/// runtime call — Today's Start/Stop, onboarding, Control Center (`ae5758a`, `d4ec3a5`) — and
/// this seam is that same call, reachable from Settings. There is no second sequence: the live
/// implementation is `LiveTodayDataSource`, which routes into `CompanionRuntime`.
@MainActor
protocol CaptureControlling: AnyObject {
    /// `.active` arms the one-shot on-watch enable prompt and dials the link; `.off` stops the
    /// receiver and closes any open pause interval, so coverage reads "off" rather than a pause
    /// that never ended. Call it AFTER writing `AppSettings.captureIntent`, so the row flips at
    /// once rather than waiting on a watch that may not be in range. `source` names the surface
    /// in the flight recorder and the pause journal.
    func applyCaptureIntent(_ intent: CaptureIntent, source: PauseSource)
}

/// Previews and `-demo-data`: records what was asked for, since there is no runtime to ask.
@MainActor
@Observable
final class MockCaptureControl: CaptureControlling {
    private(set) var applied: [CaptureIntent] = []

    func applyCaptureIntent(_ intent: CaptureIntent, source: PauseSource) {
        applied.append(intent)
    }
}

// MARK: - Watch

@MainActor
protocol WatchStatusSource: AnyObject {
    var deviceName: String { get }
    /// Nil until the watch reports one — an unknown battery renders as nothing, never as 0%.
    var batteryPercent: Int? { get }
    var firmwareVersion: String? { get }
    /// The exact build ("v4.41.0-678-g49b06928d") from the watch's Device Information Service.
    /// Nil until it has been read. `firmwareVersion` is major.minor.patch only.
    var firmwareRevision: String? { get }
    /// The watch's own reported state — approved vocabulary ("Recording", "Paused", …).
    var watchReports: String { get }
    var isConnected: Bool { get }
    /// The watch answered without the audio service (an official update replaced the audio
    /// firmware, or it never had it). Stays true until a connection gets past that point.
    var needsAudioFirmware: Bool { get }
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
    var firmwareRevision: String? = "v4.36.0-12-g1a2b3c4d5"
    var watchReports = Copy.Status.recording
    var isConnected = true
    /// `-demo.needsFirmware` stages a watch whose audio firmware was replaced.
    var needsAudioFirmware = ProcessInfo.processInfo.arguments.contains("-demo.needsFirmware")

    func findWatch() {}
    func forget() { isConnected = false }
}

// MARK: - Storage

/// Everything the Storage screen draws, from the store's in-memory index and the runtime's
/// cold-tier summary. Built by `StoragePlanner` so the arithmetic has a test and so the live
/// source and the mock cannot disagree about what a number means.
struct StorageOverview: Equatable {
    var recordingCount: Int
    /// Audio bytes on the phone: never moved, or moved and still uploading.
    var audioOnPhoneBytes: Int64
    /// Audio bytes evicted to iCloud.
    var audioInCloudBytes: Int64
    var audioInCloudCount: Int
    /// Moved and not yet confirmed uploaded (still on the phone, and counted there).
    var uploadingBytes: Int64
    var uploadingCount: Int
    /// Transcripts, AI outputs, the database, sidecars, the flight recorder.
    var textBytes: Int64
    /// Downloaded weights plus the compiled cache.
    var modelBytes: Int64
    var temporaryBytes: Int64
    var freeBytes: Int64
    var capacityBytes: Int64
    /// iCloud Drive is reachable for this app right now.
    var cloudAvailable: Bool
    var restoring: ColdAudioTier.Summary.Restore?
    var cloudError: String?

    /// Everything of ours that is on the phone.
    var onPhoneBytes: Int64 { audioOnPhoneBytes + textBytes + modelBytes + temporaryBytes }
    /// Every recording's audio, wherever it is.
    var audioBytes: Int64 { audioOnPhoneBytes + audioInCloudBytes }
}

/// A phone's capacity is a round number ("512 GB", "1 TB"), and reads as one.
enum StorageCapacity {
    static func label(_ bytes: Int64) -> String {
        let gb = Double(bytes) / Double(1 << 30)
        if gb >= 1_000 { return "\((gb / 1_024 * 10).rounded() / 10) TB" }
        return gb >= 64 ? "\(Int(gb.rounded())) GB" : Formatting.storageSize(bytes)
    }
}

/// What a rule would move: the preview beside the age picker.
struct StoragePreview: Equatable {
    var bytes: Int64
    var count: Int
    /// Of all audio (phone and iCloud together), 0…100.
    var percent: Int
}

/// The Storage screen's arithmetic, pure over the sidecars.
enum StoragePlanner {
    static func overview(
        metas: [SegmentMeta], footprint: StorageFootprint?, cold: ColdAudioTier.Summary?
    ) -> StorageOverview {
        var onPhone: Int64 = 0
        var inCloud: Int64 = 0
        var inCloudCount = 0
        var uploading: Int64 = 0
        var uploadingCount = 0
        var count = 0
        for meta in metas where !meta.isOpen {
            count += 1
            if let coldStorage = meta.coldStorage {
                if coldStorage.isEvicted {
                    inCloud += coldStorage.bytes
                    inCloudCount += 1
                } else {
                    uploading += coldStorage.bytes
                    uploadingCount += 1
                    onPhone += coldStorage.bytes
                }
            } else {
                onPhone += meta.logBytes
            }
        }
        let text = footprint.map {
            $0.transcriptBytes + $0.databaseBytes + $0.sidecarBytes + $0.diagnosticsBytes + $0.otherBytes
        } ?? 0
        return StorageOverview(
            recordingCount: count,
            audioOnPhoneBytes: onPhone,
            audioInCloudBytes: inCloud,
            audioInCloudCount: inCloudCount,
            uploadingBytes: uploading,
            uploadingCount: uploadingCount,
            textBytes: text,
            modelBytes: footprint.map { $0.modelBytes + $0.cacheBytes } ?? 0,
            temporaryBytes: footprint?.temporaryBytes ?? 0,
            freeBytes: footprint?.freeBytes ?? 0,
            capacityBytes: footprint?.capacityBytes ?? 0,
            cloudAvailable: cold?.available ?? false,
            restoring: cold?.restoring,
            cloudError: cold?.lastError)
    }

    /// What `olderThanDays` would move right now, out of everything (so the share is of all
    /// audio and does not jump as audio moves).
    static func wouldMove(
        metas: [SegmentMeta], olderThanDays: Int, nowMs: Int64, audioBytes: Int64
    ) -> StoragePreview {
        let minAgeMs = Int64(max(1, olderThanDays)) * 86_400_000
        var bytes: Int64 = 0
        var count = 0
        for meta in metas where ColdAudioTier.isEligible(meta, minAgeMs: minAgeMs, now: nowMs) {
            bytes += meta.logBytes
            count += 1
        }
        let percent = audioBytes > 0 ? Int((Double(bytes) / Double(audioBytes) * 100).rounded()) : 0
        return StoragePreview(bytes: bytes, count: count, percent: min(max(percent, 0), 100))
    }
}

@MainActor
protocol StorageStatsSource: AnyObject {
    var recordingCount: Int { get }
    var recordingsSize: String { get }
    /// The same figure as `recordingsSize`, unformatted, so the storage-limit row can say how
    /// much of the limit is used without re-deriving it from a display string.
    var recordingsBytes: Int64 { get }
    var freeSpace: String { get }
    /// The overview, once the sidecars have been read; nil until then.
    var overview: StorageOverview? { get }
    /// What the age picker's current value would move. Synchronous over the cached sidecars,
    /// so the preview follows the picker without a round trip.
    func wouldMove(olderThanDays: Int) -> StoragePreview
    /// Starts bringing every recording in iCloud back to the phone.
    func bringEverythingBack()
    /// The byte sweep runs only while the Storage screen is visible; see `LiveStorageStatsSource`.
    func setVisible(_ visible: Bool)
    func deleteAllRecordings()
    /// Writes WAV copies of every closed recording. Returns how many files were written.
    func exportAllAudio() async -> Int
}

@MainActor
@Observable
final class MockStorageStatsSource: StorageStatsSource {
    var recordingCount = 383
    var recordingsSize = "2.1 GB"
    var recordingsBytes: Int64 = 2_254_857_830

    /// The artboard case: the phone on 2026-10-12, with a season of audio already in iCloud.
    var overview: StorageOverview? = StorageOverview(
        recordingCount: 383,
        audioOnPhoneBytes: 805_306_368,
        audioInCloudBytes: 1_449_551_462,
        audioInCloudCount: 241,
        uploadingBytes: 0,
        uploadingCount: 0,
        textBytes: 347_078_656,
        modelBytes: 2_533_359_616,
        temporaryBytes: 0,
        freeBytes: 20_500_000_000,
        capacityBytes: 512_000_000_000,
        cloudAvailable: true,
        restoring: nil,
        cloudError: nil)

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

    /// Roughly: the share of the mock library older than the age, on a 240-day history.
    func wouldMove(olderThanDays: Int) -> StoragePreview {
        guard let overview else { return StoragePreview(bytes: 0, count: 0, percent: 0) }
        let share = max(0, min(1, 1 - Double(olderThanDays) / 240))
        let bytes = Int64(Double(overview.audioOnPhoneBytes) * share)
        return StoragePreview(
            bytes: bytes, count: Int(Double(overview.recordingCount) * share),
            percent: Int((Double(bytes) / Double(max(overview.audioBytes, 1)) * 100).rounded()))
    }

    func bringEverythingBack() {
        overview?.restoring = .init(done: 12, total: 241)
    }

    func setVisible(_ visible: Bool) {}

    func deleteAllRecordings() {
        recordingCount = 0
        recordingsSize = "0 KB"
        recordingsBytes = 0
        overview?.recordingCount = 0
        overview?.audioOnPhoneBytes = 0
        overview?.audioInCloudBytes = 0
        overview?.audioInCloudCount = 0
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
    /// The native runtime a downloadable model runs on. Decides whether THIS phone can run it
    /// at all (Core AI needs iOS 27 and a device build); Apple Speech is `.cactus` by default
    /// only because the field is meaningless for it.
    var runtime: LocalEngineRuntime = .cactus
    /// True when nothing is hosted for this model yet: the row offers the Files inbox, not a
    /// download arrow, and says so.
    var isImportOnly = false

    /// True when this build, on this OS, has an engine for the model — false is the Core AI
    /// entry on iOS 26 or a simulator, where the row shows "needs iOS 27" and cannot be chosen.
    var canRunHere: Bool { !isDownloadable || ParakeetEngineFactory.isSupported(runtime) }

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
            isRecommended: spec.recommended,
            runtime: spec.runtime,
            isImportOnly: !spec.hasDownloadSource
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
    /// Installed, but the runtime's one-time setup pass (Core AI specialization) has not run —
    /// just installed, or its compiled cache went stale and was discarded. It runs the next time
    /// the app is open; until then recordings WAIT for this model. Apple Speech does not stand
    /// in (the kit resolves an installed model to itself), so no surface may say it does.
    case preparing
    case installed
    case failed
    /// This engine cannot run here at all (e.g. Apple Speech has no model for the phone's
    /// language). Offering a download would be offering something that can never finish.
    case unavailable

    /// A transfer or an unpack is in flight, so the row shows progress and a Cancel.
    var isBusy: Bool {
        switch self {
        case .downloading, .installing, .preparing: return true
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
        // Installed-but-setting-up is not a fallback: the kit waits for this model.
        let state = state(for: id)
        return state != .installed && state != .preparing
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

    func state(for modelId: String) -> LocalModelState {
        // Same rule as the live source: a model this build cannot run is unavailable, however
        // the preview would like to animate it.
        if let option = model(modelId), !option.canRunHere { return .unavailable }
        return states[modelId] ?? .notInstalled
    }

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

/// One import source as the screens need it. A value type, so the live source and the mock
/// cannot describe the same situation with different shapes.
struct ImportSourceState: Equatable {
    /// What iOS is currently willing to hand over. `limited` is the iOS 18+ Contacts case,
    /// where only the contacts the user picked in the system sheet are visible.
    enum Access: Equatable { case notDetermined, granted, limited, denied }

    var kind: ContextImportKind
    var isEnabled: Bool
    var access: Access
    var isRefreshing: Bool
    /// When the last SUCCESSFUL import finished — the only input to "Updated …".
    var lastImportedAtMs: Int64?
    var lastFailure: ContextImportFailure?
    var importedCount: Int
    var selection: ContextImportSelection
    var pastDays: Int
    var futureDays: Int
}

/// A group, account or calendar the user can include or exclude.
struct ImportChoice: Identifiable, Equatable {
    /// Namespaced (`group:` / `container:` / a calendar identifier), because Contacts groups
    /// and containers are two different id spaces sharing one selection.
    let id: String
    let name: String
    /// The account it lives in ("iCloud", "Work"), where that is not the name itself.
    let detail: String?
    let section: ImportChoiceSection
}

/// Which list a choice belongs to on the picker.
enum ImportChoiceSection: Equatable { case account, group, calendar }

/// About You: the bio, and per-source control of the two phone imports.
///
/// The imports used to be two fire-once buttons with no state — see `ContextImportSettings` in
/// the kit for what that cost. Everything the screen now needs about a source is one
/// `ImportSourceState`, and every change to a source goes through one of these calls.
@MainActor
protocol AboutYouSource: AnyObject {
    /// The free-text bio. Written by the screen's debounced saver, never per keystroke.
    var bio: String { get set }
    func state(for kind: ContextImportKind) -> ImportSourceState
    /// Turning a source ON is the ONE place either framework is asked for permission.
    func setEnabled(_ enabled: Bool, for kind: ContextImportKind)
    func setSelection(_ selection: ContextImportSelection, for kind: ContextImportKind)
    func setCalendarWindow(pastDays: Int, futureDays: Int)
    /// A user-initiated refresh. Automatic ones happen without the screen asking.
    func refresh(_ kind: ContextImportKind)
    /// Both sources at once. Removing ONE source's data is `setEnabled(false, for:)`: a switch
    /// that is off must not leave imported names in the context behind it, so the two are the
    /// same act and there is no second control that could disagree with the switch.
    func clearImported()
    /// The groups / accounts / calendars available to pick from. Empty when access has not
    /// been granted — asking for the list must never provoke a permission prompt.
    func choices(for kind: ContextImportKind) async -> [ImportChoice]
}

@MainActor
@Observable
final class MockAboutYouSource: AboutYouSource {
    var bio =
        "Roger — software engineer, keen hiker. Planning a long walking trip. "
        + "Book club friends at Riverside Hall: Owen Hughes, Jamie Lee…"

    private var settings = ContextImportSettings(
        contacts: ContextSourceSettings(
            isEnabled: true, lastImportedAtMs: MockAboutYouSource.nowMs - 4 * 60 * 1000,
            importedCount: 142
        ),
        calendar: ContextSourceSettings(
            isEnabled: true, pastDays: 30, futureDays: 21,
            lastImportedAtMs: MockAboutYouSource.nowMs - 4 * 60 * 1000, importedCount: 38
        )
    )
    private var refreshing: Set<ContextImportKind> = []

    private nonisolated static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func state(for kind: ContextImportKind) -> ImportSourceState {
        let source = settings[kind]
        return ImportSourceState(
            kind: kind,
            isEnabled: source.isEnabled,
            access: source.isEnabled ? .granted : .notDetermined,
            isRefreshing: refreshing.contains(kind),
            lastImportedAtMs: source.lastImportedAtMs,
            lastFailure: source.lastFailure,
            importedCount: source.importedCount,
            selection: source.selection,
            pastDays: source.pastDays,
            futureDays: source.futureDays
        )
    }

    func setEnabled(_ enabled: Bool, for kind: ContextImportKind) {
        settings[kind].isEnabled = enabled
        if enabled {
            refresh(kind)
        } else {
            removeImported(kind)
        }
    }

    func setSelection(_ selection: ContextImportSelection, for kind: ContextImportKind) {
        settings[kind].selection = selection
        refresh(kind)
    }

    func setCalendarWindow(pastDays: Int, futureDays: Int) {
        settings.calendar.pastDays = pastDays
        settings.calendar.futureDays = futureDays
        refresh(.calendar)
    }

    func refresh(_ kind: ContextImportKind) {
        guard !refreshing.contains(kind) else { return }
        refreshing.insert(kind)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self else { return }
            settings[kind].lastImportedAtMs = Self.nowMs
            settings[kind].lastFailure = nil
            settings[kind].importedCount =
                settings[kind].selection.selectsNothing ? 0 : (kind == .contacts ? 142 : 38)
            refreshing.remove(kind)
        }
    }

    /// Off means the data is gone, not parked — the same rule the live source keeps.
    private func removeImported(_ kind: ContextImportKind) {
        settings[kind].lastImportedAtMs = nil
        settings[kind].importedCount = 0
        settings[kind].contributedTerms = []
    }

    func clearImported() {
        for kind in ContextImportKind.allCases {
            settings[kind].isEnabled = false
            removeImported(kind)
        }
    }

    func choices(for kind: ContextImportKind) async -> [ImportChoice] {
        switch kind {
        case .contacts:
            return [
                ImportChoice(
                    id: "container:icloud", name: "iCloud", detail: nil, section: .account),
                ImportChoice(
                    id: "container:work", name: "Work", detail: nil, section: .account),
                ImportChoice(
                    id: "group:bookclub", name: "Riverside Hall", detail: "iCloud",
                    section: .group),
                ImportChoice(
                    id: "group:family", name: "Family", detail: "iCloud", section: .group),
            ]
        case .calendar:
            return [
                ImportChoice(
                    id: "cal:home", name: "Home", detail: "iCloud", section: .calendar),
                ImportChoice(
                    id: "cal:work", name: "Work", detail: "Exchange", section: .calendar),
                ImportChoice(
                    id: "cal:birthdays", name: "Birthdays", detail: "Subscribed",
                    section: .calendar),
            ]
        }
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

// MARK: - Processing modes (what the routers are actually doing)

/// Whether a "first" mode is currently being carried by its fallback, per axis.
///
/// Read on demand, never streamed: `lastFallback` changes at most once per transcribed segment
/// or AI job, and the only reader is a settings screen. See `Copy+ProcessingFallback.swift` for
/// what the app says about it and why that sentence lives on Storage & Privacy.
@MainActor
protocol ProcessingModeSource: AnyObject {
    /// `TranscriptionModeRouter.lastFallback` — nil when the configured path is working.
    var transcriptionFallback: ProcessingFallback? { get }
    /// `AiModeRouter.lastFallback` — nil when the configured path is working.
    var aiFallback: ProcessingFallback? { get }
}

/// The artboard case is the healthy one: both nil, so the stance card shows no live line. The
/// two overrides exist for previews and for the design gallery — a mock that could only ever
/// render "everything is fine" is how an unreachable state ships broken.
@MainActor
@Observable
final class MockProcessingModeSource: ProcessingModeSource {
    var transcriptionFallback: ProcessingFallback?
    var aiFallback: ProcessingFallback?

    init(
        transcriptionFallback: ProcessingFallback? = nil,
        aiFallback: ProcessingFallback? = nil
    ) {
        self.transcriptionFallback = transcriptionFallback
        self.aiFallback = aiFallback
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

/// The Storage card: what this app's files add up to, already worded, plus the two things
/// that can be wrong with storage — a write the store refused, and the pause floor being hit.
///
/// Worded here rather than in the screen so the live source, the mock and the support report
/// say exactly the same thing, and so the arithmetic (which buckets go in which row) has a test.
struct DiagnosticStorage: Equatable {
    /// "2.1 GB · 3,799 files".
    var recordings: String
    /// Transcripts, AI outputs, the database, sidecars, the flight recorder.
    var textAndIndex: String
    /// Downloaded weights plus the compiled cache.
    var model: String
    /// `tmp/`.
    var temporary: String
    /// "14.1 GB of 512 GB".
    var free: String
    /// "1.3 GB · 241 recordings" once anything is in iCloud; nil otherwise.
    var inCloud: String?
    /// Present while the pause floor is active (`RuntimeDiagnostics.pauseRequested`): the value
    /// of a "Recording paused" row.
    var pausedLine: String?
    /// Present while the low-storage flag is raised but capture is not yet paused.
    var lowLine: String?
    /// Present until a write succeeds after one failed.
    var writeFailure: Fault?

    struct Fault: Equatable {
        var title: String
        var detail: String
    }

    /// The rows, from the kit's measurement and the runtime's flags.
    static func describe(
        _ footprint: StorageFootprint,
        pauseRequested: Bool,
        lowStorage: Bool,
        pauseFloorBytes: Int64,
        writeFailure: StoreWriteFailure?,
        cold: ColdAudioTier.Summary? = nil
    ) -> DiagnosticStorage {
        let size = Formatting.storageSize
        let floor = size(pauseFloorBytes)
        let inCloud: String? = (cold?.inCloudCount ?? 0) > 0
            ? "\(size(cold!.inCloudBytes)) · \(cold!.inCloudCount.formatted()) recordings"
                + (cold!.uploadingCount > 0 ? " · \(cold!.uploadingCount) uploading" : "")
            : nil
        return DiagnosticStorage(
            recordings: Copy.Settings.Diagnostics.storageRecordingsValue(
                size: size(footprint.audioBytes), files: footprint.audioFiles),
            textAndIndex: size(
                footprint.transcriptBytes + footprint.databaseBytes + footprint.sidecarBytes
                    + footprint.diagnosticsBytes + footprint.otherBytes),
            model: size(footprint.modelBytes + footprint.cacheBytes),
            temporary: size(footprint.temporaryBytes),
            free: Copy.Settings.Diagnostics.storageFreeValue(
                free: size(footprint.freeBytes), capacity: StorageCapacity.label(footprint.capacityBytes)),
            inCloud: inCloud,
            pausedLine: pauseRequested
                ? Copy.Settings.Diagnostics.storagePausedValue(floor: floor) : nil,
            lowLine: lowStorage && !pauseRequested
                ? Copy.Settings.Diagnostics.storageLowValue(floor: floor) : nil,
            writeFailure: writeFailure.map { failure in
                let when = Date(timeIntervalSince1970: Double(failure.atMs) / 1000)
                return Fault(
                    title: Copy.Settings.Diagnostics.storageWriteFailed,
                    detail: Copy.Settings.Diagnostics.storageWriteFailedDetail(
                        when: "\(TimeFmt.dayLabel(for: when)) \(TimeFmt.time(when))",
                        phoneFull: failure.isStorageFull))
            }
        )
    }

    /// The support-report block, newline-terminated.
    var reportLines: String {
        var lines = [
            "Storage: recordings \(recordings) · transcripts & index \(textAndIndex) · "
                + "model & cache \(model) · temporary \(temporary) · free \(free)"
        ]
        if let inCloud { lines.append("In iCloud: \(inCloud)") }
        if let pausedLine { lines.append("Recording paused: \(pausedLine)") }
        if let lowLine { lines.append("Storage low: \(lowLine)") }
        if let writeFailure { lines.append("\(writeFailure.title): \(writeFailure.detail)") }
        return lines.joined(separator: "\n") + "\n"
    }
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

    /// The watch's send-refusal line, newline-terminated so it drops into the report as a block.
    /// Empty while no watch has been read — a report from a phone that never saw a watch should
    /// not carry a row about one.
    static func watchSend(_ health: WatchSendHealth) -> String {
        guard health != .unknown else { return "" }
        return Copy.Settings.Diagnostics.watchCouldNotSendReport(health.count) + "\n"
    }

    /// The failing steps of the processing pass, with the raw error each one threw.
    ///
    /// Unlike a transcription failure there is no classified vocabulary to fall back on, and
    /// this block only exists in the report and the Diagnostics screen — the two places whose
    /// entire purpose is to carry the technical answer to whoever can act on it. Empty while
    /// the pass is healthy.
    static func pipeline(_ pipeline: DiagnosticPipeline) -> String {
        guard !pipeline.failing.isEmpty else { return "" }
        let lines = pipeline.failing.map { stage in
            "  \(stage.title) — \(stage.detail)"
                + (stage.reason.map { ": \($0)" } ?? "")
        }
        return "Processing steps failing:\n" + lines.joined(separator: "\n") + "\n"
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

/// One step of the processing pass that is not working, in plain language.
///
/// Stages are only listed while they are FAILING. A healthy pipeline is a single summary row,
/// because thirteen rows saying "fine" is how a screen teaches people to stop reading it.
struct DiagnosticStage: Identifiable, Equatable {
    /// The stage's raw name — the row key, never printed.
    let id: String
    /// What this step of the pass does, said the way a person would say it.
    let title: String
    /// e.g. "failing · 4 tries · next in 40 s".
    let detail: String
    /// The classified-ish reason. Diagnostics only, like the detailed log: this is the thrown
    /// error described, and it may be developer prose.
    let reason: String?
}

/// Whether the processing half of the app is turning at all, and what is wrong if not.
struct DiagnosticPipeline: Equatable {
    /// The value beside the "Processing" row, e.g. "working · last pass 2 s ago".
    var summary: String
    /// Only the stages that are failing, worst first.
    var failing: [DiagnosticStage] = []
    /// Times the watchdog has had to restart a wedged loop this session. Almost always 0; when
    /// it is not, that is the single most important number on this screen.
    var loopRestarts: Int = 0
}

/// What the watch says about audio it could not hand to this phone.
///
/// The watch counts every notification its radio refused, and the count is the only thing that
/// separates two losses that look identical from here: audio missing while it CLIMBS is the link
/// failing to keep up; audio missing while it stays FLAT is this phone having stopped
/// acknowledging, so the watch's buffer never freed. Opposite fixes, so the app must not guess.
///
/// `notReported` is a third state on purpose. Firmware older than the counter leaves the field
/// zero, and showing that as "never" would be a confident wrong answer (spec Section 3, `flags`
/// bit3).
enum WatchSendHealth: Equatable {
    /// No Info snapshot yet — no watch has been read, so the row is absent entirely.
    case unknown
    /// This firmware predates the counter: it cannot say, and says so.
    case notReported
    /// Times the watch's transport refused a send since the watch started. 0 is a real zero.
    case refusals(UInt32)

    /// The count when there is one, nil when this watch does not report it. Feeds
    /// `Copy.Settings.Diagnostics.watchCouldNotSendValue`, which words both cases.
    var count: UInt32? {
        if case .refusals(let n) = self { return n }
        return nil
    }
}

/// The watch's own refusal, in the app's words — nil when the watch has not refused anything.
///
/// The wire protocol names its refusals precisely (`AuthStatus`, `RevokeReason`,
/// `ProtocolErrorCode`, the version range in the Info snapshot) and the phone used to decode all
/// of it and show none of it. `StatusUI.WatchLinkFault` classifies; these are the words.
/// A row whose value needs a sentence beneath it some of the time: the value on the right, and
/// the sentence (when there is one) under the whole row.
struct DiagnosticNotice: Equatable {
    var value: String
    var detail: String?
}

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

/// One recorded Ask recall experiment as the Diagnostics screen shows it: when, the question
/// in the user's own words (clipped), and what the two passes found.
struct AskRecallCheckRow: Identifiable, Equatable {
    let id: String
    /// "Sep 18 · 3:12 PM"
    let when: String
    let question: String
    /// `Copy.Settings.Diagnostics.AskRecall.recordDetail` — counts only.
    let detail: String
}

/// Where the DEBUG replay of recent questions has got to. `.done` carries one row per
/// question so the result stays on screen.
enum AskRecallReplayState: Equatable {
    case idle
    case running
    case done([AskRecallReplayRow])
    case failed
}

@MainActor
protocol DiagnosticsSource: AnyObject {
    var receiverStatus: String { get }
    var watchReports: String { get }
    /// Why the watch is turning this phone away, when it is. Nil is the calm case: the row
    /// simply is not there.
    var watchLink: DiagnosticLinkFault? { get }
    /// Audio the watch could not hand over, as the watch counts it. `.unknown` while no watch
    /// has been read — the row is absent rather than guessing on the watch's behalf.
    var watchSend: WatchSendHealth { get }
    /// Frames the watch sent while this app held no stream to put them in, since the app started.
    /// Zero is the only healthy value, but anything else is a link out of step rather than audio
    /// lost: the watch kept those frames and resent them, and whatever it could not keep is
    /// recorded as a gap in the recording.
    var orphanedFrames: Int { get }
    /// Rebuild-index progress, and a way to start one. The index is derived data, so this
    /// throws nothing away that cannot be written again from the database.
    var indexRebuild: IndexRebuildState { get }
    func rebuildSearchIndex() async
    var queueWaiting: Int { get }
    var queueFailed: Int { get }
    /// The queue is waiting because the app was not in the foreground, not because anything is
    /// wrong: local transcription and AI are deferred while backgrounded. The runtime has
    /// always computed this (`RuntimeDiagnostics.transcriptionDeferredInBackground`) and no
    /// screen ever read it, so a queue held for that reason showed a bare "N waiting".
    var transcriptionHeldInBackground: Bool { get }
    /// The failed tasks with their reasons — the answer to "6 failed, but why?", which until
    /// now was persisted in `transcription_tasks.lastError` and shown nowhere.
    var failedItems: [DiagnosticFailure] { get }
    /// Whether the processing pass is running, and which of its steps are failing. Before
    /// this, a stage that threw every pass was invisible everywhere but the detailed log — and
    /// since one failing stage used to abandon the whole pass, "invisible" meant the live
    /// preview and the conversation grouping stopped too, with the app still saying Recording.
    var pipeline: DiagnosticPipeline { get }
    /// Conversations transcribed but still owed an AI title/summary/tags, and whether a pass
    /// is running right now. The enrichment counterpart of the transcription queue.
    var enrichmentWaiting: Int { get }
    var enrichmentRunning: Bool { get }
    var recentSegments: [DiagnosticSegment] { get }
    /// What this app's files add up to, and whether storage is in trouble. Nil until measured:
    /// the measurement walks every file, so a live source does it only while the screen is up.
    var storage: DiagnosticStorage? { get }
    /// Raw technical lines — counters and gap metadata only, never audio or transcript text.
    var detailedLogLines: [String] { get }
    var supportReportText: String { get }
    /// When this binary was built, and from which revision: "Sep 9, 2026 at 3:24 PM · 84ca738 ·
    /// 12 min ago". The question it answers is "am I looking at the build I just installed, or
    /// the one from this morning?", which every other row on this screen is read in the light of
    /// — a stale build makes a healthy-looking report meaningless.
    var buildInfo: String { get }
    /// The app's own CPU watchdog: set when this process has been spending more than its budget
    /// while in the background. Nil is the calm case and the row is absent.
    var powerAlert: DiagnosticNotice? { get }
    /// Charging, battery, Low Power Mode and heat: the conditions that hold model work.
    var phone: DiagnosticNotice { get }
    /// Whether voice recognition is on, what it has left, and why it is not running if it is not.
    var voices: DiagnosticNotice { get }
    /// Recordings no transcription service could take right now. Zero is the calm case.
    var queueParked: Int { get }
    /// A refused cloud account, while it holds sending. Nil is the calm case.
    var cloudAccount: DiagnosticNotice? { get }
    /// iOS would not keep the app running, or took the audio session. Nil is the calm case.
    var residency: DiagnosticNotice? { get }
    /// The watch's last restart, once a watch has been read.
    var watchRestart: DiagnosticNotice? { get }
    /// The archive server's sync, when one is linked.
    var archive: DiagnosticNotice? { get }
    /// The Ask recall experiment's newest records, newest first. Empty until a question's
    /// range overflowed what one answer can read — the ordinary library is read whole and
    /// never gets there, and an empty card says so rather than showing zeros.
    var askRecallRecords: [AskRecallCheckRow] { get }
    /// Whether a semantic (meaning) pass is wired at all. False is reported as such, never as
    /// "meaning found nothing".
    var askRecallSemanticAvailable: Bool { get }
    /// The DEBUG replay of recent questions through both passes, and a way to start one.
    /// Retrieval only: no model call, nothing answered, nothing saved.
    var askRecallReplay: AskRecallReplayState { get }
    func replayAskRecall() async
    /// The screen says when it is on screen. A live source does nothing while it is not: the
    /// counters it keeps are re-read from every sidecar and the whole log file, and a source
    /// that refreshes for a screen nobody is looking at is how a feedback loop went unnoticed
    /// at a full CPU core.
    func setVisible(_ visible: Bool)
}

@MainActor
@Observable
final class MockDiagnosticsSource: DiagnosticsSource {
    var receiverStatus = Copy.Settings.Diagnostics.receiverRecording
    var watchReports = Copy.Status.recording
    var watchLink: DiagnosticLinkFault?
    /// The artboard case: a watch that reports the counter and has had a handful of refusals.
    var watchSend: WatchSendHealth = .refusals(3)
    var orphanedFrames = 0
    var indexRebuild: IndexRebuildState = .idle
    var queueWaiting = 0
    var queueFailed = 0
    var transcriptionHeldInBackground = false
    var enrichmentWaiting = 0
    var enrichmentRunning = false
    var failedItems: [DiagnosticFailure] = []
    var pipeline = DiagnosticPipeline(summary: Copy.Settings.Diagnostics.pipelineWorking("2 s"))
    var powerAlert: DiagnosticNotice?
    var phone = DiagnosticNotice(
        value: Copy.Settings.Diagnostics.phoneValue(
            pluggedIn: true, percent: 64, lowPower: false, hot: false))
    var voices = DiagnosticNotice(
        value: Copy.Settings.Diagnostics.voicesValue(
            waiting: 12, hold: nil, lastCheckAgo: "3 sec", checking: false))
    var queueParked = 0
    var cloudAccount: DiagnosticNotice?
    var residency: DiagnosticNotice?
    var watchRestart: DiagnosticNotice? = DiagnosticNotice(value: "software update")
    var archive: DiagnosticNotice?
    var buildInfo = "Sep 9, 2026 at 3:24 PM · 84ca738 · 12 min ago"
    /// The artboard case is the phone on 2026-10-12: audio a fifth of what iOS blamed on the
    /// app, and a `tmp/` folder bigger than the recordings.
    var storage: DiagnosticStorage? = DiagnosticStorage(
        recordings: Copy.Settings.Diagnostics.storageRecordingsValue(size: "2.1 GB", files: 3_799),
        textAndIndex: "331 MB",
        model: "2.4 GB",
        temporary: "6.2 GB",
        free: Copy.Settings.Diagnostics.storageFreeValue(free: "14.4 GB", capacity: "512 GB"),
        inCloud: "1.3 GB · 241 recordings",
        pausedLine: nil,
        lowLine: nil,
        writeFailure: nil)

    func setVisible(_ visible: Bool) {}

    func rebuildSearchIndex() async {
        indexRebuild = .running
        indexRebuild = .done(Copy.Settings.Diagnostics.rebuildIndexDone(recentSegments.count))
    }

    /// The artboard case: one question that overflowed the ceiling, with a rescue.
    var askRecallRecords: [AskRecallCheckRow] = [
        .init(
            id: "1", when: Copy.Settings.Diagnostics.AskRecall.when(day: "Sep 18", time: "3:12 PM"),
            question: "Did the plumber ever quote for the boiler?",
            detail: Copy.Settings.Diagnostics.AskRecall.recordDetail(
                keptBatches: 12, packedBatches: 31, keyword: 9, semantic: 7, both: 4,
                rescued: 2, lost: 1, semanticRan: true))
    ]
    var askRecallSemanticAvailable = true
    var askRecallReplay: AskRecallReplayState = .idle

    /// The replay over the mock world: each recent mock question against the mock library.
    /// The mock search is a whole-string match, so the keyword pass searches the question's
    /// content words; the meaning pass is the same list with the first hit swapped for one
    /// only it found, so the artboard shows an overlap and an exclusive find on each side.
    func replayAskRecall() async {
        askRecallReplay = .running
        let world = MockWorld.shared
        let questions = (try? await world.recentThreads())?.flatMap { $0.turns.map(\.question) }
            ?? []
        let rows = await AskRecallReplay.run(
            questions: questions, limit: 20,
            recall: { question, limit in
                var seen = Set<String>()
                var hits: [AskIndexHit] = []
                let words = question.lowercased()
                    .split { !$0.isLetter }
                    .map(String.init)
                    .filter { $0.count > 3 }
                for word in words {
                    let found = (try? await world.search(query: word, scope: .everything))?
                        .conversations ?? []
                    for hit in found where hits.count < limit && seen.insert(hit.id).inserted {
                        hits.append(AskIndexHit(id: hit.id, score: 1))
                    }
                }
                let meaning = Array(hits.dropFirst()) + hits.prefix(1).map {
                    AskIndexHit(id: "\($0.id)-meaning", score: 1)
                }
                return AskRetriever.RecallHits(keyword: hits, semantic: meaning, semanticRan: true)
            },
            title: { id in
                id.hasSuffix("-meaning")
                    ? "Coffee with Dana"
                    : world.conversations.first { $0.id == id }?.title
            })
        askRecallReplay = .done(rows)
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
        \(SupportReportText.watchSend(watchSend))Transcription queue: \(Copy.Settings.Diagnostics.queueValue(
            waiting: queueWaiting, failed: queueFailed,
            heldInBackground: transcriptionHeldInBackground))
        \(SupportReportText.failures(failedItems))Processing: \(pipeline.summary)
        \(SupportReportText.pipeline(pipeline))Recent segments:
        \(recentSegments.map { "  \($0.title) — \($0.detail)" }.joined(separator: "\n"))
        (Counters and gap metadata only — never audio or transcript text.)
        """
    }
}

// MARK: - AI Assistants (the archive sync)

/// Why a link attempt failed, as the Link step says it.
enum AssistantsLinkFailure: Equatable {
    /// A scanned or opened code the server refused: codes last ten minutes and work once.
    case expired(code: String)
    /// A typed code the server refused (it may be mistyped).
    case refused(code: String)
    case tooMany
    case unreachable(host: String)
    case badAddress
    case server(host: String)
    /// The Keychain would not keep the link.
    case keepFailed

    var code: String? {
        switch self {
        case .expired(let code), .refused(let code): return code
        default: return nil
        }
    }

    var heading: String {
        switch self {
        case .expired: return Copy.AssistantAccess.expiredHeading
        case .refused: return Copy.AssistantAccess.refusedHeading
        case .tooMany: return Copy.AssistantAccess.tooManyHeading
        case .unreachable(let host): return Copy.AssistantAccess.unreachableHeading(host)
        case .badAddress: return Copy.AssistantAccess.badAddressHeading
        case .server(let host): return Copy.AssistantAccess.serverErrorHeading(host)
        case .keepFailed: return Copy.AssistantAccess.keepFailedHeading
        }
    }

    var line: String {
        switch self {
        case .expired: return Copy.AssistantAccess.expiredLine
        case .refused: return Copy.AssistantAccess.refusedLine
        case .tooMany: return Copy.AssistantAccess.tooManyLine
        case .unreachable: return Copy.AssistantAccess.unreachableLine
        case .badAddress: return Copy.AssistantAccess.badAddressLine
        case .server: return Copy.AssistantAccess.serverErrorLine
        case .keepFailed: return Copy.AssistantAccess.keepFailedLine
        }
    }

    /// The server's refusal (`409`): a code that came from a scan or a link cannot be mistyped,
    /// so it has expired or been used; a typed one may just be wrong.
    static func from(_ error: ArchiveSyncService.LinkError?, code: String, host: String, fromScan: Bool) -> AssistantsLinkFailure {
        switch error {
        case .codeRefused?: return fromScan ? .expired(code: code) : .refused(code: code)
        case .server(429)?: return .tooMany
        case .network?: return .unreachable(host: host)
        case .badOrigin?: return .badAddress
        case .server?, .malformed?: return .server(host: host)
        case nil: return .keepFailed
        }
    }
}

/// Where the setup flow is: each flag pushes one screen, and clearing the first pops the whole
/// flow back to AI Assistants (Done on Connect). Held by the source, so a link opened from
/// outside the app can start it, and so it outlives the screens.
@MainActor
@Observable
final class AssistantsFlow {
    /// AI Assistants → Link.
    var showLink = false
    /// Link → Choose, once linked.
    var showChoose = false
    /// AI Assistants → Choose: linked earlier, not yet chosen.
    var showChooseDirect = false
    /// Choose → Connect, after Start Syncing.
    var showConnect = false
    /// AI Assistants → Connect (Connect Another Assistant).
    var showConnectOnly = false
    /// AI Assistants → Conversations (the scope).
    var showScope = false
    /// AI Assistants → one assistant.
    var detailAccessId: String?
    /// What the Link step's fields start with (a code from a link or a scan).
    var serverText = ""
    var codeText = ""

    // The review screenshots' starting points (`AssistantsDemo`): read once by the screen they
    // belong to, then cleared.
    var demoOpenCard: ConnectCard?
    var demoMacTool: MacTool?
    var demoScopeDraft: ArchiveSharingScope?
    var demoConfirmUnlink = false

    func finish() {
        showConnect = false
        showChoose = false
        showChooseDirect = false
        showConnectOnly = false
        showLink = false
    }

    func startLink(server: String = "", code: String = "") {
        serverText = server
        codeText = code
        showChooseDirect = false
        showConnectOnly = false
        showScope = false
        detailAccessId = nil
        showLink = true
    }
}

/// Settings › AI Assistants. What the screens show (the kit's published status, the link and
/// what the person allowed, and the phone's own counts) and what a person does there.
/// `startObserving`/`stopObserving` bracket the screens being on screen: the source does nothing
/// at all while they are not.
@MainActor
protocol AssistantsSource: AnyObject {
    var status: ArchiveSyncStatus { get }
    /// The link, the switch, what the person allowed, and whether setup finished.
    var sync: ArchiveSyncSettings { get }
    /// The phone's own conversation counts, for the scope choices; nil until loaded.
    var counts: ArchiveScopeCounts? { get }
    /// A link or an unlink in flight.
    var isWorking: Bool { get }
    var linkFailure: AssistantsLinkFailure? { get }
    /// What the last unlink left to say, when it did not simply delete.
    var unlinkNote: String? { get }
    var flow: AssistantsFlow { get }
    /// The time the screens count from.
    var nowMs: Int64 { get }
    func startObserving()
    func stopObserving()
    /// `GET /sync/status` once. Connect polls this while it is on screen.
    func refreshServerStatus() async
    func loadCounts() async
    /// A code the app was opened with (`pebbleaudio://link`, or `https://<server>/link`): it
    /// opens the Link step with the fields filled in. Nothing is sent until Link This Phone.
    func receive(_ invitation: ArchiveLinkInvitation)
    func clearLinkFailure()
    func link(code: String, server: String, fromScan: Bool)
    /// The Choose step's Start Syncing: what the person allowed, then the sync.
    func startSyncing(_ preferences: ArchivePreferences)
    func setEnabled(_ enabled: Bool)
    func setPreferences(_ preferences: ArchivePreferences)
    func revoke(_ access: ArchiveServerStatus.Access) async -> Bool
    func unlink() async -> ArchiveUnlinkOutcome
    /// Conversation titles for what an assistant read, by id; unknown ids are left out.
    func titles(conversationIds: [String]) async -> [String: String]
}

extension AssistantsSource {
    var host: String? { sync.origin.flatMap { URL(string: $0)?.host ?? $0 } }

    /// The address an assistant connects to.
    var connectorURL: String? { sync.origin.map { ArchiveEndpoint.url(URL(string: $0)!, "/mcp").absoluteString } }

    /// Everything that can read the server: the assistants and the Pebble plugin.
    var everyAccess: [ArchiveServerStatus.Access] { status.server?.access ?? [] }

    /// The assistants that can read the server. The Pebble plugin is not one; see `pebblePlugin`.
    var assistants: [ArchiveServerStatus.Access] { everyAccess.filter { !$0.isPebblePlugin } }

    /// The Pebble plugin's access, listed under the watch in Who can read: the most recently used.
    var pebblePlugin: ArchiveServerStatus.Access? {
        everyAccess.filter(\.isPebblePlugin).max { ($0.lastUsedAtMs ?? 0) < ($1.lastUsedAtMs ?? 0) }
    }

    /// The Settings root row's value.
    var rowValue: String {
        guard sync.isLinked else { return Copy.AssistantAccess.rowNotSetUp }
        if case .revoked = status.link { return Copy.AssistantAccess.rowUnlinked }
        guard sync.setupComplete else { return Copy.AssistantAccess.rowNotSetUp }
        guard sync.enabled else { return Copy.AssistantAccess.rowOff }
        let names = assistants.map(\.name)
        return names.isEmpty ? Copy.AssistantAccess.rowNoneConnected : Copy.list(names)
    }

    /// The server as the privacy model sees it: nil until something can have gone there.
    var privacyServer: PrivacyInputs.ServerState? {
        guard sync.isLinked, sync.setupComplete, let host else { return nil }
        return PrivacyInputs.ServerState(
            host: host, paused: !sync.enabled, scope: sync.preferences.scope,
            clipsAllowed: sync.preferences.clips, editsAllowed: sync.preferences.edits,
            assistants: everyAccess.map {
                .init(name: $0.name, canWrite: $0.canWrite, lastUsedAtMs: $0.lastUsedAtMs)
            },
            assistantsFetchedAtMs: status.serverStatusAtMs,
            assistantsStale: status.serverUnreachable)
    }

    /// Delete All names the server only when its wipe can reach it.
    var deleteAllHost: String? {
        guard sync.isLinked, let host else { return nil }
        if case .revoked = status.link { return nil }
        return host
    }
}

/// Previews, `-demo-data`, and the review screenshots (`-assistantsDemo <state>`): the round-3
/// states, with the mockups' synthetic people and counts.
@MainActor
@Observable
final class MockAssistantsSource: AssistantsSource {
    var status = ArchiveSyncStatus()
    var sync = ArchiveSyncSettings(enabled: false, setupComplete: false)
    var counts: ArchiveScopeCounts?
    var isWorking = false
    var linkFailure: AssistantsLinkFailure?
    var unlinkNote: String?
    let flow = AssistantsFlow()
    var nowMs: Int64
    /// Conversation titles the demo knows.
    var knownTitles: [String: String] = [:]

    init(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.nowMs = nowMs
        counts = AssistantsDemo.counts(nowMs: nowMs)
    }

    func startObserving() {}
    func stopObserving() {}
    func refreshServerStatus() async {}
    func loadCounts() async {
        if counts == nil { counts = AssistantsDemo.counts(nowMs: nowMs) }
    }

    func receive(_ invitation: ArchiveLinkInvitation) {
        linkFailure = nil
        flow.startLink(server: invitation.host, code: invitation.code)
    }

    func clearLinkFailure() { linkFailure = nil }

    func link(code: String, server: String, fromScan: Bool) {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let origin = ArchiveEndpoint.acceptableOrigin(trimmed.isEmpty ? ArchiveSyncProtocol.defaultOrigin : trimmed)
        else {
            linkFailure = .badAddress
            return
        }
        linkFailure = nil
        sync = ArchiveSyncSettings(
            origin: origin.absoluteString, deviceId: "demo-phone", enabled: false, setupComplete: false)
        status.link = .linked(host: origin.host ?? trimmed)
        flow.showChoose = true
    }

    func startSyncing(_ preferences: ArchivePreferences) {
        sync.preferences = preferences
        sync.setupComplete = true
        sync.enabled = true
        status.enabled = true
        status.lastBatchAtMs = nowMs
        flow.showConnect = true
    }

    func setEnabled(_ enabled: Bool) {
        sync.enabled = enabled
        status.enabled = enabled
    }

    func setPreferences(_ preferences: ArchivePreferences) { sync.preferences = preferences }

    func revoke(_ access: ArchiveServerStatus.Access) async -> Bool {
        status.server?.access.removeAll { $0.id == access.id && $0.kind == access.kind }
        return true
    }

    func unlink() async -> ArchiveUnlinkOutcome {
        status = ArchiveSyncStatus()
        sync = ArchiveSyncSettings(enabled: false, setupComplete: false)
        return .deleted
    }

    func titles(conversationIds: [String]) async -> [String: String] {
        knownTitles.filter { conversationIds.contains($0.key) }
    }
}

// MARK: - Pebble plugin

/// Settings › Watch › Pebble App Plugin: the server's half of putting the Pebble Audio plugin in
/// the Pebble app. Whether a server is linked, a one-time code for the plugin's settings page, and
/// whether the plugin has connected. `PluginInstallModel` holds what the section shows; this is
/// only what the server answers.
@MainActor
protocol PluginInstallSource: AnyObject {
    /// A Pebble Audio server is linked and has not stopped accepting this phone.
    var archiveLinked: Bool { get }
    /// A new code. It ends the one before it.
    func mintCode() async -> Result<ArchivePluginCode, ArchivePluginFailure>
    func connection() async -> Result<ArchivePluginConnection, ArchivePluginFailure>
}

/// Previews, `-demo-data`, the tests, and the review renders (`-pluginDemo <state>`): a server
/// that answers at once with synthetic codes.
@MainActor
final class MockPluginInstallSource: PluginInstallSource {
    var archiveLinked = true
    var connected = false
    var lastUsedAtMs: Int64?
    var reachable = true
    /// Handed out in turn; the last repeats.
    var codes = ["K7QM-3XWD", "R4TN-8WPX", "H2CV-6MJB"]
    var codeLifetimeMs: Int64 = 600_000
    var nowMs: () -> Int64
    private(set) var minted = 0
    private(set) var checks = 0

    init(
        state: PluginInstallDemo.State? = PluginInstallDemo.state,
        nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.nowMs = nowMs
        switch state {
        case .needsServer: archiveLinked = false
        case .unreachable: reachable = false
        case .connected:
            connected = true
            lastUsedAtMs = nowMs() - 2 * 60_000
        case .notConnected, .expired, .none: break
        }
        if state == .expired { codeLifetimeMs = 0 }
    }

    func mintCode() async -> Result<ArchivePluginCode, ArchivePluginFailure> {
        guard archiveLinked else { return .failure(.notLinked) }
        guard reachable else { return .failure(.unavailable) }
        let code = codes[min(minted, codes.count - 1)]
        minted += 1
        return .success(ArchivePluginCode(code: code, expiresAtMs: nowMs() + codeLifetimeMs))
    }

    func connection() async -> Result<ArchivePluginConnection, ArchivePluginFailure> {
        checks += 1
        guard archiveLinked else { return .failure(.notLinked) }
        guard reachable else { return .failure(.unavailable) }
        return .success(
            ArchivePluginConnection(connected: connected, lastUsedAtMs: connected ? lastUsedAtMs : nil))
    }
}

/// DEBUG builds read `-pluginDemo <state>` with `-demo-data`, so each state of the section can be
/// rendered without a server. (With no Pebble app on a simulator, Install shows its own state.)
enum PluginInstallDemo {
    enum State: String {
        case notConnected, connected, needsServer, unreachable, expired
    }

    static var state: State? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-pluginDemo"), index + 1 < args.count {
            return State(rawValue: args[index + 1])
        }
        #endif
        return nil
    }

    #if DEBUG
    /// Review renders through `ImageRenderer`, which draws the Open In menu's UIKit anchor as a
    /// placeholder over the install button, turn the anchor off. Never set in the app.
    @MainActor static var rendersWithoutMenuAnchor = false
    #endif
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
    let processing: ProcessingModeSource
    let apiKeys: ApiKeyChecking
    let aiModels: [AiModelOption]
    let assistants: AssistantsSource
    let plugin: PluginInstallSource

    init(
        capture: CaptureControlling? = nil,
        watch: WatchStatusSource? = nil,
        storage: StorageStatsSource? = nil,
        localModel: LocalModelManaging? = nil,
        aboutYou: AboutYouSource? = nil,
        diagnostics: DiagnosticsSource? = nil,
        cloudHealth: CloudHealthSource? = nil,
        processing: ProcessingModeSource? = nil,
        apiKeys: ApiKeyChecking? = nil,
        aiModels: [AiModelOption]? = nil,
        assistants: AssistantsSource? = nil,
        plugin: PluginInstallSource? = nil
    ) {
        self.capture = capture ?? MockCaptureControl()
        self.watch = watch ?? MockWatchStatusSource()
        self.storage = storage ?? MockStorageStatsSource()
        self.localModel = localModel ?? MockLocalModelManager()
        self.aboutYou = aboutYou ?? MockAboutYouSource()
        self.diagnostics = diagnostics ?? MockDiagnosticsSource()
        self.cloudHealth = cloudHealth ?? MockCloudHealthSource()
        self.processing = processing ?? MockProcessingModeSource()
        self.apiKeys = apiKeys ?? MockApiKeyChecker()
        self.assistants = assistants ?? AssistantsDemo.makeSource()
        self.plugin = plugin ?? MockPluginInstallSource()
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
