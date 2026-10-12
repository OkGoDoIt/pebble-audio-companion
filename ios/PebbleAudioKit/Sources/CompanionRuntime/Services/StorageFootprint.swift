import Foundation

/// What this app's files on the phone add up to, bucketed the way a person asks the question
/// ("how much of that is the audio?"), plus the volume they sit on.
///
/// It exists because the number MetricKit reports for the app is not the number anyone expects.
/// On 2026-10-12 MetricKit said 11.7 GB of app data on a phone at 497.6 of 512 GB; the audio was
/// 2.1 GB of it. The rest was the on-device model and its compiled cache (2.4 GB, needed) and
/// 6.2 GB of a system compiler's leftovers in `tmp/` (see `ScratchFileSweep.directoryRules`).
/// A "Recordings: 2.1 GB" row next to "Free space: 14 GB" would have hidden that for months.
///
/// Measuring is a walk over every file (about 6,000 on that phone), so it is done only for the
/// Diagnostics screen while it is on screen, and never on a refresh tick.
public struct StorageFootprint: Equatable, Sendable {
    /// Frame logs under `segments/`.
    public var audioBytes: Int64 = 0
    public var audioFiles: Int = 0
    /// Sidecars and the recovery index.
    public var sidecarBytes: Int64 = 0
    /// Transcripts, AI outputs and the content-classifier's clips.
    public var transcriptBytes: Int64 = 0
    /// The SQLite database and its journal.
    public var databaseBytes: Int64 = 0
    /// The flight recorder and the MetricKit archive.
    public var diagnosticsBytes: Int64 = 0
    /// Anything else under the app's own root.
    public var otherBytes: Int64 = 0
    /// Downloaded on-device model weights.
    public var modelBytes: Int64 = 0
    /// `Library/Caches` — the compiled Neural Engine program lives here.
    public var cacheBytes: Int64 = 0
    /// `tmp/` — scratch files and whatever a system framework left behind.
    public var temporaryBytes: Int64 = 0
    /// Every regular file counted above.
    public var totalFiles: Int = 0
    /// What the volume will let an app use ("important usage": purgeable space counts as free).
    public var freeBytes: Int64 = 0
    public var capacityBytes: Int64 = 0

    public init() {}

    /// Everything counted, which is what MetricKit's `totalFileSizeMetric` roughly answers.
    public var totalBytes: Int64 {
        audioBytes + sidecarBytes + transcriptBytes + databaseBytes + diagnosticsBytes
            + otherBytes + modelBytes + cacheBytes + temporaryBytes
    }

    /// Folder names under the app root, by bucket. Anything not named here is `otherBytes`.
    static let transcriptFolders: Set<String> = ["transcription", "ai", "analysis"]
    static let databaseFolders: Set<String> = ["db"]
    static let diagnosticsFolders: Set<String> = ["diagnostics"]
    static let segmentsFolder = "segments"
    static let audioSuffix = ".spxlog"

    /// `appRoot` is the store's root (`…/audio-companion`); `volume` is any URL on the volume
    /// to size (the app root is fine). Folders that do not exist count as zero.
    public static func measure(
        appRoot: URL,
        modelsDirectory: URL?,
        cachesDirectory: URL?,
        temporaryDirectory: URL?,
        volume: URL
    ) -> StorageFootprint {
        var footprint = StorageFootprint()
        let fm = FileManager.default
        let children =
            (try? fm.contentsOfDirectory(
                at: appRoot, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey]
            )) ?? []
        for child in children {
            let name = child.lastPathComponent
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if name == segmentsFolder {
                    let (audio, sidecars) = walk(child) { url in url.lastPathComponent.hasSuffix(audioSuffix) }
                    footprint.audioBytes += audio.bytes
                    footprint.audioFiles += audio.files
                    footprint.sidecarBytes += sidecars.bytes
                    footprint.totalFiles += audio.files + sidecars.files
                } else {
                    let (matched, _) = walk(child) { _ in true }
                    footprint.totalFiles += matched.files
                    if transcriptFolders.contains(name) {
                        footprint.transcriptBytes += matched.bytes
                    } else if databaseFolders.contains(name) {
                        footprint.databaseBytes += matched.bytes
                    } else if diagnosticsFolders.contains(name) {
                        footprint.diagnosticsBytes += matched.bytes
                    } else {
                        footprint.otherBytes += matched.bytes
                    }
                }
            } else if values?.isRegularFile == true {
                let bytes = Int64(values?.fileSize ?? 0)
                footprint.totalFiles += 1
                // The recovery index is the sidecars' cache; everything else loose at the root
                // (receiver state, migration state, the cloud hold) is bookkeeping.
                if name.hasPrefix("segments_index") {
                    footprint.sidecarBytes += bytes
                } else {
                    footprint.otherBytes += bytes
                }
            }
        }
        for (directory, keyPath) in [
            (modelsDirectory, \StorageFootprint.modelBytes),
            (cachesDirectory, \StorageFootprint.cacheBytes),
            (temporaryDirectory, \StorageFootprint.temporaryBytes),
        ] {
            guard let directory else { continue }
            let (matched, _) = walk(directory) { _ in true }
            footprint[keyPath: keyPath] += matched.bytes
            footprint.totalFiles += matched.files
        }
        if let values = try? volume.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) {
            footprint.capacityBytes = Int64(values.volumeTotalCapacity ?? 0)
            footprint.freeBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
        }
        return footprint
    }

    struct Tally: Equatable {
        var bytes: Int64 = 0
        var files = 0
    }

    /// Every regular file under `directory`, however deep, split by `matches`.
    static func walk(_ directory: URL, matches: (URL) -> Bool) -> (matched: Tally, rest: Tally) {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys, options: [])
        else { return (Tally(), Tally()) }
        var matched = Tally()
        var rest = Tally()
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            if matches(url) {
                matched.bytes += bytes
                matched.files += 1
            } else {
                rest.bytes += bytes
                rest.files += 1
            }
        }
        return (matched, rest)
    }
}
