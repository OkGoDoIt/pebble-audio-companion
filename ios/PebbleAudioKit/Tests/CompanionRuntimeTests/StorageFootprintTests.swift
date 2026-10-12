import Foundation
import Testing

@testable import CompanionRuntime

@Suite struct StorageFootprintTests {
    /// A container shaped like the phone's, in miniature: every bucket lands where the
    /// Diagnostics screen will name it, and the total is the sum of the parts.
    @Test func bucketsTheContainerTheWayTheScreenNamesIt() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("footprint-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("audio-companion", isDirectory: true)
        let models = base.appendingPathComponent("models", isDirectory: true)
        let caches = base.appendingPathComponent("Caches", isDirectory: true)
        let tmp = base.appendingPathComponent("tmp", isDirectory: true)

        func put(_ path: String, _ bytes: Int, under: URL = root) throws {
            let url = under.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
        }
        try put("segments/seg-1.spxlog", 1_000)
        try put("segments/seg-2.spxlog", 2_000)
        try put("segments/seg-1.meta.json", 100)
        try put("segments/seg-2.meta.json", 100)
        try put("segments_index.json", 50)
        try put("transcription/seg-1.json", 300)
        try put("ai/outputs.json", 20)
        try put("analysis/clips/L000.mp3", 400)
        try put("db/companion.sqlite", 5_000)
        try put("db/companion.sqlite-wal", 500)
        try put("diagnostics/companion.log", 70)
        try put("receiver_state.json", 10)
        try put("upload-bodies/.keep", 0)
        try put("parakeet/weights.mlirb", 9_000, under: models)
        try put("coreai-cache/program.bin", 8_000, under: caches)
        try put("com.apple.MetalPerformanceShadersGraph/mpsgraph-1/main.bc.mlir", 7_000, under: tmp)
        try put("pebble-audio-companion.log", 30, under: tmp)

        let footprint = StorageFootprint.measure(
            appRoot: root, modelsDirectory: models, cachesDirectory: caches,
            temporaryDirectory: tmp, volume: base)

        #expect(footprint.audioBytes == 3_000)
        #expect(footprint.audioFiles == 2)
        #expect(footprint.sidecarBytes == 250)
        #expect(footprint.transcriptBytes == 720)
        #expect(footprint.databaseBytes == 5_500)
        #expect(footprint.diagnosticsBytes == 70)
        #expect(footprint.otherBytes == 10)
        #expect(footprint.modelBytes == 9_000)
        #expect(footprint.cacheBytes == 8_000)
        #expect(footprint.temporaryBytes == 7_030)
        #expect(footprint.totalFiles == 17)
        #expect(footprint.totalBytes == 33_580)
        #expect(footprint.capacityBytes > 0)
        #expect(footprint.freeBytes > 0)
    }

    @Test func foldersThatDoNotExistCountAsNothing() {
        let nowhere = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        let footprint = StorageFootprint.measure(
            appRoot: nowhere, modelsDirectory: nil, cachesDirectory: nil, temporaryDirectory: nil,
            volume: nowhere)
        #expect(footprint == StorageFootprint())
    }
}
