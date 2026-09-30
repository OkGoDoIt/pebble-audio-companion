import Foundation
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// The promises on `HistoryDay` (HistoryModels.swift) and the day builder's rules (plan 5.3,
// 7.10), on hand-built days and on seeded fuzzed ones. Every built day is also run through
// `HistoryDayBuilder.honestyViolations`, which re-derives the invariants from coverage alone.

private let zone = "UTC"
private let dateKey = "2026-03-10"
private let dayStart = LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: zone)!.startMs  // 05:00
private let dayEnd = LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: zone)!.endMs

/// Wall clock on the test day: `at(9, 30)` is 09:30; hours past 24 are after midnight.
private func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Int64 {
    dayStart + Int64((hour - 5) * 3_600 + minute * 60 + second) * 1_000
}

private func min(_ n: Int64) -> Int64 { n * 60_000 }

/// A gap record `offsetSeconds` into a recording that starts at sample 0.
private func gap(
    at offsetSeconds: Int64, seconds: Int64, reason: GapReason? = nil, raw: Int? = nil,
    skip: Bool = false
) -> GapMeta {
    let sample = UInt64(offsetSeconds * 16_000)
    return GapMeta(
        firstMissingSequence: UInt32(sample / 320), missingFrameCount: UInt32(seconds * 50),
        firstMissingSampleIndex: sample,
        origin: skip ? GapMeta.originSequenceSkip : GapMeta.originWatch,
        reasonRaw: skip ? nil : (raw ?? reason.map { Int($0.rawValue) }))
}

/// Builds a day from recordings, their states and speech, and checks every promise on it.
private struct Day {
    var segments: [SegmentMeta] = []
    var states: [String: TranscriptionState] = [:]
    var reasons: [String: String] = [:]
    var runs: [HistorySpeechRun] = []
    var pauses: [PauseInterval] = []
    var conversations: [HistoryConversationInput] = []
    var turnPreviews: [HistoryTurnPreview] = []
    var chapters: [HistoryChapterInput] = []
    var followUps: [HistoryFollowUpInput] = []
    var content: [HistoryContentSpanInput] = []
    var deleted: [HistoryDeletedSpanInput] = []
    var windows: [HistoryDayWindow] = [HistoryDayWindow(range: dayStart..<dayEnd, zoneID: zone)]
    var nowMs: Int64?
    var isLive = false
    var rules = HistoryDayRules.default

    /// A recording from `start` to `end` (wall ms), transcribed `state`.
    @discardableResult
    mutating func record(
        _ id: String, _ start: Int64, _ end: Int64, _ state: TranscriptionState = .complete,
        gaps: [GapMeta] = [], conversation: String? = nil, failure: String? = nil
    ) -> SegmentMeta {
        let meta = makeSegment(
            id: id, stream: UInt32(segments.count + 1), startTimeMs: start,
            durationSamples: UInt64(end - start) * 16, gaps: gaps)
        segments.append(meta)
        states[id] = state
        if let failure { reasons[id] = failure }
        if let conversation {
            if let index = conversations.firstIndex(where: { $0.id == conversation }) {
                conversations[index].segmentIds.append(id)
                conversations[index].endMs = end
            } else {
                conversations.append(
                    HistoryConversationInput(
                        id: conversation, startMs: start, endMs: end, title: "Title \(conversation)",
                        segmentIds: [id]))
            }
        }
        return meta
    }

    mutating func speech(_ id: String, _ start: Int64, _ end: Int64) {
        runs.append(HistorySpeechRun(segmentId: id, startMs: start, endMs: end))
    }

    var input: HistoryDayBuilder.Input {
        HistoryDayBuilder.Input(
            dateKey: dateKey, windows: windows,
            segments: segments.map { SegmentCoverageInput(meta: $0) }, pauses: pauses,
            speechRuns: runs,
            segmentStates: segments.compactMap {
                HistorySegmentState(meta: $0, state: states[$0.segmentId], failureReason: reasons[$0.segmentId])
            },
            chapters: chapters, conversations: conversations, turnPreviews: turnPreviews,
            followUps: followUps,
            contentSpans: content, deletedSpans: deleted, nowMs: nowMs, isLive: isLive, rules: rules)
    }

    func build(sourceLocation: SourceLocation = #_sourceLocation) -> HistoryDay {
        let input = self.input
        let day = HistoryDayBuilder.build(input)
        let problems = HistoryDayBuilder.honestyViolations(of: day, input: input)
        #expect(problems.isEmpty, "\(problems)", sourceLocation: sourceLocation)
        return day
    }
}

private extension HistoryDay {
    var gaps: [HistoryGap] {
        items.compactMap { if case .gap(let gap) = $0 { return gap } else { return nil } }
    }
    var cards: [HistoryChapterBlock] {
        items.compactMap { if case .chapter(let block) = $0 { return block } else { return nil } }
    }
    func gaps(_ kind: HistoryGap.Kind) -> [HistoryGap] { gaps.filter { $0.kind == kind } }
    /// "card" or the gap kind, per item, for readable expectations.
    var shape: [String] {
        items.map {
            switch $0 {
            case .chapter: return "card"
            case .gap(let gap): return gap.kind.rawValue
            case .zoneChange: return "zone"
            case .live: return "live"
            }
        }
    }
}

