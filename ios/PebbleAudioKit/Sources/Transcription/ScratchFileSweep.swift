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
/// Only transient names are touched — `cactus_stt-` PCM/WAV staging from
/// `ParakeetTranscriptionProvider`, `pebble-flac-` from `PcmFlac`, and `cactus_download_` model
/// archives from `ParakeetModelStore` (up to 1.2 GB; the download is a foreground session, so one
/// cannot be in flight in a process that is just starting) — and only when older than
/// `minimumAgeMs`, a second guard against ever deleting a file still in use.
///
/// The same for whole DIRECTORIES a system framework leaves behind (`directoryRules`). On
/// 2026-10-12 the phone was at 497.6 of 512 GB and MetricKit blamed this app for 11.7 GB; 6.19 GB
/// of it was six `tmp/com.apple.MetalPerformanceShadersGraph/mpsgraph-<pid>-<date>-<hash>/`
/// folders, each holding the Neural Engine compiler's 1.02 GB `.bc.mlir` dump for one model
/// compile, all from the Core AI cache recompiles of 09-29/09-30. The audio itself was 2.1 GB.
/// A compile that finishes removes its own folder; one the process dies inside does not, and
/// nothing — not iOS, not the framework, not this app — ever looked at the folder again.
public enum ScratchFileSweep {
    public static let prefixes = ["cactus_stt-", "pebble-flac-", "cactus_download_"]
    public static let minimumAgeMs: Int64 = 10 * 60_000

    /// A parent folder under the scratch directory, and the prefix of the per-run subfolders
    /// inside it that are removed whole once older than `directoryMinimumAgeMs`.
    public struct DirectoryRule: Equatable, Sendable {
        public var parent: String
        public var prefix: String

        public init(parent: String, prefix: String) {
            self.parent = parent
            self.prefix = prefix
        }
    }

    public static let directoryRules: [DirectoryRule] = [
        DirectoryRule(parent: "com.apple.MetalPerformanceShadersGraph", prefix: "mpsgraph-")
    ]

    /// A day. A model compile takes minutes, and a folder the compiler is still writing into is
    /// modified as it goes; a folder untouched for a day belongs to a process that is gone.
    public static let directoryMinimumAgeMs: Int64 = 24 * 60 * 60_000

    public struct Result: Equatable, Sendable {
        public var files: Int
        public var bytes: Int64
    }

    @discardableResult
    public static func run(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        minimumAgeMs: Int64 = minimumAgeMs,
        directoryMinimumAgeMs: Int64 = directoryMinimumAgeMs
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

        let directoryCutoff = now.addingTimeInterval(-Double(directoryMinimumAgeMs) / 1_000)
        for rule in directoryRules {
            let parent = directory.appendingPathComponent(rule.parent, isDirectory: true)
            guard
                let subfolders = try? fm.contentsOfDirectory(
                    at: parent, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
            else { continue }
            for folder in subfolders where folder.lastPathComponent.hasPrefix(rule.prefix) {
                guard
                    let values = try? folder.resourceValues(
                        forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                    values.isDirectory == true,
                    (values.contentModificationDate ?? .distantPast) <= directoryCutoff
                else { continue }
                let (files, bytes) = contents(of: folder)
                if (try? fm.removeItem(at: folder)) != nil {
                    result.files += files
                    result.bytes += bytes
                }
            }
        }
        return result
    }

    /// Regular files under `folder`, however deep, and their total size.
    private static func contents(of folder: URL) -> (files: Int, bytes: Int64) {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [])
        else { return (0, 0) }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }
}
