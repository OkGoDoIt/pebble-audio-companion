import AppDB
import Foundation
import SegmentStore
import StatusUI
import Testing
import WireProtocol

// Today's day-coverage strip, and the two things it used to say that were not true.
//
//  1. It counted VAD-suppressed silence as RECORDED. `LiveTodayDataSource.coverage` built its
//     `SegmentCoverageInput`s with no `frameSampleRanges`, which is the only input from which
//     `CoverageComputer` can separate quiet from audio — so `.quiet` was unreachable from real
//     data (only the artboard ever drew it) and a quiet hour claimed to be an hour of recording.
//     The live screen's timeline has always recut those windows out of the recorded spans using
//     the watch's own `silenceSuppressed` gaps; the day strip now runs the same code.
//
//  2. A conversation that received no audio rendered its duration as "0 sec".
//
// Both are pure mappings, so both are pinned here rather than left to a screenshot.

// `@MainActor` because `LiveTodayDataSource` is — its statics are isolated with it, the same
// way `TodayMappingTests` reaches `conversationRow`.
@Suite("CU · coverage quiet recut") @MainActor
struct CUCoverageQuietRecutTests {

    // MARK: - Fixtures (16 kHz, 20 ms frames: 50 frames and 16 000 samples per second)

    /// 2026-09-08 12:00:00 UTC — comfortably inside the 2026-09-08 logical day (05:00 → 05:00).
    static let noonMs: Int64 = 1_788_868_800_000
    static let zone = "UTC"
    static var dateKey: String { LogicalDay.dateKey(forMs: noonMs, timeZoneID: zone) }

    static func meta(startMs: Int64, seconds: Int, gaps: [GapMeta] = []) -> SegmentMeta {
        SegmentMeta(
            segmentId: "seg-1",
            streamId: 1,
            protocolVersion: 1,
            codecIdRaw: 1,
            channels: 1,
            frameSamples: 320,
            sampleRateHz: 16_000,
            bitRateBps: 16_000,
            frameDurationMs: 20,
            startTimeMs: UInt64(startMs),
            startMonotonicMs: 0,
            receivedAtMs: startMs,
            firstSampleIndex: 0,
            lastSampleIndexExclusive: UInt64(16_000 * seconds),
            frameCount: Int64(seconds * 50),
            gaps: gaps,
            recordedTimeZone: zone
        )
    }

    static func gap(at second: Int, seconds: Int, reason: GapReason) -> GapMeta {
        GapMeta(
            firstMissingSequence: UInt32(second * 50),
            missingFrameCount: UInt32(seconds * 50),
            firstMissingSampleIndex: UInt64(second * 16_000),
            origin: GapMeta.originWatch,
            reasonRaw: Int(reason.rawValue)
        )
    }

    static func coverage(_ metas: [SegmentMeta], nowOffset seconds: Int) -> CoverageDisplay? {
        LiveTodayDataSource.coverage(
            nowMs: noonMs + Int64(seconds) * 1000,
            zone: zone,
            dateKey: dateKey,
            segments: metas,
            pauses: []
        )
    }

    // MARK: - The defect

