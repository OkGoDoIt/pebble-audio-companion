import Foundation
import Testing

@testable import Transcription

// The store's additions for the Core AI runtime, hermetically: the inbox install path, the
// wrapper-folder hoist, the prepare pass and its foreground rule, the `.preparing` state, and
// the refusal to touch a runtime this build cannot run. The preparer and the extractor are
// fakes; nothing here needs Core AI or a bundle.

// MARK: - Fakes

private actor Gate {
    private var opened = false
    var isOpen: Bool { opened }
    func open() { opened = true }
}

private final class FakeDownloader: ParakeetArchiveDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var requestedURLs: [URL] { lock.withLock { urls } }

    func download(
        from url: URL, to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { urls.append(url) }
        try Task.checkCancellation()
        FileManager.default.createFile(atPath: destination.path, contents: Data("archive".utf8))
    }
}

/// "Extracts" by writing `marker` (the runtime's install marker), optionally inside a wrapper
/// folder the way `zip -r out.zip bundle/` lays an archive out.
private struct FakeExtractor: ParakeetArchiveExtracting {
    var marker = "metadata.json"
    var wrapper: String?
    var failure: Error?

    func extract(archiveAt archive: URL, into directory: URL) throws {
        if let failure { throw failure }
        let root = wrapper.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("bundle".utf8).write(to: root.appendingPathComponent(marker))
        try Data("weights".utf8).write(to: root.appendingPathComponent("encoder.aimodel"))
    }
}

private final class FakePreparer: ParakeetModelPreparing, @unchecked Sendable {
    private let lock = NSLock()
    private var prepared: [String] = []
    let failure: Error?
    let gate: Gate?

    init(failure: Error? = nil, gate: Gate? = nil) {
        self.failure = failure
        self.gate = gate
    }

    var preparedIds: [String] { lock.withLock { prepared } }
    private var discarded: [String] = []
    var discardedIds: [String] { lock.withLock { discarded } }

    func discardBuiltArtifacts(spec: ParakeetModelSpec, directory: URL) async {
        lock.withLock { discarded.append(spec.id) }
    }

    func prepare(spec: ParakeetModelSpec, directory: URL) async throws {
        if let gate {
            while await gate.isOpen == false { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        // The real preparer needs the unpacked bundle to be there.
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(spec.installMarkerFileName).path))
        lock.withLock { prepared.append(spec.id) }
    }
}

private final class ForegroundBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = true
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - Support

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("parakeet-coreai-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

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

private let coreAI = ParakeetModelCatalog.byId(ParakeetModelCatalog.coreAIModelId)
private let cactus = ParakeetModelCatalog.byId(ParakeetModelCatalog.defaultModelId)

private func makeStore(
    root: URL,
    downloader: FakeDownloader = FakeDownloader(),
    extractor: FakeExtractor = FakeExtractor(),
    preparer: FakePreparer = FakePreparer(),
    supported: Set<LocalEngineRuntime> = [.cactus, .coreAI],
    foreground: ForegroundBox = ForegroundBox()
) -> ParakeetModelStore {
    ParakeetModelStore(
        location: ParakeetModelLocation(modelsDirectory: root.appendingPathComponent("models")),
        downloader: downloader,
        extractor: extractor,
        temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
        inboxDirectory: root.appendingPathComponent("inbox", isDirectory: true),
        preparer: { _ in preparer },
        supportedRuntimes: supported,
        isForeground: { foreground.value }
    )
}

private func dropInInbox(_ root: URL, id: String) throws -> URL {
    let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let zip = inbox.appendingPathComponent("\(id).zip")
    try Data("zip".utf8).write(to: zip)
    return zip
}

// MARK: - Tests

@Suite struct ParakeetModelLocationCoreAITests {
    @Test func coreAIInstallNeedsMetadataAndItsOwnVersionFile() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = ParakeetModelLocation(modelsDirectory: root)
        let dir = location.directory(for: coreAI)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(location.isInstalled(coreAI) == false)

        // A Cactus-style install in the same folder is NOT a Core AI install.
        try Data("x".utf8).write(to: dir.appendingPathComponent("config.txt"))
        try Data(coreAI.revision.utf8).write(to: dir.appendingPathComponent(".cactus_version"))
        #expect(location.isInstalled(coreAI) == false)

        try Data("{}".utf8).write(to: dir.appendingPathComponent("metadata.json"))
        #expect(location.isInstalled(coreAI) == false)  // no .coreai_version yet
        try Data(coreAI.revision.utf8).write(to: dir.appendingPathComponent(".coreai_version"))
        #expect(location.isInstalled(coreAI))
        #expect(location.installedModelPath(for: coreAI) == dir)

        // Installed is not prepared until the marker is written.
        #expect(location.isPrepared(coreAI) == false)
        try Data("prepared".utf8).write(to: dir.appendingPathComponent(".prepared"))
        #expect(location.isPrepared(coreAI))
        // Cactus never needs preparing.
        #expect(location.isPrepared(cactus))
    }

    /// The provider withdraws `.prepared` when the compiled cache goes stale and restores it after
    /// the rebuild; neither write may make an uninstalled directory look ready.
    @Test func setPreparedWritesAndRemovesTheMarkerOnlyForAnInstalledModel() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = ParakeetModelLocation(modelsDirectory: root)
        let dir = location.directory(for: coreAI)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        location.setPrepared(coreAI, true)
        #expect(location.isPrepared(coreAI) == false)  // not installed: nothing written

        try Data("{}".utf8).write(to: dir.appendingPathComponent("metadata.json"))
        try Data(coreAI.revision.utf8).write(to: dir.appendingPathComponent(".coreai_version"))
        location.setPrepared(coreAI, true)
        #expect(location.isPrepared(coreAI))
        location.setPrepared(coreAI, false)
        #expect(location.isPrepared(coreAI) == false)
        #expect(location.isInstalled(coreAI))  // the model files are untouched
    }
}

