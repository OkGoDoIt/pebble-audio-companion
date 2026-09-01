import Foundation
import Testing

@testable import LiveAudio

// The live row is a clock, not a stack.
//
// It used to be drawn by right-aligning the newest bars in the array, which has no time axis at
// all: whatever had arrived most recently was painted hard against the right edge and called the
// present. A stream that stopped therefore left a full, still, green minute sitting under the
// word "Recording" for as long as the screen stayed open.

@Suite struct WaveformWindowTests {

    private let slotCount = 40
    private let windowMs: Int64 = 60_000

    private func bar(
        _ timeMs: Int64, amplitude: Float = 0.8, state: WaveformBarState = .recorded
    ) -> WaveformBar {
        WaveformBar(timeMs: timeMs, amplitude: amplitude, state: state, segmentId: "seg-1")
    }

    private func slots(_ bars: [WaveformBar], nowMs: Int64) -> [WaveformBar?] {
        WaveformWindow.slots(
            bars: bars, nowMs: nowMs, slotCount: slotCount, windowMs: windowMs)
    }

    /// A bar's position is its age. Audio from the far end of the window belongs at the far left,
    /// no matter that it is the only bar there is.
    @Test func barsArePlacedByAgeNotByArrayPosition() {
        let now: Int64 = 1_000_000
        let row = slots([bar(now - 58_000)], nowMs: now)

        #expect(row.count == slotCount)
        #expect(row.last as? WaveformBar == nil, "58-second-old audio is not the present")
        #expect(row.compactMap { $0 }.count == 1)
        #expect(row.firstIndex(where: { $0 != nil }) == 1)
    }

    /// The defect, directly. One minute of solid audio, then the watch goes quiet: the row must
    /// empty out over the following minute instead of standing still.
    @Test func audioThatStopsDrainsOutOfTheWindow() {
        let stopped: Int64 = 500_000
        let bars = (0..<240).map { bar(stopped - Int64($0) * 250) }

        let atStop = slots(bars, nowMs: stopped).compactMap { $0 }.count
        #expect(atStop == slotCount, "a full minute of audio fills the row")

        let halfLater = slots(bars, nowMs: stopped + 30_000).compactMap { $0 }.count
        #expect(halfLater > 0)
        #expect(halfLater < atStop, "thirty seconds on, half the row has drained")

        let aMinuteLater = slots(bars, nowMs: stopped + 61_000).compactMap { $0 }.count
        #expect(aMinuteLater == 0, "a minute on, nothing recent is left to draw")
    }

    /// The same bars redrawn later must not creep rightwards: the row is anchored to now, so
    /// old audio never migrates back into the present.
    @Test func theSameBarsNeverDriftTowardsThePresent() {
        let now: Int64 = 800_000
        let single = [bar(now - 20_000)]
        let firstIndex = slots(single, nowMs: now).firstIndex { $0 != nil }
        let laterIndex = slots(single, nowMs: now + 15_000).firstIndex { $0 != nil }
        #expect(firstIndex != nil && laterIndex != nil)
        #expect(laterIndex! < firstIndex!, "as time passes, the same audio moves left")
    }

    /// Several bars share a slot at this resolution. Loss must never be averaged away — the same
    /// rule the coverage strip follows.
    @Test func lossIsNeverAveragedAwayWhenBarsShareASlot() {
        let now: Int64 = 300_000
        let inOneSlot: Int64 = now - 1_000
        let row = slots(
            [
                bar(inOneSlot, amplitude: 0.9, state: .recorded),
                bar(inOneSlot + 250, amplitude: 0, state: .gap),
                bar(inOneSlot + 500, amplitude: 0.7, state: .recorded),
            ],
            nowMs: now
        )
        let drawn = row.compactMap { $0 }
        #expect(drawn.count == 1)
        #expect(drawn[0].state == .gap, "a gap inside a slot must survive the merge")
    }

    /// Voice outranks quiet, and the loudest bar carries the slot's height, so a slot holding one
    /// word and five silent frames still shows the word.
    @Test func voiceOutranksQuietAndTheLoudestBarSetsTheHeight() {
        let now: Int64 = 300_000
        let inOneSlot: Int64 = now - 800
        let row = slots(
            [
                bar(inOneSlot, amplitude: 0, state: .silence),
                bar(inOneSlot + 250, amplitude: 0.4, state: .recorded),
                bar(inOneSlot + 500, amplitude: 0.9, state: .recorded),
                bar(inOneSlot + 700, amplitude: 0, state: .suppressedSilence),
            ],
            nowMs: now
        )
        let drawn = row.compactMap { $0 }
        #expect(drawn.count == 1)
        #expect(drawn[0].state == .recorded)
        #expect(drawn[0].amplitude == 0.9)
    }

    /// A received-at stamp slightly ahead of the caller's clock belongs in the newest slot, not
    /// dropped on the floor where the row would look emptier than the audio we hold.
    @Test func slightlyFutureDatedAudioLandsInTheNewestSlot() {
        let now: Int64 = 200_000
        let row = slots([bar(now + 200)], nowMs: now)
        #expect(row.last as? WaveformBar != nil)
        #expect(row.compactMap { $0 }.count == 1)
    }

    /// Audio we HOLD outranks audio we merely infer: a slot carrying a quarter-second of measured
    /// quiet reads as quiet, not as the fainter tick that means "live link, sent nothing".
    @Test func measuredQuietOutranksSilenceTheWatchSkipped() {
        let now: Int64 = 300_000
        let inOneSlot: Int64 = now - 800
        let row = slots(
            [
                bar(inOneSlot, amplitude: 0, state: .suppressedSilence),
                bar(inOneSlot + 250, amplitude: 0, state: .silence),
                bar(inOneSlot + 500, amplitude: 0, state: .suppressedSilence),
            ],
            nowMs: now
        )
        let drawn = row.compactMap { $0 }
        #expect(drawn.count == 1)
        #expect(drawn[0].state == .silence)
    }

    /// The row's contract, stated directly: the left edge is one window ago and the right edge is
    /// now, whatever is or is not in between.
    @Test func theRowSpansExactlyTheWindowEndingAtNow() {
        let now: Int64 = 900_000
        // One bar per slot across the whole window, oldest first.
        let slotMs = windowMs / Int64(slotCount)
        let everySlot = (0..<slotCount).map { bar(now - Int64($0) * slotMs) }
        let full = slots(everySlot, nowMs: now)
        #expect(full.allSatisfy { $0 != nil }, "a bar in every slot fills the row end to end")

        // The two edges, exactly: one millisecond older than the window is off the row.
        #expect(slots([bar(now - windowMs + 1)], nowMs: now).first! != nil)
        #expect(slots([bar(now - windowMs)], nowMs: now).allSatisfy { $0 == nil })
        #expect(slots([bar(now)], nowMs: now).last! != nil)
    }

    @Test func anEmptyWindowDrawsNothing() {
        #expect(slots([], nowMs: 1_000).allSatisfy { $0 == nil })
        #expect(slots([], nowMs: 1_000).count == slotCount)
        #expect(WaveformWindow.slots(bars: [], nowMs: 0, slotCount: 0, windowMs: 60_000).isEmpty)
    }
}
