import Foundation

/// Lays live-waveform bars onto a fixed row of slots ending at NOW.
///
/// The live row used to be drawn by right-aligning the newest bars in the array, with no time
/// axis at all: whatever had arrived most recently was painted hard against the right edge and
/// called the present. When the watch stopped sending — a starved link, a lost STREAM_STOP, an
/// app resumed from suspension — the last minute of green bars simply stayed there, motionless
/// and undated, under a headline that said "Recording".
///
/// Placing every bar by its age instead makes the row a clock. Audio that stops drains leftwards
/// and is gone one window later, so a still waveform is visibly a waveform with nothing in it
/// rather than a frozen picture of a minute that has passed.
public enum WaveformWindow {
    /// `slotCount` slots ending at the slot that contains `nowMs`, oldest first, each covering
    /// `windowMs / slotCount`. A slot with no audio in it is nil — genuinely empty, drawn as
    /// nothing, never borrowed from a neighbour.
    ///
    /// **The slot grid is absolute, not anchored on `nowMs`.** A bar's slot is `timeMs / slotMs`,
    /// so a given quarter-second of audio belongs to one slot for its whole life on screen and
    /// the row marches left one whole slot at a time. Anchoring the grid on `now` instead — the
    /// original `now - timeMs` age division — re-cut the boundaries on every republish: the
    /// monitor ticks at 4 Hz and a slot is 750 ms, so two of every three redraws re-grouped the
    /// underlying 250 ms bars into different slots. Nothing had changed in the audio, yet a third
    /// of the row's bars hopped a slot and every affected height (and transcribed/captured
    /// colour) changed with them. That is the flicker: not motion, but the row being re-diced
    /// under a stationary clock.
    ///
    /// Several bars share a slot at this resolution, and they are reduced rather than picked
    /// from. State follows severity — loss outranks everything and must never be smoothed away
    /// (the same rule the coverage strip follows), then voice, then measured quiet, then the
    /// silence the watch skipped. Height is the MEAN amplitude of the bars carrying the winning
    /// state, so a slot draws the level of the interval it stands for. Taking the loudest bar
    /// instead let one 250 ms peak speak for 750 ms, which made neighbouring slots jump between
    /// peak and floor as audio crossed a boundary — the same visual noise, one level down.
    public static func slots(
        bars: [WaveformBar],
        nowMs: Int64,
        slotCount: Int,
        windowMs: Int64
    ) -> [WaveformBar?] {
        guard slotCount > 0, windowMs > 0 else { return [] }
        let slotMs = max(1, windowMs / Int64(slotCount))
        let newestSlot = floorDiv(nowMs, slotMs)
        var accums = [Accum?](repeating: nil, count: slotCount)
        for bar in bars {
            // Future-dated bars (a received-at stamp slightly ahead of the caller's clock) belong
            // in the newest slot rather than nowhere.
            let stepsBack = max(0, newestSlot - floorDiv(bar.timeMs, slotMs))
            guard stepsBack < Int64(slotCount) else { continue }
            let index = slotCount - 1 - Int(stepsBack)
            var accum =
                accums[index] ?? Accum(slotStartMs: (newestSlot - stepsBack) * slotMs)
            accum.add(bar)
            accums[index] = accum
        }
        return accums.map { $0?.bar }
    }

    /// Reduces the bars that share one slot into the single bar the slot draws.
    private struct Accum {
        let slotStartMs: Int64
        private var rank = -1
        private var state: WaveformBarState = .suppressedSilence
        private var segmentId: String?
        private var maxSampleIndex: UInt64?
        private var amplitudeSum: Double = 0
        private var amplitudeCount = 0

        init(slotStartMs: Int64) { self.slotStartMs = slotStartMs }

        mutating func add(_ bar: WaveformBar) {
            let barRank = WaveformWindow.rank(bar.state)
            if barRank > rank {
                // A more severe state supersedes what the slot held: start its average over, so a
                // gap or a word is never diluted by the quiet it displaced.
                rank = barRank
                state = bar.state
                segmentId = nil
                maxSampleIndex = nil
                amplitudeSum = 0
                amplitudeCount = 0
            } else if barRank < rank {
                return
            }
            amplitudeSum += Double(bar.amplitude)
            amplitudeCount += 1
            if let id = bar.segmentId { segmentId = id }
            if let sample = bar.maxSampleIndex {
                // The slot's highest sample index, so "transcribed through here" is monotone and
                // the colour cannot flip back as the row is redrawn.
                maxSampleIndex = max(maxSampleIndex ?? sample, sample)
            }
        }

        var bar: WaveformBar {
            WaveformBar(
                timeMs: slotStartMs,
                amplitude: amplitudeCount > 0 ? Float(amplitudeSum / Double(amplitudeCount)) : 0,
                state: state,
                segmentId: segmentId,
                maxSampleIndex: maxSampleIndex
            )
        }
    }

    /// Display severity. Missing audio is the one thing a reduction may never lose.
    ///
    /// Audio we HOLD outranks audio we merely infer, so a slot carrying a quarter-second of
    /// measured quiet reads as quiet rather than as skipped silence. The two used to be ranked
    /// the other way round, which was harmless only while both drew the same dot; now that
    /// skipped silence is the fainter mark, ranking it above measured quiet would throw away the
    /// stronger claim.
    private static func rank(_ state: WaveformBarState) -> Int {
        switch state {
        case .gap: return 3
        case .recorded: return 2
        case .silence: return 1
        case .suppressedSilence: return 0
        }
    }

    /// Floors towards negative infinity, unlike `/`, so the grid stays uniform either side of the
    /// epoch instead of widening into one double-length slot at zero.
    private static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}