@Suite struct HistoryDayHonestyTests {

    // MARK: - Empty, tiling, edges

    @Test("a day with nothing recorded has no items and no edges")
    func emptyDay() {
        let day = Day().build()
        #expect(day.hasRecordings == false)
        #expect(day.items.isEmpty)
        #expect(day.leadingEdge == nil && day.trailingEdge == nil)
    }

    @Test("one conversation: calm ends become edges, the talk one card")
    func oneConversation() throws {
        var day = Day()
        day.record("a", at(9), at(10), conversation: "c1")
        day.speech("a", at(9, 10), at(9, 50))
        let built = day.build()
        #expect(built.hasRecordings)
        #expect(built.shape == ["card"])
        let card = try #require(built.cards.first)
        #expect(card.startMs == at(9, 10) && card.endMs == at(9, 50))
        // The grouper's title is not the card's: a fallback card is untitled.
        #expect(card.source == .conversation && card.title == nil && card.summary == nil)
        #expect(card.id == "talk-a-\(at(9, 10))")
        // 05:00-09:00 nothing recorded + 10 min of wordless recording (quiet by the 15-min rule).
        #expect(built.leadingEdge == HistoryEdge(atMs: at(9, 10), kind: .notListening))
        #expect(built.trailingEdge == HistoryEdge(atMs: at(9, 50), kind: .notListening))
    }

    @Test("seconds of calm at either end of the day get no edge line")
    func noEdgeForSeconds() throws {
        // 2026-09-23 on the real backup: 19 s of the watch saving power at 5 AM (calm, and a
        // pause never folds) became "Nothing recorded until 5:00 AM" at the top of the day.
        var day = Day()
        day.record("a", at(5), at(12), .pending, gaps: [gap(at: 0, seconds: 19, reason: .powerSave)])
        day.record("b", at(12), dayEnd - 30_000, .pending)
        let built = day.build()
        #expect(built.leadingEdge == nil)
        #expect(built.trailingEdge == nil)
        // A real stretch of calm still has its line.
        var later = Day()
        later.record("a", at(5), at(12), .pending, gaps: [gap(at: 0, seconds: 180, reason: .powerSave)])
        #expect(later.build().leadingEdge == HistoryEdge(atMs: at(5, 3), kind: .notListening))
    }

    @Test("an edge is quiet when the watch heard nothing for most of it")
    func quietEdge() throws {
        var day = Day()
        // Recording from 05:00; the first three hours the watch reported as suppressed silence.
        day.record("a", at(5), at(9), gaps: [gap(at: 0, seconds: 3 * 3_600, reason: .silenceSuppressed)])
        day.speech("a", at(8, 5), at(8, 50))
        let built = day.build()
        #expect(built.leadingEdge?.kind == .quiet)
        #expect(built.leadingEdge?.atMs == at(8, 5))
    }

    // MARK: - Loss

    @Test("strict form: loss outside a card is its own item however short, and names its cause")
    func shortLossStays() throws {
        var day = Day()
        day.rules = HistoryDayRules(carryShortLoss: false)
        day.record(
            "a", at(9), at(11),
            gaps: [gap(at: 3_600, seconds: 10, reason: .transportReset)], conversation: "c")
        day.speech("a", at(9, 10), at(9, 30))
        day.speech("a", at(10, 30), at(10, 50))
        let built = day.build()
        let missing = built.gaps(.audioMissing)
        try #require(missing.count == 1)
        #expect(missing[0].startMs == at(10) && missing[0].endMs == at(10, 0, 10))
        #expect(missing[0].lossCauses == [.connectionReset])
        #expect(missing[0].isOpenable == false)
    }

    @Test("loss inside a talk stretch is the card's missing time, never a separate item")
    func lossInsideCard() throws {
        var day = Day()
        day.record("a", at(9), at(10), gaps: [gap(at: 1_800, seconds: 90, reason: .spoolOverflow)], conversation: "c")
        day.speech("a", at(9, 10), at(9, 30))
        day.speech("a", at(9, 32), at(9, 50))  // 2 min between: not a real pause, no cut
        let built = day.build()
        #expect(built.shape == ["card"])
        #expect(built.cards[0].missingMs == 90_000)
    }

