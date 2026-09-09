import AppDB
import Foundation
import SegmentStore
import StatusUI
import Testing
import WireProtocol

// The live conversation's parity with a finished one: the timeline mapping behind the strip at
// the top of the screen, and the snapshot fields the screen's AI affordances hang off.
//
// The timeline is the part with logic in it. It re-windows `CoverageComputer` — which is keyed
// on a logical DAY — onto one conversation's own span, and everything that can go wrong there
// is arithmetic: a stretch dropped at the 5 AM boundary, a gap rendered as a hairline nobody
// can see, and above all loss and quiet being confused for each other, which is the one thing
// this product may never do.

@Suite("live conversation parity")
struct LiveParityTests {

    // MARK: - Fixtures

    /// 2026-09-08 12:00:00 UTC.
    static let noonMs: Int64 = 1_788_868_800_000
    /// 2026-09-08 04:55:00 UTC — five minutes before the 5 AM logical-day boundary.
    static let beforeBoundaryMs: Int64 = 1_788_843_300_000
    /// 2026-09-08 05:10:00 UTC.
    static let afterBoundaryMs: Int64 = 1_788_844_200_000

    /// 16 kHz, 20 ms frames: 50 frames and 16 000 samples per second.
    static func meta(
        id: String = "seg-1", startMs: Int64, seconds: Int, gaps: [GapMeta] = []
    ) -> SegmentMeta {
        SegmentMeta(
            segmentId: id,
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
            recordedTimeZone: "UTC"
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

    static func display(
        metas: [SegmentMeta], pauses: [PauseInterval] = [], startMs: Int64, seconds: Int
    ) -> LiveTimelineDisplay? {
        LiveTimeline.display(
            metas: metas, pauses: pauses, startMs: startMs,
            nowMs: startMs + Int64(seconds) * 1000,
            timeZone: TimeZone(identifier: "UTC") ?? .gmt)
    }

    // MARK: - Loss is explicit

    /// The whole reason the live screen gets a timeline at all: a person watching a recording
    /// has to be able to see that something went missing while it was happening.
    @Test func lostAudioIsDrawnAndNamed() throws {
        let timeline = try #require(
            Self.display(
                metas: [
                    Self.meta(
                        startMs: Self.noonMs, seconds: 600,
                        gaps: [Self.gap(at: 300, seconds: 30, reason: .transportReset)])
                ],
                startMs: Self.noonMs, seconds: 600))

        #expect(timeline.stripSpans.contains { $0.kind == .missing })
        #expect(timeline.missingText == Copy.Today.missing(Formatting.duration(30_000)))
        // 600 s of extent minus the 30 s that never arrived.
        #expect(timeline.headline == Copy.Today.recorded(Formatting.duration(570_000)))
    }

    /// Q6: known silence is not loss. A `silenceSuppressed` gap is the watch saving battery on a
    /// quiet room, and drawing it amber would tell someone their recording broke when it did
    /// not. It is not audio either — the headline counts only what actually arrived, or a quiet
    /// meeting would claim an hour of recording it never made.
    @Test func suppressedSilenceIsQuietAndNeitherLossNorAudio() throws {
        let timeline = try #require(
            Self.display(
                metas: [
                    Self.meta(
                        startMs: Self.noonMs, seconds: 600,
                        gaps: [Self.gap(at: 300, seconds: 120, reason: .silenceSuppressed)])
                ],
                startMs: Self.noonMs, seconds: 600))

        #expect(!timeline.stripSpans.contains { $0.kind == .missing })
        #expect(timeline.missingText == nil)
        #expect(timeline.stripSpans.contains { $0.kind == .quiet })
        // 600 s of extent, 120 s of it skipped as silence.
        #expect(timeline.headline == Copy.Today.recorded(Formatting.duration(480_000)))
    }

    /// The quiet pass may only recut RECORDED time. Reclassifying a gap or a pause as quiet
    /// would be inventing silence nobody reported.
    @Test func theQuietPassNeverEatsLossOrAPause() {
        let base: [AppDB.CoverageSpan] = [
            AppDB.CoverageSpan(kind: .missing, startMs: 0, endMs: 100),
            AppDB.CoverageSpan(kind: .paused, startMs: 100, endMs: 200),
            AppDB.CoverageSpan(kind: .recorded, startMs: 200, endMs: 300),
        ]
        let result = LiveTimeline.applyingQuiet(base, silence: [0..<300])
        #expect(result.filter { $0.kind == .missing }.map(\.durationMs) == [100])
        #expect(result.filter { $0.kind == .paused }.map(\.durationMs) == [100])
        #expect(result.filter { $0.kind == .quiet }.map(\.durationMs) == [100])
        #expect(!result.contains { $0.kind == .recorded })
    }

    /// A gap reason we cannot decode is loss, never quiet — the fail-closed half of the same
    /// rule `CoverageComputer.isVisibleLoss` applies.
    @Test func anUnknownGapReasonIsNotTreatedAsQuiet() {
        let unknown = GapMeta(
            firstMissingSequence: 0, missingFrameCount: 50, firstMissingSampleIndex: 16_000,
            origin: GapMeta.originWatch, reasonRaw: 0x7F)
        let windows = LiveTimeline.silenceWindows(
            [Self.meta(startMs: Self.noonMs, seconds: 600, gaps: [unknown])])
        #expect(windows.isEmpty)
    }

