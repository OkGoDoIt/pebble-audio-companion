import Foundation
import GRDB
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

@Suite struct ConversationGrouperTests {
    let t0 = testEpochMs

    func group(
        _ segments: [SegmentMeta], pauses: [PauseInterval] = [], open: String? = nil,
        previous: [GroupedConversation]? = nil
    ) -> [GroupedConversation] {
        ConversationGrouper.group(
            segments: segments, pauses: pauses, openSegmentId: open,
            fallbackTimeZoneID: "UTC", previous: previous)
    }

    @Test func sameStreamRotationChainsWhenSegmentsAbut() {
        // What the stream-id clause is actually for: a 15-min rotation hands straight over,
        // so the successor abuts its predecessor and stays in the same conversation.
        let a = makeSegment(
            id: "a", stream: 7, startTimeMs: t0, durationSamples: minutesSamples(10))
        let b = makeSegment(
            id: "b", stream: 7, startTimeMs: t0, firstSample: minutesSamples(10),
            durationSamples: minutesSamples(5))
        let convos = group([a, b])
        #expect(convos.count == 1)
        #expect(convos[0].id == "conv-a")
        #expect(convos[0].memberSegmentIds == ["a", "b"])
        #expect(convos[0].startMs == t0)
        #expect(convos[0].endMs == t0 + minutesMs(15))
    }

    @Test func sameStreamDoesNotChainAcrossARealBreak() {
        // A Pebble stream id survives a long silent disconnect, so "same stream" cannot mean
        // "same conversation" on its own. Roger's library had 34 breaks of 5 min to 10.5 HOURS
        // glued back together by the unbounded clause, collapsing 438 segments into 17
        // conversations of up to 53 h. Past the 5-minute window it is a new conversation.
        let a = makeSegment(
            id: "a", stream: 7, startTimeMs: t0, durationSamples: minutesSamples(10))
        let b = makeSegment(
            id: "b", stream: 7, startTimeMs: t0, firstSample: minutesSamples(18),
            durationSamples: minutesSamples(5))
        let convos = group([a, b])
        #expect(convos.map(\.memberSegmentIds) == [["a"], ["b"]])
        #expect(convos[0].endMs == t0 + minutesMs(10))
    }

