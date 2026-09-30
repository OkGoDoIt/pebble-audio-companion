import Foundation
import Testing

@testable import Transcription

// Deleting part of a segment's transcript. One segment routinely holds the end of one
// conversation and the start of the next, so deleting a conversation removes the turns that
// start in its range of the segment and must leave the neighbour's exactly as they were — and
// the removal has to hold against a transcript that lands AFTER the delete.
@Suite struct TranscriptRedactionTests {

    private let clock = ClockBox(9_000)

    private func store(_ root: URL) -> FileTranscriptStore {
        FileTranscriptStore(root: root, nowMs: { [clock] in clock.postIncrement() })
    }

    /// Three turns: a conversation that ends at 60 s, and another that runs from 60 s on.
    private func routed() -> RoutedTranscription {
        RoutedTranscription(
            text: "see you at the dentist let us talk about the budget the numbers are in",
            modeUsed: .remoteOnly,
            providerId: "cloud",
            modelUsed: "model-1",
            segments: [
                TranscriptSegment(text: "see you at the dentist", startMs: 10_000, endMs: 14_000, speaker: "1"),
                TranscriptSegment(text: "let us talk about the budget", startMs: 61_500, endMs: 66_000, speaker: "2"),
                TranscriptSegment(text: "the numbers are in", startMs: 70_000, endMs: 73_000, speaker: "1"),
            ],
            words: [
                TranscriptWord(text: "dentist", startMs: 13_000, endMs: 14_000),
                TranscriptWord(text: "budget", startMs: 65_000, endMs: 66_000),
                TranscriptWord(text: "numbers", startMs: 70_500, endMs: 71_000),
            ]
        )
    }

    private func sidecarURL(_ root: URL, _ segmentId: String) -> URL {
        root.appendingPathComponent("transcription/transcripts")
            .appendingPathComponent("\(segmentId)\(FileTranscriptStore.redactionsSuffix)")
    }

    @Test func redactionRemovesTheTurnsAndWordsThatStartInTheRange() throws {
        let store = store(try makeTempRoot("redact"))
        let original = try store.save("seg-1", result: routed())
        let versionBefore = store.version("seg-1")

        let redacted = try #require(try store.redact("seg-1", mediaRangeMs: 60_000..<900_000))

        #expect(redacted.segments == [original.segments[0]])
        #expect(redacted.words == [original.words[0]])
        #expect(redacted.text == "see you at the dentist")
        // Everything that is not words is what it was.
        #expect(redacted.providerId == original.providerId)
        #expect(redacted.modeUsed == original.modeUsed)
        #expect(redacted.modelUsed == original.modelUsed)
        #expect(redacted.createdAtMs == original.createdAtMs)
        // On disk, not only in the return value — and through the timings-only reader too.
        #expect(store.load("seg-1") == redacted)
        #expect(store.loadSpeechTimings("seg-1") == [original.segments[0]])
        #expect(store.version("seg-1") != versionBefore)
    }

    @Test func theDeletedWordsAreNotInTheFileAtAll() throws {
        let root = try makeTempRoot("redact-bytes")
        let store = store(root)
        try store.save("seg-1", result: routed())

        try store.redact("seg-1", mediaRangeMs: 0..<60_000)

        let file = root.appendingPathComponent("transcription/transcripts")
            .appendingPathComponent("seg-1\(FileTranscriptStore.suffix)")
        let bytes = try String(contentsOf: file, encoding: .utf8)
        #expect(!bytes.contains("dentist"))
        #expect(bytes.contains("budget"))
        // The sidecar names ranges, never words.
        let sidecar = try String(contentsOf: sidecarURL(root, "seg-1"), encoding: .utf8)
        #expect(!sidecar.contains("dentist"))
    }

    /// The race the sidecar exists for: a transcription that was running, or uploading, when
    /// the delete happened was made from the audio as it was. When it lands it must not put
    /// the deleted words back.
    @Test func aLateSaveOfTheFullOriginalCannotRestoreTheDeletedWords() throws {
        let root = try makeTempRoot("redact-late")
        let store = store(root)
        try store.save("seg-1", result: routed())
        try store.redact("seg-1", mediaRangeMs: 0..<60_000)

        let landed = try store.save("seg-1", result: routed())

        #expect(landed.segments.map(\.text) == ["let us talk about the budget", "the numbers are in"])
        #expect(landed.words.map(\.text) == ["budget", "numbers"])
        #expect(landed.text == "let us talk about the budget the numbers are in")
        #expect(store.load("seg-1") == landed)

        // And after a relaunch: the ranges are on disk, not in the store object.
        let relaunched = self.store(root)
        #expect(relaunched.redactions("seg-1") == [0..<60_000])
        let again = try relaunched.save("seg-1", result: routed())
        #expect(!again.text.contains("dentist"))
    }

    @Test func aRangeDeletedBeforeAnyTranscriptExistsStillCoversTheOneToCome() throws {
        let store = store(try makeTempRoot("redact-early"))

        #expect(try store.redact("seg-1", mediaRangeMs: 60_000..<900_000) == nil)
        #expect(store.load("seg-1") == nil)

        let landed = try store.save("seg-1", result: routed())
        #expect(landed.segments.map(\.text) == ["see you at the dentist"])
    }

