import Foundation

// The Storage copy that reads `AppSettings` (what "forever" is, how a limit is named). The rest
// is in `Copy.swift`, which the widgets compile too.

extension Copy.Settings.Storage {
    /// "Forever", or an age.
    static func keepLabel(_ days: Int) -> String {
        days == AppSettings.keepForever ? "Forever" : ageLabel(days)
    }
    /// What the two rules add up to, under their card.
    static func deletingLine(keepDays: Int, limitBytes: Int64, cloud: Bool) -> String {
        let age = keepDays == AppSettings.keepForever ? nil : ageLabel(keepDays)
        let limit = limitBytes > 0 ? AppSettings.retentionLimitLabel(limitBytes) : nil
        switch (age, limit) {
        case (nil, nil):
            return "Nothing is deleted automatically."
        case (let age?, nil):
            return "After \(age), a recording and its transcript are deleted"
                + (cloud ? ", from iCloud too." : ".")
        case (nil, let limit?):
            return "Past \(limit) on this phone, the oldest recordings are deleted with "
                + "their transcripts."
        case (let age?, let limit?):
            return "After \(age), a recording and its transcript are deleted"
                + (cloud ? ", from iCloud too" : "")
                + ". Past \(limit) on this phone, the oldest go first."
        }
    }
    /// The age picker's footer when Keep recordings hides some of the ages.
    static func cloudAgesLimited(keepDays: Int) -> String {
        "Recordings are kept for \(keepLabel(keepDays)), so only shorter ages are offered."
    }
    /// Under the row when the chosen age is at or past Keep recordings, e.g. "Recordings
    /// are kept for 1 month, so audio moves after 2 weeks instead of 2 months."
    static func cloudAgeShortened(effectiveDays: Int, chosenDays: Int, keepDays: Int) -> String {
        "Recordings are kept for \(keepLabel(keepDays)), so audio moves after "
            + "\(ageLabel(effectiveDays)) instead of \(ageLabel(chosenDays))."
    }
    /// Under the row when Keep recordings is too short for any age.
    static func cloudNeedsLongerKeep(minimumKeepDays: Int) -> String {
        "Needs recordings kept for at least \(keepLabel(minimumKeepDays))"
    }
}