    @Test("loss causes: largest share first, each once, and an undecodable reason names none")
    func lossCauses() throws {
        var day = Day()
        day.rules = HistoryDayRules(carryShortLoss: false)  // the strict form: each its own item
        day.record(
            "a", at(9), at(10),
            gaps: [
                gap(at: 600, seconds: 20, skip: true),
                gap(at: 620, seconds: 40, reason: .spoolOverflow),
                gap(at: 660, seconds: 5, skip: true),
                gap(at: 1_800, seconds: 30, raw: 99),
            ])
        let built = day.build()
        let missing = built.gaps(.audioMissing)
        try #require(missing.count == 2)
        #expect(missing[0].lossCauses == [.watchBufferFull, .phoneMissedAudio])
        #expect(missing[1].lossCauses == [])
        #expect(HistoryDayBuilder.lossCause(of: gap(at: 0, seconds: 1, reason: .micConflict)) == .watchDictation)
        #expect(HistoryDayBuilder.lossCause(of: gap(at: 0, seconds: 1, reason: .userDisabled)) == .stoppedOnWatch)
        #expect(HistoryDayBuilder.lossCause(of: gap(at: 0, seconds: 1, reason: .lowBattery)) == .watchBattery)
        #expect(HistoryDayBuilder.lossCause(of: gap(at: 0, seconds: 1, reason: .codecError)) == .watchAudioFault)
        #expect(HistoryDayBuilder.lossCause(of: gap(at: 0, seconds: 1, reason: .powerSave)) == nil)
    }

    @Test("suppressed silence is quiet, never missing; a skip one silence record covers is quiet too")
    func silenceIsNeverMissing() {
        var day = Day()
        day.record(
            "a", at(9), at(10),
            gaps: [
                gap(at: 600, seconds: 1_200, reason: .silenceSuppressed),
                gap(at: 700, seconds: 60, skip: true),
            ])
        day.speech("a", at(9, 1), at(9, 9))
        day.speech("a", at(9, 40), at(9, 55))
        let built = day.build()
        #expect(built.gaps(.audioMissing).isEmpty)
        #expect(built.gaps(.quiet).contains { $0.startMs == at(9, 9) && $0.endMs == at(9, 40) })
    }

    // MARK: - Not recording

    @Test("time nothing recorded is never quiet, not even a sliver between quiet")
    func offIsNeverQuiet() {
        var day = Day()
        day.record("a", at(9), at(10), gaps: [gap(at: 0, seconds: 3_600, reason: .silenceSuppressed)])
        day.record("b", at(10, 1), at(11), gaps: [gap(at: 0, seconds: 3_540, reason: .silenceSuppressed)])
        day.record("c", at(11), at(11, 30))
        day.speech("c", at(11), at(11, 30))
        day.record("z", at(8), at(8, 30))
        day.speech("z", at(8), at(8, 30))
        let built = day.build()
        let off = built.gaps(.notRecording)
        #expect(off.contains { $0.startMs == at(10) && $0.endMs == at(10, 1) })
    }

    // MARK: - Transcription states

    @Test("a failed or untranscribed recording ends a stretch and is never inside a card")
    func untranscribedNeverInCard() throws {
        var day = Day()
        day.record("a", at(9), at(9, 15), conversation: "c")
        day.record("b", at(9, 15), at(9, 16), .failed, conversation: "c", failure: "quota")
        day.record("d", at(9, 16), at(9, 30), conversation: "c")
        day.record("e", at(9, 30), at(9, 31), .pending, conversation: "c")
        day.record("f", at(9, 31), at(9, 45), conversation: "c")
        day.speech("a", at(9, 10), at(9, 15))
        day.speech("d", at(9, 16), at(9, 30))
        day.speech("f", at(9, 31), at(9, 40))
        let built = day.build()
        #expect(built.shape == ["card", "transcriptionFailed", "card", "notTranscribedYet", "card"])
        let failed = try #require(built.gaps(.transcriptionFailed).first)
        #expect(failed.failureReason == "quota" && failed.isOpenable)
        #expect(built.gaps(.notTranscribedYet).first?.isOpenable == true)
    }

    // MARK: - Pauses

    @Test("the watch's power save is a pause mid-day and part of the edge at the ends")
    func powerSave() {
        var day = Day()
        day.record(
            "a", at(9), at(12),
            gaps: [
                gap(at: 0, seconds: 1_800, reason: .powerSave),
                gap(at: 5_400, seconds: 1_800, reason: .powerSave),
                gap(at: 9_000, seconds: 1_800, reason: .powerSave),
            ])
        day.speech("a", at(9, 30), at(10, 30))
        day.speech("a", at(11), at(11, 30))
        let built = day.build()
        #expect(built.shape == ["card", "paused", "card"])
        #expect(built.gaps(.paused)[0].pausedBy == .watchPowerSave)
        #expect(built.leadingEdge == HistoryEdge(atMs: at(9, 30), kind: .notListening))
        #expect(built.trailingEdge == HistoryEdge(atMs: at(11, 30), kind: .notListening))
    }

