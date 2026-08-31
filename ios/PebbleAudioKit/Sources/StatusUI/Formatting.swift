import Foundation

// Port of the duration/size pieces of `app/.../ui/Formatting.kt`. The date/time-of-day
// helpers are NOT ported here: Q16 anchors all display times in each segment's recorded
// timezone, so the SwiftUI layer formats dates with Foundation calendars per segment.

/// Plain-language duration/size formatting for timeline rows and detail views.
public enum Formatting {
    /// "38 sec", "5 min", "1 hr 12 min"
    public static func duration(_ durationMs: Int64) -> String {
        let totalSeconds = durationMs / 1000
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

    /// "1.5 GB", "320 MB", "12 KB"
    public static func storageSize(_ bytes: Int64) -> String {
        if bytes >= (1 << 30) {
            return "\(formatOneDecimal(Double(bytes) / Double(1 << 30))) GB"
        }
        if bytes >= (1 << 20) {
            return "\(bytes / (1 << 20)) MB"
        }
        return "\(max(bytes / 1024, 0)) KB"
    }

    private static func formatOneDecimal(_ value: Double) -> String {
        let tenths = Int(value * 10)
        return "\(tenths / 10).\(tenths % 10)"
    }
}
