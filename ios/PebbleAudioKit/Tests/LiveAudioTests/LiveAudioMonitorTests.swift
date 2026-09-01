import Foundation
import SegmentStore
import Testing

@testable import LiveAudio

// Port of `app/src/commonTest/.../LiveAudioMonitorTest.kt` — all 8 cases, same names.

/// Fake decoder: byte value of the frame's first byte selects loud sine vs silence.
private struct FakeDecoder: LiveFrameDecoder {
    func decode(_ frames: [[UInt8]]) async -> [Int16] {
        var out = [Int16](repeating: 0, count: frames.count * 320)
        for (frameIndex, payload) in frames.enumerated() {
            let loud = !payload.isEmpty && payload[0] != 0
            if loud {
                for i in 0..<320 {
                    out[frameIndex * 320 + i] = Int16(sin(2 * Double.pi * Double(i) / 32.0) * 8000)
                }
            }
        }
        return out
    }
}

private struct LowSpeechDecoder: LiveFrameDecoder {
    func decode(_ frames: [[UInt8]]) async -> [Int16] {
        [Int16](repeating: 120, count: frames.count * 320)
    }
}

/// A clock the test moves by hand, so "time passed and nothing arrived" is expressible at all.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _nowMs: Int64

    init(nowMs: Int64) { _nowMs = nowMs }

    var nowMs: Int64 {
        get { lock.withLock { _nowMs } }
        set { lock.withLock { _nowMs = newValue } }
    }
}

private final class CountingDecoder: LiveFrameDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var _decodeCalls = 0
    var decodeCalls: Int { lock.withLock { _decodeCalls } }

    func decode(_ frames: [[UInt8]]) async -> [Int16] {
        lock.withLock { _decodeCalls += 1 }
        return await FakeDecoder().decode(frames)
    }
}

private func frames(_ count: Int, loud: Bool) -> [SegmentFrame] {
    (0..<count).map { index in
        SegmentFrame(
            sequence: UInt32(index),
            sampleIndex: UInt64(index * 320),
            payload: [UInt8](repeating: loud ? 1 : 0, count: 25)
        )
    }
}

@Suite struct LiveAudioMonitorTests {

    @Test func loudFramesBecomeRecordedBars() async {
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { 100_000 })
        await monitor.onFrames(segmentId: "seg-1", frames: frames(25, loud: true), receivedAtMs: 100_000)

        await monitor.processPending()

