import Foundation
import SegmentStore
import Testing

@testable import AppDB

// The yardstick for topic-sized conversations, over a READ-ONLY copy of Roger's real library.
//
// 384 conversation starts were marked by reading eight whole days of transcripts (2026-09-19 …
// 09-29; 199 `certain`, 185 `unsure`), together with 394 "traps": pauses of two minutes or more,
// and asides, after which the SAME conversation carries on. A predicted start counts when it is
// within two minutes of a marked one, each marked start matching at most one prediction.
//
//   PEBBLE_UNITS_BACKUP=<backup root holding segments/ and transcription/transcripts/>
//   PEBBLE_UNITS_LABELS=<folder holding labels/<day>.json and days/<day>.index.json>
//
// The labels and the transcripts they were made from are a person's conversations and live
// outside the repository; the suite skips cleanly without them.

private let unitsEnv = ProcessInfo.processInfo.environment
private let unitsBackup = unitsEnv["PEBBLE_UNITS_BACKUP"]
private let unitsLabels = unitsEnv["PEBBLE_UNITS_LABELS"]

private var unitsAvailable: Bool {
    guard let unitsBackup, let unitsLabels else { return false }
    return FileManager.default.fileExists(atPath: unitsBackup + "/segments")
        && FileManager.default.fileExists(atPath: unitsLabels + "/labels")
}

private struct UnitsTranscript: Decodable {
    struct Turn: Decodable {
        var startMs: Int64
        var endMs: Int64
        var text: String?
        var speaker: String?
    }
    var segments: [Turn]?
}

private struct LabelFile: Decodable {
    struct Unit: Decodable {
        var startLine: Int
        var confidence: String
    }
    struct Trap: Decodable { var line: Int }
    var units: [Unit]
    var traps: [Trap]?
}

private struct IndexLine: Decodable {
    var line: Int
    var ws: Int64
}

struct SegmentationScore {
    var certain = 0
    var certainFound = 0
    var unsure = 0
    var unsureFound = 0
    var cuts = 0
    var cutsMatched = 0
    var traps = 0
    var trapsHit = 0
}

private func loadLibrary() throws -> (metas: [SegmentMeta], evidence: [String: SegmentSpeechEvidence]) {
    let root = URL(fileURLWithPath: unitsBackup!)
    let decoder = JSONDecoder()
    var metas: [SegmentMeta] = []
    for file in try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("segments"), includingPropertiesForKeys: nil)
    where file.lastPathComponent.hasSuffix(".meta.json") {
        metas.append(try decoder.decode(SegmentMeta.self, from: Data(contentsOf: file)))
    }
    var evidence: [String: SegmentSpeechEvidence] = [:]
    for meta in metas {
        let url = root.appendingPathComponent(
            "transcription/transcripts/\(meta.segmentId).transcript.json")
        var speech: [SpeechSpan]?
        if let data = try? Data(contentsOf: url),
            let transcript = try? decoder.decode(UnitsTranscript.self, from: data)
        {
            speech = (transcript.segments ?? []).map {
                SpeechSpan(
                    startMs: $0.startMs, endMs: $0.endMs, text: $0.text ?? "",
                    speaker: $0.speaker)
            }
        }
        evidence[meta.segmentId] = SegmentSpeechEvidence.of(meta, transcriptSpeech: speech)
    }
    return (metas, evidence)
}

private func percentile(_ sorted: [Int64], _ q: Double) -> Int64 {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
}

private func minutes(_ ms: Int64) -> String {
    let m = Double(ms) / 60_000
    return m >= 60 ? String(format: "%dh%02d", Int(m) / 60, Int(m) % 60) : String(format: "%.0fm", m)
}

@Suite(
    "Topic-sized conversations over the real library",
    .enabled(if: unitsAvailable, "set PEBBLE_UNITS_BACKUP and PEBBLE_UNITS_LABELS")
)
struct RealConversationSegmentationTests {
    static let tolerance: Int64 = 120_000

