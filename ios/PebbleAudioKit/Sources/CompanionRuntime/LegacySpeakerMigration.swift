import AppDB
import Foundation
import GRDB
import Transcription

/// Before replacing a transcript, preserve its older label-based human names on their actual
/// audio. Request-local speaker numbers must never name a different voice after retranscription.
enum LegacySpeakerMigration {
    struct Outcome: Sendable {
        var anchoredRanges = 0
        var unanchoredAssignments = 0
    }

    private struct Candidate {
        var range: Range<Int64>
        var personId: String
        var assignment: String
    }

    static func anchorBeforeReprocessing(
        segmentId: String, transcript: SegmentTranscript?, database: AppDatabase, nowMs: Int64
    ) async throws -> Outcome {
        try await database.writer.write { db in
            let owningPieces = try Row.fetchAll(db, sql: """
                SELECT conversationId, startMediaMs, endMediaMs FROM conversation_segments
                WHERE segmentId = ? ORDER BY conversationId
                """, arguments: [segmentId])
            var outcome = Outcome()
            var candidates: [Candidate] = []
            var targetAssignments = Set<String>()
            for piece in owningPieces {
                let conversationId: String = piece["conversationId"]
                let assignments = try Row.fetchAll(db, sql: """
                    SELECT sa.label, sa.personId, p.name FROM speaker_assignments sa
                    JOIN people p ON p.id = sa.personId WHERE sa.conversationId = ?
                    """, arguments: [conversationId]).map { row in
                        SpeakerAssignment(conversationId: conversationId, label: row["label"],
                                          personId: row["personId"], personName: row["name"])
                    }
                let relevant = assignments.filter {
                    SpeakerKey(stored: $0.label).map { $0.segmentId == segmentId } ?? true
                }
                guard !relevant.isEmpty else { continue }
                let lower: Int64 = piece["startMediaMs"] ?? 0
                let upper: Int64 = piece["endMediaMs"] ?? Int64.max
                for assignment in relevant {
                    targetAssignments.insert("\(conversationId)|\(assignment.label)")
                }
                for turn in transcript?.segments ?? [] {
                    guard turn.startMs >= lower, turn.startMs < upper,
                        let speaker = turn.speaker,
                        let assignment = SpeakerAssignment.match(
                            SpeakerKey(segmentId: segmentId, label: speaker), in: assignments)
                    else { continue }
                    let start = max(turn.startMs, lower)
                    let end = min(turn.endMs, upper)
                    guard start >= 0, end > start else { continue }
                    candidates.append(Candidate(range: start..<end, personId: assignment.personId,
                                                assignment: "\(conversationId)|\(assignment.label)"))
                }

                // Older broad names also covered neighboring segments. Materialize their
                // current effective names there before removing the broad keys, including
                // scoped-over-broad precedence. No neighbor's existing scoped row is changed.
                let broad = relevant.filter { SpeakerKey(stored: $0.label) == nil }
                if !broad.isEmpty {
                    let neighbors = try String.fetchAll(db, sql: """
                        SELECT DISTINCT segmentId FROM conversation_segments
                        WHERE conversationId = ? AND segmentId <> ?
                        """, arguments: [conversationId, segmentId])
                    let rawLabels = Set(broad.map { SpeakerKey(segmentId: segmentId, label: $0.label).label })
                    for neighbor in neighbors {
                        for label in rawLabels {
                            let key = SpeakerKey(segmentId: neighbor, label: label)
                            guard let assignment = SpeakerAssignment.match(key, in: assignments) else { continue }
                            try db.execute(sql: """
                                INSERT OR IGNORE INTO speaker_assignments (conversationId, label, personId)
                                VALUES (?, ?, ?)
                                """, arguments: [conversationId, key.stored, assignment.personId])
                        }
                    }
                }
                for assignment in relevant {
                    try db.execute(sql: "DELETE FROM speaker_assignments WHERE conversationId = ? AND label = ?",
                                   arguments: [conversationId, assignment.label])
                }
            }
            let protected = try Row.fetchAll(db, sql: """
                SELECT startMediaMs, endMediaMs FROM speaker_corrections WHERE segmentId = ?
                """, arguments: [segmentId]).map { row -> Range<Int64> in
                    let start: Int64 = row["startMediaMs"]
                    let end: Int64 = row["endMediaMs"]
                    return start..<end
                }
            var inserted = protected
            var anchored = Set<String>()
            for candidate in candidates {
                // Overlapping different speakers cannot be represented by a single-person
                // correction. Keep the overlap unnamed instead of picking whichever came first.
                let conflicting = candidates.filter { $0.personId != candidate.personId }.map(\.range)
                let ranges = ArchiveExport.subtract([candidate.range], inserted + conflicting)
                for range in ranges {
                    try db.execute(sql: """
                        INSERT INTO speaker_corrections
                            (id, segmentId, startMediaMs, endMediaMs, personId, createdAtMs)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [UUID().uuidString.lowercased(), segmentId, range.lowerBound,
                                           range.upperBound, candidate.personId, nowMs])
                    inserted.append(range)
                    outcome.anchoredRanges += 1
                }
                // An existing manual decision safely protects the passage even when it leaves
                // no uncovered range to migrate.
                if !ranges.isEmpty || protected.contains(where: { $0.overlaps(candidate.range) }) {
                    anchored.insert(candidate.assignment)
                }
            }
            outcome.unanchoredAssignments = targetAssignments.subtracting(anchored).count
            return outcome
        }
    }
}
