import Foundation
import StatusUI

/// Renders the build stamp for the Diagnostics screen: when this binary was built, from which
/// revision, and how long ago.
///
/// Pure and clock-injected so the whole matrix is testable — the values it formats come from
/// `BuildInfo`, which the "Generate Build Info" script phase rewrites on every build (see
/// project.yml), and which is therefore never the same twice on a real device.
enum BuildFormatting {
    /// "Sep 9, 2026 at 3:24 PM · 84ca738 · 12 min ago".
    ///
    /// The absolute time comes first because it is the unambiguous half: someone reading a
    /// screenshot hours later still knows exactly which build it was. The relative half is what
    /// answers the question at a glance while standing at the desk having just deployed.
    ///
    /// `nowMs` of 0 means "no clock yet" (the value the source holds before its first refresh),
    /// which drops the relative half rather than claiming the build is 57 years old.
    static func describe(builtAtISO8601: String, revision: String, nowMs: Int64) -> String {
        guard let built = date(fromISO8601: builtAtISO8601) else {
            return Copy.Settings.Diagnostics.buildUnknown
        }
        var parts = [absolute.string(from: built)]
        if revision != "unknown" { parts.append(revision) }
        let elapsedMs = nowMs - Int64(built.timeIntervalSince1970 * 1000)
        if nowMs > 0, elapsedMs >= 0 {
            parts.append("\(Formatting.duration(elapsedMs)) ago")
        }
        return parts.joined(separator: " · ")
    }

    /// The placeholder committed at `App/Generated/BuildInfo.swift` says "unknown", and so does a
    /// build made outside a git checkout; both mean "there is no stamp to show".
    private static func date(fromISO8601 value: String) -> Date? {
        guard value != "unknown" else { return nil }
        return iso8601.date(from: value)
    }

    private static let iso8601 = ISO8601DateFormatter()

    /// The device's own locale and time zone: this is read by a person holding the phone, not
    /// parsed by anything, so it should look like every other date iOS shows them.
    private static let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