    /// The reported case, at the scale it was reported: an hour-long meeting in which the watch
    /// sent forty minutes and suppressed twenty. The strip used to say "1 hr recorded".
    @Test func suppressedSilenceIsNotCountedAsRecorded() throws {
        let display = try #require(
            Self.coverage(
                [
                    Self.meta(
                        startMs: Self.noonMs, seconds: 3600,
                        gaps: [Self.gap(at: 1200, seconds: 1200, reason: .silenceSuppressed)])
                ],
                nowOffset: 3600))
        #expect(display.headline == Copy.Today.recorded(Formatting.duration(2_400_000)))
        #expect(display.headline != Copy.Today.recorded(Formatting.duration(3_600_000)))
    }

    /// And the colour it was unreachable in. `.quiet` appearing at all on a real build is the
    /// point of the change, not a side effect of it.
    @Test func quietIsReachableFromRealData() throws {
        let display = try #require(
            Self.coverage(
                [
                    Self.meta(
                        startMs: Self.noonMs, seconds: 600,
                        gaps: [Self.gap(at: 300, seconds: 120, reason: .silenceSuppressed)])
                ],
                nowOffset: 600))
        #expect(display.spans.contains { $0.span.kind == .quiet })
        // Quiet is calm, not a fault: nothing is claimed missing.
        #expect(display.missingText == nil)
    }

    // MARK: - What the recut must not do

    /// Loss is still loss. The quiet pass may only recut recorded time — reclassifying a
    /// transport reset as "quiet" would be the exact confusion this product forbids.
    @Test func lostAudioIsStillLost() throws {
        let display = try #require(
            Self.coverage(
                [
                    Self.meta(
                        startMs: Self.noonMs, seconds: 600,
                        gaps: [Self.gap(at: 300, seconds: 30, reason: .transportReset)])
                ],
                nowOffset: 600))
        #expect(display.spans.contains { $0.span.kind == .missing })
        #expect(display.missingText == Copy.Today.missing(Formatting.duration(30_000)))
        #expect(display.headline == Copy.Today.recorded(Formatting.duration(570_000)))
    }

    /// A gap reason we cannot decode fails closed to loss, never to quiet — the same rule
    /// `CoverageComputer.isVisibleLoss` and `LiveTimeline.silenceWindows` both apply.
    @Test func anUndecodableGapReasonStaysLoss() throws {
        let unknown = GapMeta(
            firstMissingSequence: 0, missingFrameCount: 50 * 30,
            firstMissingSampleIndex: 300 * 16_000,
            origin: GapMeta.originWatch, reasonRaw: 0x7F)
        let display = try #require(
            Self.coverage(
                [Self.meta(startMs: Self.noonMs, seconds: 600, gaps: [unknown])],
                nowOffset: 600))
        #expect(!display.spans.contains { $0.span.kind == .quiet })
        #expect(display.missingText == Copy.Today.missing(Formatting.duration(30_000)))
    }

    /// A day with no suppressed silence is unchanged — the recut is a no-op, not a rounding
    /// difference, so this cannot quietly alter every existing day.
    @Test func aDayWithNoSuppressedSilenceIsUnchanged() throws {
        let display = try #require(
            Self.coverage([Self.meta(startMs: Self.noonMs, seconds: 600)], nowOffset: 600))
        #expect(display.headline == Copy.Today.recorded(Formatting.duration(600_000)))
        #expect(!display.spans.contains { $0.span.kind == .quiet })
    }

    /// Today's strip and the live conversation's strip are now the same computation, so they
    /// cannot disagree about the same minute. Asserted directly, because "they run the same
    /// code" is a claim that only stays true while someone checks it.
    @Test func theDayStripAgreesWithTheLiveConversationStrip() throws {
        let metas = [
            Self.meta(
                startMs: Self.noonMs, seconds: 600,
                gaps: [Self.gap(at: 200, seconds: 100, reason: .silenceSuppressed)])
        ]
        let day = try #require(Self.coverage(metas, nowOffset: 600))
        let live = try #require(
            LiveTimeline.display(
                metas: metas, pauses: [], startMs: Self.noonMs,
                nowMs: Self.noonMs + 600_000,
                timeZone: TimeZone(identifier: Self.zone) ?? .gmt))
        #expect(day.headline == live.headline)
        #expect(day.missingText == live.missingText)
    }
}

// MARK: - "0 sec" is not a length

@Suite("CU · no audio received") @MainActor
struct CUNoAudioReceivedTests {

    /// Five rows in the real library have `endMs == startMs`: a conversation was opened and
    /// nothing ever arrived. "0 sec" reads as a recording too short to bother with.
    @Test func aConversationWithNoAudioSaysSo() {
        #expect(ConversationDuration.label(durationMs: 0) == Copy.Conversation.noAudioReceived)
    }

    /// Only exactly zero. A 400 ms recording also formats as "0 sec", and that is imprecise but
    /// true — audio did arrive, and claiming none did would be the same lie in reverse.
    @Test func realAudioKeepsItsLength() {
        #expect(ConversationDuration.label(durationMs: 400) == Formatting.duration(400))
        #expect(ConversationDuration.label(durationMs: 90_000) == Formatting.duration(90_000))
    }

    /// A live conversation is zero-length for the first second of its life. "No audio received"
    /// over a recording that is starting normally would be alarming and wrong.
    @Test func aLiveConversationIsNeverAccusedOfSilence() {
        #expect(
            ConversationDuration.label(durationMs: 0, isLive: true) == Formatting.duration(0))
    }

    /// The Library row and Today's row are the same sentence, because they call the same
    /// function — the drift this helper exists to prevent.
    @Test func theLibraryRowAndTodaysRowAgree() {
        let row = LibraryRow(
            id: "c1", title: "Nothing arrived", startMs: 1_788_868_800_000,
            endMs: 1_788_868_800_000, dateKey: "2026-09-08")
        #expect(TimeFmt.rowMeta(row).contains(Copy.Conversation.noAudioReceived))

        let display = LiveTodayDataSource.conversationRow(
            ConversationListRow(
                id: "c1", title: "Nothing arrived", startMs: 1_788_868_800_000,
                endMs: 1_788_868_800_000))
        #expect(display.meta.contains(Copy.Conversation.noAudioReceived))
    }
}
