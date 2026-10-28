import Foundation
import Testing

@testable import Firmware

// The screen's behaviour, driven from fixtures. Everything here runs without a network, a
// simulator or a watch — which matters because none of the three are available to the sessions
// that will change this next.

private struct StubFetcher: FirmwareFeedFetching {
    let result: Result<FirmwareFeed, FirmwareFeedError>
    func fetch(from url: URL) async throws -> FirmwareFeed { try result.get() }
}

private struct StubDownloader: FirmwareAssetDownloading {
    /// Bytes to "download". Verification runs for real against them.
    let bytes: Data
    var failWith: FirmwareDownloadError?
    /// Long enough for a test to cancel mid-flight.
    var delay: Duration = .zero

    func download(
        _ release: FirmwareRelease,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failWith { throw failWith }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try bytes.write(to: destination)
        onProgress(Int64(bytes.count), Int64(bytes.count))
        try FirmwareChecksum.verify(fileAt: destination, matches: release)
        return destination
    }
}

@MainActor
@Suite("Firmware update model")
struct FirmwareUpdateModelTests {

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func feed() throws -> FirmwareFeed {
        try FirmwareFeed.decode(firmwareFixture("feed_valid.json"))
    }

    private func model(
        source: URL? = URL(string: "https://example.invalid/firmware.json"),
        fetcher: any FirmwareFeedFetching,
        downloader: any FirmwareAssetDownloading = StubDownloader(bytes: Data()),
        staging: FirmwareStagingArea,
        handoffLog: any FirmwareHandoffLogging = InMemoryFirmwareHandoffLog(),
        watchReported: String? = nil
    ) -> FirmwareUpdateModel {
        FirmwareUpdateModel(
            source: source,
            fetcher: fetcher,
            downloader: downloader,
            staging: staging,
            handoffLog: handoffLog,
            cache: nil,
            watchReportedVersion: { watchReported }
        )
    }

