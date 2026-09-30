import Testing

@testable import Transcription

@Suite struct HistorySpokenTurnTests {
    @Test("a turn's preview is one line, cut at a word near 160 characters")
    func preview() {
        #expect(HistorySpokenTurn.preview("  \n ") == nil)
        #expect(HistorySpokenTurn.preview("See you\nat  eight.") == "See you at eight.")
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        let cut = HistorySpokenTurn.preview(long)!
        #expect(cut.hasSuffix("word…"))
        #expect(cut.count <= HistorySpokenTurn.maxCharacters + 1)
    }
}