    /// Scores a grouping's conversation starts against one day's labels.
    static func score(
        starts: [Int64], day: String, into score: inout SegmentationScore
    ) throws {
        let folder = URL(fileURLWithPath: unitsLabels!)
        let decoder = JSONDecoder()
        let labels = try decoder.decode(
            LabelFile.self,
            from: Data(contentsOf: folder.appendingPathComponent("labels/\(day).json")))
        let index = try decoder.decode(
            [IndexLine].self,
            from: Data(contentsOf: folder.appendingPathComponent("days/\(day).index.json")))
        let wall = Dictionary(uniqueKeysWithValues: index.map { ($0.line, $0.ws) })
        guard let dayStart = index.first?.ws, let dayEnd = index.last?.ws else { return }
        let marked: [(ms: Int64, certain: Bool)] = labels.units.dropFirst().compactMap { unit in
            wall[unit.startLine].map { ($0, unit.confidence == "certain") }
        }
        let traps = (labels.traps ?? []).compactMap { wall[$0.line] }
        // The first conversation of the day has no start to find; leave it out on both sides.
        let cuts = starts.filter { $0 > dayStart + 1_000 && $0 <= dayEnd }

        var pairs: [(distance: Int64, cut: Int, mark: Int)] = []
        for (c, cut) in cuts.enumerated() {
            for (m, mark) in marked.enumerated() where abs(cut - mark.ms) <= tolerance {
                pairs.append((abs(cut - mark.ms), c, m))
            }
        }
        pairs.sort { $0.distance < $1.distance }
        var usedCuts = Set<Int>()
        var usedMarks = Set<Int>()
        for pair in pairs where !usedCuts.contains(pair.cut) && !usedMarks.contains(pair.mark) {
            usedCuts.insert(pair.cut)
            usedMarks.insert(pair.mark)
        }
        score.certain += marked.filter(\.certain).count
        score.unsure += marked.filter { !$0.certain }.count
        score.certainFound += usedMarks.filter { marked[$0].certain }.count
        score.unsureFound += usedMarks.filter { !marked[$0].certain }.count
        score.cuts += cuts.count
        score.cutsMatched += usedCuts.count
        score.traps += traps.count
        let unmatched = cuts.enumerated().filter { !usedCuts.contains($0.offset) }.map(\.element)
        score.trapsHit += traps.filter { trap in
            unmatched.contains { abs($0 - trap) <= tolerance }
        }.count
    }

    /// First to last labelled line of a day.
    static func dayWindow(_ day: String) throws -> ClosedRange<Int64> {
        let folder = URL(fileURLWithPath: unitsLabels!)
        let index = try JSONDecoder().decode(
            [IndexLine].self,
            from: Data(contentsOf: folder.appendingPathComponent("days/\(day).index.json")))
        return (index.first?.ws ?? 0)...(index.last?.ws ?? 0)
    }

    static let days = [
        "2026-09-19", "2026-09-20", "2026-09-21", "2026-09-22", "2026-09-23", "2026-09-27",
        "2026-09-28", "2026-09-29",
    ]

    static func report(
        _ name: String, _ all: [GroupedConversation],
        evidence: [String: SegmentSpeechEvidence]
    ) throws -> (score: SegmentationScore, spoken: [Int64]) {
        var score = SegmentationScore()
        // A unit nobody spoke in (the silent tail of a run) is not a conversation and is not
        // shown as one; it neither finds nor misses a marked start.
        let conversations = all.filter { conversation in
            conversation.members.contains { member in
                evidence[member.segmentId]?.speech.contains {
                    member.contains(mediaMs: $0.startMs)
                } ?? false
            }
        }
        let starts = conversations.map(\.startMs).sorted()
        for day in days { try Self.score(starts: starts, day: day, into: &score) }
        // Lengths of the conversations that start inside the labelled days.
        let windows = try days.map { try dayWindow($0) }
        let lengths = conversations.filter { conversation in
            windows.contains { $0.contains(conversation.startMs) }
        }.map { $0.endMs - $0.startMs }.filter { $0 > 0 }.sorted()
        let line = String(
            format:
                "%@: certain %d/%d (%.0f%%) unsure %d/%d cuts %d matched %d (%.0f%%) traps hit %d/%d | n=%d median %@ p90 %@ max %@ >1h %d >2h %d",
            name, score.certainFound, score.certain,
            100 * Double(score.certainFound) / Double(max(score.certain, 1)), score.unsureFound,
            score.unsure, score.cuts, score.cutsMatched,
            100 * Double(score.cutsMatched) / Double(max(score.cuts, 1)), score.trapsHit,
            score.traps, lengths.count, minutes(percentile(lengths, 0.5)),
            minutes(percentile(lengths, 0.9)), minutes(lengths.last ?? 0),
            lengths.filter { $0 > 3_600_000 }.count, lengths.filter { $0 > 7_200_000 }.count)
        print(line)
        return (score, lengths)
    }

