import Foundation
import GRDB

/// One analysed turn's voice, kept so that a new sample or a removed one re-reads recordings
/// already analysed without the models. The vector is sealed by the voice key like every other
/// voice record; AppDB stores it without interpreting it.
public struct VoiceTurnPrint: Equatable, Sendable {
    public var id: Int64
    public var startMediaMs: Int64
    public var endMediaMs: Int64
    public var speechConfidence: Double
    /// The run whose names cover this turn: the one that analysed it, or the history run that
    /// asked for it again.
    public var runID: String
    /// The embedding model's recipe, in the clear: it names a model, not a voice.
    public var recipeJSON: Data
    public var sealedEmbedding: Data
    public init(id: Int64 = 0, startMediaMs: Int64, endMediaMs: Int64, speechConfidence: Double,
                runID: String, recipeJSON: Data, sealedEmbedding: Data) {
        self.id = id; self.startMediaMs = startMediaMs; self.endMediaMs = endMediaMs
        self.speechConfidence = speechConfidence; self.runID = runID
        self.recipeJSON = recipeJSON; self.sealedEmbedding = sealedEmbedding
    }
}

/// A recording's saved prints, as read for naming against the current voices.
public struct VoicePrintSource: Equatable, Sendable {
    public var segmentId: String
    public var recipeID: String
    public var sourceRevision: String
    public var sourceGeneration: Int64
    /// The voices (corpus revision) its names were last matched against.
    public var matchedCorpus: Int64
    /// The audio analysed so far, merged.
    public var analyzed: [Range<Int64>]
    public var prints: [VoiceTurnPrint]
}

