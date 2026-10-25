import Foundation
import Testing
import Transcription
@testable import SpeakerRecognition

private struct CorruptSpeakerDownload: ParakeetArchiveDownloading {
    func download(from url: URL, to destination: URL,
                  onProgress: @escaping @Sendable (Int64, Int64) -> Void) throws {
        try Data("corrupt".utf8).write(to: destination)
        onProgress(7, 7)
    }
}

private actor LocalSpeakerArchives: ParakeetArchiveDownloading {
    let root: URL
    var calls = 0
    init(_ root: URL) { self.root = root }
    func download(from url: URL, to destination: URL,
                  onProgress: @escaping @Sendable (Int64, Int64) -> Void) throws {
        calls += 1
        let file: URL
        if url.lastPathComponent.hasPrefix("wespeaker") { file = root.appendingPathComponent("wespeaker.zip") }
        else {
            let path = url.path.components(separatedBy: "/Segmentation.mlmodelc/").last!
            file = root.appendingPathComponent("Segmentation.mlmodelc").appendingPathComponent(path)
        }
        try FileManager.default.copyItem(at: file, to: destination)
        let bytes = Int64(try Data(contentsOf: file).count)
        onProgress(bytes, bytes)
    }
}

@Suite struct SpeakerModelStoreTests {
    @Test func corruptDownloadIsNotPublishedAndFailureSurvivesStatusRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-model-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerModelStore(root: root, downloader: CorruptSpeakerDownload())
        await #expect(throws: SpeakerRecognitionError.self) { try await store.install() }
        #expect(!(await store.isInstalled()))
        guard case .failed = await store.state() else { Issue.record("Missing install failure"); return }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PEBBLE_SPEAKER_MODEL_FIXTURES"] != nil))
    func actualPinnedPublicArchivesInstallAndUninstall() async throws {
        let source = try #require(ProcessInfo.processInfo.environment["PEBBLE_SPEAKER_MODEL_FIXTURES"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-model-install-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = LocalSpeakerArchives(URL(fileURLWithPath: source))
        let store = SpeakerModelStore(root: root, downloader: downloader)
        try await store.install()
        #expect(await store.isInstalled())
        #expect(await store.isInstalled())
        #expect(await store.state() == .installed)
        #expect(await downloader.calls == 6)
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try await store.install()
        #expect(await downloader.calls == 6)
        try await store.uninstall()
        #expect(!(await store.isInstalled()))
    }
}
