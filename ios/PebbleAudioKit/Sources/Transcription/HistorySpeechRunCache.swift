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
/// The same pass keeps each turn's text, cut to `HistorySpokenTurn.maxCharacters` and placed on
/// the wall clock the same way, so the day's verbatim snippets cost no second decode and share
/// the runs' memoisation key.
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
        /// Their turns' text, in time order.
        public var turns: [HistorySpokenTurn]
    }

    private struct Entry {
        var version: String
        var placement: [Int64]
        /// Nil: no transcript file.
        var runs: [HistorySpeechRun]?
        var turns: [HistorySpokenTurn] = []
    }

    private let transcripts: FileTranscriptStore
    private var entries: [String: Entry] = [:]
    /// Bounded: a year of recordings is a few thousand small entries; past this the cache starts
    /// over rather than growing with the library.
    private let capacity: Int
    /// Transcripts actually decoded, for tests and signposts.
    public private(set) var reads = 0

    public init(transcripts: FileTranscriptStore, capacity: Int = 700) {
        self.transcripts = transcripts
        self.capacity = capacity
    }

    /// Speech runs for the recordings among `metas` that are `.complete` (after `states`, the
    /// state History draws each in; a recording missing from it uses its own).
    public func runs(for metas: [SegmentMeta], states: [String: TranscriptionState]) -> Result {
        var runs: [HistorySpeechRun] = []
        var turns: [HistorySpokenTurn] = []
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
                let read = read(meta)
                entry = Entry(version: version, placement: placement, runs: read?.runs, turns: read?.turns ?? [])
                if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
                entries[meta.segmentId] = entry
            }
            if let segmentRuns = entry.runs {
                present.insert(meta.segmentId)
                runs += segmentRuns
                turns += entry.turns
            }
        }
        turns.sort { $0.startMs != $1.startMs ? $0.startMs < $1.startMs : $0.segmentId < $1.segmentId }
        return Result(runs: runs, withTranscript: present, turns: turns)
    }

    private func read(_ meta: SegmentMeta) -> (runs: [HistorySpeechRun], turns: [HistorySpokenTurn])? {
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
        let placed = ConversationBoundaryDetector.spokenRuns(evidenceMeta, evidence)
        let runs = placed.map { HistorySpeechRun(segmentId: meta.segmentId, startMs: $0.startMs, endMs: $0.endMs) }
        // `spokenRuns` maps the evidence one to one, and a `.complete` recording's evidence is
        // its timings unchanged, so run i is timing i on the wall clock.
        var turns: [HistorySpokenTurn] = []
        if placed.count == timings.count {
            // A transcriber stuck in a loop repeats one phrase for minutes; those lines are never
            // a card's snippet (`TranscriptArtefacts`, the same verdicts the transcript view hides).
            let looped = TranscriptArtefacts.loopedArtefacts(
                in: timings.map { ArtefactTurn(text: $0.text, startMs: $0.startMs) })
            for (index, (run, timing)) in zip(placed, timings).enumerated() where !looped[index] {
                guard !HistorySpokenTurn.isDegenerate(timing.text),
                    let text = HistorySpokenTurn.preview(timing.text)
                else { continue }
                turns.append(
                    HistorySpokenTurn(segmentId: meta.segmentId, startMs: run.startMs, endMs: run.endMs, text: text))
            }
        }
        return (runs, turns)
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

/// One transcript turn on the wall clock, its text cut for a preview line.
public struct HistorySpokenTurn: Equatable, Sendable {
    public static let maxCharacters = 160

    public var segmentId: String
    public var startMs: Int64
    public var endMs: Int64
    public var text: String

    public init(segmentId: String, startMs: Int64, endMs: Int64, text: String) {
        self.segmentId = segmentId
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }

    /// A single turn that is one word said over and over — the transcriber's loop inside one
    /// turn, which the across-turn detector cannot see. On the real backup: ", the, the, the,
    /// the, the, uh, you kn", "저는안녕하세요. 저는안녕하세요. 저는안녕하세요. …" and "in an apartment
    /// in Boston. I'll double I'll double I'll double I'll double". Four words or more, and fewer
    /// than a third of them distinct, or one word said four times or more making up half of them,
    /// or (seven words or more) at most half the word pairs distinct.
    public static func isDegenerate(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }
        guard words.count >= 4 else { return false }
        if Set(words).count * 3 < words.count { return true }
        var counts: [Substring: Int] = [:]
        for word in words { counts[word, default: 0] += 1 }
        let top = counts.values.max() ?? 0
        if top >= 4 && top * 2 >= words.count { return true }
        // A short phrase said over and over ("I'll double I'll double I'll double I'll double"):
        // most word pairs are repeats.
        let pairs = zip(words, words.dropFirst()).map { "\($0) \($1)" }
        return pairs.count >= 6 && Set(pairs).count * 2 <= pairs.count
    }

    /// The turn's text on one line, at most about `maxCharacters`, cut at a word; nil when
    /// nothing was said.
    public static func preview(_ text: String) -> String? {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        guard flat.count > maxCharacters else { return flat }
        let prefix = flat.prefix(maxCharacters)
        let cut = prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix
        return cut + "…"
    }
}
