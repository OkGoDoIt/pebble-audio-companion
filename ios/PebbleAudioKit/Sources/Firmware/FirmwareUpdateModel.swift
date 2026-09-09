import Foundation
import Observation

/// Why a check or a download did not work, in the small number of kinds the screen has distinct
/// sentences for. The wording lives in the app (`Copy+Firmware.swift`), the way
/// `WatchLinkFault` and `TranscriptionFailureKind` already split fact from phrasing.
public enum FirmwareFailure: Sendable, Equatable {
    case offline
    case server(status: Int)
    /// The document downloaded but this app cannot read it. Points at the publisher, not the
    /// person, and the screen says so.
    case badFeed
    /// The bytes did not match the published digest. The file has already been deleted.
    case checksum
    case storage
    case cancelled

    init(_ error: any Error) {
        switch error {
        case let error as FirmwareFeedError:
            switch error {
            case .notConfigured: self = .badFeed
            case .insecureURL, .malformed: self = .badFeed
            case .http(let status): self = .server(status: status)
            case .network: self = .offline
            }
        case let error as FirmwareDownloadError:
            switch error {
            case .http(let status): self = .server(status: status)
            case .network: self = .offline
            case .checksumMismatch, .sizeMismatch: self = .checksum
            case .storage: self = .storage
            }
        case is CancellationError:
            self = .cancelled
        default:
            self = .offline
        }
    }
}

/// What the screen is doing about the feed.
public enum FirmwareCheckState: Sendable, Equatable {
    case idle
    case checking
    case loaded(FirmwareAvailability, checkedAt: Date, fromCache: Bool)
    case failed(FirmwareFailure)
}

/// What the screen is doing about the `.pbz`.
public enum FirmwareDownloadState: Sendable, Equatable {
    /// Named `idle` rather than `none` so a `switch` over it can never be read — by a person or
    /// by type inference at a call site that made it optional — as `Optional.none`.
    case idle
    case downloading(received: Int64, total: Int64)
    /// Downloaded **and verified**. Nothing reaches this state without matching its digest.
    case ready(URL)
    case failed(FirmwareFailure)

    public var isBusy: Bool {
        if case .downloading = self { return true }
        return false
    }

    public var verifiedFile: URL? {
        if case .ready(let url) = self { return url }
        return nil
    }
}

/// The firmware screen's whole behaviour, in the kit so it can be tested with `swift test`
/// rather than only in a simulator.
///
/// It coordinates four things and owns no UI: read the configured feed, decide what (if
/// anything) is on offer, fetch and verify the image, and remember what was handed over. The
/// hand-off itself is the one step it cannot do — see `SettingsFirmwareScreen`, which owns the
/// share sheet, because iOS has no way for one app to push a document into another without the
/// person choosing the destination.
@MainActor
@Observable
public final class FirmwareUpdateModel {
    public private(set) var check: FirmwareCheckState = .idle
    public private(set) var download: FirmwareDownloadState = .idle
    /// What this app last handed to the Pebble app, if anything.
    public private(set) var lastHandoff: FirmwareHandoff?
    /// Entries in the last feed this app could not read and dropped.
    ///
    /// Surfaced rather than swallowed: dropping a release with a bad digest is the right call,
    /// but doing it silently would show someone a short list of builds and let them conclude
    /// nothing newer had been published.
    public private(set) var feedRejectedCount = 0

    /// Nil when no feed is configured. Everything else on this type is inert in that case, and
    /// Settings does not draw the row at all — see `FirmwareFeedSource`.
    public let source: URL?

    @ObservationIgnored private let fetcher: any FirmwareFeedFetching
    @ObservationIgnored private let downloader: any FirmwareAssetDownloading
    @ObservationIgnored private let staging: FirmwareStagingArea
    @ObservationIgnored private let handoffLog: any FirmwareHandoffLogging
    @ObservationIgnored private let cache: FirmwareFeedCache?
    /// The watch's own reported version, when it ever reports one. Supplied by the app layer
    /// (`SettingsDataSources.current.watch.firmwareVersion`), which reads it off the Info
    /// characteristic. Today it is always nil; the design does not depend on it.
    @ObservationIgnored private let watchReportedVersion: @MainActor () -> String?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// Retires a superseded download; see `startDownload`.
    @ObservationIgnored private var downloadGeneration = 0

    public init(
        source: URL? = FirmwareFeedSource.resolved(),
        fetcher: (any FirmwareFeedFetching)? = nil,
        downloader: any FirmwareAssetDownloading = URLSessionFirmwareDownloader(),
        staging: FirmwareStagingArea = FirmwareStagingArea(),
        handoffLog: any FirmwareHandoffLogging = UserDefaultsFirmwareHandoffLog(),
        cache: FirmwareFeedCache? = FirmwareFeedCache(),
        watchReportedVersion: @escaping @MainActor () -> String? = { nil }
    ) {
        self.source = source
        let cachingClient = cache.map { CachingFirmwareFeedClient(cache: $0) }
        self.fetcher = fetcher ?? cachingClient ?? URLSessionFirmwareFeedClient()
        self.downloader = downloader
        self.staging = staging
        self.handoffLog = handoffLog
        self.cache = cache
        self.watchReportedVersion = watchReportedVersion
        self.lastHandoff = handoffLog.last
        if source == nil { check = .loaded(.notConfigured, checkedAt: Date(), fromCache: false) }
    }

    public var isConfigured: Bool { source != nil }