    @Test("a lone recorded sliver beside the watch's power save or unrecorded time joins it, so the night is an edge")
    func sliverJoinsTheNight() {
        var day = Day()
        day.record("a", at(9), at(10))
        day.speech("a", at(9), at(10))
        // 10:00-15:00 the watch rests in power save (the record rides on the blip's recording),
        // then a 14-second recording, then nothing.
        let blip = makeSegment(
            id: "blip", stream: 9, startTimeMs: at(10), firstSample: UInt64(5 * 3_600 * 16_000),
            durationSamples: 14 * 16_000,
            gaps: [gap(at: 0, seconds: 5 * 3_600, reason: .powerSave)])
        day.segments.append(blip)
        day.states["blip"] = .pending
        var built = day.build()
        #expect(built.shape == ["card"])
        #expect(built.trailingEdge == HistoryEdge(atMs: at(10), kind: .notListening))

        // Two slivers side by side are not "alone": neither is handed to the night, so both stay
        // (a pending recording never becomes a failed one, so they do not join each other).
        var pair = day
        let second = makeSegment(
            id: "second", stream: 10, startTimeMs: at(15, 0, 14), durationSamples: 100 * 16_000)
        pair.segments.append(second)
        pair.states["second"] = .failed
        built = pair.build()
        #expect(built.gaps(.notTranscribedYet).count == 1 && built.gaps(.transcriptionFailed).count == 1)
        #expect(built.trailingEdge?.atMs == at(15, 1, 54))

        // A card is never a sliver that folds, and a pause the person made takes in nothing.
        var talk = Day()
        talk.record("a", at(9), at(10))
        talk.speech("a", at(9), at(10))
        talk.record("t", at(10), at(10, 1))
        talk.speech("t", at(10), at(10, 1))
        talk.pauses = [PauseInterval(startMs: at(10, 1), endMs: at(11), source: "statusCard")]
        talk.record("q", at(11), at(11, 1), .pending)
        talk.pauses.append(PauseInterval(startMs: at(11, 1), endMs: at(12), source: "statusCard"))
        built = talk.build()
        #expect(built.shape == ["card", "paused", "notTranscribedYet", "paused"])
        #expect(built.cards[0].endMs == at(10, 1))
    }

    @Test("a pause the person made is its own item, even at the end of the day and however short")
    func userPause() {
        var day = Day()
        day.record("a", at(9), at(10))
        day.speech("a", at(9), at(10))
        day.record("b", at(10, 1), at(11))
        day.speech("b", at(10, 1), at(11))
        day.pauses = [
            PauseInterval(startMs: at(10), endMs: at(10, 1), source: PauseSource.liveScreen.rawValue),
            PauseInterval(startMs: at(11), endMs: at(12), source: PauseSource.statusCard.rawValue),
        ]
        let built = day.build()
        #expect(built.shape == ["card", "paused", "card", "paused"])
        #expect(built.gaps(.paused).map(\.pausedBy) == [.you, .you])
        #expect(built.trailingEdge?.atMs == at(12))
        #expect(HistoryDayBuilder.pauseActor(forSource: "schedule") == .timed)
        #expect(HistoryDayBuilder.pauseActor(forSource: "intent") == .you)
        #expect(HistoryDayBuilder.pauseActor(forSource: "settingsSwitch") == .you)
        #expect(HistoryDayBuilder.pauseActor(forSource: "forgetWatch") == .other)
        #expect(HistoryDayBuilder.pauseActor(forSource: "something-old") == .other)
    }

    @Test("recorded audio wins over a pause row covering the same moment, as on the strip")
    func recordedBeatsPause() {
        var day = Day()
        day.record("a", at(9), at(10))
        day.speech("a", at(9), at(10))
        day.pauses = [PauseInterval(startMs: at(9, 30), endMs: at(10, 30), source: "statusCard")]
        let built = day.build()
        #expect(built.shape == ["card", "paused"])
        #expect(built.gaps(.paused)[0].startMs == at(10))
    }

    // MARK: - No conversation: the 15-minute rule

    @Test("wordless recording is its own openable item from 15 minutes, quiet below")
    func noConversationMinimum() {
        var day = Day()
        day.record("a", at(9), at(10, 5))
        day.speech("a", at(9), at(9, 10))
        day.speech("a", at(9, 30), at(9, 40))  // 20 min wordless before: its own item
        day.speech("a", at(9, 50), at(10))  // 10 min wordless before: bridged, then cut there
        var built = day.build()
        // The 10-minute lull stays inside the stretch (no quiet item between two cards), and the
        // cutter cuts at the talk after it: two cards, 20 and 10 minutes, back to back.
        #expect(built.shape == ["card", "noConversation", "card", "card"])
        #expect(built.cards[1].startMs == at(9, 30) && built.cards[1].endMs == at(9, 50))
        #expect(built.cards[2].startMs == at(9, 50) && built.cards[2].endMs == at(10))
        let noConversation = built.gaps(.noConversation)[0]
        #expect(noConversation.isOpenable && noConversation.descriptor == nil)
        #expect(built.trailingEdge?.atMs == at(10))  // the 5-min wordless tail is calm

        // Ten wordless minutes that no talk bridges (a pause follows) are quiet, not an item.
        var paused = Day()
        paused.record("a", at(9), at(9, 40))
        paused.speech("a", at(9), at(9, 30))
        paused.pauses = [PauseInterval(startMs: at(9, 40), endMs: at(10), source: "statusCard")]
        paused.record("b", at(10), at(10, 30))
        paused.speech("b", at(10), at(10, 30))
        built = paused.build()
        #expect(built.shape == ["card", "quiet", "paused", "card"])
        #expect(built.gaps(.quiet)[0].isOpenable == false)
    }

