import Foundation
import Testing

// Opening a conversation at a wall-clock moment (History plan 7.9).

@Suite("history moment: the row a moment lands on")
struct HistoryMomentRowTests {
    /// Rows at 10:00:00, 10:01:00 (quiet), 10:05:00, 10:06:00, as epoch ms offsets from `t0`.
    static let t0: Int64 = 1_727_690_400_000

    static func at(_ offsetMs: Int64) -> Date {
        Date(timeIntervalSince1970: Double(t0 + offsetMs) / 1000)
    }

    static func turn(_ id: String, _ offsetMs: Int64?) -> TranscriptItem {
        .turn(
            TranscriptTurn(
                id: id, speakerLabel: "S1", name: "Roger", role: .you, text: id,
                startedAt: offsetMs.map(at)))
    }

    static func quiet(_ id: String, _ offsetMs: Int64) -> TranscriptItem {
        .quiet(TranscriptMarker(id: id, text: "quiet for 4 min", startedAt: at(offsetMs)))
    }

    static let transcript: [TranscriptItem] = [
        turn("a", 0),
        quiet("q", 60_000),
        turn("b", 300_000),
        turn("c", 360_000),
    ]

    private func row(_ offsetMs: Int64, in transcript: [TranscriptItem] = transcript) -> String? {
        MomentResolver.rowIndex(in: transcript, atWallMs: Self.t0 + offsetMs)
            .map { transcript[$0].id }
    }

    @Test func beforeTheFirstRowLandsOnTheFirst() {
        #expect(row(-3_600_000) == "a")
    }

    @Test func exactlyOnARowLandsOnIt() {
        #expect(row(0) == "a")
        #expect(row(300_000) == "b")
    }

    @Test func betweenRowsLandsOnTheOneBefore() {
        #expect(row(30_000) == "a")
        #expect(row(330_000) == "b")
    }

    /// Inside a quiet stretch: the marker that says so, not the words before it.
    @Test func insideAGapLandsOnTheMarkerThatDescribesIt() {
        #expect(row(200_000) == "q")
    }

    /// A gap with no marker (between two members, say) lands on the last words before it.
    @Test func insideAnUnmarkedGapLandsOnTheLastRowBeforeIt() {
        let transcript = [Self.turn("a", 0), Self.turn("b", 3_600_000)]
        #expect(row(1_800_000, in: transcript) == "a")
    }

    @Test func afterTheLastRowLandsOnTheLast() {
        #expect(row(86_400_000) == "c")
    }

    @Test func anEmptyTranscriptHasNowhereToLand() {
        #expect(MomentResolver.rowIndex(in: [], atWallMs: Self.t0) == nil)
    }

    /// Rows with no stamp (a mock fixture, an untimed tail) are not compared; if nothing has a
    /// stamp there is nothing to land on.
    @Test func untimedRowsAreSkipped() {
        let untimed = [Self.turn("x", nil), Self.turn("y", nil)]
        #expect(MomentResolver.rowIndex(in: untimed, atWallMs: Self.t0) == nil)
        let mixed = [Self.turn("x", nil), Self.turn("a", 0), Self.turn("y", nil)]
        #expect(row(500, in: mixed) == "a")
    }

    /// By time, not by position: an out-of-order row does not capture the landing.
    @Test func theLatestStampAtOrBeforeWinsWhateverItsPosition() {
        let transcript = [
            Self.turn("a", 0), Self.turn("b", 600_000), Self.turn("stray", 60_000),
            Self.turn("c", 1_200_000),
        ]
        #expect(row(700_000, in: transcript) == "b")
        #expect(row(100_000, in: transcript) == "stray")
    }

    /// Equal stamps: the later row going back, the earlier row going forward.
    @Test func equalStampsResolveToTheLastBeforeAndTheFirstAfter() {
        let transcript = [
            Self.turn("a1", 0), Self.turn("a2", 0), Self.turn("b1", 60_000),
            Self.turn("b2", 60_000),
        ]
        #expect(row(10, in: transcript) == "a2")
        #expect(row(-10, in: transcript) == "a1")
    }

    /// A 24-hour conversation is thousands of rows; the lookup is one pass.
    @Test func aDayLongTranscriptResolvesToTheRightRow() {
        let transcript = (0..<6_000).map { Self.turn("r\($0)", Int64($0) * 14_400) }
        #expect(row(12 * 3_600_000 + 1, in: transcript) == "r3000")
        #expect(row(24 * 3_600_000, in: transcript) == "r5999")
    }
}