    @Test func rangesAccumulateAndMerge() throws {
        let store = store(try makeTempRoot("redact-merge"))
        try store.save("seg-1", result: routed())

        try store.redact("seg-1", mediaRangeMs: 60_000..<68_000)
        #expect(store.load("seg-1")?.segments.map(\.startMs) == [10_000, 70_000])
        try store.redact("seg-1", mediaRangeMs: 68_000..<900_000)
        try store.redact("seg-1", mediaRangeMs: 0..<5_000)

        #expect(store.redactions("seg-1") == [0..<5_000, 60_000..<900_000])
        #expect(store.load("seg-1")?.segments.map(\.startMs) == [10_000])
        // An empty range is no range.
        try store.redact("seg-1", mediaRangeMs: 20_000..<20_000)
        #expect(store.redactions("seg-1") == [0..<5_000, 60_000..<900_000])
    }

    @Test func aRangeWithNothingInItLeavesTheTranscriptFileAlone() throws {
        let store = store(try makeTempRoot("redact-noop"))
        let original = try store.save("seg-1", result: routed())
        let version = store.version("seg-1")

        let result = try store.redact("seg-1", mediaRangeMs: 20_000..<40_000)

        #expect(result == original)
        // Nothing derived from the transcript has to be rebuilt.
        #expect(store.version("seg-1") == version)
        #expect(store.redactions("seg-1") == [20_000..<40_000])
    }

    /// A turn belongs to the range its first instant falls in — the rule that gives it to one
    /// conversation (`ConversationMember.contains`). The bounds are start-inclusive and
    /// end-exclusive, so two adjacent ranges never both claim a turn and never both miss it.
    @Test func boundsMatchThePieceRule() throws {
        let store = store(try makeTempRoot("redact-bounds"))
        try store.save("seg-1", result: routed())

        try store.redact("seg-1", mediaRangeMs: 10_000..<61_500)

        #expect(store.load("seg-1")?.segments.map(\.startMs) == [61_500, 70_000])
    }

    /// No turn timings, nothing to cut by: the text belongs, whole, to the piece that starts
    /// the segment (`SegmentTranscript.piece`). So it goes with that piece and with no other.
    @Test func aTranscriptWithNoTimingsGoesWithThePieceThatStartsTheSegment() throws {
        let store = store(try makeTempRoot("redact-untimed"))
        let untimed = RoutedTranscription(
            text: "all of it", modeUsed: .localOnly, providerId: "local", modelUsed: nil)
        try store.save("seg-1", result: untimed)
        try store.save("seg-2", result: untimed)

        try store.redact("seg-1", mediaRangeMs: 300_000..<900_000)
        try store.redact("seg-2", mediaRangeMs: 0..<300_000)

        #expect(store.load("seg-1")?.text == "all of it")
        #expect(store.load("seg-2")?.text == "")
    }

    @Test func deletingTheSegmentForgetsItsRedactions() throws {
        let root = try makeTempRoot("redact-delete")
        let store = store(root)
        try store.save("seg-1", result: routed())
        try store.save("seg-2", result: routed())
        try store.redact("seg-1", mediaRangeMs: 0..<60_000)
        try store.redact("seg-2", mediaRangeMs: 0..<60_000)
        #expect(FileManager.default.fileExists(atPath: sidecarURL(root, "seg-1").path))

        try store.delete("seg-1")

        #expect(!FileManager.default.fileExists(atPath: sidecarURL(root, "seg-1").path))
        #expect(store.redactions("seg-1").isEmpty)
        #expect(store.redactions("seg-2") == [0..<60_000])
        // The sidecar is not a transcript: it never shows up in the listing.
        #expect(store.list().map(\.segmentId) == ["seg-2"])

        try store.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: sidecarURL(root, "seg-2").path))
        #expect(store.list().isEmpty)
    }

    /// The whole-segment version of the same race: the recording is deleted while its
    /// transcription is still running, and the result arrives a moment later.
    @Test func aTranscriptThatLandsAfterItsSegmentWasDeletedIsNotWritten() throws {
        let root = try makeTempRoot("redact-tombstone")
        let store = store(root)
        try store.save("seg-1", result: routed())
        try store.save("seg-2", result: routed())

        try store.delete("seg-1")
        let landed = try store.save("seg-1", result: routed())

        // The caller gets its result back; nothing reaches the disk.
        #expect(landed.segmentId == "seg-1")
        #expect(store.load("seg-1") == nil)
        #expect(store.list().map(\.segmentId) == ["seg-2"])

        // Delete All covers everything that had a transcript.
        try store.deleteAll()
        try store.save("seg-2", result: routed())
        #expect(store.load("seg-2") == nil)
        // A segment recorded afterwards is a new id, and saves as ever.
        try store.save("seg-3", result: routed())
        #expect(store.load("seg-3") != nil)
    }

    @Test func redactingIsTheComplementOfAPiece() throws {
        let store = store(try makeTempRoot("redact-piece"))
        let transcript = try store.save("seg-1", result: routed())

        let kept = transcript.redacting([60_000..<900_000])
        let deleted = transcript.redacting([0..<60_000])

        #expect(kept.segments + deleted.segments == transcript.segments)
        #expect(kept.words + deleted.words == transcript.words)
        #expect(transcript.redacting([]) == transcript)
    }
}