    @Test("two short wordless runs bridged by a short quiet hole count as one run")
    func noConversationBridgesQuietHoles() {
        var day = Day()
        // 09:10-09:18 wordless, 09:18-09:19 silence, 09:19-09:27 wordless: a 17-min run.
        day.record("a", at(9), at(9, 50), gaps: [gap(at: 1_080, seconds: 60, reason: .silenceSuppressed)])
        day.speech("a", at(9), at(9, 10))
        day.speech("a", at(9, 27), at(9, 40))
        let built = day.build()
        #expect(built.shape == ["card", "noConversation", "card"])
        #expect(built.gaps(.noConversation)[0].endMs - built.gaps(.noConversation)[0].startMs == min(17))
    }

    @Test("a no-speech recording is no conversation; a classifier descriptor is carried only when given")
    func noSpeechAndDescriptors() {
        var day = Day()
        day.record("a", at(9), at(9, 30), .noSpeech)
        day.record("b", at(9, 30), at(10))
        day.speech("b", at(9, 30), at(10))  // words, but the classifier says music
        day.content = [HistoryContentSpanInput(startMs: at(9, 30), endMs: at(10), kind: .noConversation, descriptor: "music")]
        day.record("c", at(10), at(10, 10))
        day.speech("c", at(10), at(10, 10))
        let built = day.build()
        #expect(built.gaps(.noConversation).map(\.descriptor) == [nil, "music"])
    }

    // MARK: - Folding under 2 minutes

    @Test("a sliver of nothing recorded between two stretches of one conversation leaves one card")
    func slivers() throws {
        var day = Day()
        day.record("a", at(9), at(9, 30), conversation: "c")
        day.record("b", at(9, 30, 40), at(10), conversation: "c")
        day.speech("a", at(9), at(9, 30))
        day.speech("b", at(9, 30, 40), at(10))
        let built = day.build()
        #expect(built.shape == ["card"])
        #expect(built.cards[0].startMs == at(9) && built.cards[0].endMs == at(10))
    }

    @Test("a short untranscribed recording folds into quiet beside it, never into a card")
    func shortPendingFolds() {
        var day = Day()
        day.record("a", at(9), at(9, 30))
        day.speech("a", at(9), at(9, 10))
        day.record("p", at(9, 30), at(9, 31), .pending)
        day.record("b", at(9, 31), at(10))
        day.speech("b", at(9, 50), at(10))
        let built = day.build()
        // The minute folds into the wordless time around it (never into a card).
        #expect(built.shape == ["card", "noConversation", "card"])
        #expect(built.gaps(.notTranscribedYet).isEmpty)

        var beside = Day()
        beside.record("a", at(9), at(9, 30))
        beside.speech("a", at(9), at(9, 30))
        beside.record("p", at(9, 30), at(9, 31), .pending)
        beside.record("b", at(9, 31), at(10))
        beside.speech("b", at(9, 31), at(10))
        #expect(beside.build().shape == ["card", "notTranscribedYet", "card"])
    }

    // MARK: - Fallback cards

    @Test("fallback cards ignore the grouper: cut only at real pauses, untitled, never forced short")
    func fallbackCutting() throws {
        var day = Day()
        day.record("a", at(9), at(10), conversation: "c1")
        day.record("b", at(10), at(10, 45), conversation: "c2")
        day.speech("a", at(9), at(9, 20))
        day.speech("a", at(9, 22), at(10))  // 2-min pause: no cut
        day.speech("b", at(10), at(10, 10))  // conversation changes here: ignored, no cut
        day.speech("b", at(10, 14), at(10, 30))  // 4-min pause: cut at 10:14
        var built = day.build()
        #expect(built.shape == ["card", "card", "noConversation"])  // 15-min wordless tail
        #expect(built.cards.map(\.title) == [nil, nil])
        #expect(built.cards.map(\.startMs) == [at(9), at(10, 14)])
        #expect(built.cards.map(\.id) == ["talk-a-\(at(9))", "talk-b-\(at(10, 14))"])

        // Two hours with no real pause stays one two-hour card.
        var long = Day()
        long.record("a", at(9), at(11, 5))
        var t = at(9)
        while t < at(11) {
            long.speech("a", t, t + min(2))
            t += min(3)  // one-minute pauses
        }
        built = long.build()
        #expect(built.shape == ["card"])
        #expect(built.cards[0].endMs - built.cards[0].startMs >= min(119))
    }

