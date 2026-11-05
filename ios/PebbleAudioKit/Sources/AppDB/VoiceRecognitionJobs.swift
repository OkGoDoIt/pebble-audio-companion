import Foundation
import GRDB

extension VoiceIdentityStore {
    @discardableResult public func enqueueJob(
        runID: String, segmentId: String, startMediaMs: Int64, endMediaMs: Int64,
        recipeID: String, explicitRerun: Bool = false,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> VoiceRecognitionJob {
        try Self.range(startMediaMs, endMediaMs)
        guard !recipeID.isEmpty else { throw VoiceIdentityError.invalidRecord }
        return try await db.writer.write { d in
            let config = try Self.configuration(d)
            guard config.mode == .local else { throw VoiceIdentityError.disabled }
            guard let source = try Self.source(d, segmentId: segmentId) else { throw VoiceIdentityError.missingSource }
            guard try Self.activeRun(d, id: runID) else { throw VoiceIdentityError.invalidRecord }
            // Repeated foreground scans are idempotent even when they propose a new run ID. New
            // voices don't ask for the audio again: its prints are named afresh instead.
            if !explicitRerun, let row = try Row.fetchOne(d, sql: """
                SELECT * FROM voice_jobs WHERE segmentId = ? AND startMediaMs = ? AND endMediaMs = ?
                    AND recipeID = ? AND sourceRevision = ? AND sourceGeneration = ?
                    AND configGeneration = ? AND state IN ('pending','running','done') LIMIT 1
                """, arguments: [segmentId, startMediaMs, endMediaMs, recipeID, source.revision,
                    source.generation, config.generation]) { return Self.job(row) }
            if let row = try Row.fetchOne(d, sql: "SELECT * FROM voice_jobs WHERE runID = ? AND segmentId = ? AND startMediaMs = ? AND endMediaMs = ?",
                                         arguments: [runID, segmentId, startMediaMs, endMediaMs]) { return Self.job(row) }
            if explicitRerun {
                try Self.clearSuppressions(d, segmentId: segmentId, start: startMediaMs, end: endMediaMs)
                // Names on audio already analysed are brought up to date from its prints in place,
                // so an unchanged name is never deleted and re-added (nor re-sent to the archive).
                let analysed = try VoicePrintStore.analyzed(d, segmentId: segmentId, recipeID: recipeID, source: source)
                for row in try Row.fetchAll(d, sql: """
                    SELECT id, startMediaMs, endMediaMs FROM voice_auto_attributions
                    WHERE segmentId = ? AND startMediaMs < ? AND endMediaMs > ?
                    """, arguments: [segmentId, endMediaMs, startMediaMs]) {
                    // A recording with any prints has its names decided again from them, whole.
                    guard analysed.isEmpty else { continue }
                    try d.execute(sql: "DELETE FROM voice_auto_attributions WHERE id = ?", arguments: [row["id"] as String])
                }
            }
            let id = UUID().uuidString.lowercased()
            try d.execute(sql: """
                INSERT INTO voice_jobs(id,runID,segmentId,startMediaMs,endMediaMs,cursorMediaMs,recipeID,
                    sourceRevision,sourceGeneration,configGeneration,corpusRevision,updatedAtMs)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [id, runID, segmentId, startMediaMs, endMediaMs, startMediaMs, recipeID,
                    source.revision, source.generation, config.generation, config.corpusRevision, nowMs])
            return Self.job(try Row.fetchOne(d, sql: "SELECT * FROM voice_jobs WHERE id = ?", arguments: [id])!)
        }
    }

    /// The newest recording with audio left to check. New recordings are newest by nature and a
    /// history run walks back from where it was asked, so everything is in one order: what was
    /// said today, then yesterday, back to the oldest. Ordering new recordings ahead of a whole
    /// separate run meant the run got nothing whenever new audio arrived faster than it could
    /// be checked, which was always (2026-11-05: 15 h a day arriving, 10 h checked, a 530 h run
    /// that had analysed 21 windows in three days). A recording still being transcribed waits:
    /// its transcript says where the speech is and who is who.
    public func claimNextJob(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws -> VoiceRecognitionJob? {
        try await db.writer.write { d in
            while true {
                guard let row = try Row.fetchOne(d, sql: """
                    SELECT * FROM voice_jobs j WHERE j.state = 'pending'
                        AND NOT EXISTS (SELECT 1 FROM transcription_tasks t WHERE t.segmentId = j.segmentId
                                        AND t.state IN ('Pending', 'Running', 'Uploading'))
                    ORDER BY j.segmentId DESC, j.rowid DESC LIMIT 1
                    """) else { return nil }
                var job = Self.job(row)
                // Only the job about to run is checked. Sweeping the whole queue here was a
                // correlated scan of every pending row for every window.
                guard try Self.validWork(d, segmentId: job.segmentId, token: job.token),
                      try Self.activeRun(d, id: job.runID) else {
                    try d.execute(sql: "UPDATE voice_jobs SET state = 'cancelled' WHERE id = ?", arguments: [job.id])
                    continue
                }
                try d.execute(sql: "UPDATE voice_jobs SET state = 'running', updatedAtMs = ? WHERE id = ?", arguments: [nowMs, job.id])
                job.state = .running; job.updatedAtMs = nowMs
                return job
            }
        }
    }

    /// A bounded window and its cursor commit together. Retries cannot lose a window or apply
    /// it twice. Manual corrections overlapping a prediction suppress that prediction only.
    /// `window` is the audio analysed, with the `prints` of its turns; `matchedCorpus` is the
    /// voices the names were matched against (the job's own by default). Names from voices
    /// that have changed since are not saved; the prints are, and are named again from there.
    @discardableResult public func advanceJob(
        id: String, expectedCursorMediaMs: Int64, nextCursorMediaMs: Int64,
        attributions: [VoiceAutomaticAttribution], unmatched: [VoiceUnmatchedCrop] = [],
        window: Range<Int64>? = nil, prints: [VoiceTurnPrint] = [], matchedCorpus: Int64? = nil,
        nameWhenDone: Bool = false, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> Bool {
        guard attributions.count <= 256 else { throw VoiceIdentityError.capacityExceeded }
        for attribution in attributions { try Self.validate(attribution) }
        return try await db.writer.write { d in
            guard let row = try Row.fetchOne(d, sql: "SELECT * FROM voice_jobs WHERE id = ?", arguments: [id]) else { return false }
            let job = Self.job(row)
            guard job.state == .running, job.cursorMediaMs == expectedCursorMediaMs,
                  try Self.validWork(d, segmentId: job.segmentId, token: job.token),
                  try Self.activeRun(d, id: job.runID) else { return false }
            guard nextCursorMediaMs > expectedCursorMediaMs, nextCursorMediaMs <= job.endMediaMs,
                  window.map({ $0.lowerBound >= expectedCursorMediaMs && $0.upperBound <= nextCursorMediaMs }) ?? prints.isEmpty
            else { throw VoiceIdentityError.invalidRecord }
            let matched = matchedCorpus ?? job.token.corpusRevision
            let current = try Self.configuration(d).corpusRevision
            if let window {
                try VoicePrintStore.recordWindow(d, job: job, window: window, prints: prints, matchedCorpus: matched)
            }
            for a in attributions {
                guard a.segmentId == job.segmentId, a.runID == job.runID, a.recipeID == job.recipeID,
                      a.startMediaMs >= expectedCursorMediaMs, a.endMediaMs <= nextCursorMediaMs,
                      a.sourceRevision == job.token.sourceRevision else { throw VoiceIdentityError.invalidRecord }
                if matched == current { _ = try Self.insertAutomatic(d, attribution: a, token: job.token) }
            }
            guard unmatched.allSatisfy({ $0.segmentId == job.segmentId && $0.recipeID == job.recipeID
                && $0.startMediaMs >= expectedCursorMediaMs && $0.endMediaMs <= nextCursorMediaMs
                && $0.sourceRevision == job.token.sourceRevision }) else { throw VoiceIdentityError.invalidRecord }
            try VoiceUnmatchedStore.insert(d, unmatched)
            try d.execute(sql: "UPDATE voice_jobs SET cursorMediaMs = ?, state = ?, updatedAtMs = ?, attempts = 0, lastError = NULL WHERE id = ?",
                          arguments: [nextCursorMediaMs, nextCursorMediaMs == job.endMediaMs ? "done" : "pending", nowMs, id])
            if nameWhenDone, nextCursorMediaMs == job.endMediaMs { try VoicePrintStore.markStale(d, segmentId: job.segmentId) }
            return true
        }
    }

    /// Moves the cursor over audio already analysed (for this run or another): no model time,
    /// and the stretch's prints are named for this run from what they hold.
    @discardableResult public func adoptAnalyzed(
        id: String, expectedCursorMediaMs: Int64, nextCursorMediaMs: Int64,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> Bool {
        try await db.writer.write { d in
            guard let row = try Row.fetchOne(d, sql: "SELECT * FROM voice_jobs WHERE id = ?", arguments: [id]) else { return false }
            let job = Self.job(row)
            guard job.state == .running, job.cursorMediaMs == expectedCursorMediaMs,
                  try Self.validWork(d, segmentId: job.segmentId, token: job.token),
                  try Self.activeRun(d, id: job.runID) else { return false }
            guard nextCursorMediaMs > expectedCursorMediaMs, nextCursorMediaMs <= job.endMediaMs else {
                throw VoiceIdentityError.invalidRecord
            }
            try VoicePrintStore.adopt(d, segmentId: job.segmentId,
                                      range: expectedCursorMediaMs..<nextCursorMediaMs, runID: job.runID)
            try d.execute(sql: "UPDATE voice_jobs SET cursorMediaMs = ?, state = ?, updatedAtMs = ?, attempts = 0, lastError = NULL WHERE id = ?",
                          arguments: [nextCursorMediaMs, nextCursorMediaMs == job.endMediaMs ? "done" : "pending", nowMs, id])
            return true
        }
    }

    /// Nothing in this stretch to analyse (no speech in it): the cursor moves, no model runs.
    @discardableResult public func skipJob(id: String, expectedCursorMediaMs: Int64, nextCursorMediaMs: Int64,
                                           nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws -> Bool {
        try await db.writer.write { d in
            guard let row = try Row.fetchOne(d, sql: "SELECT * FROM voice_jobs WHERE id = ?", arguments: [id]) else { return false }
            let job = Self.job(row)
            guard job.state == .running, job.cursorMediaMs == expectedCursorMediaMs,
                  try Self.validWork(d, segmentId: job.segmentId, token: job.token) else { return false }
            guard nextCursorMediaMs > expectedCursorMediaMs, nextCursorMediaMs <= job.endMediaMs else {
                throw VoiceIdentityError.invalidRecord
            }
            try d.execute(sql: "UPDATE voice_jobs SET cursorMediaMs = ?, state = ?, updatedAtMs = ?, attempts = 0, lastError = NULL WHERE id = ?",
                          arguments: [nextCursorMediaMs, nextCursorMediaMs == job.endMediaMs ? "done" : "pending", nowMs, id])
            if nextCursorMediaMs == job.endMediaMs { try VoicePrintStore.markStale(d, segmentId: job.segmentId) }
            return true
        }
    }

    /// Recordings whose audio has been read before and is still wanted.
    public func readySources() async throws -> Set<String> {
        try await db.reader.read { d in
            Set(try String.fetchAll(d, sql: "SELECT segmentId FROM voice_sources WHERE state = 'ready'"))
        }
    }

    /// Whether transcription found no speech anywhere in this recording.
    public func transcribedAsNoSpeech(segmentId: String) async throws -> Bool {
        try await db.reader.read { d in
            try Bool.fetchOne(d, sql: "SELECT EXISTS(SELECT 1 FROM transcription_tasks WHERE segmentId = ? AND state = 'NoSpeech')",
                              arguments: [segmentId]) ?? false
        }
    }

    /// Recordings with live or finished work over the whole of their audio, and how long that
    /// audio was: one read that saves a launch re-reading each recording to learn it's queued.
    public func coveredRecordings() async throws -> [String: Int64] {
        try await db.reader.read { d in
            var out: [String: Int64] = [:]
            for row in try Row.fetchAll(d, sql: """
                SELECT segmentId, MAX(endMediaMs) AS endMs FROM voice_jobs
                WHERE startMediaMs = 0 AND state IN ('pending', 'running', 'done') GROUP BY segmentId
                """) { out[row["segmentId"]] = row["endMs"] }
            return out
        }
    }

    public func failJob(id: String, error: String, retryable: Bool,
                        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws {
        try await db.writer.write { d in
            try d.execute(sql: """
                UPDATE voice_jobs SET attempts = attempts + 1, updatedAtMs = ?, lastError = ?,
                    state = CASE WHEN ? AND attempts < 2 THEN 'pending' ELSE 'failed' END
                WHERE id = ? AND state = 'running'
                """, arguments: [nowMs, String(error.prefix(512)), retryable, id])
        }
    }

    /// A history run that now covers a recording takes over its waiting new-recording job, so the
    /// run's progress is the whole of what is left and the recording is checked once, in the
    /// run's order. Windows already analysed are kept as prints, which the run adopts for free.
    @discardableResult public func foldRecentJobs(segmentId: String, startMediaMs: Int64,
                                                  endMediaMs: Int64) async throws -> Int {
        try await db.writer.write { d in
            try d.execute(sql: """
                UPDATE voice_jobs SET state = 'cancelled'
                WHERE segmentId = ? AND runID LIKE 'recent:%' AND state = 'pending'
                    AND startMediaMs >= ? AND endMediaMs <= ?
                """, arguments: [segmentId, startMediaMs, endMediaMs])
            return d.changesCount
        }
    }

    /// Backgrounding or memory pressure pauses the window without spending a retry attempt.
    public func releaseJob(id: String) async throws {
        try await db.writer.write { d in
            try d.execute(sql: "UPDATE voice_jobs SET state = 'pending' WHERE id = ? AND state = 'running'", arguments: [id])
        }
    }

    /// Called once when a worker starts. No timers, polling, or inference is performed by DB.
    public func resumeInterruptedJobs() async throws {
        try await db.writer.write { d in
            try Self.cancelStaleJobs(d)
            try d.execute(sql: "UPDATE voice_jobs SET state = 'pending' WHERE state = 'running'")
        }
    }

    public func cancelRun(_ runID: String) async throws {
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO voice_runs(runID,state) VALUES (?, 'cancelled') ON CONFLICT(runID) DO UPDATE SET state = 'cancelled'", arguments: [runID])
            // A stopped recording's speakers are named from what was heard of them.
            try d.execute(sql: """
                UPDATE voice_print_sources SET matchedCorpus = \(VoicePrintStore.staleCorpus)
                WHERE matchedCorpus <> \(VoicePrintStore.frozenCorpus) AND segmentId IN (
                    SELECT segmentId FROM voice_jobs WHERE runID = ? AND state IN ('pending','running'))
                """, arguments: [runID])
            try d.execute(sql: "UPDATE voice_jobs SET state = 'cancelled' WHERE runID = ? AND state IN ('pending','running')", arguments: [runID])
        }
    }

    /// Undo removes automatic names from the run's ranges and prevents the normal worker from
    /// immediately restoring them. Only an explicit rerun removes these suppression ranges.
    public func undoRun(_ runID: String) async throws {
        try await db.writer.write { d in
            try VoiceArchiveRevocationStore.revoke(d, scope: .run, targetID: runID)
            try d.execute(sql: """
                INSERT INTO voice_suppressions(segmentId,startMediaMs,endMediaMs)
                    SELECT segmentId,startMediaMs,endMediaMs FROM voice_jobs WHERE runID = ?
                    UNION SELECT segmentId,startMediaMs,endMediaMs FROM voice_auto_attributions WHERE runID = ?
                """, arguments: [runID, runID])
            // Undo this pass only. A newer explicit rerun may legitimately cover the same audio.
            try d.execute(sql: "DELETE FROM voice_auto_attributions WHERE runID = ?", arguments: [runID])
            try d.execute(sql: "INSERT INTO voice_runs(runID,state) VALUES (?, 'undone') ON CONFLICT(runID) DO UPDATE SET state = 'undone'", arguments: [runID])
            try d.execute(sql: "UPDATE voice_jobs SET state = 'cancelled' WHERE runID = ?", arguments: [runID])
        }
    }

    public func jobs(runID: String, limit: Int = 512) async throws -> [VoiceRecognitionJob] {
        try await db.reader.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM voice_jobs WHERE runID = ? ORDER BY updatedAtMs, id LIMIT ?",
                             arguments: [runID, max(1, min(512, limit))]).map(Self.job)
        }
    }

    /// Recordings with a job that failed for good and nothing still waiting for them.
    public func failedRecordingCount() async throws -> Int {
        try await db.reader.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(DISTINCT segmentId) FROM voice_jobs f WHERE f.state = 'failed'
                    AND NOT EXISTS (SELECT 1 FROM voice_jobs p WHERE p.segmentId = f.segmentId
                                    AND p.state IN ('pending', 'running', 'done') AND p.updatedAtMs > f.updatedAtMs)
                """) ?? 0
        }
    }

    /// Recordings with audio still to check, whichever run asked for them, and recordings
    /// whose names are still from voices that have changed since.
    public func pendingRecordingCount() async throws -> Int {
        try await db.reader.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM (
                    SELECT segmentId FROM voice_jobs WHERE state IN ('pending', 'running')
                    UNION
                    SELECT p.segmentId FROM voice_print_sources p JOIN voice_sources s ON s.segmentId = p.segmentId
                    WHERE s.state = 'ready' AND s.generation = p.sourceGeneration AND s.revision = p.sourceRevision
                        AND p.matchedCorpus NOT IN ((SELECT corpusRevision FROM voice_recognition_config WHERE id = 1), ?)
                        -- With no voices at all there are no names to bring up to date.
                        AND EXISTS (SELECT 1 FROM voice_examples))
                """, arguments: [VoicePrintStore.frozenCorpus]) ?? 0
        }
    }

    public func runs(limit: Int = 20) async throws -> [VoiceRunSummary] {
        try await db.reader.read { d in
            try Row.fetchAll(d, sql: """
                SELECT runID, SUM(state = 'pending') AS pending, SUM(state = 'running') AS running,
                    SUM(state = 'done') AS done, SUM(state = 'failed') AS failed, SUM(state = 'cancelled') AS cancelled,
                    SUM(cursorMediaMs - startMediaMs) AS completedMediaMs,
                    SUM(endMediaMs - startMediaMs) AS totalMediaMs, MAX(updatedAtMs) AS updatedAtMs,
                    SUM(CASE WHEN state IN ('done', 'failed') THEN 1.0 WHEN state = 'cancelled' THEN 0.0
                        ELSE CAST(cursorMediaMs - startMediaMs AS REAL) / MAX(1, endMediaMs - startMediaMs) END) AS progress
                FROM voice_jobs GROUP BY runID ORDER BY updatedAtMs DESC LIMIT ?
                """, arguments: [max(1, min(100, limit))]).map { row in
                    VoiceRunSummary(runID: row["runID"], pending: row["pending"], running: row["running"], done: row["done"],
                        failed: row["failed"], cancelled: row["cancelled"], completedMediaMs: row["completedMediaMs"],
                        totalMediaMs: row["totalMediaMs"], updatedAtMs: row["updatedAtMs"],
                        progress: row["progress"] ?? 0)
                }
        }
    }

    static func job(_ r: Row) -> VoiceRecognitionJob {
        VoiceRecognitionJob(id: r["id"], runID: r["runID"], segmentId: r["segmentId"], recipeID: r["recipeID"],
            startMediaMs: r["startMediaMs"], endMediaMs: r["endMediaMs"], cursorMediaMs: r["cursorMediaMs"], updatedAtMs: r["updatedAtMs"],
            token: VoiceWorkToken(configGeneration: r["configGeneration"], corpusRevision: r["corpusRevision"],
                                 sourceGeneration: r["sourceGeneration"], sourceRevision: r["sourceRevision"]),
            state: VoiceJobState(rawValue: r["state"]) ?? .cancelled, attempts: r["attempts"], lastError: r["lastError"])
    }
    /// Work outlives new voices (its prints are named again), never a switch-off or a changed recording.
    static func cancelStaleJobs(_ d: Database) throws {
        try d.execute(sql: """
            UPDATE voice_jobs SET state = 'cancelled' WHERE state IN ('pending','running') AND (
                NOT EXISTS (SELECT 1 FROM voice_recognition_config c WHERE c.mode = 'local'
                    AND c.generation = voice_jobs.configGeneration)
                OR NOT EXISTS (SELECT 1 FROM voice_sources s WHERE s.segmentId = voice_jobs.segmentId
                    AND s.state = 'ready' AND s.generation = voice_jobs.sourceGeneration AND s.revision = voice_jobs.sourceRevision)
                OR NOT EXISTS (SELECT 1 FROM voice_runs r WHERE r.runID = voice_jobs.runID AND r.state = 'active'))
            """)
    }
    static func clearSuppressions(_ d: Database, segmentId: String, start: Int64, end: Int64) throws {
        let rows = try Row.fetchAll(d, sql: "SELECT * FROM voice_suppressions WHERE segmentId = ? AND startMediaMs < ? AND endMediaMs > ?",
                                   arguments: [segmentId, end, start])
        for row in rows {
            let id: Int64 = row["id"], lower: Int64 = row["startMediaMs"], upper: Int64 = row["endMediaMs"]
            try d.execute(sql: "DELETE FROM voice_suppressions WHERE id = ?", arguments: [id])
            for (a, b) in [(lower, min(start, upper)), (max(end, lower), upper)] where b > a {
                try d.execute(sql: "INSERT INTO voice_suppressions(segmentId,startMediaMs,endMediaMs) VALUES (?,?,?)", arguments: [segmentId, a, b])
            }
        }
    }
}
