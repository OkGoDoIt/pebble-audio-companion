import Foundation
import Testing

@testable import Transcription

// Soniox sends some spaces as tokens of their own — most often the one after a comma — and the
// provider used to drop every blank token before building turns, so the next word was glued to
// the one before it ("so,right") in the stored turns while Soniox's own `text` kept the space.
// In a real backup that was 5,140 joins in 765 of 1,176 transcripts. Synthetic text below, in
// the response shape the async API returns.

@Suite struct SonioxWordSpacingTests {
    private func provider() -> SonioxTranscriptionProvider {
        SonioxTranscriptionProvider(
            transport: FakeHttpTransport { _ in throw AssertionError("unused") },
            apiKey: { "k" }, cloudConsent: { true }, diarizationEnabled: { true })
    }

    /// The space after the comma is its own token, and so is the one before an audio event.
    /// A blank token carries a speaker and timings of its own; neither may split a turn or
    /// move its bounds.
    static let body = """
        {"text":"We met at noon, right after lunch. <laughter> Then we left.",
         "tokens":[
           {"text":"We","start_ms":0,"end_ms":200,"speaker":"1","confidence":0.9},
           {"text":" met","start_ms":200,"end_ms":400,"speaker":"1","confidence":0.9},
           {"text":" at","start_ms":400,"end_ms":500,"speaker":"1","confidence":0.9},
           {"text":" noon","start_ms":500,"end_ms":800,"speaker":"1","confidence":0.9},
           {"text":",","start_ms":800,"end_ms":820,"speaker":"1","confidence":0.9},
           {"text":" ","start_ms":820,"end_ms":840,"speaker":"2"},
           {"text":"right","start_ms":900,"end_ms":1100,"speaker":"1","confidence":0.9},
           {"text":" after","start_ms":1100,"end_ms":1300,"speaker":"1","confidence":0.9},
           {"text":" lunch","start_ms":1300,"end_ms":1600,"speaker":"1","confidence":0.9},
           {"text":".","start_ms":1600,"end_ms":1620,"speaker":"1","confidence":0.9},
           {"text":" <laughter>","start_ms":1650,"end_ms":2200,"is_audio_event":true},
           {"text":"Then","start_ms":2300,"end_ms":2500,"speaker":"1","confidence":0.9},
           {"text":" we","start_ms":2500,"end_ms":2600,"speaker":"1","confidence":0.9},
           {"text":" left","start_ms":2600,"end_ms":2800,"speaker":"1","confidence":0.9},
           {"text":".","start_ms":2800,"end_ms":2820,"speaker":"1","confidence":0.9}
         ]}
        """