    @Test("a fallback card's snippet: an early turn of 8+ words, else the longest early one, else the first of 4+")
    func snippets() throws {
        var day = Day()
        day.record("a", at(9), at(10))
        day.speech("a", at(9), at(9, 20))
        day.speech("a", at(9, 30), at(9, 50))
        day.turnPreviews = [
            HistoryTurnPreview(startMs: at(8, 59), text: "Before the card starts here"),
            HistoryTurnPreview(startMs: at(9, 0, 5), text: "Okay."),
            HistoryTurnPreview(startMs: at(9, 1), text: "Yeah, sure."),
            HistoryTurnPreview(startMs: at(9, 2), text: "So the library on Monday then"),
            HistoryTurnPreview(startMs: at(9, 3), text: "So the library on Monday then, at ten, okay?"),
            HistoryTurnPreview(startMs: at(9, 30), text: "Hmm"),
            HistoryTurnPreview(startMs: at(9, 31), text: "Right okay"),
            HistoryTurnPreview(startMs: at(9, 40), text: "this one is late but long enough to use"),
        ]
        var built = day.build()
        // First card: the first early turn of 8+ words. Second: none of 8+ early, so the longest
        // early turn — not the later long one.
        #expect(built.cards.map(\.snippet) == ["So the library on Monday then, at ten, okay?", "Right okay"])
        // No early 8-word turn in the first card either: the longest of its first five minutes.
        day.turnPreviews.remove(at: 4)
        #expect(day.build().cards.first?.snippet == "So the library on Monday then")
        // No turn at all in the first five minutes: the first of 4+ words later in the card.
        day.turnPreviews = [
            HistoryTurnPreview(startMs: at(9, 10), text: "ok"),
            HistoryTurnPreview(startMs: at(9, 11), text: "then we go there"),
        ]
        built = day.build()
        #expect(built.cards.first?.snippet == "then we go there")
        // A script written without spaces: 12 characters is long enough.
        day.turnPreviews = [
            HistoryTurnPreview(startMs: at(9, 0, 10), text: "はい"),
            HistoryTurnPreview(startMs: at(9, 0, 20), text: "来週の月曜日に図書館へ行きます"),
            HistoryTurnPreview(startMs: at(9, 0, 30), text: "That is a very long English sentence with many words"),
        ]
        #expect(day.build().cards.first?.snippet == "来週の月曜日に図書館へ行きます")
        // A chapter never gets one.
        day.chapters = [HistoryChapterInput(id: "ch", startMs: at(9), endMs: at(9, 20), title: "T")]
        #expect(day.build().cards.first?.snippet == nil)
    }

    @Test("a pause, deletion or unrecorded time always ends a stretch")
    func stretchBreakers() {
        var day = Day()
        day.record("a", at(9), at(9, 30), conversation: "c")
        day.record("b", at(9, 35), at(10), conversation: "c")
        day.speech("a", at(9), at(9, 30))
        day.speech("b", at(9, 35), at(10))
        #expect(day.build().shape == ["card", "notRecording", "card"])
        day.pauses = [PauseInterval(startMs: at(9, 30), endMs: at(9, 35), source: "statusCard")]
        #expect(day.build().shape == ["card", "paused", "card"])
        day.pauses = []
        day.deleted = [HistoryDeletedSpanInput(startMs: at(9, 20), endMs: at(9, 40), cause: .user)]
        let built = day.build()
        #expect(built.shape == ["card", "deleted", "card"])
        #expect(built.gaps(.deleted)[0].deletedBy == .user)
    }

    // MARK: - Chapters

    @Test("a chapter takes its range, counts the loss in it, and is cut where the words are unknown")
    func chapters() throws {
        var day = Day()
        day.record("a", at(9), at(10), gaps: [gap(at: 600, seconds: 30, reason: .spoolOverflow)])
        day.record("f", at(10), at(10, 10), .failed)
        day.record("b", at(10, 10), at(11))
        day.speech("a", at(9), at(10))
        day.speech("b", at(10, 10), at(11))
        day.chapters = [
            HistoryChapterInput(id: "ch-1", startMs: at(9), endMs: at(10, 30), title: "Morning", summary: "…"),
        ]
        let built = day.build()
        #expect(built.shape == ["card", "transcriptionFailed", "card", "card"])
        let cards = built.cards
        #expect(cards[0].id == "ch-1" && cards[0].source == .chapter && cards[0].missingMs == 30_000)
        #expect(cards[1].id == "ch-1~\(at(10, 10))" && cards[1].endMs == at(10, 30))
        #expect(cards[2].source == .conversation && cards[2].startMs == at(10, 30))
    }

    // MARK: - Follow-ups

    @Test("follow-ups attach by moment, by an 80% share of a span, or not at all; open first")
    func followUps() throws {
        var day = Day()
        day.record("a", at(9), at(11))
        day.speech("a", at(9), at(9, 30))
        day.speech("a", at(10), at(10, 30))
        day.followUps = [
            .init(id: "done-early", text: "d", done: true, placement: .moment(at(9, 1))),
            .init(id: "open-late", text: "o2", done: false, placement: .moment(at(9, 20))),
            .init(id: "open-early", text: "o1", done: false, placement: .moment(at(9, 5))),
            // 10 min span, 8 in the first card: attached.
            .init(id: "span-80", text: "s", done: false, placement: .span(startMs: at(9, 22), endMs: at(9, 32))),
            // 10 min span, 7 in the second card: not attached.
            .init(id: "span-70", text: "s", done: false, placement: .span(startMs: at(10, 23), endMs: at(10, 33))),
            .init(id: "in-quiet", text: "q", done: false, placement: .moment(at(9, 45))),
            .init(id: "day", text: "x", done: false, placement: .dayOnly),
        ]
        let built = day.build()
        #expect(built.cards[0].followUps.map(\.id) == ["open-early", "open-late", "span-80", "done-early"])
        #expect(built.cards[1].followUps.isEmpty)
    }

