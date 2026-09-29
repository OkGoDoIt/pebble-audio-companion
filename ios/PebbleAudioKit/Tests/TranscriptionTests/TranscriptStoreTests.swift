import Foundation
import Testing

@testable import Transcription

// Port of `core/transcription/src/jvmTest/.../FileTranscriptStoreTest.kt` — all 6 cases, same
// names — plus one Swift-side guard that the JSON on disk keeps the exact kotlinx
// key/omission shape the migration importer depends on.
@Suite struct TranscriptStoreTests {

    private let clock = ClockBox(9_000)

    private func store(_ root: URL) -> FileTranscriptStore {
        FileTranscriptStore(root: root, nowMs: { [clock] in clock.postIncrement() })
    }

    private func routed(_ text: String) -> RoutedTranscription {
        RoutedTranscription(
            text: text,
            modeUsed: .localFirst,
            providerId: "local",
            modelUsed: "model-1",
            segments: [TranscriptSegment(text: "hello", startMs: 1_000, endMs: 2_000)],
            words: [TranscriptWord(text: "hello", startMs: 1_000, endMs: 1_400)]
        )
    }

    @Test func saveAndLoadRoundTrip() throws {
        let store = store(try makeTempRoot("transcripts"))

        try store.save("seg-1", result: routed("hello world"))

        let loaded = store.load("seg-1")
        #expect(loaded?.text == "hello world")
        #expect(loaded?.modeUsed == .localFirst)
        #expect(loaded?.providerId == "local")
        #expect(loaded?.modelUsed == "model-1")
        #expect(loaded?.segmentId == "seg-1")
        #expect(
            loaded?.segments == [TranscriptSegment(text: "hello", startMs: 1_000, endMs: 2_000)])
        #expect(loaded?.words == [TranscriptWord(text: "hello", startMs: 1_000, endMs: 1_400)])
    }

    @Test func saveOverwritesExistingTranscript() throws {
        let store = store(try makeTempRoot("transcripts"))
        try store.save("seg-1", result: routed("first"))

        try store.save("seg-1", result: routed("second"))

        #expect(store.load("seg-1")?.text == "second")
        #expect(store.list().count == 1)
    }

    @Test func listReturnsTranscriptsOrderedByCreation() throws {
        let store = store(try makeTempRoot("transcripts"))
        try store.save("seg-b", result: routed("b"))
        try store.save("seg-a", result: routed("a"))

        #expect(store.list().map(\.segmentId) == ["seg-b", "seg-a"])
    }

    @Test func deleteRemovesOneTranscript() throws {
        let store = store(try makeTempRoot("transcripts"))
        try store.save("seg-1", result: routed("one"))
        try store.save("seg-2", result: routed("two"))

        try store.delete("seg-1")

        #expect(store.load("seg-1") == nil)
        #expect(store.load("seg-2")?.text == "two")
    }

    @Test func deleteAllRemovesEverything() throws {
        let store = store(try makeTempRoot("transcripts"))
        try store.save("seg-1", result: routed("one"))
        try store.save("seg-2", result: routed("two"))

        try store.deleteAll()

        #expect(store.list().isEmpty)
    }

    // `version` is the identity the AI stages memoise a whole library against, on every pass.
    // Pinned: stable while the file is untouched, "absent" for no file, and different once the
    // file is rewritten with other content — the three facts the memo caches depend on.
    @Test func versionIsStableAbsentOrChanged() throws {
        let store = store(try makeTempRoot("transcripts"))
        #expect(store.version("seg-1") == "absent")

        try store.save("seg-1", result: routed("hello world"))
        let first = store.version("seg-1")
        #expect(first != "absent")
        #expect(store.version("seg-1") == first)

        try store.save("seg-1", result: routed("hello world, and then some more of it"))
        #expect(store.version("seg-1") != first)
    }

    @Test func loadOfMissingSegmentIsNull() throws {
        #expect(store(try makeTempRoot("transcripts")).load("seg-missing") == nil)
    }

    /// Not in the KMP file: pins the on-disk JSON to the kotlinx.serialization shape
    /// (`encodeDefaults = false`) — exact key names, and omission of null `modelUsed`/`speaker`
    /// and empty `segments`/`words` — so old-app files and Swift files stay mutually readable.
    @Test func jsonKeysMatchKmpSerialization() throws {
        let root = try makeTempRoot("transcripts")
        let store = store(root)
        try store.save("seg-full", result: routed("hello world"))
        try store.save(
            "seg-minimal",
            result: RoutedTranscription(
                text: "hi", modeUsed: .remoteOnly, providerId: "cloud", modelUsed: nil))

        func keys(_ segmentId: String) throws -> Set<String> {
            let url =
                root
                .appendingPathComponent("transcription", isDirectory: true)
                .appendingPathComponent("transcripts", isDirectory: true)
                .appendingPathComponent("\(segmentId).transcript.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            return Set((object as? [String: Any])?.keys.map { $0 } ?? [])
        }

        #expect(
            try keys("seg-full") == [
                "segmentId", "text", "modeUsed", "providerId", "modelUsed", "createdAtMs",
                "segments", "words",
            ])
        #expect(
            try keys("seg-minimal") == [
                "segmentId", "text", "modeUsed", "providerId", "createdAtMs",
            ])

        // Enum values serialize as the Kotlin constant names, and a nil segment speaker is
        // omitted from the nested object.
        let full = try JSONSerialization.jsonObject(
            with: Data(
                contentsOf:
                    root
                    .appendingPathComponent("transcription", isDirectory: true)
                    .appendingPathComponent("transcripts", isDirectory: true)
                    .appendingPathComponent("seg-full.transcript.json"))) as? [String: Any]
        #expect(full?["modeUsed"] as? String == "LocalFirst")
        let firstSegment = (full?["segments"] as? [[String: Any]])?.first
        #expect(firstSegment?.keys.contains("speaker") == false)
    }
}

@Suite struct ScratchFileSweepTests {
    @Test func removesOnlyOldTransientScratchFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Date().addingTimeInterval(-3_600)
        func make(_ name: String, bytes: Int, modified: Date) throws {
            let url = dir.appendingPathComponent(name)
            try Data(count: bytes).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path)
        }
        try make("cactus_stt-A.raw", bytes: 1_000, modified: old)
        try make("cactus_stt-B.wav", bytes: 500, modified: old)
        try make("pebble-flac-C.flac", bytes: 250, modified: old)
        try make("cactus_stt-fresh.raw", bytes: 10, modified: Date())  // may still be in use
        try make("cactus_download_x.zip", bytes: 10, modified: old)  // a killed download's archive
        try make("pebble-audio-companion.log", bytes: 10, modified: old)

        let result = ScratchFileSweep.run(in: dir)

        #expect(result == ScratchFileSweep.Result(files: 4, bytes: 1_760))
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["cactus_stt-fresh.raw", "pebble-audio-companion.log"])
    }
}
