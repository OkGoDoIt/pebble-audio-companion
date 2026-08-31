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