    // MARK: - Today

    @Test("today runs to now with no trailing edge; recording, the unsettled tail is the live block")
    func today() throws {
        var day = Day()
        day.nowMs = at(12)
        day.record("a", at(9), at(11))
        day.speech("a", at(9), at(11))
        day.record("p", at(11), at(12), .pending)
        var built = day.build()
        #expect(built.isToday && built.trailingEdge == nil)
        #expect(built.shape == ["card", "notTranscribedYet"])
        #expect(built.items.last?.endMs == at(12))

        day.isLive = true
        built = day.build()
        #expect(built.shape == ["card", "live"])
        guard case .live(let live)? = built.items.last else { throw TestFailure() }
        #expect(live.startMs == at(11) && live.endMs == at(12))

        // The block takes only the unsettled tail: loss before it stays an item of its own.
        var lossy = Day()
        lossy.nowMs = at(12)
        lossy.isLive = true
        lossy.record("a", at(9), at(11, 50), gaps: [gap(at: 9_000, seconds: 30, reason: .transportReset)])
        lossy.speech("a", at(9), at(11))
        lossy.record("p", at(11, 50), at(12), .pending)
        built = lossy.build()
        // The 30 s of loss is carried by the wordless stretch (as its missing time), and the
        // block stops there rather than take it in.
        #expect(built.shape == ["card", "noConversation", "live"])
        #expect(built.gaps(.noConversation)[0].missingMs == 30_000)
        guard case .live(let tail)? = built.items.last else { throw TestFailure() }
        #expect(tail.startMs == at(11, 50) && tail.endMs == at(12))

        // Nothing unsettled: the block marks now and has no length.
        var settled = Day()
        settled.nowMs = at(12)
        settled.isLive = true
        settled.record("a", at(9), at(12))
        settled.speech("a", at(9), at(12))
        built = settled.build()
        #expect(built.shape == ["card", "live"])
        guard case .live(let now)? = built.items.last else { throw TestFailure() }
        #expect(now.startMs == at(12) && now.endMs == at(12))
    }

    // MARK: - Zones

    @Test("a zone change inside the day: a divider where it changes, times keep absolute order")
    func zoneChange() throws {
        let tokyo = "Asia/Tokyo"
        // 09:00 UTC in one zone, then a recording stamped Tokyo two hours later.
        var day = Day()
        var first = day.record("a", at(9), at(10))
        first.recordedTimeZone = zone
        var second = day.record("b", at(11), at(12))
        second.recordedTimeZone = tokyo
        day.segments = [first, second]
        day.speech("a", at(9), at(10))
        day.speech("b", at(11), at(12))
        let timeline = ZoneTimeline(segments: day.segments, currentZoneID: zone)
        day.windows = HistoryDayWindow.from(timeline.windows(of: dateKey))
        try #require(day.windows.count == 2)
        let built = day.build()
        let change = try #require(built.items.first { if case .zoneChange = $0 { return true } else { return false } })
        #expect(change.startMs == at(11))
        #expect(built.cards.map(\.zoneID) == [zone, tokyo])
        #expect(built.zoneID == zone)
    }

    // MARK: - The proposed rule: short loss carried by its neighbour

    @Test("carryShortLoss: a burst of buffer drops is one row with its loss, still counted and named")
    func carryShortLoss() throws {
        var day = Day()
        var drops: [GapMeta] = []
        for second in stride(from: Int64(600), to: 660, by: 4) {
            drops.append(gap(at: second, seconds: 1, reason: .spoolOverflow))
        }
        drops.append(gap(at: 1_800, seconds: 300, reason: .transportReset))  // 5 min: stays an item
        day.record("p", at(9), at(10), .pending, gaps: drops)
        day.record("z", at(8), at(8, 30))
        day.speech("z", at(8), at(8, 30))
        day.rules = HistoryDayRules(carryShortLoss: false)
        #expect(day.build().gaps(.audioMissing).count == 16)
        day.rules = .default
        let built = day.build()
        #expect(built.shape == ["card", "notRecording", "notTranscribedYet", "audioMissing", "notTranscribedYet"])
        let carrier = built.gaps(.notTranscribedYet)[0]
        #expect(carrier.missingMs == 15_000 && carrier.lossCauses == [.watchBufferFull])
        #expect(built.gaps(.audioMissing)[0].lossCauses == [.connectionReset])
    }

