import Foundation

/// Removes the per-call scratch files a transcription leaves behind when the process dies in the
/// middle of one.
///
/// Every producer deletes its own files in a `defer` — which never runs when iOS kills the process
/// (jetsam, a watchdog, a suspension with a lock held). On 2026-09-29 the phone's `tmp/` held
/// eight `cactus_stt-*.raw` spools from 09-19 onward, up to 18.6 MB each, and four
/// `pebble-flac-*.flac` encodes; nothing would ever have removed them, and iOS only purges `tmp/`
/// when it is under storage pressure.
///
/// Only the transient, single-call names are touched (`cactus_stt-` PCM/WAV staging from
/// `ParakeetTranscriptionProvider`, `pebble-flac-` from `PcmFlac`), and only when older than
/// `minimumAgeMs` — at launch nothing in this process is transcribing yet, and the age is a
/// second guard against ever deleting a file still in use. Model-download archives are the
/// store's business and are left alone.
public enum ScratchFileSweep {
    public static let prefixes = ["cactus_stt-", "pebble-flac-"]
    public static let minimumAgeMs: Int64 = 10 * 60_000

    public struct Result: Equatable, Sendable {
        public var files: Int
        public var bytes: Int64
    }

    @discardableResult
    public static func run(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        minimumAgeMs: Int64 = minimumAgeMs
    ) -> Result {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard
            let entries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys)
        else { return Result(files: 0, bytes: 0) }
        let cutoff = now.addingTimeInterval(-Double(minimumAgeMs) / 1_000)
        var result = Result(files: 0, bytes: 0)
        for url in entries {
            let name = url.lastPathComponent
            guard prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                (values.contentModificationDate ?? .distantPast) <= cutoff
            else { continue }
            if (try? fm.removeItem(at: url)) != nil {
                result.files += 1
                result.bytes += Int64(values.fileSize ?? 0)
            }
        }
        return result
    }
}