    /// Plan 6.1: paused is its own state, never missing. A pause the person asked for must not
    /// read as the app losing their audio.
    @Test func aPausedWindowIsPausedNotMissing() throws {
        let timeline = try #require(
            Self.display(
                metas: [Self.meta(startMs: Self.noonMs, seconds: 300)],
                pauses: [
                    PauseInterval(
                        startMs: Self.noonMs + 300_000, endMs: Self.noonMs + 600_000,
                        source: PauseSource.liveScreen.rawValue)
                ],
                startMs: Self.noonMs, seconds: 600))

        #expect(timeline.stripSpans.contains { $0.kind == .paused })
        #expect(!timeline.stripSpans.contains { $0.kind == .missing })
        #expect(timeline.missingText == nil)
    }

    // MARK: - The re-windowing itself

    /// Every moment of the conversation is accounted for by exactly one span, edge to edge.
    /// A hole here would be time the strip silently declines to describe.
    @Test func spansCoverTheWholeConversationContiguously() throws {
        let timeline = try #require(
            Self.display(
                metas: [
                    Self.meta(
                        startMs: Self.noonMs, seconds: 600,
                        gaps: [Self.gap(at: 120, seconds: 10, reason: .spoolOverflow)])
                ],
                startMs: Self.noonMs, seconds: 600))

        let ranges = timeline.stripSpans.map(\.range)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == 1)
        for (left, right) in zip(ranges, ranges.dropFirst()) {
            #expect(left.upperBound == right.lowerBound)
        }
    }

    /// `CoverageComputer` is keyed on a logical day (5 AM → 5 AM), so a conversation running
    /// through the boundary is computed once per day it touches. The pieces have to come back
    /// as ONE stretch — otherwise a recording that happened to start at 4:55 AM would show a
    /// seam at five o'clock that nothing in the world corresponds to.
    @Test func aConversationAcrossTheDayBoundaryIsOneStretch() throws {
        let seconds = Int((Self.afterBoundaryMs - Self.beforeBoundaryMs) / 1000)
        let timeline = try #require(
            Self.display(
                metas: [Self.meta(startMs: Self.beforeBoundaryMs, seconds: seconds)],
                startMs: Self.beforeBoundaryMs, seconds: seconds))

        #expect(timeline.stripSpans.count == 1)
        #expect(timeline.stripSpans.first?.kind == .recorded)
        #expect(timeline.headline == Copy.Today.recorded(Formatting.duration(15 * 60_000)))
    }

    /// Nothing captured, nothing paused, nothing lost — so there is nothing to say, and the
    /// screen shows no card rather than a blank grey bar pretending to be information.
    @Test func anEmptyWindowProducesNoCard() {
        #expect(Self.display(metas: [], startMs: Self.noonMs, seconds: 600) == nil)
    }

    /// A window that has not opened yet (the clock jitter between a conversation's start and
    /// the first refresh) must not divide by zero or invert.
    @Test func aZeroLengthWindowProducesNoCard() {
        #expect(Self.display(metas: [], startMs: Self.noonMs, seconds: 0) == nil)
    }

    // MARK: - What the screen hangs its affordances off

    /// The parity contract in one assertion: the screen's summary, Ask, Notes and Follow-ups
    /// all address `conversationId`, so a snapshot without one is a screen with nothing on it.
    /// The demo snapshot is what previews and `-demo-data` render, so it has to carry the same
    /// fields the live source now fills in.
    @Test func theDemoSnapshotCarriesEverythingTheScreenNeeds() {
        let demo = LiveSnapshot.demo(isLive: true)
        #expect(!demo.conversationId.isEmpty)
        #expect(demo.summary?.isEmpty == false)
        #expect(demo.timeline != nil)
    }

    /// No live conversation means no id — which is exactly what the bottom bar disables on,
    /// rather than opening Ask scoped to a conversation that does not exist. This is the shape
    /// `LiveTodayDataSource.refreshLive` publishes the moment a recording ends, which is why the
    /// screen keeps the last id it saw rather than reading this one.
    @Test func aSnapshotWithNoRecordingHasNoConversation() {
        let idle = LiveSnapshot(startedLine: "", isLive: false, items: [])
        #expect(idle.conversationId.isEmpty)
        #expect(idle.summary == nil)
        #expect(idle.timeline == nil)
    }

    /// The demo's paused/stopped phase is the "recording ended" state the screen now renders
    /// instead of a Live badge it no longer has and a Pause button with nothing to pause: the
    /// id survives, so [Open Conversation] and the AI actions still address something.
    @Test func theEndedDemoSnapshotStillNamesItsConversation() {
        let ended = LiveSnapshot.demo(isLive: false)
        #expect(!ended.isLive)
        #expect(!ended.conversationId.isEmpty)
    }

    // The two tests that used to close this suite pinned the Pause/Stop sublines ("ends here ·
    // resume anytime" / "ends here · recording off") and the spoken form built from them. Both
    // the Pause button and its sublines are gone: the bar offers one Stop, so there is no
    // second control to be told apart from and nothing left for a caption to disambiguate.
    // `theEndedDemoSnapshotStillNamesItsConversation` above already covers what Stop leaves
    // behind.
}
