import AppDB
import Foundation
import SegmentStore

/// Where speech was in each recording, for History's day (`HistorySpeechRun`), memoised on the
/// transcript file's version.
///
/// A day holds about a hundred recordings and each transcript is 100-370 KB of JSON; decoding
/// them on every rebuild is the O(library) shape that has already cost this app a charger's worth
/// of CPU (`EnrichmentWorker.planFor`, 2026-09-09). So a recording's runs are computed once and
/// kept against `FileTranscriptStore.version` (one `stat`, no read) and the recording's own
/// placement on the clock; only a transcript that changed is read again. Reads happen here, on the
/// actor's executor — never on the main actor.
///
/// The runs are exactly the grouper's (`SegmentSpeechEvidence.of` placed by
/// `ConversationBoundaryDetector.spokenRuns`), so a card sits where the conversation screen puts
/// the words.
public actor HistorySpeechRunCache {
    public struct Result: Sendable {
        /// Runs of the recordings that have a transcript file.
        public var runs: [HistorySpeechRun]
        /// Recordings whose transcript file is present (a `.complete` without one is a fault).
        public var withTranscript: Set<String>
    }

    private struct Entry {
        var version: String
        var placement: [Int64]
        /// Nil: no transcript file.
        var runs: [HistorySpeechRun]?
    }

    private let transcripts: FileTranscriptStore
    private var entries: [String: Entry] = [:]
    /// Bounded: a year of recordings is a few thousand small entries; past this the cache starts
    /// over rather than growing with the library.
    private let capacity: Int
    /// Transcripts actually decoded, for tests and signposts.
    public private(set) var reads = 0

    public init(transcripts: FileTranscriptStore, capacity: Int = 4_000) {
        self.transcripts = transcripts
        self.capacity = capacity
    }

    /// Speech runs for the recordings among `metas` that are `.complete` (after `states`, the
    /// state History draws each in; a recording missing from it uses its own).
    public func runs(for metas: [SegmentMeta], states: [String: TranscriptionState]) -> Result {
        var runs: [HistorySpeechRun] = []
        var present: Set<String> = []
        for meta in metas {
            let state = states[meta.segmentId] ?? meta.transcriptionState
            guard state == .complete else { continue }
            let version = transcripts.version(meta.segmentId)
            let placement = Self.placement(meta)
            let entry: Entry
            if let cached = entries[meta.segmentId], cached.version == version, cached.placement == placement {
                entry = cached
            } else {
                entry = Entry(version: version, placement: placement, runs: read(meta))
                if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
                entries[meta.segmentId] = entry
            }
            if let segmentRuns = entry.runs {
                present.insert(meta.segmentId)
                runs += segmentRuns
            }
        }
        return Result(runs: runs, withTranscript: present)
    }

    private func read(_ meta: SegmentMeta) -> [HistorySpeechRun]? {
        reads += 1
        guard let timings = transcripts.loadSpeechTimings(meta.segmentId) else { return nil }
        var evidenceMeta = meta
        evidenceMeta.transcriptionState = .complete
        let evidence = SegmentSpeechEvidence.of(
            evidenceMeta,
            transcriptSpeech: timings.map {
                SpeechSpan(
                    startMs: $0.startMs, endMs: $0.endMs,
                    wordCount: $0.text.split(whereSeparator: \.isWhitespace).count)
            })
        return ConversationBoundaryDetector.spokenRuns(evidenceMeta, evidence).map {
            HistorySpeechRun(segmentId: meta.segmentId, startMs: $0.startMs, endMs: $0.endMs)
        }
    }

    /// What `spokenRuns` places a recording's runs by: its wall anchor and its extent.
    private static func placement(_ meta: SegmentMeta) -> [Int64] {
        [
            meta.startWallMs, Int64(meta.sampleRateHz),
            Int64(bitPattern: meta.firstSampleIndex ?? .max),
            Int64(bitPattern: meta.lastSampleIndexExclusive ?? .max),
            meta.closedAtMs ?? -1,
        ]
    }
}
