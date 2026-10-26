import AppDB
import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import Transcription

@Suite("audio content classifier")
struct AudioContentClassifierTests {
    /// A closed 16 kHz / 20 ms segment of `wallMs`, with `gaps` of withheld quiet in it.
    private func meta(
        wallMs: Int64 = 900_000, gaps: [(startMs: Int64, durationMs: Int64)] = [],
        state: TranscriptionState = .complete, closed: Bool = true
    ) -> SegmentMeta {
        let withheld = gaps.reduce(Int64(0)) { $0 + $1.durationMs }
        var meta = SegmentMeta(
            segmentId: "seg-1",
            streamId: 1,
            protocolVersion: 1,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 9_800,
            frameDurationMs: 20,
            startTimeMs: 1_700_000_000_000,
            startMonotonicMs: 0,
            receivedAtMs: 1_700_000_000_000 + wallMs,
            firstSampleIndex: 0,
            lastSampleIndexExclusive: UInt64(wallMs) * 16,
            headReceivedAtMs: 1_700_000_000_000 + wallMs,
            frameCount: (wallMs - withheld) / 20,
            gaps: gaps.map { gap in
                GapMeta(
                    firstMissingSequence: UInt32(gap.startMs / 20),
                    missingFrameCount: UInt32(gap.durationMs / 20),
                    firstMissingSampleIndex: UInt64(gap.startMs) * 16,
                    origin: GapMeta.originWatch,
                    reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
                )
            },
            closeReason: closed ? .rotated : nil
        )
        meta.transcriptionState = state
        return meta
    }

    private func talk(_ startMs: Int64, _ endMs: Int64, words: Int) -> TranscriptSegment {
        TranscriptSegment(
            // Distinct words per turn: identical turns are what the loop detector looks for.
            text: (0..<words).map { "t\(startMs)w\($0)" }.joined(separator: " "), startMs: startMs,
            endMs: endMs)
    }

    private var start: Int64 { 1_700_000_000_000 }

    @Test("a conversation, then minutes with no words, then one stray word")
    func conversationThenQuietThenAWord() throws {
        // 0-5 min steady talk; 5-12 min nothing; 12:10 one "Okay."; 12-15 min nothing.
        var turns: [TranscriptSegment] = []
        for minute in 0..<5 {
            turns.append(talk(Int64(minute) * 60_000, Int64(minute) * 60_000 + 55_000, words: 120))
        }
        turns.append(TranscriptSegment(text: "Okay.", startMs: 730_000, endMs: 731_000))
        let spans = try #require(AudioContentClassifier.classify(meta: meta(), turns: turns))
        #expect(spans.map(\.kind) == [.conversation, .noConversation])
        #expect(spans[0].startMs == start && spans[0].endMs == start + 300_000)
        #expect(spans[0].wordCount == 600)
        #expect(spans[0].confidence == AudioContentMethod.conversationConfidence)
        // The stray word makes the whole ten minutes "a few words", not ten verdicts.
        #expect(spans[1].startMs == start + 300_000 && spans[1].endMs == start + 900_000)
        #expect(spans[1].descriptor == AudioContentDescriptor.fewWords)
        #expect(spans[1].wordCount == 1)
        #expect(spans.allSatisfy { $0.version == AudioContentMethod.version })
    }

    @Test("wordless minutes carry no descriptor, only 'no conversation'")
    func wordlessHasNoDescriptor() throws {
        let turns = [talk(0, 50_000, words: 80)]
        let spans = try #require(AudioContentClassifier.classify(meta: meta(), turns: turns))
        #expect(spans.last?.kind == .noConversation)
        #expect(spans.last?.descriptor == nil)
        #expect(spans.last?.decidedBy == AudioContentDecider.wordRate)
    }

    @Test("two words a minute is the line: one word a minute is not a conversation")
    func thresholdIsTwoWordsAMinute() throws {
        let sparse = (0..<15).map { minute in
            TranscriptSegment(
                text: "yeah", startMs: Int64(minute) * 60_000 + 10_000,
                endMs: Int64(minute) * 60_000 + 11_000)
        }
        let one = try #require(AudioContentClassifier.classify(meta: meta(), turns: sparse))
        #expect(one.map(\.kind) == [.noConversation])
        let two = (0..<15).map { minute in
            TranscriptSegment(
                text: "yeah \(minute)", startMs: Int64(minute) * 60_000 + 10_000,
                endMs: Int64(minute) * 60_000 + 11_000)
        }
        let spans = try #require(AudioContentClassifier.classify(meta: meta(), turns: two))
        #expect(spans.map(\.kind) == [.conversation])
    }

    @Test("a transcriber loop over quiet audio is not a conversation")
    func loopIsNoConversation() throws {
        // The same sentence thirty times over three minutes, then real talk.
        var turns = (0..<30).map { index in
            TranscriptSegment(
                text: "Que paso que paso ahora mismo", startMs: Int64(index) * 6_000,
                endMs: Int64(index) * 6_000 + 5_000)
        }
        for minute in 3..<15 {
            turns.append(talk(Int64(minute) * 60_000, Int64(minute) * 60_000 + 55_000, words: 100))
        }
        let spans = try #require(AudioContentClassifier.classify(meta: meta(), turns: turns))
        #expect(spans.first?.kind == .noConversation)
        #expect(spans.first?.decidedBy == AudioContentDecider.loop)
        #expect(spans.first?.descriptor == nil)
        #expect(spans.last?.kind == .conversation)
    }

