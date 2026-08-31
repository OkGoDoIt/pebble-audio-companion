import Foundation
import Testing

@testable import Transcription

// Hermetic install-contract tests: no network, no 700 MB archive. The downloader and the
// extractor are seams, so what is exercised here is the state machine and the on-disk
// "installed" rule (config.txt + a .cactus_version that matches THIS spec's revision).

// MARK: - Fakes

private actor Gate {
    private var opened = false
    var isOpen: Bool { opened }
    func open() { opened = true }
}

private final class FakeDownloader: ParakeetArchiveDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    let progress: [(Int64, Int64)]
    let failure: Error?
    let gate: Gate?

    init(progress: [(Int64, Int64)] = [], failure: Error? = nil, gate: Gate? = nil) {
        self.progress = progress
        self.failure = failure
        self.gate = gate
    }

    var requestedURLs: [URL] { lock.withLock { urls } }

    func download(
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { urls.append(url) }
        for (received, total) in progress { onProgress(received, total) }
        if let gate {
            // Sleeping throws CancellationError, which is how a cancelled install unwinds.
            while await gate.isOpen == false { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        FileManager.default.createFile(
            atPath: destination.path, contents: Data("archive".utf8)
        )
    }
}

/// "Extracts" by writing the one file that makes an install count as complete.
private struct FakeExtractor: ParakeetArchiveExtracting {
    let failure: Error?

    init(failure: Error? = nil) { self.failure = failure }

    func extract(archiveAt archive: URL, into directory: URL) throws {
        if let failure { throw failure }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("weights".utf8).write(
            to: directory.appendingPathComponent(ParakeetModelLocation.configFileName)
        )
    }
}

// MARK: - Support

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("parakeet-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Polls until `predicate` holds (progress reaches the actor through a Task hop).
private func waitUntil(
    _ description: String, timeoutMs: Int = 3_000, _ predicate: @Sendable () async -> Bool
) async throws {
    var waited = 0
    while waited < timeoutMs {
        if await predicate() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
        waited += 5
    }
    Issue.record("timed out waiting for \(description)")
}

private let spec = ParakeetModelCatalog.byId(ParakeetModelCatalog.defaultModelId)

// MARK: - Tests

@Suite struct ParakeetModelLocationTests {
    private func install(
        into root: URL, spec: ParakeetModelSpec, config: Bool, version: String?
    ) throws {
        let directory = root.appendingPathComponent(spec.installDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if config {
            try Data("weights".utf8).write(
                to: directory.appendingPathComponent(ParakeetModelLocation.configFileName)
            )
        }
        if let version {
            try Data(version.utf8).write(
                to: directory.appendingPathComponent(ParakeetModelLocation.versionFileName)
            )
        }
    }

    @Test func installedNeedsBothConfigAndAMatchingVersion() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = ParakeetModelLocation(modelsDirectory: root)

        #expect(location.isInstalled(spec) == false)  // nothing on disk

        try install(into: root, spec: spec, config: true, version: nil)
        #expect(location.isInstalled(spec) == false)  // extracted, revision unrecorded

        try install(into: root, spec: spec, config: true, version: "v1.09")
        #expect(location.isInstalled(spec) == false)  // stale revision ⇒ re-download
        #expect(location.recordedVersion(for: spec) == "v1.09")

        try install(into: root, spec: spec, config: true, version: spec.revision)
        #expect(location.isInstalled(spec))
        #expect(location.installedModelPath(for: spec)?.lastPathComponent == "parakeet-tdt-0.6b-v3")
    }

    @Test func aRecordedVersionWithoutConfigIsNotInstalled() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try install(into: root, spec: spec, config: false, version: spec.revision)
        let location = ParakeetModelLocation(modelsDirectory: root)
        #expect(location.isInstalled(spec) == false)
        #expect(location.installedModelPath(for: spec) == nil)
    }

    @Test func trailingWhitespaceInTheVersionFileIsTolerated() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try install(into: root, spec: spec, config: true, version: "\(spec.revision)\n")
        #expect(ParakeetModelLocation(modelsDirectory: root).isInstalled(spec))
    }

    @Test func modelsLiveUnderCachesModels() {
        #expect(ParakeetModelLocation.defaultModelsDirectory.lastPathComponent == "models")
        #expect(
            ParakeetModelLocation.defaultModelsDirectory.deletingLastPathComponent().path
                .contains("Caches")
        )
    }
}

