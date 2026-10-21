import Foundation
import SegmentStore
import Testing

@testable import AppDB

// A watch that has just been reset counts from its own epoch, 2010-01-01, until a phone sets
// its time, and a stream begun then carries that birth clock on every recording in it. The app
// filed those recordings in 2010: on a real backup, 38 of them, and day recaps keyed
// 2009-12-31 and 2010-01-01. Every sample → wall mapping now places such a recording at its
// arrival (`SegmentMeta.sampleClockAnchorMs`).

@Suite("a watch clock that was never set")
struct UnsetWatchClockTests {
    /// The watch's 2010 epoch plus the 12 s it had been up.
    static let unsetBirth: Int64 = 1_262_304_012_425
    /// Fifteen minutes of samples, 20 h into the stream.
    static let first: UInt64 = 20 * 3_600 * 16_000
    static let span: UInt64 = 15 * 60 * 16_000
    static let arrival: Int64 = 1_789_424_563_703

    static func recording(birth: Int64, arrival: Int64 = arrival) -> SegmentMeta {
        var meta = makeSegment(
            id: "seg-1", stream: 7, startTimeMs: birth, firstSample: first, durationSamples: span,
            close: .rotated, tz: "UTC")
        meta.receivedAtMs = arrival
        meta.closedAtMs = arrival + Int64(span / 16)
        return meta
    }

    @Test("its recordings are placed at their arrival, and every mapping agrees")
    func placedAtArrival() {
        let meta = Self.recording(birth: Self.unsetBirth)
        #expect(meta.startWallMs == Self.arrival)
        #expect(ConversationGrouper.segmentStartMs(meta) == Self.arrival)
        #expect(ConversationGrouper.segmentEndMs(meta) == Self.arrival + 900_000)
        // A gap a minute in sits a minute after arrival, on the same clock as the start.
        #expect(
            ConversationGrouper.wallMs(ofSample: Self.first + 60 * 16_000, in: meta)
                == Self.arrival + 60_000)
        #expect(LogicalDay.dateKey(forMs: meta.startWallMs, timeZoneID: "UTC").hasPrefix("2026-"))
        // The sidecar keeps what the watch sent.
        #expect(meta.startTimeMs == UInt64(Self.unsetBirth))
    }

    @Test("a set clock is left exactly as the watch reported it")
    func setClockUntouched() {
        // A healthy stream: born 20 h before this recording, which arrived 3 s after it began.
        let birth = Self.arrival - 20 * 3_600_000 - 3_000
        let meta = Self.recording(birth: birth)
        #expect(meta.sampleClockAnchorMs == birth)
        #expect(meta.startWallMs == Self.arrival - 3_000)
    }
}