    @Test func differentStreamsChainWithinFiveMinutes() {
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10))
        let b = makeSegment(
            id: "b", stream: 2, startTimeMs: t0 + minutesMs(13),
            durationSamples: minutesSamples(4))
        let convos = group([a, b])
        #expect(convos.count == 1)
        #expect(convos[0].memberSegmentIds == ["a", "b"])
    }

    @Test func moreThanFiveMinutesOfNoAudioSplits() {
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10))
        let b = makeSegment(
            id: "b", stream: 2, startTimeMs: t0 + minutesMs(16),
            durationSamples: minutesSamples(4))
        let convos = group([a, b])
        #expect(convos.map(\.id) == ["conv-a", "conv-b"])
        #expect(convos[0].endMs == t0 + minutesMs(10))
        #expect(convos[1].startMs == t0 + minutesMs(16))
    }

    @Test func userStopSplitsEvenWithinFiveMinutes() {
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10),
            close: userStopClose)
        let b = makeSegment(
            id: "b", stream: 2, startTimeMs: t0 + minutesMs(11),
            durationSamples: minutesSamples(4))
        #expect(group([a, b]).map(\.id) == ["conv-a", "conv-b"])

        // A non-user stop reason (policy) does NOT force a split.
        let aPolicy = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10),
            close: CloseReasonMeta(
                kind: CloseReasonMeta.kindStopped,
                stopReasonRaw: Int(StopReason.policy.rawValue)))
        #expect(group([aPolicy, b]).count == 1)
    }

    @Test func pauseJournalEntryBetweenSegmentsSplitsEvenWithinFiveMinutes() {
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10))
        let aEnd = t0 + minutesMs(10)
        let b = makeSegment(
            id: "b", stream: 2, startTimeMs: aEnd + minutesMs(2),
            durationSamples: minutesSamples(4))

        // Without the pause the pair chains …
        #expect(group([a, b]).count == 1)
        // … a pause interval in the between-segments window splits it.
        let pause = PauseInterval(startMs: aEnd + 10_000, endMs: aEnd + 40_000, source: "intent")
        #expect(group([a, b], pauses: [pause]).map(\.id) == ["conv-a", "conv-b"])
        // An OPEN pause (endMs nil) started between the segments splits too.
        let open = PauseInterval(startMs: aEnd + 10_000, endMs: nil, source: "statusCard")
        #expect(group([a, b], pauses: [open]).count == 2)
    }

    @Test func singleSegmentIsNeverSplit() {
        // One reattached segment spanning 30 min with internal loss, silence, and even a
        // pause interval inside its span: the rules apply between segments, never within one.
        let seg = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(30),
            gaps: [
                lossGap(atSample: minutesSamples(5), minutes: 10),
                silenceGap(atSample: minutesSamples(20), minutes: 3),
            ])
        let pauseInside = PauseInterval(
            startMs: t0 + minutesMs(10), endMs: t0 + minutesMs(12), source: "liveScreen")
        let convos = group([seg], pauses: [pauseInside])
        #expect(convos.count == 1)
        #expect(convos[0].memberSegmentIds == ["a"])
        #expect(convos[0].endMs == t0 + minutesMs(30))
    }

    @Test func liveWhileLastMemberIsTheOpenSegment() throws {
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10))
        let b = makeSegment(
            id: "b", stream: 1, startTimeMs: t0, firstSample: minutesSamples(11),
            durationSamples: minutesSamples(2), close: nil)
        #expect(group([a, b], open: "b")[0].isLive)
        #expect(!group([a, b], open: nil)[0].isLive)
        // Open segment in an OLDER conversation does not mark the newer one live.
        let c = makeSegment(
            id: "c", stream: 9, startTimeMs: t0 + minutesMs(30),
            durationSamples: minutesSamples(1))
        let convos = group([a, b, c], open: "b")
        #expect(convos.count == 2)
        #expect(convos[0].isLive && !convos[1].isLive)
    }

    @Test func timezoneComesFromFirstMemberWithDeviceFallback() {
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(1),
            tz: "America/New_York")
        let b = makeSegment(
            id: "b", stream: 1, startTimeMs: t0, firstSample: minutesSamples(2),
            durationSamples: minutesSamples(1), tz: "Asia/Tokyo")
        #expect(group([a, b])[0].timeZoneID == "America/New_York")
        // First member without the field (pre-rebuild file) falls back.
        let legacy = makeSegment(
            id: "c", stream: 2, startTimeMs: t0 + minutesMs(60),
            durationSamples: minutesSamples(1))
        #expect(group([legacy])[0].timeZoneID == "UTC")
    }

    @Test func rebuildIsDeterministicAndIdempotent() async throws {
        let db = try AppDatabase.inMemory()
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10))
        let b = makeSegment(
            id: "b", stream: 2, startTimeMs: t0 + minutesMs(12),
            durationSamples: minutesSamples(4))
        let c = makeSegment(
            id: "c", stream: 3, startTimeMs: t0 + minutesMs(60),
            durationSamples: minutesSamples(5))

        let first = try await ConversationGrouper.rebuild(
            segments: [a, b, c], pauses: [], openSegmentId: nil,
            fallbackTimeZoneID: "UTC", db: db)
        let second = try await ConversationGrouper.rebuild(
            segments: [a, b, c], pauses: [], openSegmentId: nil,
            fallbackTimeZoneID: "UTC", db: db)
        #expect(first == second)
        #expect(first.map(\.id) == ["conv-a", "conv-c"])

        let persisted = try await db.reader.read { try ConversationGrouper.fetchAll($0) }
        #expect(persisted == first)
        let memberCount = try await db.reader.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM conversation_segments") ?? -1
        }
        #expect(memberCount == 3)
    }

    @Test func previousGroupingKeepsIdStableWhenFirstMemberIsDeleted() {
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10))
        let b = makeSegment(
            id: "b", stream: 1, startTimeMs: t0, firstSample: minutesSamples(11),
            durationSamples: minutesSamples(4))
        let before = group([a, b])
        #expect(before.map(\.id) == ["conv-a"])
        // Retention deletes "a"; with the previous grouping the id survives.
        let after = group([b], previous: before)
        #expect(after.map(\.id) == ["conv-a"])
        #expect(after[0].memberSegmentIds == ["b"])
        // Without it, the natural deterministic id applies.
        #expect(group([b]).map(\.id) == ["conv-b"])
    }
}