// The Core AI entry is `published: false` (6aedb35): the store refuses to download it and asks
// for a Files-inbox import instead. Every install below therefore starts from an inbox archive —
// the download path is covered by the Cactus entry and by `ParakeetModelStoreTests`.
@Suite struct ParakeetModelStoreCoreAITests {
    @Test func installUnpacksPreparesAndOnlyThenIsInstalled() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preparer = FakePreparer()
        let store = makeStore(root: root, preparer: preparer)
        _ = try dropInInbox(root, id: coreAI.id)
        let stream = await store.states()
        let observed = Task {
            var seen: [ParakeetInstallState] = []
            for await entries in stream {
                if let row = entries.first(where: { $0.id == coreAI.id }) { seen.append(row.state) }
                if seen.last == .installed { break }
            }
            return seen
        }

        #expect(await store.install(coreAI.id) == .installed)

        let seen = await observed.value
        #expect(seen.contains(.installing))
        #expect(seen.contains(.preparing))
        #expect(seen.last == .installed)
        #expect(preparer.preparedIds == [coreAI.id])
        let location = ParakeetModelLocation(modelsDirectory: root.appendingPathComponent("models"))
        #expect(location.isInstalled(coreAI))
        #expect(location.isPrepared(coreAI))
        #expect(location.recordedVersion(for: coreAI) == "v1")
        #expect(
            FileManager.default.fileExists(
                atPath: location.directory(for: coreAI).appendingPathComponent(".cactus_version").path
            ) == false
        )
    }

    @Test func aCactusInstallStillNeedsNoPrepareStep() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preparer = FakePreparer()
        let store = makeStore(
            root: root, extractor: FakeExtractor(marker: "config.txt"), preparer: preparer
        )
        #expect(await store.install(cactus.id) == .installed)
        #expect(preparer.preparedIds.isEmpty)
    }

    @Test func aFailedPrepareKeepsTheFilesAndRetryOnlyPrepares() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader()
        let store = makeStore(
            root: root, downloader: downloader,
            preparer: FakePreparer(failure: ParakeetEngineError.insufficientMemory(availableMb: 300, requiredMb: 700))
        )
        let zip = try dropInInbox(root, id: coreAI.id)
        let state = await store.install(coreAI.id)
        #expect(state == .failed(message: "Not enough memory to prepare the model right now. Close other apps and try again."))
        let location = ParakeetModelLocation(modelsDirectory: root.appendingPathComponent("models"))
        #expect(location.isInstalled(coreAI))
        #expect(location.isPrepared(coreAI) == false)
        // A refresh keeps the failure (no silent restart of a pass that just failed).
        #expect(await store.refresh().first { $0.id == coreAI.id }?.state == state)

        // The retry goes straight to preparing: the archive was consumed by the first install
        // and nothing asks the network for another.
        #expect(FileManager.default.fileExists(atPath: zip.path) == false)
        let retry = makeStore(root: root, downloader: downloader)
        #expect(await retry.install(coreAI.id) == .installed)
        #expect(downloader.requestedURLs.isEmpty)
    }

    @Test func aModelLoadFailureHasItsOwnMessage() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(
            root: root, preparer: FakePreparer(failure: ParakeetEngineError.modelLoadFailed("bad graph"))
        )
        _ = try dropInInbox(root, id: coreAI.id)
        #expect(await store.install(coreAI.id) == .failed(message: "The model couldn't be prepared. Try again."))
    }

    @Test func cancelDuringPrepareRemovesTheInstall() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root, preparer: FakePreparer(gate: Gate()))
        _ = try dropInInbox(root, id: coreAI.id)
        let install = Task { await store.install(coreAI.id) }
        try await waitUntil("prepare to start") { await store.state(of: coreAI.id) == .preparing }
        await store.cancel(coreAI.id)
        #expect(await install.value == .notInstalled)
        let location = ParakeetModelLocation(modelsDirectory: root.appendingPathComponent("models"))
        #expect(FileManager.default.fileExists(atPath: location.directory(for: coreAI).path) == false)
    }

    @Test func refreshInstallsAnArchiveFromTheInboxAndConsumesIt() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader()
        let preparer = FakePreparer()
        let store = makeStore(root: root, downloader: downloader, preparer: preparer)
        let zip = try dropInInbox(root, id: coreAI.id)
        #expect(store.inboxArchive(for: coreAI) == zip)

        let rows = await store.refresh()
        #expect(rows.first { $0.id == coreAI.id }?.state.isBusy == true)
        try await waitUntil("the inbox install to finish") {
            await store.state(of: coreAI.id) == .installed
        }
        #expect(downloader.requestedURLs.isEmpty)
        #expect(preparer.preparedIds == [coreAI.id])
        #expect(FileManager.default.fileExists(atPath: zip.path) == false)
        #expect(store.inboxArchive(for: coreAI) == nil)
    }

    @Test func installPrefersAnInboxArchiveOverTheNetwork() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader()
        let store = makeStore(root: root, downloader: downloader)
        _ = try dropInInbox(root, id: coreAI.id)
        #expect(await store.install(coreAI.id) == .installed)
        #expect(downloader.requestedURLs.isEmpty)
    }

    @Test func aCorruptInboxArchiveIsReportedAndNotRetriedForever() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(
            root: root, extractor: FakeExtractor(failure: ZipExtractionError.notAZipArchive)
        )
        let zip = try dropInInbox(root, id: coreAI.id)
        _ = await store.refresh()
        try await waitUntil("the failure") {
            if case .failed = await store.state(of: coreAI.id) { return true }
            return false
        }
        // Consumed, so the next refresh does not start the same failing install again.
        #expect(FileManager.default.fileExists(atPath: zip.path) == false)
        _ = await store.refresh()
        if case .failed = await store.state(of: coreAI.id) {} else {
            Issue.record("the failure should still be showing")
        }
    }

    @Test func anArchiveWrappedInOneFolderIsHoisted() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(
            root: root, extractor: FakeExtractor(wrapper: "parakeet-tdt-0.6b-v3_float16_streaming150")
        )
        _ = try dropInInbox(root, id: coreAI.id)
        #expect(await store.install(coreAI.id) == .installed)
        let dir = ParakeetModelLocation(modelsDirectory: root.appendingPathComponent("models"))
            .directory(for: coreAI)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("metadata.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("encoder.aimodel").path))
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("parakeet-tdt-0.6b-v3_float16_streaming150").path
            ) == false
        )
    }

    @Test func hoistLeavesAnythingButASingleWrapperAlone() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        // Two folders, neither hoisted.
        for name in ["a", "b"] {
            let dir = root.appendingPathComponent(name)
            try manager.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("metadata.json"))
        }
        try ParakeetModelStore.hoistSingleWrapperDirectory(in: root, marker: "metadata.json")
        #expect(manager.fileExists(atPath: root.appendingPathComponent("metadata.json").path) == false)
        #expect(manager.fileExists(atPath: root.appendingPathComponent("a/metadata.json").path))
        // One folder without the marker: also left alone.
        let other = try makeTempDirectory()
        defer { try? manager.removeItem(at: other) }
        try manager.createDirectory(at: other.appendingPathComponent("x"), withIntermediateDirectories: true)
        try ParakeetModelStore.hoistSingleWrapperDirectory(in: other, marker: "metadata.json")
        #expect(manager.fileExists(atPath: other.appendingPathComponent("x").path))
    }

    /// An install can finish after the app has left the screen (a long import, a download the
    /// user walked away from). The cold pass after it must wait for the foreground too — only the
    /// refresh path used to check.
    @Test func anInstallThatFinishesInTheBackgroundWaitsForTheForegroundToPrepare() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let foreground = ForegroundBox()
        foreground.value = false
        let preparer = FakePreparer()
        let store = makeStore(root: root, preparer: preparer, foreground: foreground)
        _ = try dropInInbox(root, id: coreAI.id)

        #expect(await store.install(coreAI.id) == .preparing)
        #expect(preparer.preparedIds.isEmpty)

        foreground.value = true
        _ = await store.refresh()
        try await waitUntil("the prepare pass") { await store.state(of: coreAI.id) == .installed }
        #expect(preparer.preparedIds == [coreAI.id])
    }

    /// Uninstalling a Core AI model also drops the ~1.1 GB the runtime built from it outside the
    /// install directory — which a re-import could otherwise meet, stale, again.
    @Test func uninstallDropsWhatTheRuntimeBuiltFromTheModel() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preparer = FakePreparer()
        let store = makeStore(root: root, preparer: preparer)
        _ = try dropInInbox(root, id: coreAI.id)
        #expect(await store.install(coreAI.id) == .installed)
        #expect(await store.uninstall(coreAI.id) == .notInstalled)
        #expect(preparer.discardedIds == [coreAI.id])
    }

    @Test func anUnpackedModelIsPreparedOnAForegroundRefreshOnly() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Simulate an install that got as far as the version file (the app was killed mid-pass).
        let location = ParakeetModelLocation(modelsDirectory: root.appendingPathComponent("models"))
        let dir = location.directory(for: coreAI)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("metadata.json"))
        try Data(coreAI.revision.utf8).write(to: dir.appendingPathComponent(".coreai_version"))

        let foreground = ForegroundBox()
        foreground.value = false
        let preparer = FakePreparer()
        let store = makeStore(root: root, preparer: preparer, foreground: foreground)

        // Background: reported as preparing (not installed, not usable), nothing started.
        #expect(await store.refresh().first { $0.id == coreAI.id }?.state == .preparing)
        #expect(await store.state(of: coreAI.id) == .preparing)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(preparer.preparedIds.isEmpty)
        #expect(location.isPrepared(coreAI) == false)

        // Foreground: the pass runs and the model becomes installed.
        foreground.value = true
        _ = await store.refresh()
        try await waitUntil("the prepare pass") { await store.state(of: coreAI.id) == .installed }
        #expect(preparer.preparedIds == [coreAI.id])
        #expect(location.isPrepared(coreAI))
    }

    @Test func anUnsupportedRuntimeIsNeitherDownloadedNorTakenFromTheInbox() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloader()
        let store = makeStore(root: root, downloader: downloader, supported: [.cactus])
        let zip = try dropInInbox(root, id: coreAI.id)

        #expect(await store.install(coreAI.id) == .failed(message: "This model needs iOS 27 on an iPhone."))
        _ = await store.refresh()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(downloader.requestedURLs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: zip.path))  // left for a build that can

        // The Cactus model is unaffected.
        let cactusStore = makeStore(
            root: root, downloader: downloader, extractor: FakeExtractor(marker: "config.txt"),
            supported: [.cactus]
        )
        #expect(await cactusStore.install(cactus.id) == .installed)
    }

    @Test func uninstallRemovesAPreparedModelAndItsMarkers() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        _ = try dropInInbox(root, id: coreAI.id)
        #expect(await store.install(coreAI.id) == .installed)
        #expect(await store.uninstall(coreAI.id) == .notInstalled)
        let location = ParakeetModelLocation(modelsDirectory: root.appendingPathComponent("models"))
        #expect(location.isInstalled(coreAI) == false)
        #expect(location.isPrepared(coreAI) == false)
        #expect(await store.state(of: coreAI.id) == .notInstalled)
    }

    @Test func preparingCountsAsBusy() {
        #expect(ParakeetInstallState.preparing.isBusy)
        #expect(ParakeetInstallState.preparing.isInstalled == false)
        #expect(ParakeetInstallState.preparing.fractionCompleted == nil)
    }
}
