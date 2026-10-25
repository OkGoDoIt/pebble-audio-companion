import Foundation
import GRDB

/// Account-local, opt-in acoustic evidence. Predictions and human examples are separate tables.
/// Every asynchronous result must present the token captured before audio decoding/inference.
public struct VoiceIdentityStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func configuration() async throws -> VoiceRecognitionConfiguration {
        try await db.reader.read { try Self.configuration($0) }
    }

    /// Off invalidates in-flight work but leaves already displayed names frozen until removed.
    public func setMode(_ mode: VoiceRecognitionMode, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws {
        try await db.writer.write { d in
            try d.execute(sql: """
                UPDATE voice_recognition_config SET mode = ?, generation = generation + 1,
                    enabledAtMs = CASE WHEN ? = 'local' THEN ? ELSE enabledAtMs END WHERE id = 1 AND mode <> ?
                """, arguments: [mode.rawValue, mode.rawValue, nowMs, mode.rawValue])
            if mode == .off {
                try d.execute(sql: "UPDATE voice_jobs SET state = 'cancelled' WHERE state IN ('pending','running')")
                try d.execute(sql: "UPDATE voice_history_plans SET state = 'cancelled' WHERE state = 'active'")
            }
        }
    }

    /// Must precede decoding. A deleted ID can never be resurrected by a delayed decoder.
    /// A redacted source requires a genuinely different digest before becoming usable again.
    public func prepareSource(segmentId: String, revision: String) async throws -> VoiceSourceState {
        guard !segmentId.isEmpty, !revision.isEmpty else { throw VoiceIdentityError.invalidRecord }
        return try await db.writer.write { d in
            if try Bool.fetchOne(d, sql: "SELECT EXISTS(SELECT 1 FROM voice_source_revocations WHERE segmentId = ? AND revision = ?)",
                                 arguments: [segmentId, revision]) == true { throw VoiceIdentityError.sourceInvalidated }
            if let row = try Row.fetchOne(d, sql: "SELECT * FROM voice_sources WHERE segmentId = ?", arguments: [segmentId]) {
                let state: String = row["state"]
                let oldRevision: String = row["revision"]
                if state == "deleted" || state == "expired" { throw VoiceIdentityError.sourceDeleted }
                if state == "invalidated", oldRevision == revision { throw VoiceIdentityError.sourceInvalidated }
                if oldRevision != revision {
                    try d.execute(sql: "INSERT OR IGNORE INTO voice_source_revocations(segmentId,revision) VALUES (?,?)", arguments: [segmentId, oldRevision])
                    try Self.eraseSourceArtifacts(d, segmentId: segmentId)
                    try d.execute(sql: "UPDATE voice_sources SET revision = ?, generation = generation + 1, state = 'ready' WHERE segmentId = ?",
                                  arguments: [revision, segmentId])
                }
            } else {
                try d.execute(sql: "INSERT INTO voice_sources(segmentId, revision) VALUES (?, ?)", arguments: [segmentId, revision])
            }
            return try Self.source(d, segmentId: segmentId)!
        }
    }

    public func workContext(segmentId: String) async throws -> VoiceWorkContext? {
        try await db.reader.read { d in
            guard let source = try Self.source(d, segmentId: segmentId) else { return nil }
            return VoiceWorkContext(configuration: try Self.configuration(d), source: source,
                                    examples: try Self.examples(d, personId: nil))
        }
    }

    public func examples(personId: String? = nil) async throws -> [VoiceConfirmedExample] {
        try await db.reader.read { try Self.examples($0, personId: personId) }
    }

    public func automaticSegmentIds(personId: String? = nil, runID: String? = nil) async throws -> [String] {
        try await db.reader.read { d in
            try String.fetchAll(d, sql: """
                SELECT DISTINCT segmentId FROM voice_auto_attributions
                WHERE (? IS NULL OR personId = ?) AND (? IS NULL OR runID = ?) ORDER BY segmentId
                """, arguments: [personId, personId, runID, runID])
        }
    }

    public func profiles() async throws -> [VoiceProfileSummary] {
        try await db.reader.read { d in
            let people = try Row.fetchAll(d, sql: """
                SELECT p.*, COUNT(e.id) AS exampleCount, MAX(e.createdAtMs) AS updatedAtMs,
                    p.id IS (SELECT currentUserPersonId FROM speaker_identity_state WHERE id = 1) AS isCurrentUser
                FROM people p JOIN voice_examples e ON e.personId = p.id GROUP BY p.id
                ORDER BY isCurrentUser DESC, p.name COLLATE NOCASE, p.id
                """)
            return try people.map { row in
                let id: String = row["id"]
                return VoiceProfileSummary(person: Person(id: id, name: row["name"], isCurrentUser: row["isCurrentUser"]),
                    exampleCount: row["exampleCount"], updatedAtMs: row["updatedAtMs"],
                    recipeIDs: try String.fetchAll(d, sql: "SELECT DISTINCT recipeID FROM voice_examples WHERE personId = ? ORDER BY recipeID", arguments: [id]))
            }
        }
    }

    /// Only call from a human confirmation action. Inference results have no conversion API.
    /// Repeated crops are deduplicated, and each person/recipe is capped at 32 examples.
    @discardableResult public func commitExample(_ example: VoiceConfirmedExample, token: VoiceWorkToken) async throws -> Bool {
        try await commitExamples([example], token: token)
    }

    /// A guided enrollment's disjoint crops commit as one decision. Cancellation or a bad crop
    /// cannot leave a partially saved profile, and one enrollment advances one corpus revision.
    @discardableResult public func commitExamples(
        _ examples: [VoiceConfirmedExample], token: VoiceWorkToken,
        authorize: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Bool {
        guard !examples.isEmpty, examples.count <= 32, let first = examples.first,
              examples.allSatisfy({ $0.segmentId == first.segmentId && $0.personId == first.personId }) else {
            throw VoiceIdentityError.invalidRecord
        }
        for example in examples { try Self.validate(example) }
        return try await db.writer.write { d in
            guard authorize(), try Self.valid(d, segmentId: first.segmentId, token: token, requiresEnabled: false),
                  examples.allSatisfy({ $0.sourceRevision == token.sourceRevision }) else { return false }
            let originalRevision = try Self.configuration(d).corpusRevision
            let identity = try SpeakerCorrectionStore.fetchSnapshot(d, segmentIds: [first.segmentId])
            for example in examples {
                guard !identity.corrections.contains(where: {
                    $0.segmentId == example.segmentId && $0.startMediaMs < example.endMediaMs
                        && $0.endMediaMs > example.startMediaMs && $0.person?.id != example.personId
                }) else { throw VoiceIdentityError.invalidRecord }
                // Partially overlapping recrops of the same audio are not independent evidence.
                let duplicate = try String.fetchOne(d, sql: """
                    SELECT id FROM voice_examples WHERE personId = ? AND segmentId = ? AND startMediaMs < ?
                        AND endMediaMs > ? AND sourceRevision = ? AND recipeID = ? LIMIT 1
                    """, arguments: [example.personId, example.segmentId, example.endMediaMs, example.startMediaMs, example.sourceRevision, example.recipeID])
                if duplicate != nil { continue }
                let count = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM voice_examples WHERE personId = ? AND recipeID = ?",
                                            arguments: [example.personId, example.recipeID]) ?? 0
                guard count < 32 else { throw VoiceIdentityError.capacityExceeded }
                try d.execute(sql: """
                    INSERT INTO voice_examples(id,personId,confirmationID,sessionID,segmentId,startMediaMs,endMediaMs,
                        sourceRevision,recipeID,recipeJSON,embeddingJSON,qualityJSON,createdAtMs)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [example.id, example.personId, example.confirmationID, example.sessionID,
                        example.segmentId, example.startMediaMs, example.endMediaMs, example.sourceRevision, example.recipeID,
                        example.recipeJSON, example.embeddingJSON, example.qualityJSON, example.createdAtMs])
            }
            try d.execute(sql: "UPDATE voice_recognition_config SET corpusRevision = ? WHERE id = 1 AND corpusRevision > ?",
                          arguments: [originalRevision + 1, originalRevision])
            return true
        }
    }

    public func removeExample(id: String) async throws {
        try await db.writer.write { d in
            guard let person = try String.fetchOne(d, sql: "SELECT personId FROM voice_examples WHERE id = ?", arguments: [id]) else { return }
            try d.execute(sql: "DELETE FROM voice_examples WHERE id = ?", arguments: [id])
            // Existing predictions may have depended on this example; retaining them would
            // make 'remove example' misleading. Human names remain untouched.
            try d.execute(sql: "DELETE FROM voice_auto_attributions WHERE personId = ?", arguments: [person])
        }
    }

    public func forgetProfile(personId: String) async throws {
        try await db.writer.write { d in
            try VoiceArchiveRevocationStore.revoke(d, scope: .person, targetID: personId)
            try d.execute(sql: "DELETE FROM voice_examples WHERE personId = ?", arguments: [personId])
            try d.execute(sql: "DELETE FROM voice_auto_attributions WHERE personId = ?", arguments: [personId])
            // Even an already empty profile can have an in-flight first enrollment.
            try d.execute(sql: "UPDATE voice_recognition_config SET corpusRevision = corpusRevision + 1 WHERE id = 1")
        }
    }

    @discardableResult public func commitAutomatic(_ attribution: VoiceAutomaticAttribution, token: VoiceWorkToken) async throws -> Bool {
        try Self.validate(attribution)
        return try await db.writer.write { d in
            guard try Self.valid(d, segmentId: attribution.segmentId, token: token) else { return false }
            return try Self.insertAutomatic(d, attribution: attribution, token: token)
        }
    }

    /// Forget only acoustic state. A segment deletion tombstone survives so late work cannot
    /// recreate examples after deletion. Standalone enrollment sources use the same contract.
    public func deleteSource(segmentId: String) async throws {
        try await db.writer.write { d in
            try Self.eraseSourceArtifacts(d, segmentId: segmentId)
            try d.execute(sql: """
                INSERT INTO voice_sources(segmentId,revision,generation,state) VALUES (?, '', 1, 'deleted')
                ON CONFLICT(segmentId) DO UPDATE SET generation = generation + 1, state = 'deleted'
                """, arguments: [segmentId])
        }
    }

    /// Routine recording retention is separate from the explicitly saved voice profile.
    /// Keep confirmed vectors and their provenance; expire only work and names on this source.
    public func expireSource(segmentId: String) async throws {
        try await db.writer.write { d in
            for table in ["voice_auto_attributions", "voice_jobs", "voice_suppressions"] {
                try d.execute(sql: "DELETE FROM \(table) WHERE segmentId = ?", arguments: [segmentId])
            }
            try d.execute(sql: """
                INSERT INTO voice_sources(segmentId,revision,generation,state) VALUES (?, '', 1, 'expired')
                ON CONFLICT(segmentId) DO UPDATE SET generation = generation + 1,
                    state = CASE WHEN state = 'deleted' THEN 'deleted' ELSE 'expired' END
                """, arguments: [segmentId])
        }
    }

    public func removeSourceRange(segmentId: String, startMediaMs: Int64, endMediaMs: Int64) async throws {
        try Self.range(startMediaMs, endMediaMs)
        try await db.writer.write { d in
            try Self.eraseDependentPredictions(d, segmentId: segmentId, start: startMediaMs, end: endMediaMs)
            for table in ["voice_examples", "voice_auto_attributions"] {
                try d.execute(sql: "DELETE FROM \(table) WHERE segmentId = ? AND startMediaMs < ? AND endMediaMs > ?",
                              arguments: [segmentId, endMediaMs, startMediaMs])
            }
            try d.execute(sql: "DELETE FROM voice_jobs WHERE segmentId = ?", arguments: [segmentId])
            try d.execute(sql: "INSERT OR IGNORE INTO voice_source_revocations(segmentId,revision) SELECT segmentId,revision FROM voice_sources WHERE segmentId = ?", arguments: [segmentId])
            try d.execute(sql: "UPDATE voice_sources SET generation = generation + 1, state = 'invalidated' WHERE segmentId = ? AND state <> 'deleted'", arguments: [segmentId])
        }
    }

    /// Includes standalone microphone enrollment. Keep people/manual labels and tombstones.
    public func deleteAll() async throws {
        try await db.writer.write { d in
            try VoiceArchiveRevocationStore.revoke(d, scope: .all)
            try d.execute(sql: """
                UPDATE voice_recognition_config SET generation = generation + 1, corpusRevision = corpusRevision + 1 WHERE id = 1;
                DELETE FROM voice_examples; DELETE FROM voice_auto_attributions;
                DELETE FROM voice_jobs; DELETE FROM voice_suppressions; DELETE FROM voice_runs;
                UPDATE voice_sources SET generation = generation + 1, state = 'deleted';
                """)
        }
    }

    /// A restored database without its device-only decryption key has no usable voice corpus.
    /// Clear that derived state and turn recognition off; available recordings remain eligible
    /// for a new, explicit enrollment. A temporarily locked key must never call this operation.
    public func resetUnavailableProfiles() async throws {
        try await db.writer.write { d in
            try VoiceArchiveRevocationStore.revoke(d, scope: .all)
            try d.execute(sql: """
                UPDATE voice_recognition_config SET mode = 'off', generation = generation + 1,
                    corpusRevision = corpusRevision + 1 WHERE id = 1;
                DELETE FROM voice_examples; DELETE FROM voice_auto_attributions;
                DELETE FROM voice_jobs; DELETE FROM voice_suppressions; DELETE FROM voice_runs;
                """)
        }
    }

    public func clearAutomatic(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws {
        try await db.writer.write { d in
            try VoiceArchiveRevocationStore.revoke(d, scope: .all)
            try d.execute(sql: """
                INSERT INTO voice_suppressions(segmentId,startMediaMs,endMediaMs)
                    SELECT segmentId,startMediaMs,endMediaMs FROM voice_auto_attributions;
                DELETE FROM voice_auto_attributions;
                UPDATE voice_recognition_config SET generation = generation + 1,
                    enabledAtMs = CASE WHEN mode = 'local' THEN ? ELSE enabledAtMs END WHERE id = 1;
                UPDATE voice_jobs SET state = 'cancelled' WHERE state IN ('pending','running');
                UPDATE voice_history_plans SET state = 'cancelled' WHERE state = 'active';
                """, arguments: [nowMs])
        }
    }

    static func configuration(_ d: Database) throws -> VoiceRecognitionConfiguration {
        let row = try Row.fetchOne(d, sql: "SELECT * FROM voice_recognition_config WHERE id = 1")!
        return VoiceRecognitionConfiguration(mode: VoiceRecognitionMode(rawValue: row["mode"]) ?? .off,
                                             generation: row["generation"], corpusRevision: row["corpusRevision"], enabledAtMs: row["enabledAtMs"])
    }
    static func source(_ d: Database, segmentId: String) throws -> VoiceSourceState? {
        try Row.fetchOne(d, sql: "SELECT * FROM voice_sources WHERE segmentId = ? AND state = 'ready'", arguments: [segmentId])
            .map { VoiceSourceState(segmentId: $0["segmentId"], revision: $0["revision"], generation: $0["generation"]) }
    }
    static func valid(_ d: Database, segmentId: String, token: VoiceWorkToken, requiresEnabled: Bool = true) throws -> Bool {
        let config = try configuration(d)
        guard (!requiresEnabled || config.mode == .local), config.generation == token.configGeneration,
              config.corpusRevision == token.corpusRevision,
              let source = try source(d, segmentId: segmentId) else { return false }
        return source.generation == token.sourceGeneration && source.revision == token.sourceRevision
    }
    static func examples(_ d: Database, personId: String?) throws -> [VoiceConfirmedExample] {
        try Row.fetchAll(d, sql: "SELECT * FROM voice_examples WHERE (? IS NULL OR personId = ?) ORDER BY createdAtMs, id",
                         arguments: [personId, personId]).map { row in
            VoiceConfirmedExample(id: row["id"], personId: row["personId"], confirmationID: row["confirmationID"],
                sessionID: row["sessionID"], segmentId: row["segmentId"], startMediaMs: row["startMediaMs"],
                endMediaMs: row["endMediaMs"], sourceRevision: row["sourceRevision"], recipeID: row["recipeID"],
                recipeJSON: row["recipeJSON"], embeddingJSON: row["embeddingJSON"], qualityJSON: row["qualityJSON"], createdAtMs: row["createdAtMs"])
        }
    }
    static func fetchAutomatic(_ d: Database, segmentIds: [String], currentUserPersonId: String?) throws -> [VoiceResolvedAttribution] {
        guard !segmentIds.isEmpty, try d.tableExists("voice_auto_attributions") else { return [] }
        let placeholders = Array(repeating: "?", count: segmentIds.count).joined(separator: ",")
        return try Row.fetchAll(d, sql: """
            SELECT a.*, p.name AS personName, v.originID AS archiveOriginID
            FROM voice_auto_attributions a JOIN people p ON p.id = a.personId
            CROSS JOIN voice_archive_state v
            WHERE a.segmentId IN (\(placeholders)) ORDER BY a.segmentId,a.startMediaMs,a.createdAtMs,a.id
            """, arguments: StatementArguments(segmentIds)).map { row in
                let personId: String = row["personId"]
                return VoiceResolvedAttribution(attribution: VoiceAutomaticAttribution(
                    id: row["id"], personId: personId, segmentId: row["segmentId"], startMediaMs: row["startMediaMs"],
                    endMediaMs: row["endMediaMs"], sourceRevision: row["sourceRevision"], recipeID: row["recipeID"],
                    score: row["score"], margin: row["margin"], calibrationID: row["calibrationID"], runID: row["runID"],
                    disposition: VoiceAttributionDisposition(rawValue: row["disposition"]) ?? .suggestion, createdAtMs: row["createdAtMs"],
                    archiveOriginID: row["archiveOriginID"], archiveGeneration: row["archiveGeneration"]),
                    person: Person(id: personId, name: row["personName"], isCurrentUser: personId == currentUserPersonId))
            }
    }
    static func eraseSourceArtifacts(_ d: Database, segmentId: String) throws {
        try eraseDependentPredictions(d, segmentId: segmentId, start: 0, end: Int64.max)
        for table in ["voice_examples", "voice_auto_attributions", "voice_jobs", "voice_suppressions"] {
            try d.execute(sql: "DELETE FROM \(table) WHERE segmentId = ?", arguments: [segmentId])
        }
    }
    private static func eraseDependentPredictions(_ d: Database, segmentId: String, start: Int64, end: Int64) throws {
        try d.execute(sql: """
            DELETE FROM voice_auto_attributions WHERE personId IN (
                SELECT personId FROM voice_examples WHERE segmentId = ? AND startMediaMs < ? AND endMediaMs > ?)
            """, arguments: [segmentId, end, start])
    }
    static func range(_ start: Int64, _ end: Int64) throws {
        guard start >= 0, end > start else { throw VoiceIdentityError.invalidRecord }
    }
    static func validate(_ e: VoiceConfirmedExample) throws {
        try range(e.startMediaMs, e.endMediaMs)
        guard [e.id, e.personId, e.confirmationID, e.sessionID, e.segmentId, e.sourceRevision, e.recipeID].allSatisfy({ !$0.isEmpty }) else {
            throw VoiceIdentityError.invalidRecord
        }
        for data in [e.recipeJSON, e.embeddingJSON, e.qualityJSON] {
            guard !data.isEmpty, data.count <= 262_144,
                  (try? JSONSerialization.jsonObject(with: data)) != nil else { throw VoiceIdentityError.invalidRecord }
        }
    }
    static func validate(_ a: VoiceAutomaticAttribution) throws {
        try range(a.startMediaMs, a.endMediaMs)
        guard [a.id, a.personId, a.segmentId, a.sourceRevision, a.recipeID, a.calibrationID, a.runID].allSatisfy({ !$0.isEmpty }),
              a.score.isFinite, (-1...1).contains(a.score),
              a.margin.map({ $0.isFinite && (0...2).contains($0) }) ?? true else { throw VoiceIdentityError.invalidRecord }
    }
    static func activeRun(_ d: Database, id: String) throws -> Bool {
        guard !id.isEmpty else { throw VoiceIdentityError.invalidRecord }
        try d.execute(sql: "INSERT OR IGNORE INTO voice_runs(runID) VALUES (?)", arguments: [id])
        return try String.fetchOne(d, sql: "SELECT state FROM voice_runs WHERE runID = ?", arguments: [id]) == "active"
    }
    static func insertAutomatic(_ d: Database, attribution a: VoiceAutomaticAttribution, token: VoiceWorkToken) throws -> Bool {
        guard a.sourceRevision == token.sourceRevision, try activeRun(d, id: a.runID),
              try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM voice_examples WHERE personId = ? AND recipeID = ?", arguments: [a.personId, a.recipeID]) ?? 0 > 0 else { return false }
        for table in ["speaker_corrections", "voice_suppressions"] {
            if try Bool.fetchOne(d, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE segmentId = ? AND startMediaMs < ? AND endMediaMs > ?)",
                                arguments: [a.segmentId, a.endMediaMs, a.startMediaMs]) == true { return false }
        }
        try d.execute(sql: """
            INSERT OR IGNORE INTO voice_auto_attributions(id,personId,segmentId,startMediaMs,endMediaMs,sourceRevision,
                recipeID,score,margin,calibrationID,runID,disposition,createdAtMs,archiveGeneration)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,(SELECT generation FROM voice_archive_state WHERE id = 1))
            """, arguments: [a.id, a.personId, a.segmentId, a.startMediaMs, a.endMediaMs, a.sourceRevision,
                a.recipeID, a.score, a.margin, a.calibrationID, a.runID, a.disposition.rawValue, a.createdAtMs])
        return true
    }
}