    @Test func blankTokensKeepTheirSpaceAndNothingElse() throws {
        let transcript = try JSONDecoder().decode(
            SonioxTranscriptionProvider.SonioxTranscript.self, from: Data(Self.body.utf8))
        let result = try provider().mapTranscript(transcript)

        #expect(result.segments.map(\.text) == ["We met at noon, right after lunch. Then we left."])
        #expect(result.segments.map(\.speaker) == ["1"])
        #expect(result.segments.first?.startMs == 0)
        #expect(result.segments.first?.endMs == 2820)
        // Words are the spoken tokens, as before: no blank word, no audio event.
        #expect(result.words.map(\.text) == [
            "We", "met", "at", "noon", ",", "right", "after", "lunch", ".", "Then", "we", "left",
            ".",
        ])
    }

    @Test func aTranscriptOfOnlyBlanksAndEventsHasNoTurns() {
        let tokens = [
            SonioxTranscriptionProvider.SonioxBatchToken(text: " ", startMs: 0, endMs: 10),
            SonioxTranscriptionProvider.SonioxBatchToken(
                text: "<music>", startMs: 10, endMs: 900, isAudioEvent: true),
        ]
        #expect(provider().groupIntoSegments(tokens).isEmpty)
    }

    // MARK: - Transcripts already on the phone

    /// What an older build wrote: the turns glued, Soniox's own text intact.
    private func writeLegacy(
        _ root: URL, providerId: String = SonioxTranscriptionProvider.providerId,
        text: String = "We met at noon, right after lunch. Then we left. Okay, right."
    ) throws {
        let dir = root.appendingPathComponent("transcription/transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcript = SegmentTranscript(
            segmentId: "seg-1", text: text, modeUsed: .remoteOnly, providerId: providerId,
            modelUsed: "stt-async-v5", createdAtMs: 1,
            segments: [
                TranscriptSegment(
                    text: "We met at noon,right after lunch.", startMs: 0, endMs: 1620,
                    speaker: "1", confidence: 0.9, minConfidence: 0.8),
                TranscriptSegment(text: "Then we left.", startMs: 2500, endMs: 3020, speaker: "1"),
                TranscriptSegment(text: "Okay,right.", startMs: 4000, endMs: 4600, speaker: "2"),
            ],
            words: [TranscriptWord(text: "We", startMs: 0, endMs: 200)])
        try JSONEncoder().encode(transcript).write(
            to: dir.appendingPathComponent("seg-1.transcript.json"))
    }

    @Test func storedTurnsReadWithTheirSpacesBack() throws {
        let root = try makeTempRoot("soniox-spacing")
        try writeLegacy(root)
        let store = FileTranscriptStore(root: root, nowMs: { 0 })
        let repaired = [
            "We met at noon, right after lunch.", "Then we left.", "Okay, right.",
        ]

        let loaded = try #require(store.load("seg-1"))
        #expect(loaded.segments.map(\.text) == repaired)
        // Only the text moves.
        #expect(loaded.segments.map(\.startMs) == [0, 2500, 4000])
        #expect(loaded.segments.map(\.speaker) == ["1", "1", "2"])
        #expect(loaded.segments[0].confidence == 0.9)
        #expect(loaded.segments[0].minConfidence == 0.8)
        #expect(store.loadWithoutWords("seg-1")?.segments.map(\.text) == repaired)

        // The segmenter's input stays what it cut existing recordings by.
        #expect(store.loadSpeechTimings("seg-1")?.first?.text == "We met at noon,right after lunch.")
        // Nothing is written back.
        let onDisk = try JSONDecoder().decode(
            StoredTurns.self,
            from: Data(contentsOf: root.appendingPathComponent(
                "transcription/transcripts/seg-1.transcript.json")))
        #expect(onDisk.segments.last?.text == "Okay,right.")
    }

    /// Anything that does not line up letter for letter is left exactly as stored: a text that
    /// differs (a redaction rebuilds it from the turns), and other providers.
    @Test func turnsThatDoNotLineUpAreLeftAlone() throws {
        let differs = try makeTempRoot("soniox-spacing-differs")
        try writeLegacy(differs, text: "We met at noon, right after lunch. Okay, right.")
        #expect(
            FileTranscriptStore(root: differs, nowMs: { 0 }).load("seg-1")?.segments.first?.text
                == "We met at noon,right after lunch.")

        let other = try makeTempRoot("soniox-spacing-other")
        try writeLegacy(other, providerId: "openai")
        #expect(
            FileTranscriptStore(root: other, nowMs: { 0 }).load("seg-1")?.segments.last?.text
                == "Okay,right.")
    }

    private struct StoredTurns: Decodable {
        struct Turn: Decodable { var text: String }
        var segments: [Turn]
    }

    /// Over a real backup (`PEBBLE_HISTORY_BACKUP`, a backup root; only read): every Soniox
    /// transcript reads back with the same letters in the same turns, and with no word joined
    /// that Soniox's own text keeps apart. Prints counts only.
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["PEBBLE_HISTORY_BACKUP"] != nil,
            "set PEBBLE_HISTORY_BACKUP to a backup root"))
    func aRealBackupReadsWithEverySpaceBack() throws {
        let root = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PEBBLE_HISTORY_BACKUP"]))
        let store = FileTranscriptStore(root: root, nowMs: { 0 })
        func letters(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        func wordCount(_ turns: [TranscriptSegment]) -> Int {
            turns.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        }
        var soniox = 0
        var changed = 0
        var wordsBefore = 0
        var wordsAfter = 0
        for transcript in store.list() where transcript.providerId == SonioxTranscriptionProvider.providerId {
            soniox += 1
            let stored = try #require(store.loadSpeechTimings(transcript.segmentId))
            #expect(transcript.segments.map { letters($0.text) } == stored.map { letters($0.text) })
            // Nothing left to put back: a second pass over the repaired turns adds no space.
            let again = SegmentTranscript.restoringWordSpaces(
                transcript.segments, from: transcript.text, providerId: transcript.providerId)
            #expect(again == transcript.segments)
            if transcript.segments != stored { changed += 1 }
            wordsBefore += wordCount(stored)
            wordsAfter += wordCount(transcript.segments)
        }
        print(
            "soniox-spacing: \(soniox) Soniox transcripts, \(changed) read back with spaces "
                + "restored, \(wordsAfter - wordsBefore) words separated")
        #expect(soniox > 0)
    }
}
