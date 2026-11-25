import Foundation
import GRDB

/// What has to notice, in the database, that the words of a settled segment were replaced by better
/// ones (a cloud hearing of what this device transcribed during an outage).
///
/// Everything derived from a transcript is keyed on the segment's STATE or on which audio it covers,
/// because a finished transcript never changed; this is the exception, so each of them is told.
/// What a person made is not here: typed titles, notes, splits, names and follow-up decisions are
/// keyed to the audio and stay as they are.
public enum TranscriptReplacement {
    /// Titles and summaries are owed a rewrite (a typed title stays, and the old words stay on screen
    /// until the new ones are written), and the day's recap has these recordings to read again.
    /// Follow-ups re-read by themselves: their key holds the transcript's version.
    public static func wordsChanged(_ db: Database, segmentIds: [String]) throws {
        guard !segmentIds.isEmpty else { return }
        let marks = databaseQuestionMarks(count: segmentIds.count)
        try db.execute(
            sql: """
                UPDATE annotations
                SET isFinal = 0, finalAttempts = 0, nextAttemptAtMs = NULL, transientFailures = 0
                WHERE isFinal = 1 AND conversationId IN (
                    SELECT conversationId FROM conversation_segments WHERE segmentId IN (\(marks)))
                """,
            arguments: StatementArguments(segmentIds))
        let replaced = Set(segmentIds)
        for row in try Row.fetchAll(db, sql: "SELECT dateKey, segmentIds FROM recaps") {
            let stored: String = row["segmentIds"]
            guard let covered = try? JSONDecoder().decode([String].self, from: Data(stored.utf8))
            else { continue }
            let left = covered.filter { !replaced.contains($0) }
            guard left.count != covered.count else { continue }
            let json = String(decoding: try JSONEncoder().encode(left), as: UTF8.self)
            try db.execute(
                sql: "UPDATE recaps SET segmentIds = ? WHERE dateKey = ?",
                arguments: [json, row["dateKey"] as String])
        }
    }

    /// A recording settled as "no speech" turned out to hold some: voice identification skipped it
    /// for having none, and looks again.
    public static func gainedWords(_ db: Database, segmentId: String) throws {
        guard try db.tableExists("voice_jobs") else { return }
        try db.execute(
            sql: """
                UPDATE voice_jobs SET state = 'pending', cursorMediaMs = startMediaMs
                WHERE segmentId = ? AND state = 'done'
                """,
            arguments: [segmentId])
    }

    static func installStandIns(_ db: Database) throws {
        guard try db.tableExists("transcription_tasks") else { return }
        let columns = Set(try db.columns(in: "transcription_tasks").map(\.name))
        if !columns.contains("standInFor") {
            try db.execute(sql: "ALTER TABLE transcription_tasks ADD COLUMN standInFor TEXT")
            try db.execute(sql: "ALTER TABLE transcription_tasks ADD COLUMN rehearAttempts INTEGER")
        }
        try db.execute(
            sql: """
                CREATE INDEX IF NOT EXISTS transcription_tasks_stand_in
                ON transcription_tasks(segmentId) WHERE standInFor IS NOT NULL
                """)
        // The outage that was already in the data: Soniox refused the account from 2026-11-22
        // 22:22:04 to 2026-11-25 13:08:59 (+07), and every segment settled between them went to
        // Apple Speech. The silence floor's verdicts are not among them: they name themselves.
        try db.execute(
            sql: """
                UPDATE transcription_tasks SET standInFor = 'soniox: accountOutOfFunds'
                WHERE standInFor IS NULL AND updatedAtMs BETWEEN 1795360924000 AND 1795586940000
                  AND ((state = 'Complete' AND providerId = 'speechanalyzer'
                        AND modeUsed = 'LocalOnly')
                    OR (state = 'NoSpeech' AND lastError LIKE 'no speech - speechanalyzer:%'))
                """)
    }
}
