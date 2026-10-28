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
            try Self.cancelStaleJobs(d)
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
                    let start: Int64 = row["startMediaMs"], end: Int64 = row["endMediaMs"]
                    guard !analysed.contains(where: { $0.lowerBound <= start && end <= $0.upperBound }) else { continue }
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

    public func claimNextJob(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws -> VoiceRecognitionJob? {
        try await db.writer.write { d in
            try Self.cancelStaleJobs(d)
            // New recordings before a history run: the conversations just had are the ones being read.
            guard let row = try Row.fetchOne(d, sql: """
                SELECT * FROM voice_jobs WHERE state = 'pending'
                ORDER BY (runID LIKE 'recent:%') DESC, updatedAtMs, id LIMIT 1
                """) else { return nil }
            var job = Self.job(row)
            try d.execute(sql: "UPDATE voice_jobs SET state = 'running', updatedAtMs = ? WHERE id = ?", arguments: [nowMs, job.id])
            job.state = .running; job.updatedAtMs = nowMs
            return job
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
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
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

    /// Backgrounding or memory pressure pauses the window without spending a retry attempt.
    public func releaseJob(id: String) async throws {
        try await db.writer.write { d in
            try Self.cancelStaleJobs(d)
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
                    SUM(endMediaMs - startMediaMs) AS totalMediaMs, MAX(updatedAtMs) AS updatedAtMs
                FROM voice_jobs GROUP BY runID ORDER BY updatedAtMs DESC LIMIT ?
                """, arguments: [max(1, min(100, limit))]).map { row in
                    VoiceRunSummary(runID: row["runID"], pending: row["pending"], running: row["running"], done: row["done"],
                        failed: row["failed"], cancelled: row["cancelled"], completedMediaMs: row["completedMediaMs"],
                        totalMediaMs: row["totalMediaMs"], updatedAtMs: row["updatedAtMs"])
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
