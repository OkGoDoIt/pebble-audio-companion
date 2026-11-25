import Foundation

// The Storage copy that reads `AppSettings` (what "forever" is, how a limit is named). The rest
// is in `Copy.swift`, which the widgets compile too.

extension Copy.Settings.Storage {
    /// When a stop is reached: "After 1 month" · "Past 5 GB on this phone" ·
    /// "After 1 month, or past 5 GB on this phone".
    static func when(ageDays: Int?, maxBytes: Int64) -> String {
        let limit = maxBytes > 0 ? AppSettings.retentionLimitLabel(maxBytes) : nil
        switch (ageDays.map(ageLabel), limit) {
        case (nil, nil): return never
        case (let age?, nil): return "After \(age)"
        case (nil, let limit?): return "Past \(limit) on this phone"
        case (let age?, let limit?): return "After \(age), or past \(limit) on this phone"
        }
    }

    /// Under the path when the chosen move age is at or past the deleting one, e.g. "Recordings
    /// are deleted after 1 month, so audio moves after 2 weeks instead of 2 months."
    static func movesSooner(effectiveDays: Int, chosenDays: Int, keepDays: Int) -> String {
        "Recordings are deleted after \(ageLabel(keepDays)), so audio moves after "
            + "\(ageLabel(effectiveDays)) instead of \(ageLabel(chosenDays))."
    }

    /// Under the iCloud stop when nothing gets that old.
    static func deletedFirst(keepDays: Int) -> String {
        "Recordings are deleted first, after \(ageLabel(keepDays))"
    }

    /// Under the ages when the deleting age hides some, or all, of them.
    static func agesLimited(keepDays: Int, none: Bool) -> String {
        none
            ? "Recordings are deleted after \(ageLabel(keepDays)), too soon to move by age."
            : "Recordings are deleted after \(ageLabel(keepDays)), so only shorter ages are offered."
    }
}
