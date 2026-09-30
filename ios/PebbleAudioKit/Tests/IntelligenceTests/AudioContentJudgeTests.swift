import AppDB
import Foundation
import Testing
import Transcription

@testable import Intelligence

@Suite("audio content judge")
struct AudioContentJudgeTests {
    @Test("turns are grouped by the minute their middle falls in, with speaker labels")
    func input() throws {
        let turns = [
            TranscriptSegment(text: "Hello there.", startMs: 1_000, endMs: 3_000, speaker: "1"),
            TranscriptSegment(text: "Hi.", startMs: 4_000, endMs: 5_000, speaker: "2"),
            TranscriptSegment(text: "  ", startMs: 70_000, endMs: 71_000),
            TranscriptSegment(text: "Lift up my hands.", startMs: 125_000, endMs: 130_000),
        ]
        let text = try #require(AudioContentJudge.input(turns: turns))
        #expect(text == "[m0]\nS1: Hello there.\nS2: Hi.\n\n[m2]\nLift up my hands.")
        #expect(AudioContentJudge.input(turns: []) == nil)
    }

    @Test("a reply is read leniently and bad entries are dropped")
    func parse() {
        let reply = """
            Here you go: {"minutes":[{"m":0,"kind":"conversation","confidence":0.97},
            {"m":2,"kind":"music","confidence":1.4},{"kind":"music"},{"m":-1,"kind":"loop"}]}
            """
        #expect(
            AudioContentJudge.parse(reply) == [
                JudgedMinute(m: 0, kind: "conversation", confidence: 0.97),
                JudgedMinute(m: 2, kind: "music", confidence: 1),
            ])
        #expect(AudioContentJudge.parse("no json here") == nil)
        #expect(AudioContentJudge.parse("{\"other\": 1}") == [])
    }

    @Test("the key moves with the transcript")
    func key() {
        #expect(AudioContentJudge.inputKey(transcriptVersion: "a") != AudioContentJudge.inputKey(transcriptVersion: "b"))
    }
}