        let bars = await monitor.bars
        #expect(!bars.isEmpty, "expected bars from 25 frames (500 ms)")
        #expect(bars.allSatisfy { $0.state == .recorded })
        #expect(bars.allSatisfy { $0.amplitude > 0.1 })
        #expect(bars.first?.segmentId == "seg-1")
    }

    @Test func quietFramesBecomeSilenceBars() async {
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { 100_000 })
        await monitor.onFrames(segmentId: "seg-1", frames: frames(25, loud: false), receivedAtMs: 100_000)

        await monitor.processPending()

        let bars = await monitor.bars
        #expect(bars.allSatisfy { $0.state == .silence })
    }

    @Test func lowLevelSpeechStillLooksRecordedAndVisible() async {
        let monitor = LiveAudioMonitor(decoder: LowSpeechDecoder(), nowMs: { 100_000 })
        await monitor.onFrames(segmentId: "seg-1", frames: frames(25, loud: true), receivedAtMs: 100_000)

        await monitor.processPending()

        let bars = await monitor.bars
        #expect(!bars.isEmpty)
        #expect(bars.allSatisfy { $0.state == .recorded })
        #expect(bars.allSatisfy { (0.08...0.2).contains($0.amplitude) })
        #expect(LiveAudioMonitor.displayAmplitude(120) < LiveAudioMonitor.displayAmplitude(1_000))
        #expect(LiveAudioMonitor.displayAmplitude(1_000) < LiveAudioMonitor.displayAmplitude(8_000))
    }

    @Test func gapsMarkBarsAcrossTheirDuration() async {
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { 100_000 })
        await monitor.onFrames(segmentId: "seg-1", frames: frames(13, loud: true), receivedAtMs: 100_000)
        // Gaps are reported at their trailing edge, so the span fills backward from there.
        await monitor.onGap(receivedAtMs: 102_000, approxDurationMs: 1_000)

        await monitor.processPending()

        let gapBars = await monitor.bars.filter { $0.state == .gap }
        #expect(gapBars.count == 4)  // 1000 ms / 250 ms per bar
        #expect(gapBars.allSatisfy { (101_000..<102_000).contains($0.timeMs) })
    }

    @Test func suppressedSilenceRendersAsQuietNotGap() async {
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { 100_000 })
        await monitor.onFrames(segmentId: "seg-1", frames: frames(13, loud: true), receivedAtMs: 100_000)
        // Voice-activity silence the watch skipped, reported at the resume edge: it must fill the
        // span that just ended (backward) as a quiet tick — never an amber gap or empty space.
        await monitor.onGap(receivedAtMs: 102_000, approxDurationMs: 1_000, silence: true)

        await monitor.processPending()

        let bars = await monitor.bars
        #expect(bars.allSatisfy { $0.state != .gap }, "silence must not show amber gap bars")
        let quietBars = bars.filter { (101_000..<102_000).contains($0.timeMs) }
        #expect(quietBars.count == 4)  // 1000 ms / 250 ms per bar
        #expect(quietBars.allSatisfy { $0.state == .suppressedSilence })
    }

    @Test func barsOutsideTheWindowAreTrimmed() async {
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { 0 })
        await monitor.onFrames(segmentId: "seg-1", frames: frames(13, loud: true), receivedAtMs: 10_000)
        await monitor.processPending()
        #expect(await !monitor.bars.isEmpty)

        // 10 minutes later more audio arrives; the old bars fall out of the 60 s window.
        await monitor.onFrames(segmentId: "seg-1", frames: frames(13, loud: true), receivedAtMs: 610_000)
        await monitor.processPending()

        let bars = await monitor.bars
        #expect(bars.allSatisfy { $0.timeMs >= 610_000 - monitor.windowMs })
    }

    /// The window has to age against wall-clock now, not against the newest thing in it.
    ///
    /// Trimming relative to the newest bucket meant the window only ever moved when audio
    /// arrived: the moment the watch stopped sending, the last minute of bars froze in place and
    /// stayed there — a still, green, minute-old waveform under a headline that said "Recording".
    @Test func theWindowAgesAgainstNowEvenWhenNothingArrives() async {
        let clock = MutableClock(nowMs: 100_000)
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { clock.nowMs })
        await monitor.onFrames(
            segmentId: "seg-1", frames: frames(13, loud: true), receivedAtMs: 100_000)
        await monitor.processPending()
        #expect(await !monitor.bars.isEmpty)

        // Half a minute on with nothing new: the audio is still inside the window.
        clock.nowMs = 130_000
        await monitor.processPending()
        #expect(await !monitor.bars.isEmpty)

        // Two minutes on: it has aged out, and the row drains instead of freezing.
        clock.nowMs = 220_000
        await monitor.processPending()
        #expect(await monitor.bars.isEmpty, "a stream that stopped must drain, not freeze")
    }

    @Test func framesAccumulateWhileInactiveAndDecodeInOneBatch() async {
        let countingDecoder = CountingDecoder()
        let monitor = LiveAudioMonitor(decoder: countingDecoder, nowMs: { 100_000 })

        // 4 batches arrive while the UI is hidden: no decode happens.
        for batch in 0..<4 {
            await monitor.onFrames(
                segmentId: "seg-1",
                frames: frames(13, loud: true),
                receivedAtMs: 100_000 + Int64(batch) * 260)
        }
        #expect(countingDecoder.decodeCalls == 0)

        // One catch-up decode covers the whole backlog.
        await monitor.processPending()
        #expect(countingDecoder.decodeCalls == 1)
        #expect(await !monitor.bars.isEmpty)
    }

    @Test func missingDecoderStillRendersPresence() async {
        let monitor = LiveAudioMonitor(decoder: nil, nowMs: { 100_000 })
        await monitor.onFrames(segmentId: "seg-1", frames: frames(13, loud: true), receivedAtMs: 100_000)

        await monitor.processPending()

        // Amplitude is zero (no decode) so bars read as silence, but presence is visible.
        #expect(await !monitor.bars.isEmpty)
    }

    // MARK: - The time axis

    /// A notification carries audio the watch already captured, so a batch belongs BEHIND its
    /// arrival, not in front of it. Dating it forwards put audio in the future, which is where
    /// the window's trim edge then went too — quietly shortening the minute the row can show.
    @Test func aBatchIsLaidDownBehindItsArrivalNotAheadOfIt() async {
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { 100_000 })
        // 50 frames = one second of audio, delivered in one notification at 100_000.
        await monitor.onFrames(
            segmentId: "seg-1", frames: frames(50, loud: true), receivedAtMs: 100_000)

        await monitor.processPending()

        let bars = await monitor.bars
        #expect(!bars.isEmpty)
        #expect(bars.allSatisfy { $0.timeMs <= 100_000 }, "captured audio is never in the future")
        #expect(bars.first!.timeMs >= 99_000, "one second of audio spans one second")
        #expect(bars.last!.timeMs >= 99_750, "the newest frame is the present")
    }

    /// The spool-drain case, which is what actually cost the row its minute: the watch clears a
    /// backlog at many times real time, so minutes of audio arrive inside a few seconds. Dated
    /// forwards, all of it landed ahead of now and dragged the trim edge with it, throwing away
    /// the real history behind it.
    @Test func aCatchUpBurstDoesNotPushTheWindowIntoTheFuture() async {
        let clock = MutableClock(nowMs: 100_000)
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { clock.nowMs })
        await monitor.onFrames(
            segmentId: "seg-1", frames: frames(13, loud: true), receivedAtMs: 70_000)
        await monitor.processPending()

        // A 30-second backlog arrives in one burst.
        await monitor.onFrames(
            segmentId: "seg-1", frames: frames(1_500, loud: true), receivedAtMs: 100_000)
        // 1500 frames at 500 entries a pass; a few extra passes cost nothing.
        for _ in 0..<8 { await monitor.processPending() }

        let bars = await monitor.bars
        #expect(bars.allSatisfy { $0.timeMs <= 100_000 }, "a burst must not be dated forwards")
        #expect(
            bars.contains { $0.timeMs < 71_000 },
            "audio from before the burst is still inside the window, not trimmed by a future edge")
    }

    // MARK: - Advancing through silence the watch skipped

    /// The defect the person watching sees: in a quiet room the watch sends NOTHING — it reports
    /// the skipped span only when speech resumes, which can be hours — so the row stopped growing
    /// and looked frozen. While the stream is live, every empty bar-width is laid down as the
    /// silence it is.
    @Test func aLiveStreamAdvancesThroughSilenceItIsNotBeingSent() async {
        let clock = MutableClock(nowMs: 100_000)
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { clock.nowMs })
        await monitor.setStreamLive(true)
        await monitor.onFrames(
            segmentId: "seg-1", frames: frames(13, loud: true), receivedAtMs: 100_000)
        await monitor.processPending()

        // Ten seconds of a quiet room: not one byte arrives.
        clock.nowMs = 110_000
        await monitor.processPending()

        let bars = await monitor.bars
        #expect(bars.last!.timeMs >= 109_750, "the row reaches NOW, not the last thing heard")
        let filled = bars.filter { $0.timeMs > 100_000 }
        #expect(filled.count >= 39, "ten seconds at 250 ms a bar")
        #expect(filled.allSatisfy { $0.state == .suppressedSilence })
        #expect(bars.contains { $0.state == .recorded }, "the speech before it is untouched")
    }

    /// Nothing may be invented about a stretch nobody was watching: the fill starts where the
    /// belief starts. This is what keeps "I just opened the app" blank rather than confidently
    /// quiet.
    @Test func theFillNeverBackdatesSilenceBeforeTheStreamWasBelievedLive() async {
        let clock = MutableClock(nowMs: 100_000)
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { clock.nowMs })

        await monitor.processPending()
        #expect(await monitor.bars.isEmpty, "no belief, no bars")

        await monitor.setStreamLive(true)
        clock.nowMs = 105_000
        await monitor.processPending()

        let bars = await monitor.bars
        #expect(!bars.isEmpty)
        #expect(
            bars.allSatisfy { $0.timeMs >= 100_000 },
            "the fill starts when the stream was first believed live, not one window earlier")
    }

    /// Losing the stream stops the fill — but never erases what was already believed. The seconds
    /// drawn as quiet while the link was up stay quiet; they were an honest reading at the time.
    @Test func losingTheStreamStopsTheFillAndKeepsWhatWasAlreadyDrawn() async {
        let clock = MutableClock(nowMs: 100_000)
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { clock.nowMs })
        await monitor.setStreamLive(true)
        clock.nowMs = 105_000
        await monitor.processPending()
        let whileLive = await monitor.bars.count
        #expect(whileLive > 0)

        await monitor.setStreamLive(false)
        clock.nowMs = 115_000
        await monitor.processPending()

        let bars = await monitor.bars
        #expect(bars.count == whileLive, "no new ticks, and none taken back")
        #expect(bars.allSatisfy { $0.timeMs <= 105_000 })
    }

    /// A live fill is a belief, and the watch's own gap record overrules it. Loss reported after
    /// the fact must repaint those seconds amber — never be smoothed into calm quiet.
    @Test func aGapReportedLaterOverridesSilenceAlreadyFilledIn() async {
        let clock = MutableClock(nowMs: 100_000)
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { clock.nowMs })
        await monitor.setStreamLive(true)
        clock.nowMs = 103_000
        await monitor.processPending()
        #expect(await monitor.bars.allSatisfy { $0.state == .suppressedSilence })

        // The watch resurfaces and says those three seconds were lost, not skipped.
        await monitor.onGap(receivedAtMs: 103_000, approxDurationMs: 3_000, silence: false)
        await monitor.processPending()

        let gapBars = await monitor.bars.filter { $0.state == .gap }
        #expect(gapBars.count >= 11, "three seconds of loss, at 250 ms a bar")
        #expect(gapBars.allSatisfy { (100_000...103_000).contains($0.timeMs) })
    }

    /// The fill is bounded by the window, so a long stretch off-screen backfills one minute at
    /// most rather than an afternoon of ticks nobody could have seen.
    @Test func aLongStretchOffScreenBackfillsAtMostOneWindow() async {
        let clock = MutableClock(nowMs: 100_000)
        let monitor = LiveAudioMonitor(decoder: FakeDecoder(), nowMs: { clock.nowMs })
        await monitor.setStreamLive(true)
        await monitor.processPending()

        clock.nowMs = 100_000 + 3_600_000  // an hour later
        await monitor.processPending()

        let bars = await monitor.bars
        #expect(!bars.isEmpty)
        #expect(bars.count <= Int(monitor.windowMs / 250) + 2)
        #expect(bars.allSatisfy { $0.timeMs >= clock.nowMs - monitor.windowMs })
    }
}
