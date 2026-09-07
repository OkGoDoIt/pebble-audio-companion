import Foundation

/// A durable, rotating, append-only log that outlives the process.
///
/// WHY: the on-device log was a 400-line in-memory ring. Every failure this app actually has to
/// explain ends with the process gone — iOS suspends it, jettisons it under memory pressure,
/// relaunches it for a Bluetooth event, or the watchdog kills it — and the ring goes with it. The
/// one screen a person can read on the phone therefore showed nothing about the outage they had
/// just lived through, and a support report contained no log at all. Worse, the ring holds minutes
/// of a busy session, while the questions worth asking span days: "the link died at 03:12 and
/// nothing retried until 09:40" is not answerable from four hundred lines.
///
/// So: a file, appended to, flushed per line, rotated at a bound, readable and exportable long
/// after the process that wrote it is gone.
///
/// Three details are load-bearing:
///
/// - **Protection class.** `.completeUntilFirstUserAuthentication`, explicitly. The default for a
///   file created in the app container is fine today, but this log's whole job is to record what
///   happened while the phone was locked in someone's pocket — a background relaunch that could
///   not open its own log would be silent about exactly the window we need.
/// - **Timestamps carry the date and the zone.** The ring stamped `HH:mm:ss.SSS`, which cannot
///   order two lines from different days and silently shifts when the user travels.
/// - **Monotonic uptime alongside wall time.** Wall time jumps (NTP, timezone, the user changing
///   the clock); uptime does not, and the difference between two lines' uptime versus their wall
///   time is how you read a suspension off the log.
public final class FlightRecorder: @unchecked Sendable {
    /// Where the active file and its one rotated predecessor live.
    private let directory: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "audio-companion.flight-recorder", qos: .utility)
    private let fm = FileManager.default

    private var handle: FileHandle?
    private var bytesWritten = 0

    public init(directory: URL, maxBytes: Int = 2 * 1024 * 1024) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    public var activeURL: URL { directory.appendingPathComponent("companion.log") }
    public var previousURL: URL { directory.appendingPathComponent("companion.1.log") }

    /// Everything on disk, oldest first — the rotated file then the active one. This is what the
    /// user shares, and what a support report should carry.
    public func export() -> String {
        queue.sync { try? handle?.synchronize() }
        let previous = (try? String(contentsOf: previousURL, encoding: .utf8)) ?? ""
        let active = (try? String(contentsOf: activeURL, encoding: .utf8)) ?? ""
        return previous + active
    }

    /// The whole log as ONE file the user can hand over, named so it is obvious in a share sheet.
    ///
    /// A file rather than a string: the log spans days and runs to megabytes, which a share sheet
    /// handles badly as text and a support report cannot carry inline. Written fresh each time to
    /// a temporary location so sharing can never hold the live handle open.
    public func exportFile() -> URL? {
        let text = export()
        guard !text.isEmpty else { return nil }
        let url = fm.temporaryDirectory.appendingPathComponent("pebble-audio-companion.log")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// The tail, newest line first, for the Detailed Logs screen.
    public func recentLines(limit: Int = 500) -> [String] {
        let all = export().split(separator: "\n", omittingEmptySubsequences: true)
        return all.suffix(limit).reversed().map(String.init)
    }

    public func record(_ message: String) {
        let line = Self.stamp() + "  " + message + "\n"
        queue.async { [self] in append(line) }
    }

    /// Marks a new process in the log, with the reason it exists.
    ///
    /// The single most useful line in the file. Without it a log is one undifferentiated stream
    /// and there is no way to tell "the app kept running" from "the app died and iOS brought it
    /// back four times", which are opposite diagnoses with the same symptom.
    public func recordLaunch(cause: String, version: String) {
        record("──── process start (\(cause)) v\(version) ────")
    }

    /// Called on a slow timer while the process is alive. Its absence is the signal: a gap between
    /// two heartbeats is a window in which iOS had us suspended or dead, and that window is
    /// precisely what the reliability work is about.
    public func recordHeartbeat(_ detail: String) {
        record("heartbeat \(detail)")
    }

    public func deleteAll() {
        queue.sync { [self] in
            try? handle?.close()
            handle = nil
            bytesWritten = 0
            try? fm.removeItem(at: activeURL)
            try? fm.removeItem(at: previousURL)
        }
    }

    // MARK: - Disk

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let handle = openedHandle() else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            // A failed write must not take the app down or spin: drop the handle so the next line
            // reopens, and say nothing (we are the logger; there is nowhere to complain to).
            try? handle.close()
            self.handle = nil
            return
        }
        if bytesWritten >= maxBytes { rotate() }
    }

    private func openedHandle() -> FileHandle? {
        if let handle { return handle }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: activeURL.path) {
                fm.createFile(
                    atPath: activeURL.path,
                    contents: nil,
                    attributes: [
                        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                    ]
                )
            } else {
                // Re-assert on every open: a file created before this policy existed, or restored
                // from a backup, keeps whatever class it was made with.
                try? fm.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: activeURL.path
                )
            }
            let opened = try FileHandle(forWritingTo: activeURL)
            bytesWritten = Int(try opened.seekToEnd())
            handle = opened
            return opened
        } catch {
            return nil
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        bytesWritten = 0
        try? fm.removeItem(at: previousURL)
        try? fm.moveItem(at: activeURL, to: previousURL)
    }

    // MARK: - Time

    /// `2026-09-07T14:03:11.482-0400 [up 1483.2s]`
    ///
    /// Both clocks, deliberately. Wall time is what a person reports ("it stopped around three");
    /// uptime is what survives an NTP correction and what makes a suspension legible.
    private static func stamp() -> String {
        let wall = formatter.string(from: Date())
        let uptime = ProcessInfo.processInfo.systemUptime
        return String(format: "%@ [up %.1fs]", wall, uptime)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed locale: a formatter left on the device's locale renders Arabic-Indic digits or a
        // Buddhist year for some users, which is unreadable in a support report and unsortable.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()
}