    /// What this app believes is on the watch, and why.
    ///
    /// The watch's own word wins when it exists. It does not today: the audio-companion Info
    /// characteristic's `fw_version_packed` is never assigned by the firmware, so the app reads
    /// zero and `firmwareVersion` comes back nil. The fallback is this app's memory of what it
    /// handed over, which is a much weaker claim and is labelled as one everywhere.
    public var known: KnownFirmware? {
        if let reported = watchReportedVersion(), let version = FirmwareVersion(reported) {
            return KnownFirmware(version: version, source: .watchReported)
        }
        return lastHandoff?.known
    }

    /// The current answer, or nil while nothing has been checked yet.
    public var availability: FirmwareAvailability? {
        if case .loaded(let availability, _, _) = check { return availability }
        return nil
    }

    // MARK: Checking

    /// Fetches the feed and re-decides. Safe to call on every appearance: it is a few kilobytes,
    /// and a screen that can be stale is a screen that tells people to install what they already
    /// have.
    public func refresh() async {
        guard let source else {
            check = .loaded(.notConfigured, checkedAt: Date(), fromCache: false)
            return
        }
        check = .checking
        do {
            let feed = try await fetcher.fetch(from: source)
            feedRejectedCount = feed.rejectedCount
            check = .loaded(evaluate(feed), checkedAt: Date(), fromCache: false)
        } catch {
            // Offline is not the same as "there is no firmware". If a feed was read before, show
            // that one, stamped with when it was read, rather than an error the person cannot
            // act on.
            if let entry = cache?.load(sourceURL: source) {
                feedRejectedCount = entry.feed.rejectedCount
                check = .loaded(evaluate(entry.feed), checkedAt: entry.fetchedAt, fromCache: true)
            } else {
                feedRejectedCount = 0
                check = .failed(FirmwareFailure(error))
            }
        }
    }

    private func evaluate(_ feed: FirmwareFeed) -> FirmwareAvailability {
        FirmwareUpdateCheck.evaluate(feed: feed, board: nil, installed: known?.version)
    }

    // MARK: Downloading

    /// Fetches and verifies the offered release. Does not hand anything over — that needs a
    /// second, explicit action.
    public func startDownload() {
        guard let release = availability?.release, downloadTask == nil else { return }
        // A verified copy from an earlier visit is still verified: `FirmwareStagingArea`'s
        // invariant is that nothing unverified is ever left there.
        if let existing = staging.existingDownload(for: release) {
            download = .ready(existing)
            return
        }
        download = .downloading(received: 0, total: release.sizeBytes ?? 0)
        // Every download carries a generation, and a late finisher only writes state if its
        // generation is still the current one. Without it, a cancel-then-retry lets the first
        // task's teardown clear the SECOND task's handle, after which Cancel silently does
        // nothing and two downloads can be in flight at once.
        downloadGeneration &+= 1
        let generation = downloadGeneration
        downloadTask = Task { [weak self, downloader, staging] in
            do {
                try staging.prepare()
                staging.removeAll(except: release)
                let destination = staging.location(for: release)
                let file = try await downloader.download(release, to: destination) { received, total in
                    Task { @MainActor in
                        guard let self, self.downloadGeneration == generation,
                            self.download.isBusy
                        else { return }
                        self.download = .downloading(
                            received: received, total: total > 0 ? total : (release.sizeBytes ?? 0)
                        )
                    }
                }
                await MainActor.run { self?.finish(generation, with: .ready(file)) }
            } catch is CancellationError {
                await MainActor.run { self?.finish(generation, with: .idle) }
            } catch {
                await MainActor.run {
                    self?.finish(generation, with: .failed(FirmwareFailure(error)))
                }
            }
        }
    }

    private func finish(_ generation: Int, with state: FirmwareDownloadState) {
        guard generation == downloadGeneration else { return }
        downloadTask = nil
        download = state
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        // Bumping the generation retires the cancelled task, so nothing it does on its way out
        // can write over the state a retry has already set.
        downloadGeneration &+= 1
        download = .idle
    }

    /// Throws the staged file away — the "never mind" that leaves nothing behind for a stray tap
    /// to install later.
    public func discardDownload() {
        cancelDownload()
        staging.removeAll(except: nil)
        download = .idle
    }

    // MARK: Hand-off

    /// Called once the Open In menu (or the Files export) has finished with the person having
    /// chosen a destination.
    ///
    /// `openedIn` is the bundle id iOS reports through
    /// `documentInteractionController(_:willBeginSendingToApplication:)`. Everything after that
    /// is invisible to us — whether the Pebble app accepted the board, whether the watch was in
    /// range, whether the flash finished — so this records only what was observed. The staged
    /// file is kept: iOS copies it into the receiving app, and deleting it here would break a
    /// retry when the watch was out of range.
    public func recordHandoff(
        of release: FirmwareRelease,
        at date: Date = Date(),
        destination: FirmwareHandoffDestination = .openedInApp,
        openedIn: String? = nil
    ) {
        let handoff = FirmwareHandoff(
            release: release, at: date, destination: destination, openedIn: openedIn
        )
        handoffLog.record(handoff)
        lastHandoff = handoff
        // Re-decide against the new belief, so the screen stops offering what was just sent.
        // A Files export forms no belief (`FirmwareHandoff.known`), so it correctly leaves the
        // offer standing.
        if case .loaded(let availability, let checkedAt, let fromCache) = check,
           let offered = availability.release,
           let version = handoff.known?.version {
            check = .loaded(
                FirmwareUpdateCheck.evaluate(
                    feed: FirmwareFeed(releases: [offered]), board: nil, installed: version
                ),
                checkedAt: checkedAt,
                fromCache: fromCache
            )
        }
    }

    /// Drops the memory of the last hand-off — for when it is wrong (the install was cancelled,
    /// or the watch was flashed from a Mac instead).
    public func forgetHandoff() {
        handoffLog.forget()
        lastHandoff = nil
    }
}