@Suite struct ParakeetModelStoreTests {
    private func makeStore(
        root: URL, downloader: any ParakeetArchiveDownloading,
        extractor: any ParakeetArchiveExtracting = FakeExtractor()
    ) -> ParakeetModelStore {
        ParakeetModelStore(
            location: ParakeetModelLocation(modelsDirectory: root),
            downloader: downloader,
            extractor: extractor,
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true)
        )
    }

    @Test func entriesCarryTheCatalogAndStartNotInstalled() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = await makeStore(root: root, downloader: FakeDownloader()).entries()
        #expect(entries.map(\.id) == ParakeetModelCatalog.all.map(\.id))
        #expect(entries.allSatisfy { $0.state == .notInstalled })
        #expect(entries.filter(\.recommended).count == 1)
        #expect(entries.first?.downloadBytes == 430_744_371)
    }

    @Test func installDownloadsExtractsAndRecordsTheRevision() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader(progress: [(1_000, 706_097_687)])
        let store = makeStore(root: root, downloader: downloader)

        let state = await store.install(spec.id)

        #expect(state == .installed)
        #expect(downloader.requestedURLs == [spec.downloadURL])
        let location = ParakeetModelLocation(modelsDirectory: root)
        #expect(location.isInstalled(spec))
        #expect(location.recordedVersion(for: spec) == spec.revision)
        // The staged archive is cleaned up either way.
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("tmp/cactus_download_\(spec.id).zip").path
            ) == false
        )
    }

    @Test func installOnAnAlreadyInstalledModelDoesNotDownload() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader()
        let store = makeStore(root: root, downloader: downloader)
        _ = await store.install(spec.id)
        #expect(downloader.requestedURLs.count == 1)

        #expect(await store.install(spec.id) == .installed)
        #expect(downloader.requestedURLs.count == 1)
    }

    @Test func progressIsReportedAgainstTheArchiveSize() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        let store = makeStore(
            root: root,
            downloader: FakeDownloader(progress: [(353_048_843, 706_097_687)], gate: gate)
        )

        let install = Task { await store.install(spec.id) }
        try await waitUntil("progress to reach the store") {
            await store.state(of: spec.id) == .downloading(
                receivedBytes: 353_048_843, totalBytes: 706_097_687
            )
        }
        let state = await store.state(of: spec.id)
        #expect(state.isBusy)
        #expect(state.fractionCompleted.map { abs($0 - 0.5) < 0.001 } == true)

        await gate.open()
        let final = await install.value
        #expect(final == .installed)
        let settled = await store.state(of: spec.id)
        #expect(settled.fractionCompleted == nil)
    }

    @Test func aServerWithoutContentLengthFallsBackToTheCatalogSize() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        let store = makeStore(
            root: root, downloader: FakeDownloader(progress: [(4_096, 0)], gate: gate)
        )
        let install = Task { await store.install(spec.id) }
        try await waitUntil("progress to reach the store") {
            await store.state(of: spec.id) == .downloading(
                receivedBytes: 4_096, totalBytes: spec.downloadBytes
            )
        }
        await gate.open()
        _ = await install.value
    }

    @Test func cancelLeavesNoPartialInstall() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(
            root: root, downloader: FakeDownloader(progress: [(10, 706_097_687)], gate: Gate())
        )

        let install = Task { await store.install(spec.id) }
        try await waitUntil("the download to start") { await store.state(of: spec.id).isBusy }
        await store.cancel(spec.id)

        #expect(await install.value == .notInstalled)
        #expect(await store.state(of: spec.id) == .notInstalled)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(spec.installDirectoryName).path
            ) == false
        )
    }

    @Test func aFailedDownloadReportsAMessageAndKeepsIt() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(
            root: root,
            downloader: FakeDownloader(failure: URLError(.notConnectedToInternet))
        )

        let state = await store.install(spec.id)
        #expect(state == .failed(message: "The download didn't finish. Check your connection and try again."))
        // A refresh must not quietly erase the failure the user needs to see.
        let refreshed = await store.refresh().first { $0.id == spec.id }
        #expect(refreshed?.state == state)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(spec.installDirectoryName).path
            ) == false
        )
    }

    @Test func aCorruptArchiveIsReportedAsAnUnpackFailure() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(
            root: root,
            downloader: FakeDownloader(),
            extractor: FakeExtractor(failure: ZipExtractionError.notAZipArchive)
        )
        #expect(
            await store.install(spec.id)
                == .failed(message: "The download finished but the model couldn't be unpacked. Try again.")
        )
    }

    @Test func uninstallRemovesTheModelDirectory() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root, downloader: FakeDownloader())
        _ = await store.install(spec.id)

        #expect(await store.uninstall(spec.id) == .notInstalled)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(spec.installDirectoryName).path
            ) == false
        )
        #expect(await store.state(of: spec.id) == .notInstalled)
    }

    @Test func stateStreamPublishesRowUpdates() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root, downloader: FakeDownloader())
        let stream = await store.states()

        let observed = Task {
            var seen: [ParakeetInstallState] = []
            for await entries in stream {
                if let row = entries.first(where: { $0.id == spec.id }) { seen.append(row.state) }
                if seen.last == .installed { break }
            }
            return seen
        }
        _ = await store.install(spec.id)
        let seen = await observed.value
        #expect(seen.first == .notInstalled)
        #expect(seen.last == .installed)
        #expect(seen.contains(.installing))
    }

    @Test func unknownIdsAreInert() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader()
        let store = makeStore(root: root, downloader: downloader)
        #expect(await store.install("whisper-tiny") == .notInstalled)
        #expect(await store.state(of: "whisper-tiny") == .notInstalled)
        #expect(downloader.requestedURLs.isEmpty)
    }
}