    @Test("carryShortLoss never hands loss to unrecorded time or a pause, nor lets it into an edge")
    func carryShortLossLimits() {
        var day = Day()
        day.rules = HistoryDayRules(carryShortLoss: true)
        // A 10 s loss record placed before the recording's first frame, in unrecorded time.
        let meta = makeSegment(
            id: "a", stream: 1, startTimeMs: at(9) - 60_000, firstSample: 960_000,
            durationSamples: UInt64(min(60)) * 16,
            gaps: [gap(at: 0, seconds: 10, reason: .transportReset)])
        day.segments = [meta]
        day.states = ["a": .complete]
        day.speech("a", at(9, 10), at(9, 50))
        let built = day.build()
        #expect(built.gaps(.audioMissing).count == 1)
        #expect(built.leadingEdge?.atMs == at(8, 59))
    }

    // MARK: - Fuzz

    @Test("fuzzed days keep every promise, under both loss rules, past and today")
    func fuzz() {
        var rng = SeededGenerator(seed: 0x4157_0123)
        var itemsSeen = 0
        for round in 0..<250 {
            var day = randomHistoryDay(&rng)
            if round % 5 == 0 {
                day.nowMs = dayStart + Int64.random(in: 60...1_440, using: &rng) * 60_000
                day.isLive = Bool.random(using: &rng)
            }
            for carry in [false, true] {
                day.rules = HistoryDayRules(carryShortLoss: carry)
                let built = day.build()
                itemsSeen += built.items.count
            }
        }
        #expect(itemsSeen > 1_000)
    }
}

private struct TestFailure: Error {}

/// A day of 0-8 recordings with every transcription state and gap reason, speech runs,
/// conversations, pauses, deletions, classifier spans, chapters and follow-ups.
private func randomHistoryDay(_ rng: inout SeededGenerator) -> Day {
    var day = Day()
    var cursor = dayStart + Int64.random(in: 0...600, using: &rng) * 60_000
    let states: [TranscriptionState] = [.complete, .complete, .complete, .noSpeech, .pending, .failed, .running, .disabled]
    var conversation = 0
    for index in 0..<Int.random(in: 0...8, using: &rng) {
        cursor += Int64.random(in: -2...40, using: &rng) * 30_000
        let length = Int64.random(in: 1...60, using: &rng) * 60_000
        let seconds = length / 1_000
        var gaps: [GapMeta] = []
        for _ in 0..<Int.random(in: 0...12, using: &rng) {
            let offset = Int64.random(in: -300...(seconds + 60), using: &rng)
            let span = [1, 2, 5, 30, 90, 200, 900].randomElement(using: &rng)!
            let pick = Int.random(in: 0...10, using: &rng)
            gaps.append(
                pick == 0
                    ? gap(at: max(0, offset), seconds: Int64(span), skip: true)
                    : gap(at: max(0, offset), seconds: Int64(span), raw: pick <= 8 ? pick : 99))
        }
        if Bool.random(using: &rng) { conversation += 1 }
        let id = "s\(index)"
        day.record(
            id, cursor, cursor + length, states.randomElement(using: &rng)!, gaps: gaps,
            conversation: "c\(conversation)", failure: Bool.random(using: &rng) ? "why" : nil)
        var speechAt = cursor
        while speechAt < cursor + length {
            let talk = Int64.random(in: 5...600, using: &rng) * 1_000
            if Bool.random(using: &rng) {
                day.speech(id, speechAt, Swift.min(speechAt + talk, cursor + length))
                day.turnPreviews.append(
                    HistoryTurnPreview(startMs: speechAt, text: ["ok", "yes sure", "one two three four"].randomElement(using: &rng)!))
            }
            speechAt += talk + Int64.random(in: 0...900, using: &rng) * 1_000
        }
        cursor += length
    }
    func randomSpan() -> (Int64, Int64) {
        let start = dayStart + Int64.random(in: 0...1_440, using: &rng) * 60_000
        return (start, start + Int64.random(in: 0...120, using: &rng) * 60_000)
    }
    for _ in 0..<Int.random(in: 0...2, using: &rng) {
        let (start, end) = randomSpan()
        day.pauses.append(
            PauseInterval(
                startMs: start, endMs: Bool.random(using: &rng) ? end : nil,
                source: ["statusCard", "schedule", "forgetWatch"].randomElement(using: &rng)!))
    }
    if Int.random(in: 0...4, using: &rng) == 0 {
        let (start, end) = randomSpan()
        day.deleted.append(HistoryDeletedSpanInput(startMs: start, endMs: end, cause: .retention))
    }
    if Int.random(in: 0...3, using: &rng) == 0 {
        let (start, end) = randomSpan()
        day.content.append(
            HistoryContentSpanInput(startMs: start, endMs: end, kind: .noConversation, descriptor: Bool.random(using: &rng) ? "music" : nil))
    }
    for index in 0..<Int.random(in: 0...2, using: &rng) {
        let (start, end) = randomSpan()
        day.chapters.append(HistoryChapterInput(id: "ch\(index)", startMs: start, endMs: end, title: "T"))
    }
    for index in 0..<Int.random(in: 0...5, using: &rng) {
        let (start, end) = randomSpan()
        day.followUps.append(
            HistoryFollowUpInput(
                id: "f\(index)", text: "t", done: Bool.random(using: &rng),
                placement: Bool.random(using: &rng) ? .moment(start) : .span(startMs: start, endMs: end)))
    }
    return day
}