/// Analysis costs model time; naming from a print costs a comparison. So every analysed turn
/// keeps its print, and when the voices change, names are re-matched from the prints instead of
/// analysing the audio again. Prints follow the life of the recording's other voice data: a
/// re-read or deleted recording loses them, and turning recognition off clears them all.
public struct VoicePrintStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Names here are not from the current voices, whatever they are now.
    static let staleCorpus: Int64 = -1
    /// Names were cleared by hand: only an explicit history run names this recording again.
    static let frozenCorpus: Int64 = -2

    /// The audio of this version of the recording already analysed with this recipe, merged.
    public func analyzed(segmentId: String, recipeID: String, token: VoiceWorkToken) async throws -> [Range<Int64>] {
        try await db.reader.read { d in
            try Self.analyzed(d, segmentId: segmentId, recipeID: recipeID,
                              source: VoiceSourceState(segmentId: segmentId, revision: token.sourceRevision,
                                                       generation: token.sourceGeneration))
        }
    }
    static func analyzed(_ d: Database, segmentId: String, recipeID: String, source: VoiceSourceState) throws -> [Range<Int64>] {
        guard let row = try Row.fetchOne(d, sql: """
            SELECT analyzedJSON FROM voice_print_sources WHERE segmentId = ? AND recipeID = ?
                AND sourceRevision = ? AND sourceGeneration = ?
            """, arguments: [segmentId, recipeID, source.revision, source.generation]) else { return [] }
        return ranges(row["analyzedJSON"])
    }

    /// Recordings whose names came from other voices than the current ones, newest first, with
    /// about `maxPrints` prints in all (always at least one recording).
    public func stale(corpusRevision: Int64, maxPrints: Int, maxSources: Int) async throws -> [VoicePrintSource] {
        try await db.reader.read { d in
            guard try VoiceIdentityStore.configuration(d).mode == .local else { return [] }
            let rows = try Row.fetchAll(d, sql: """
                SELECT p.* FROM voice_print_sources p JOIN voice_sources s ON s.segmentId = p.segmentId
                WHERE s.state = 'ready' AND s.generation = p.sourceGeneration AND s.revision = p.sourceRevision
                    AND p.matchedCorpus NOT IN (?, ?)
                ORDER BY p.segmentId DESC LIMIT ?
                """, arguments: [corpusRevision, Self.frozenCorpus, max(1, maxSources)])
            var sources: [VoicePrintSource] = []
            var count = 0
            for row in rows {
                let segmentId: String = row["segmentId"]
                let prints = try Row.fetchAll(d, sql: """
                    SELECT t.*, r.recipeJSON FROM voice_turn_prints t JOIN voice_print_recipes r ON r.id = t.recipe
                    WHERE t.segmentId = ? ORDER BY t.startMediaMs, t.id
                    """, arguments: [segmentId]).map(Self.print)
                guard sources.isEmpty || count + prints.count <= maxPrints else { break }
                count += prints.count
                sources.append(VoicePrintSource(segmentId: segmentId, recipeID: row["recipeID"],
                    sourceRevision: row["sourceRevision"], sourceGeneration: row["sourceGeneration"],
                    matchedCorpus: row["matchedCorpus"], analyzed: Self.ranges(row["analyzedJSON"]), prints: prints))
            }
            return sources
        }
    }

    /// Gives each recording the names matched from its prints, changing only what differs: a
    /// name that stays is never rewritten, so it is not sent to the archive again. A recording
    /// that changed since it was read waits for the next pass. Returns the recordings whose
    /// names changed.
    public func commitNames(_ updates: [(source: VoicePrintSource, names: [VoiceAutomaticAttribution])],
                            corpusRevision: Int64, configGeneration: Int64) async throws -> [String] {
        for update in updates {
            guard update.names.count <= 4_096 else { throw VoiceIdentityError.capacityExceeded }
            for name in update.names { try VoiceIdentityStore.validate(name) }
        }
        return try await db.writer.write { d in
            let config = try VoiceIdentityStore.configuration(d)
            guard config.mode == .local, config.corpusRevision == corpusRevision,
                  config.generation == configGeneration else { return [] }
            var changed: [String] = []
            for (source, names) in updates {
                guard let row = try Row.fetchOne(d, sql: "SELECT * FROM voice_print_sources WHERE segmentId = ?",
                                                arguments: [source.segmentId]),
                      row["recipeID"] == source.recipeID, row["sourceRevision"] == source.sourceRevision,
                      row["sourceGeneration"] == source.sourceGeneration, row["matchedCorpus"] == source.matchedCorpus,
                      Self.ranges(row["analyzedJSON"]) == source.analyzed,
                      let ready = try VoiceIdentityStore.source(d, segmentId: source.segmentId),
                      ready.generation == source.sourceGeneration, ready.revision == source.sourceRevision,
                      names.allSatisfy({ $0.segmentId == source.segmentId && $0.recipeID == source.recipeID
                          && $0.sourceRevision == source.sourceRevision }) else { continue }
                struct Key: Hashable { let start, end: Int64; let person: String }
                let wanted = Set(names.map { Key(start: $0.startMediaMs, end: $0.endMediaMs, person: $0.personId) })
                var kept = Set<Key>()
                var differs = false
                let existing = try Row.fetchAll(d, sql: """
                    SELECT id, personId, startMediaMs, endMediaMs FROM voice_auto_attributions
                    WHERE segmentId = ? AND recipeID = ? ORDER BY createdAtMs, id
                    """, arguments: [source.segmentId, source.recipeID])
                for name in existing {
                    let key = Key(start: name["startMediaMs"], end: name["endMediaMs"], person: name["personId"])
                    // Only names on audio these prints cover are theirs to replace.
                    guard source.analyzed.contains(where: { $0.lowerBound <= key.start && key.end <= $0.upperBound }) else { continue }
                    if wanted.contains(key), kept.insert(key).inserted { continue }
                    try d.execute(sql: "DELETE FROM voice_auto_attributions WHERE id = ?", arguments: [name["id"] as String])
                    differs = true
                }
                for name in names where !kept.contains(Key(start: name.startMediaMs, end: name.endMediaMs, person: name.personId)) {
                    if try Self.insertName(d, name) { differs = true }
                }
                try d.execute(sql: "UPDATE voice_print_sources SET matchedCorpus = ? WHERE segmentId = ?",
                              arguments: [corpusRevision, source.segmentId])
                if differs { changed.append(source.segmentId) }
            }
            return changed
        }
    }

    /// Like an analysed window's name, except that a run stopped since still owns its names;
    /// only an undone one gives them up.
    private static func insertName(_ d: Database, _ a: VoiceAutomaticAttribution) throws -> Bool {
        guard let state = try String.fetchOne(d, sql: "SELECT state FROM voice_runs WHERE runID = ?", arguments: [a.runID]),
              state != "undone",
              try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM voice_examples WHERE personId = ? AND recipeID = ?",
                               arguments: [a.personId, a.recipeID]) ?? 0 > 0 else { return false }
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
        return d.changesCount > 0
    }

    /// An analysed window's prints, with the analysed audio it adds. `matchedCorpus` is the
    /// voices its names were matched against; names from older voices leave the recording to be
    /// named again from its prints.
    static func recordWindow(_ d: Database, job: VoiceRecognitionJob, window: Range<Int64>,
                             prints: [VoiceTurnPrint], matchedCorpus: Int64) throws {
        guard prints.count <= 256 else { throw VoiceIdentityError.capacityExceeded }
        for print in prints {
            guard print.startMediaMs >= window.lowerBound, print.endMediaMs <= window.upperBound,
                  print.endMediaMs > print.startMediaMs, print.runID == job.runID,
                  print.speechConfidence.isFinite, !print.sealedEmbedding.isEmpty,
                  print.sealedEmbedding.count <= 262_144, print.recipeJSON.count <= 65_536,
                  (try? JSONSerialization.jsonObject(with: print.recipeJSON)) != nil else {
                throw VoiceIdentityError.invalidRecord
            }
        }
        let current = try VoiceIdentityStore.configuration(d).corpusRevision
        var analyzed: [Range<Int64>] = []
        var matched = matchedCorpus == current ? current : staleCorpus
        if let row = try Row.fetchOne(d, sql: "SELECT * FROM voice_print_sources WHERE segmentId = ?", arguments: [job.segmentId]) {
            if row["recipeID"] == job.recipeID, row["sourceRevision"] == job.token.sourceRevision,
               row["sourceGeneration"] == job.token.sourceGeneration {
                analyzed = ranges(row["analyzedJSON"])
                let previous: Int64 = row["matchedCorpus"]
                if previous != current { matched = staleCorpus }
            } else {
                // Another model's prints, or an earlier version of the recording.
                try d.execute(sql: "DELETE FROM voice_print_sources WHERE segmentId = ?", arguments: [job.segmentId])
            }
        }
        try d.execute(sql: """
            INSERT INTO voice_print_sources(segmentId,recipeID,sourceRevision,sourceGeneration,analyzedJSON,matchedCorpus)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(segmentId) DO UPDATE SET analyzedJSON = excluded.analyzedJSON, matchedCorpus = excluded.matchedCorpus
            """, arguments: [job.segmentId, job.recipeID, job.token.sourceRevision, job.token.sourceGeneration,
                             json(merged(analyzed + [window])), matched])
        for print in prints {
            try d.execute(sql: "INSERT OR IGNORE INTO voice_print_recipes(recipeJSON) VALUES (?)", arguments: [print.recipeJSON])
            let recipe = try Int64.fetchOne(d, sql: "SELECT id FROM voice_print_recipes WHERE recipeJSON = ?",
                                            arguments: [print.recipeJSON])!
            try d.execute(sql: """
                INSERT INTO voice_turn_prints(segmentId,startMediaMs,endMediaMs,speechConfidence,runID,recipe,embedding)
                VALUES (?,?,?,?,?,?,?)
                """, arguments: [job.segmentId, print.startMediaMs, print.endMediaMs, print.speechConfidence,
                                 print.runID, recipe, print.sealedEmbedding])
        }
    }

    /// Already analysed audio asked for again by another run: that run's names cover it now,
    /// matched afresh from the prints.
    static func adopt(_ d: Database, segmentId: String, range: Range<Int64>, runID: String) throws {
        try d.execute(sql: """
            UPDATE voice_turn_prints SET runID = ? WHERE segmentId = ? AND startMediaMs >= ? AND endMediaMs <= ?
            """, arguments: [runID, segmentId, range.lowerBound, range.upperBound])
        try d.execute(sql: "UPDATE voice_print_sources SET matchedCorpus = ? WHERE segmentId = ?",
                      arguments: [staleCorpus, segmentId])
    }

    static func merged(_ ranges: [Range<Int64>]) -> [Range<Int64>] {
        var out: [Range<Int64>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { out.append(range) }
        }
        return out
    }
    private static func json(_ ranges: [Range<Int64>]) -> String {
        "[" + ranges.map { "[\($0.lowerBound),\($0.upperBound)]" }.joined(separator: ",") + "]"
    }
    static func ranges(_ json: String) -> [Range<Int64>] {
        guard let pairs = try? JSONDecoder().decode([[Int64]].self, from: Data(json.utf8)) else { return [] }
        return pairs.compactMap { $0.count == 2 && $0[1] > $0[0] ? $0[0]..<$0[1] : nil }
    }
    private static func print(_ row: Row) -> VoiceTurnPrint {
        VoiceTurnPrint(id: row["id"], startMediaMs: row["startMediaMs"], endMediaMs: row["endMediaMs"],
            speechConfidence: row["speechConfidence"], runID: row["runID"], recipeJSON: row["recipeJSON"],
            sealedEmbedding: row["embedding"])
    }

    static func installSchema(_ d: Database) throws {
        try d.execute(sql: """
            CREATE TABLE voice_print_sources (
                segmentId TEXT PRIMARY KEY NOT NULL REFERENCES voice_sources(segmentId) ON DELETE CASCADE,
                recipeID TEXT NOT NULL, sourceRevision TEXT NOT NULL, sourceGeneration INTEGER NOT NULL,
                analyzedJSON TEXT NOT NULL DEFAULT '[]', matchedCorpus INTEGER NOT NULL
            );
            CREATE TABLE voice_print_recipes (id INTEGER PRIMARY KEY, recipeJSON BLOB NOT NULL UNIQUE);
            CREATE TABLE voice_turn_prints (
                id INTEGER PRIMARY KEY,
                segmentId TEXT NOT NULL REFERENCES voice_print_sources(segmentId) ON DELETE CASCADE,
                startMediaMs INTEGER NOT NULL, endMediaMs INTEGER NOT NULL, speechConfidence REAL NOT NULL,
                runID TEXT NOT NULL, recipe INTEGER NOT NULL REFERENCES voice_print_recipes(id),
                embedding BLOB NOT NULL,
                CHECK(startMediaMs >= 0 AND endMediaMs > startMediaMs)
            );
            CREATE INDEX voice_turn_prints_segment ON voice_turn_prints(segmentId, startMediaMs);
            CREATE TRIGGER voice_prints_source_changed AFTER UPDATE OF generation ON voice_sources
            WHEN NEW.generation <> OLD.generation BEGIN
                DELETE FROM voice_print_sources WHERE segmentId = NEW.segmentId;
            END;
            CREATE TRIGGER voice_prints_recognition_off AFTER UPDATE OF mode ON voice_recognition_config
            WHEN NEW.mode = 'off' BEGIN
                DELETE FROM voice_print_sources;
            END;
            """)
    }
}
