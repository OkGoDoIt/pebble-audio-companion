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
    /// `slotCount` slots covering `windowMs` and ending at `nowMs`, oldest first. A slot with no
    /// audio in it is nil — genuinely empty, drawn as nothing, never borrowed from a neighbour.
    ///
    /// Bars are merged rather than averaged when several land in one slot: loss outranks
    /// everything (it must never be smoothed away — the same rule the coverage strip follows),
    /// then voice, then quiet, and the loudest bar carries the slot's height.
    public static func slots(
        bars: [WaveformBar],
        nowMs: Int64,
        slotCount: Int,
        windowMs: Int64
    ) -> [WaveformBar?] {
        guard slotCount > 0, windowMs > 0 else { return [] }
        var slots = [WaveformBar?](repeating: nil, count: slotCount)
        let slotMs = max(1, windowMs / Int64(slotCount))
        for bar in bars {
            let age = nowMs - bar.timeMs
            // Future-dated bars (a received-at stamp slightly ahead of the caller's clock) belong
            // in the newest slot rather than nowhere.
            let index = age <= 0 ? slotCount - 1 : slotCount - 1 - Int(age / slotMs)
            guard slots.indices.contains(index) else { continue }
            slots[index] = merge(slots[index], bar)
        }
        return slots
    }

    /// Which of two bars represents the slot they share.
    static func merge(_ existing: WaveformBar?, _ candidate: WaveformBar) -> WaveformBar {
        guard let existing else { return candidate }
        let existingRank = rank(existing.state)
        let candidateRank = rank(candidate.state)
        if candidateRank != existingRank { return candidateRank > existingRank ? candidate : existing }
        return candidate.amplitude > existing.amplitude ? candidate : existing
    }

    /// Display severity. Missing audio is the one thing a merge may never lose.
    private static func rank(_ state: WaveformBarState) -> Int {
        switch state {
        case .gap: return 3
        case .recorded: return 2
        case .suppressedSilence: return 1
        case .silence: return 0
        }
    }
}