    @Test func topicSizedConversationsAgainstTheLabels() throws {
        let library = try loadLibrary()
        let before = ConversationGrouper.group(
            segments: library.metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: library.evidence, policy: .quietOnly)
        let clock = ContinuousClock()
        var after: [GroupedConversation] = []
        let elapsed = clock.measure {
            after = ConversationGrouper.group(
                segments: library.metas, pauses: [], openSegmentId: nil,
                fallbackTimeZoneID: "UTC", evidence: library.evidence)
        }
        print("grouping \(library.metas.count) segments took \(elapsed)")
        // The same library again, with the cuts the first pass would have written down and a
        // memo: what a relaunch costs, and what every later pass costs.
        let first = ConversationGrouper.groupDetailed(
            segments: library.metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: library.evidence)
        var committed: [String: [Int64: ConversationStartReason]] = [:]
        for (cut, reason) in first.cutsToCommit {
            committed[cut.segmentId, default: [:]][cut.mediaMs] = reason
        }
        let inputs = ConversationCutInputs(committed: committed)
        let memo = GroupingMemo()
        var relaunch: [GroupedConversation] = []
        let cold = clock.measure {
            relaunch = ConversationGrouper.group(
                segments: library.metas, pauses: [], openSegmentId: nil,
                fallbackTimeZoneID: "UTC", evidence: library.evidence, cutInputs: inputs,
                memo: memo)
        }
        let warm = clock.measure {
            _ = ConversationGrouper.group(
                segments: library.metas, pauses: [], openSegmentId: nil,
                fallbackTimeZoneID: "UTC", evidence: library.evidence, cutInputs: inputs,
                memo: memo)
        }
        print(
            "\(first.cutsToCommit.count) cuts settled; with them a cold regroup took \(cold), a repeat \(warm)")
        // Holding the settled cuts changes nothing about the answer.
        #expect(relaunch.map(\.id) == after.map(\.id))
        let words = library.evidence.values.reduce(0) { $0 + $1.speech.count }
        let lexicon = clock.measure {
            for item in library.evidence.values {
                for span in item.speech {
                    _ = ConversationLexicon.features(
                        text: String(repeating: "word ", count: span.wordCount), speaker: "1")
                }
            }
        }
        print("lexicon over \(words) turns took \(lexicon)")
        if let dump = unitsEnv["PEBBLE_UNITS_DUMP"] {
            let rows = after.map { "\($0.startMs)\t\($0.endMs)\t\($0.startReason?.rawValue ?? "-")\t\($0.id)" }
            try rows.joined(separator: "\n").write(
                toFile: dump, atomically: true, encoding: .utf8)
        }
        let old = try Self.report("long-quiet rule only", before, evidence: library.evidence)
        let new = try Self.report("with the segmenter  ", after, evidence: library.evidence)

        // The direction, pinned: far more of the real starts found, and no conversation of
        // the kind this work exists to remove.
        #expect(new.score.certainFound > old.score.certainFound * 3)
        #expect((new.spoken.last ?? 0) < 3 * 3_600_000)
        #expect(percentile(new.spoken, 0.9) < 3_600_000)
    }