    @Test("With no feed configured the whole feature is inert — and never calls the network")
    func dormantWithoutASource() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        struct ExplodingFetcher: FirmwareFeedFetching {
            func fetch(from url: URL) async throws -> FirmwareFeed {
                Issue.record("the feed must not be fetched when no source is configured")
                return FirmwareFeed(releases: [])
            }
        }
        let subject = model(
            source: nil,
            fetcher: ExplodingFetcher(),
            staging: FirmwareStagingArea(directory: directory)
        )
        #expect(subject.isConfigured == false)
        #expect(subject.availability == .notConfigured)
        await subject.refresh()
        #expect(subject.availability == .notConfigured)
    }

    @Test("A fetched feed with nothing known offers the newest build")
    func offersNewest() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subject = model(
            fetcher: StubFetcher(result: .success(try feed())),
            staging: FirmwareStagingArea(directory: directory)
        )
        await subject.refresh()
        #expect(subject.availability?.release?.version.raw == "v4.36.1")
        #expect(subject.availability?.isUpdate == false)  // nothing known ⇒ offer, do not push
        #expect(subject.known == nil)
    }

    @Test("A watch-reported version wins over the hand-off memory")
    func watchReportedWins() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = InMemoryFirmwareHandoffLog(
            FirmwareHandoff(
                releaseId: "obelix/v4.10", version: "v4.10", board: "obelix",
                handedOffAt: Date(), destination: .openedInApp,
                openedIn: PebbleAppHandoff.bundleIdentifier
            )
        )
        let subject = model(
            fetcher: StubFetcher(result: .success(try feed())),
            staging: FirmwareStagingArea(directory: directory),
            handoffLog: log,
            watchReported: "v4.36.1"
        )
        #expect(subject.known?.source == .watchReported)
        await subject.refresh()
        // The watch says it already has the newest build, so nothing is offered as an update.
        #expect(subject.availability == .upToDate(
            try #require(subject.availability?.release),
            installed: try #require(FirmwareVersion("v4.36.1"))
        ))
    }

    @Test("Without a watch report, the hand-off memory is used and labelled as such")
    func handoffMemoryIsWeak() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let at = Date(timeIntervalSince1970: 1_780_000_000)
        let log = InMemoryFirmwareHandoffLog(
            FirmwareHandoff(
                releaseId: "obelix/v4.10", version: "v4.10", board: "obelix", handedOffAt: at
            )
        )
        let subject = model(
            fetcher: StubFetcher(result: .success(try feed())),
            staging: FirmwareStagingArea(directory: directory),
            handoffLog: log
        )
        #expect(subject.known?.source == .handedOff(at))
        #expect(subject.known?.isFromWatch == false)
        await subject.refresh()
        #expect(subject.availability?.isUpdate == true)
    }

    @Test("A file saved to Files is not treated as installed")
    func savingToFilesFormsNoBelief() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = InMemoryFirmwareHandoffLog(
            FirmwareHandoff(
                releaseId: "obelix/v4.36.1", version: "v4.36.1", board: "obelix",
                handedOffAt: Date(), destination: .savedToFiles
            )
        )
        let subject = model(
            fetcher: StubFetcher(result: .success(try feed())),
            staging: FirmwareStagingArea(directory: directory),
            handoffLog: log
        )
        // Exporting a file says nothing about the watch, so the offer must still stand.
        #expect(subject.known == nil)
        await subject.refresh()
        #expect(subject.availability?.release?.version.raw == "v4.36.1")
    }

    @Test("Dropped feed entries are counted, so the screen can say the list was partly unread")
    func reportsDroppedEntries() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostile = try FirmwareFeed.decode(firmwareFixture("feed_hostile.json"))
        let subject = model(
            fetcher: StubFetcher(result: .success(hostile)),
            staging: FirmwareStagingArea(directory: directory)
        )
        await subject.refresh()
        #expect(subject.feedRejectedCount == 5)
        // And the one sound entry is still offered — a partly-unreadable feed is not a dead one.
        #expect(subject.availability?.release?.version.raw == "v4.35.0")
    }

    @Test("A failed fetch with no cache is a failure, not an empty screen")
    func failedFetch() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subject = model(
            fetcher: StubFetcher(result: .failure(.network("offline"))),
            staging: FirmwareStagingArea(directory: directory)
        )
        await subject.refresh()
        #expect(subject.check == .failed(.offline))
        #expect(subject.availability == nil)

        let server = model(
            fetcher: StubFetcher(result: .failure(.http(status: 404))),
            staging: FirmwareStagingArea(directory: directory)
        )
        await server.refresh()
        #expect(server.check == .failed(.server(status: 404)))
    }

    @Test("Download verifies, and a mismatch leaves nothing behind")
    func downloadAndVerify() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = FirmwareStagingArea(directory: directory)

        // The fixture's digests are placeholders, so build a release around real bytes.
        let bytes = Data("PK\u{03}\u{04} pretend pbz".utf8)
        let good = FirmwareRelease(
            version: try #require(FirmwareVersion("4.36.1")),
            board: .pebbleTime2,
            assetURL: URL(string: "https://example.invalid/fw.pbz")!,
            sizeBytes: Int64(bytes.count),
            sha256: try FirmwareChecksum.sha256Hex(
                ofFileAt: try writeTemp(bytes, in: directory)
            )
        )
        let subject = model(
            fetcher: StubFetcher(result: .success(FirmwareFeed(releases: [good]))),
            downloader: StubDownloader(bytes: bytes),
            staging: staging
        )
        await subject.refresh()
        subject.startDownload()
        try await settle { subject.download.verifiedFile != nil }
        let file = try #require(subject.download.verifiedFile)
        #expect(file.lastPathComponent.hasSuffix(".pbz"))
        #expect(FileManager.default.fileExists(atPath: file.path))

        // Same release, wrong bytes: the staged file must not survive.
        let tampered = model(
            fetcher: StubFetcher(result: .success(FirmwareFeed(releases: [good]))),
            downloader: StubDownloader(bytes: Data("not the published build".utf8)),
            staging: staging
        )
        await tampered.refresh()
        tampered.discardDownload()
        tampered.startDownload()
        try await settle { if case .failed = tampered.download { return true } else { return false } }
        #expect(tampered.download == .failed(.checksum))
        #expect(staging.existingDownload(for: good) == nil)
    }

    @Test("Cancelling then retrying ends in a verified download, not a clobbered state")
    func cancelThenRetry() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = FirmwareStagingArea(directory: directory)

        let bytes = Data("PK\u{03}\u{04} pretend pbz".utf8)
        let source = directory.appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let release = FirmwareRelease(
            version: try #require(FirmwareVersion("4.36.1")),
            board: .pebbleTime2,
            assetURL: URL(string: "https://example.invalid/fw.pbz")!,
            sizeBytes: Int64(bytes.count),
            sha256: try FirmwareChecksum.sha256Hex(ofFileAt: source)
        )
        let subject = model(
            fetcher: StubFetcher(result: .success(FirmwareFeed(releases: [release]))),
            downloader: StubDownloader(bytes: bytes, delay: .milliseconds(120)),
            staging: staging
        )
        await subject.refresh()

        subject.startDownload()
        #expect(subject.download.isBusy)
        subject.cancelDownload()
        #expect(subject.download == .idle)

        // The retry must own the state from here on: the cancelled task's teardown is still to
        // come, and before the generation guard it would have cleared this one's handle.
        subject.startDownload()
        try await settle { subject.download.verifiedFile != nil }
        #expect(subject.download.verifiedFile != nil)
        // Give the retired task's teardown a chance to misbehave, then re-check.
        try await Task.sleep(for: .milliseconds(200))
        #expect(subject.download.verifiedFile != nil)
    }

    @Test("Recording a hand-off stops the screen offering what was just sent")
    func handoffUpdatesTheOffer() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = InMemoryFirmwareHandoffLog()
        let subject = model(
            fetcher: StubFetcher(result: .success(try feed())),
            staging: FirmwareStagingArea(directory: directory),
            handoffLog: log
        )
        await subject.refresh()
        let offered = try #require(subject.availability?.release)

        subject.recordHandoff(
            of: offered, destination: .openedInApp, openedIn: PebbleAppHandoff.bundleIdentifier
        )
        #expect(log.last?.version == offered.version.raw)
        #expect(PebbleAppHandoff.isPebbleApp(log.last?.openedIn))
        #expect(subject.availability?.isUpdate == false)
        if case .upToDate = try #require(subject.availability) {} else {
            Issue.record("expected up-to-date after handing over the offered build")
        }

        // And it can be taken back when it was wrong.
        subject.forgetHandoff()
        #expect(subject.lastHandoff == nil)
    }

    @Test("A build the watch reports after the feed arrived re-decides the offer")
    func reevaluatesWhenTheWatchReports() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = ReportedBox()
        let subject = FirmwareUpdateModel(
            source: URL(string: "https://example.invalid/firmware.json"),
            fetcher: StubFetcher(result: .success(try feed())),
            downloader: StubDownloader(bytes: Data()),
            staging: FirmwareStagingArea(directory: directory),
            handoffLog: InMemoryFirmwareHandoffLog(),
            cache: nil,
            watchReportedVersion: { box.value }
        )
        await subject.refresh()
        #expect(subject.availability?.isUpdate == false)  // nothing known yet

        box.value = "v4.10.0-12-gabcdef12"
        subject.reevaluate()
        #expect(subject.availability?.isUpdate == true)

        // A hand-off does not outrank the watch: until it reports the new build, the offer stands.
        let offered = try #require(subject.availability?.release)
        subject.recordHandoff(
            of: offered, destination: .openedInApp, openedIn: PebbleAppHandoff.bundleIdentifier
        )
        #expect(subject.availability?.isUpdate == true)

        box.value = offered.version.raw
        subject.reevaluate()
        #expect(subject.availability?.isUpdate == false)
    }

    @Test("The Pebble app is recognised by bundle id, and nothing else is")
    func recognisesPebble() {
        #expect(PebbleAppHandoff.isPebbleApp("coredevices.coreapp"))
        #expect(PebbleAppHandoff.isPebbleApp("coredevices.coreapp.dev"))
        #expect(!PebbleAppHandoff.isPebbleApp("com.apple.DocumentsApp"))
        #expect(!PebbleAppHandoff.isPebbleApp(nil))
        #expect(!PebbleAppHandoff.isPebbleApp("dev.audiocompanion.app"))
    }

    // MARK: Helpers

    @MainActor
    private final class ReportedBox {
        var value: String?
    }

    private func writeTemp(_ bytes: Data, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        return url
    }

    /// `startDownload` is fire-and-forget by design (the UI observes the state), so tests wait
    /// for the state to arrive rather than for a task handle the model does not expose.
    private func settle(
        timeout: Duration = .seconds(5),
        until condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for the model to settle")
    }
}