    @Test("a minute faster than anyone talks, made of one phrase, is a loop; fast varied talk is not")
    func implausibleRateLoop() throws {
        // "Yeah. Yeah. Yeah." at 400 words a minute, in long turns the display rule keeps.
        let yeah = (0..<3).map { minute in
            TranscriptSegment(
                text: Array(repeating: "Yeah.", count: 400).joined(separator: " ")
                    + " minute \(minute)",
                startMs: Int64(minute) * 60_000, endMs: Int64(minute) * 60_000 + 60_000)
        }
        let looped = try #require(
            AudioContentClassifier.classify(meta: meta(wallMs: 180_000), turns: yeah))
        #expect(looped.map(\.decidedBy) == [AudioContentDecider.loop])
        // 330 distinct words a minute is implausible too, but it is not repetition.
        let fast = (0..<3).map { minute in
            talk(Int64(minute) * 60_000, Int64(minute) * 60_000 + 60_000, words: 330)
        }
        let talked = try #require(
            AudioContentClassifier.classify(meta: meta(wallMs: 180_000), turns: fast))
        #expect(talked.map(\.kind) == [.conversation])
    }

    @Test("a stray remark with nothing said around it is a few words, not a conversation")
    func strayRemarkIsFewWords() throws {
        // Roger's example: 12 seconds after a long quiet stretch, "It is a good one. Thanks."
        let short = meta(wallMs: 12_000)
        let remark = [TranscriptSegment(text: "It is a good one. Thanks.", startMs: 2_000, endMs: 6_000)]
        let quiet = try #require(
            AudioContentClassifier.classify(meta: short, turns: remark, neighbours: .quiet))
        #expect(quiet.map(\.kind) == [.noConversation])
        #expect(quiet[0].decidedBy == AudioContentDecider.isolatedWords)
        #expect(quiet[0].descriptor == AudioContentDescriptor.fewWords)
        #expect(quiet[0].wordCount == 6)
        // A neighbour that is not transcribed yet: not judged until it is.
        let unknown = try #require(
            AudioContentClassifier.classify(meta: short, turns: remark, neighbours: .unknown))
        #expect(unknown.map(\.kind) == [.conversation])
        // The next recording starts talking straight away: the remark is part of that.
        let talking = try #require(
            AudioContentClassifier.classify(
                meta: short, turns: remark,
                neighbours: AudioContentNeighbours(wordsBefore: 0, wordsAfter: 60)))
        #expect(talking.map(\.kind) == [.conversation])
        // Short is not the same as sparse: 12 seconds with 40 words is talk.
        let burst = [talk(0, 12_000, words: 40)]
        let spoken = try #require(
            AudioContentClassifier.classify(meta: short, turns: burst, neighbours: .quiet))
        #expect(spoken.map(\.kind) == [.conversation])
    }

    @Test("a remark in the middle of a long recording is judged against the minutes around it")
    func strayRemarkInsideASegment() throws {
        // 15 minutes: talk 0-3, nothing 3-8, "Coffee." at 8:30, nothing after.
        var turns = (0..<3).map { minute in
            talk(Int64(minute) * 60_000, Int64(minute) * 60_000 + 55_000, words: 90)
        }
        turns.append(TranscriptSegment(text: "Coffee. Coffee, we'll see.", startMs: 510_000, endMs: 514_000))
        let spans = try #require(
            AudioContentClassifier.classify(meta: meta(), turns: turns, neighbours: .quiet))
        #expect(spans.first?.kind == .conversation && spans.first?.wordCount == 270)
        let remark = try #require(spans.first { $0.decidedBy == AudioContentDecider.isolatedWords })
        #expect(remark.startMs == start + 480_000 && remark.wordCount == 4)
        // Within two minutes of the talk it would have been a pause in that talk instead.
        var near = Array(turns.prefix(3))
        near.append(TranscriptSegment(text: "Coffee. Coffee, we'll see.", startMs: 250_000, endMs: 254_000))
        let joined = try #require(
            AudioContentClassifier.classify(meta: meta(), turns: near, neighbours: .quiet))
        #expect(!joined.contains { $0.decidedBy == AudioContentDecider.isolatedWords })
    }

    @Test("neighbours are read across a short gap only, and an unsettled one is unknown")
    func neighbourContext() {
        var a = meta(wallMs: 600_000)
        a.segmentId = "a"
        var b = meta(wallMs: 600_000)
        b.segmentId = "b"
        b.startTimeMs = a.startTimeMs + 630_000  // 30 s after a ends
        var c = meta(wallMs: 600_000, state: .pending)
        c.segmentId = "c"
        c.startTimeMs = b.startTimeMs + 610_000  // 10 s after b ends, still transcribing
        let segments = [a, b, c]
        let turnsOf: (String) -> [TranscriptSegment]? = { id in
            id == "a" ? [self.talk(560_000, 590_000, words: 25)] : []
        }
        let around = AudioContentClassifier.neighbours(
            of: 1, in: segments, turnsOf: turnsOf, versionOf: { _ in "v" })
        #expect(around.neighbours.wordsBefore == 25)
        #expect(around.neighbours.wordsAfter == nil)
        #expect(around.key == "a:C:v/c:Pending")
        let first = AudioContentClassifier.neighbours(
            of: 0, in: segments, turnsOf: turnsOf, versionOf: { _ in "v" })
        #expect(first.neighbours.wordsBefore == 0)  // nothing before a
    }

    @Test("an AI reading turns talk-rate lyrics into no conversation, but never adds talk")
    func judgementApplies() throws {
        let turns = (0..<7).map { minute in
            talk(Int64(minute) * 60_000, Int64(minute) * 60_000 + 55_000, words: 100)
        }
        let judged = [
            JudgedMinute(m: 1, kind: "music", confidence: 0.95),
            JudgedMinute(m: 2, kind: "music", confidence: 0.97),
            JudgedMinute(m: 3, kind: "tvOrVideo", confidence: 0.9),
            JudgedMinute(m: 4, kind: "music", confidence: 0.85),  // not sure enough
            JudgedMinute(m: 5, kind: "loop", confidence: 0.99),  // the word rules own loops
            JudgedMinute(m: 6, kind: "gibberish", confidence: 0.99),  // not acted on
            JudgedMinute(m: 7, kind: "conversation", confidence: 0.99),  // a quiet minute stays quiet
        ]
        let spans = try #require(
            AudioContentClassifier.classify(
                meta: meta(wallMs: 480_000), turns: turns, neighbours: .quiet, judged: judged))
        #expect(spans.map(\.decidedBy) == ["wordRate", "contentJudge", "contentJudge", "wordRate", "wordRate"])
        #expect(spans.map(\.kind) == [.conversation, .noConversation, .noConversation, .conversation, .noConversation])
        // Lyrics are named, and two minutes of them are one span that still says so; TV is
        // plain "no conversation", a span of its own.
        #expect(spans.map(\.descriptor) == [nil, AudioContentDescriptor.music, nil, nil, nil])
        #expect(spans[1].endMs - spans[1].startMs == 120_000)
        #expect(spans[1].confidence == AudioContentMethod.judgeConfidence)
    }

    @Test("a NoSpeech segment is one no-conversation span with the transcriber as author")
    func noSpeechSegment() throws {
        let spans = try #require(
            AudioContentClassifier.classify(meta: meta(state: .noSpeech), turns: nil))
        #expect(spans.count == 1)
        #expect(spans[0].kind == .noConversation && spans[0].decidedBy == AudioContentDecider.noSpeech)
        #expect(spans[0].endMs - spans[0].startMs == 900_000)
    }

    @Test("nothing is classified that is not settled: open, pending, failed, or missing its file")
    func unsettledIsUnclassified() {
        #expect(AudioContentClassifier.classify(meta: meta(closed: false), turns: []) == nil)
        for state in [TranscriptionState.pending, .running, .uploading, .failed, .disabled] {
            #expect(AudioContentClassifier.classify(meta: meta(state: state), turns: []) == nil)
        }
        // `Complete` without a transcript is a bookkeeping fault, never read as silence.
        #expect(AudioContentClassifier.classify(meta: meta(), turns: nil) == nil)
    }

    @Test("a verdict that straddles a quiet gap is placed on both sides of it, not across it")
    func verdictsSkipGaps() throws {
        // 15 min wall; watch withheld 3:00-6:00 as quiet. Stored audio 0-12 min.
        let gapped = meta(gaps: [(180_000, 180_000)])
        let turns = (0..<12).map { minute in
            talk(Int64(minute) * 60_000, Int64(minute) * 60_000 + 55_000, words: 100)
        }
        let spans = try #require(AudioContentClassifier.classify(meta: gapped, turns: turns))
        #expect(spans.map(\.kind) == [.conversation, .conversation])
        #expect(spans[0].endMs == start + 180_000)
        #expect(spans[1].startMs == start + 360_000 && spans[1].endMs == start + 900_000)
        // Both pieces keep the media stretch they came from, for the masks.
        #expect(spans[0].mediaStartMs == 0 && spans[1].mediaEndMs == 720_000)
        #expect(spans.reduce(0) { $0 + $1.wordCount } == 1_200)
    }

    @Test("a short trailing piece joins the minute before it")
    func trailingPieceJoins() {
        let edges = AudioContentClassifier.windowEdges(mediaSpan: 140_000)
        #expect(edges == [0..<60_000, 60_000..<140_000])
        #expect(AudioContentClassifier.windowEdges(mediaSpan: 20_000) == [0..<20_000])
        #expect(AudioContentClassifier.windowEdges(mediaSpan: 0).isEmpty)
    }
}