    /// "If you ever have a 10-hour conversation in any circumstance, that is a bug." The
    /// circumstance that made the 24-hour ones was audio with no transcript, so: the whole
    /// real library with NOTHING transcribed, and then with each recording in turn the only
    /// one not transcribed (one real recording holds fifteen minutes of audio across eight and
    /// a half hours of wall clock).
    @Test func noUnitIsEverDayLongWhateverIsOrIsNotTranscribed() throws {
        let library = try loadLibrary()
        func longest(_ evidence: [String: SegmentSpeechEvidence]) -> Int64 {
            ConversationGrouper.group(
                segments: library.metas, pauses: [], openSegmentId: nil,
                fallbackTimeZoneID: "UTC", evidence: evidence
            ).map { $0.endMs - $0.startMs }.max() ?? 0
        }
        let nothing = longest([:])
        print("nothing transcribed: longest unit \(minutes(nothing))")
        #expect(nothing < 2 * 3_600_000)

        // The recordings whose wall span is far longer than their audio are the dangerous ones.
        let stretched = library.metas.filter {
            ConversationGrouper.segmentEndMs($0) - ConversationGrouper.segmentStartMs($0)
                > ConversationGrouper.segmentAudioMs($0) + 3_600_000
        }
        for meta in stretched {
            var evidence = library.evidence
            evidence[meta.segmentId] = SegmentSpeechEvidence(
                segmentId: meta.segmentId, isSettled: false, speech: [])
            let worst = longest(evidence)
            print("\(meta.segmentId) untranscribed: longest unit \(minutes(worst))")
            #expect(worst < 2 * 3_600_000, "\(meta.segmentId)")
        }
    }

    /// The upgrade itself, on a copy of the real database: migrate, regroup twice, and check
    /// what the phone will see — every sample in exactly one conversation, nothing day-long,
    /// the same ids on the second pass, and nothing written when nothing changed.
    @Test func theRealDatabaseMigratesAndRegroupsIntoTopicSizedConversations() async throws {
        let root = URL(fileURLWithPath: unitsBackup!)
        let source = root.appendingPathComponent("db")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-units-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(name), to: scratch.appendingPathComponent(name))
        }
        let database = try AppDatabase.open(at: scratch.appendingPathComponent("companion.sqlite"))
        let library = try loadLibrary()
        let before = try await database.reader.read { try ConversationGrouper.fetchAll($0) }

        let memo = GroupingMemo()
        let first = try await ConversationGrouper.rebuildDetailed(
            segments: library.metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: library.evidence, memo: memo, db: database)
        let second = try await ConversationGrouper.rebuildDetailed(
            segments: library.metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: library.evidence, memo: memo, db: database)
        let settled = try await ConversationCutStore(db: database).committed()
        let longest = first.conversations.map { $0.endMs - $0.startMs }.max() ?? 0
        let longestBefore = before.map { $0.endMs - $0.startMs }.max() ?? 0
        print(
            "real database: \(before.count) conversations (longest \(minutes(longestBefore))) -> \(first.conversations.count) (longest \(minutes(longest))); \(settled.count) cuts settled")

        #expect(first.changed && first.structureChanged)
        #expect(!second.changed && !second.structureChanged)
        #expect(second.conversations.map(\.id) == first.conversations.map(\.id))
        #expect(Set(first.conversations.map(\.id)).count == first.conversations.count)
        #expect(longest < 2 * 3_600_000)

        // Every segment's stored audio is covered exactly once, in order.
        var pieces: [String: [ConversationMember]] = [:]
        for conversation in first.conversations {
            for member in conversation.members { pieces[member.segmentId, default: []].append(member) }
        }
        #expect(Set(pieces.keys) == Set(library.metas.map(\.segmentId)))
        for (segmentId, owned) in pieces {
            let ordered = owned.sorted { ($0.startMediaMs ?? 0) < ($1.startMediaMs ?? 0) }
            #expect(ordered.first?.startMediaMs == nil, "\(segmentId) does not start at 0")
            #expect(ordered.last?.endMediaMs == nil, "\(segmentId) does not run to its end")
            for (earlier, later) in zip(ordered, ordered.dropFirst()) {
                #expect(earlier.endMediaMs == later.startMediaMs, "\(segmentId) has a hole or overlap")
            }
        }
        // What was read back is what was grouped.
        let stored = try await database.reader.read { try ConversationGrouper.fetchAll($0) }
        #expect(stored.map(\.members) == first.conversations.sorted {
            $0.startMs == $1.startMs ? $0.id < $1.id : $0.startMs < $1.startMs
        }.map(\.members))
    }
}
