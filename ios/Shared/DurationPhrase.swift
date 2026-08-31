import Foundation

/// Plain-language durations for surfaces where precision would be a lie.
///
/// The loss notification says "for about {duration}" (Copy.Notifications.lossBody), so
/// `approximate` returns the BARE phrase ("40 seconds") and `about` adds the hedge once —
/// never "about about". Deliberately coarse: the gap length we know is itself an estimate,
/// and "for about 43.6 seconds" would claim a certainty the wire data does not have.
enum DurationPhrase {
    /// "40 seconds" · "3 minutes" · "1 hour 20 minutes". Rounded, never zero.
    static func approximate(ms: Int64) -> String {
        let totalSeconds = max(0, ms) / 1000
        if totalSeconds < 60 {
            // Nearest 5 s, floored at 5 — below that "seconds" is noise, not information.
            let rounded = max(5, Int(((Double(totalSeconds) / 5).rounded()) * 5))
            if rounded >= 60 { return unit(1, "minute") }
            return unit(rounded, "second")
        }
        if totalSeconds < 3600 {
            let minutes = Int((Double(totalSeconds) / 60).rounded())
            if minutes >= 60 { return unit(1, "hour") }
            return unit(max(1, minutes), "minute")
        }
        let hours = Int(totalSeconds / 3600)
        // Remainder to the nearest 5 min; a bare "2 hours" beats "2 hours 3 minutes".
        var minutes = Int((Double((totalSeconds % 3600)) / 60 / 5).rounded()) * 5
        var wholeHours = hours
        if minutes >= 60 {
            wholeHours += 1
            minutes = 0
        }
        if minutes == 0 { return unit(wholeHours, "hour") }
        return "\(unit(wholeHours, "hour")) \(unit(minutes, "minute"))"
    }

    /// "about 40 seconds" — the hedged form, for anywhere the surrounding copy does not
    /// already supply "about".
    static func about(ms: Int64) -> String { "about \(approximate(ms: ms))" }

    /// Compact, exact-ish duration for chrome that has room for numbers and no hedge:
    /// "38 sec" · "5 min" · "1 hr 12 min". Mirrors `StatusUI.Formatting.duration` so the
    /// widget prints the same string the app does without linking the kit.
    static func compact(ms: Int64) -> String {
        let totalSeconds = max(0, ms) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        switch (hours, minutes) {
        case let (h, m) where h > 0 && m > 0: return "\(h) hr \(m) min"
        case let (h, _) where h > 0: return "\(h) hr"
        case let (_, m) where m > 0: return "\(m) min"
        default: return "\(seconds) sec"
        }
    }

    private static func unit(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}
