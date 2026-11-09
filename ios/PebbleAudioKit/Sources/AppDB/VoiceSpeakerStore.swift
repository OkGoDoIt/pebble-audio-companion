import Foundation
import GRDB

/// One crop of one speaker in a recording, with how sure the detector was it's speech (percent).
public struct VoiceSpeakerCrop: Equatable, Sendable {
    public var startMs: Int64
    public var endMs: Int64
    public var confidencePercent: Int
    public init(startMs: Int64, endMs: Int64, confidencePercent: Int) {
        self.startMs = startMs; self.endMs = endMs; self.confidencePercent = confidencePercent
    }
}

/// A speaker found in a recording, before it has a row: their crops and, for one heard enough
/// to compare across recordings, their pooled voice (sealed like every other voice record).
public struct VoiceSpeakerDraft: Equatable, Sendable {
    public var crops: [VoiceSpeakerCrop]
    public var sealedVoice: Data?
    public var recipeJSON: Data?
    public init(crops: [VoiceSpeakerCrop], sealedVoice: Data?, recipeJSON: Data?) {
        self.crops = crops; self.sealedVoice = sealedVoice; self.recipeJSON = recipeJSON
    }
}

/// A speaker as read for clustering.
public struct VoiceSpeakerInput: Sendable {
    public var id: Int64
    public var segmentId: String
    public var cropCount: Int
    public var sealedVoice: Data
    public var recipeJSON: Data
    /// Their person by a human's word: a decision, or a name on audio in this speaker's crops.
    public var person: String?
    public var rejected: Set<String>
    public var ignored: Bool
    public var separations: [String: String] = [:]
    public var requiresReview: Bool = false
}

/// A recording's speakers as read for naming.
public struct VoiceNamingSpeaker: Equatable, Sendable {
    public var id: Int64
    public var crops: [VoiceSpeakerCrop]
    public var personId: String?
    public var suggestedPersonId: String?
    public var score: Double?
    public var repaired = false
    public init(id: Int64, crops: [VoiceSpeakerCrop], personId: String?, suggestedPersonId: String?, score: Double?) {
        self.id = id; self.crops = crops; self.personId = personId
        self.suggestedPersonId = suggestedPersonId; self.score = score
    }
}

public struct VoiceNamingRecording: Equatable, Sendable {
    public var segmentId: String
    public var speakers: [VoiceNamingSpeaker]
    /// Audio a person has decided about, or an undone run covers: never named automatically.
    public var blocked: [Range<Int64>]
    public init(segmentId: String, speakers: [VoiceNamingSpeaker], blocked: [Range<Int64>]) {
        self.segmentId = segmentId; self.speakers = speakers; self.blocked = blocked
    }
}

/// What clustering decided for a speaker.
public struct VoiceSpeakerAssignment: Equatable, Sendable {
    public var speakerId: Int64
    public var clusterId: Int64
    public var personId: String?
    public var score: Double
    public var suggestedPersonId: String?
    public var suggestedScore: Double?
    public var ignored: Bool
    public init(speakerId: Int64, clusterId: Int64, personId: String?, score: Double,
                suggestedPersonId: String?, suggestedScore: Double?, ignored: Bool) {
        self.speakerId = speakerId; self.clusterId = clusterId; self.personId = personId; self.score = score
        self.suggestedPersonId = suggestedPersonId; self.suggestedScore = suggestedScore; self.ignored = ignored
    }
}

/// One appearance of a voice: its speaker in one recording, and the clip that speaks clearest.
public struct VoiceClusterClip: Equatable, Sendable {
    public var speakerId: Int64
    public var segmentId: String
    public var startMediaMs: Int64
    public var endMediaMs: Int64
    public var confidencePercent: Int
    public var speechMs: Int64
    public var heardAtMs: Int64
}

/// A group of speakers with no name: a voice to ask about.
public struct VoiceCluster: Equatable, Sendable {
    public var id: Int64
    public var repaired = false
    public var speechMs: Int64
    public var lastHeardMs: Int64
    public var suggestedPersonId: String?
    public var suggestedScore: Double?
    /// One per speaker, clearest first.
    public var clips: [VoiceClusterClip]
    public var recordingCount: Int { Set(clips.map(\.segmentId)).count }
}

/// A stretch of a recording where a voice with no name yet was heard: one speaker's crops, the
/// voice they sorted into, and who it might be.
public struct VoiceSpeakerSpan: Equatable, Sendable {
    public var speakerId: Int64
    public var segmentId: String
    public var clusterId: Int64
    public var crops: [VoiceSpeakerCrop]
    public var suggestedPersonId: String?
    public var suggestedScore: Double?
}

/// A conversation someone was heard in: how long, and the clip that speaks clearest.
public struct VoicePersonAppearance: Equatable, Sendable {
    public var conversationId: String
    public var title: String?
    public var startMs: Int64
    public var speechMs: Int64
    /// The speakers that make this their appearance, to say it wasn't them.
    public var speakerIds: [Int64]
    public var clip: VoiceClusterClip
}

/// How much of everything said one person has been named on.
public struct VoicePersonStats: Equatable, Sendable {
    public var personId: String
    public var speechMs: Int64
    public var conversations: Int
    public var lastHeardMs: Int64?
    /// Voices that might be them: asked about, not yet answered.
    public var possibleMatches: Int
}

/// How much of everything said has a name, overall and by person.
public struct VoiceCoverage: Equatable, Sendable {
    public var speechMs: Int64
    public var namedMs: Int64
    public var byPerson: [VoicePersonStats]
}

/// Voices are named the way a photo library names faces: every recording's speakers are sorted
/// into groups by voice, a person names a group once, and what's in it (now and later) follows.
/// Speakers and groups are derived from saved prints and rebuilt freely; what a person said about
/// them (`voice_speaker_decisions`) is the only thing here that can't be derived again.
public struct VoiceSpeakerStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public enum DecisionKind: String, Sendable {
        /// This speaker is this person.
        case confirmed
        /// This speaker isn't this person.
        case rejected
        /// Stop asking about this voice, here and wherever it's heard.
        case ignored
        /// Leave this one recording's speaker out of everything.
        case excluded
    }

    static func installSchema(_ d: Database) throws {
        try d.execute(sql: """
            CREATE TABLE voice_speakers (
                id INTEGER PRIMARY KEY,
                segmentId TEXT NOT NULL REFERENCES voice_print_sources(segmentId) ON DELETE CASCADE,
                cropsJSON TEXT NOT NULL, cropCount INTEGER NOT NULL, speechMs INTEGER NOT NULL,
                voice BLOB, recipe INTEGER REFERENCES voice_print_recipes(id),
                clusterId INTEGER, personId TEXT, score REAL,
                suggestedPersonId TEXT, suggestedScore REAL, hidden INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX voice_speakers_segment ON voice_speakers(segmentId);
            CREATE INDEX voice_speakers_cluster ON voice_speakers(clusterId);
            CREATE INDEX voice_speakers_person ON voice_speakers(personId);
            CREATE TABLE voice_speaker_decisions (
                id INTEGER PRIMARY KEY,
                speakerId INTEGER NOT NULL REFERENCES voice_speakers(id) ON DELETE CASCADE,
                kind TEXT NOT NULL, personId TEXT, createdAtMs INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX voice_speaker_decision_once ON voice_speaker_decisions(speakerId, kind, COALESCE(personId, ''));
            CREATE INDEX voice_speaker_decision_person ON voice_speaker_decisions(personId);
            ALTER TABLE voice_print_sources ADD COLUMN speechMs INTEGER NOT NULL DEFAULT 0;
            UPDATE voice_print_sources SET matchedCorpus = \(VoicePrintStore.staleCorpus)
                WHERE matchedCorpus <> \(VoicePrintStore.frozenCorpus);
            """)
        // Partial historical schema fixtures omit people.
        guard try d.tableExists("people") else { return }
        try d.execute(sql: """
            CREATE TRIGGER voice_decisions_person_deleted AFTER DELETE ON people BEGIN
                DELETE FROM voice_speaker_decisions WHERE personId = OLD.id;
            END;
            """)
    }

    // --- speakers ---------------------------------------------------------------------------

    /// How many crops each recording's speakers hold, to tell which need sorting again.
    public func cropCounts(segmentIds: [String]) async throws -> [String: Int] {
        guard !segmentIds.isEmpty else { return [:] }
        return try await db.reader.read { d in
            var out: [String: Int] = [:]
            for chunk in stride(from: 0, to: segmentIds.count, by: 400).map({ Array(segmentIds[$0..<min($0 + 400, segmentIds.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in try Row.fetchAll(d, sql: """
                    SELECT segmentId, SUM(cropCount) AS crops FROM voice_speakers WHERE segmentId IN (\(marks)) GROUP BY segmentId
                    """, arguments: StatementArguments(chunk)) { out[row["segmentId"]] = row["crops"] }
            }
            return out
        }
    }

    /// A recording's speakers as just sorted. A speaker with the same crops keeps its row, so
    /// what a person said about it stands; one that changed takes over the decisions of the
    /// old speaker it shares the most audio with.
    public func replaceSpeakers(_ recordings: [(segmentId: String, drafts: [VoiceSpeakerDraft])]) async throws {
        try await db.writer.write { d in
            let constraints = try VoiceSplitStore.constraints(d)
            for (segmentId, drafts) in recordings {
                // A split may have been saved while this derivation was in flight. Never let
                // that old result pool across the new boundaries; the next pass rereads them.
                if drafts.contains(where: { draft in
                    Set(draft.crops.map { crop in
                        let signature = VoiceSplitConstraint.signature(for: [crop], constraints: constraints[segmentId] ?? [])
                        return signature.keys.sorted().map { "\($0)=\(signature[$0]!)" }.joined(separator: "|")
                    }).count > 1
                }) { continue }
                guard try Bool.fetchOne(d, sql: "SELECT EXISTS(SELECT 1 FROM voice_print_sources WHERE segmentId = ?)",
                                        arguments: [segmentId]) == true else { continue }
                let old = try Row.fetchAll(d, sql: "SELECT id, cropsJSON FROM voice_speakers WHERE segmentId = ?", arguments: [segmentId])
                    .map { (id: $0["id"] as Int64, json: $0["cropsJSON"] as String) }
                var kept = Set<Int64>()
                var added: [(id: Int64, crops: [VoiceSpeakerCrop])] = []
                for draft in drafts {
                    let json = Self.encode(draft.crops)
                    if let same = old.first(where: { $0.json == json && !kept.contains($0.id) }) {
                        kept.insert(same.id)
                        continue
                    }
                    var recipe: Int64?
                    if let recipeJSON = draft.recipeJSON {
                        try d.execute(sql: "INSERT OR IGNORE INTO voice_print_recipes(recipeJSON) VALUES (?)", arguments: [recipeJSON])
                        recipe = try Int64.fetchOne(d, sql: "SELECT id FROM voice_print_recipes WHERE recipeJSON = ?", arguments: [recipeJSON])
                    }
                    try d.execute(sql: """
                        INSERT INTO voice_speakers(segmentId,cropsJSON,cropCount,speechMs,voice,recipe) VALUES (?,?,?,?,?,?)
                        """, arguments: [segmentId, json, draft.crops.count, draft.crops.reduce(0) { $0 + $1.endMs - $1.startMs },
                                         draft.sealedVoice, recipe])
                    let addedID = d.lastInsertedRowID
                    if draft.sealedVoice == nil,
                       !VoiceSplitConstraint.signature(for: draft.crops, constraints: constraints[segmentId] ?? []).isEmpty {
                        try d.execute(sql: "UPDATE voice_speakers SET clusterId=? WHERE id=?", arguments: [addedID, addedID])
                    }
                    added.append((addedID, draft.crops))
                }
                for gone in old where !kept.contains(gone.id) {
                    let goneCrops = Self.decode(gone.json)
                    func shared(_ crops: [VoiceSpeakerCrop]) -> Int64 {
                        crops.reduce(0) { total, crop in
                            total + goneCrops.reduce(0) { $0 + max(0, min(crop.endMs, $1.endMs) - max(crop.startMs, $1.startMs)) }
                        }
                    }
                    if let heir = added.max(by: { shared($0.crops) < shared($1.crops) }), shared(heir.crops) > 0 {
                        try d.execute(sql: "UPDATE OR IGNORE voice_speaker_decisions SET speakerId = ? WHERE speakerId = ?",
                                      arguments: [heir.id, gone.id])
                    }
                    try d.execute(sql: "DELETE FROM voice_speakers WHERE id = ?", arguments: [gone.id])
                }
            }
        }
    }

    // --- clustering -------------------------------------------------------------------------

    /// Changes whenever clustering could decide differently.
    public func clusterKey() async throws -> String {
        try await db.reader.read { d in
            let row = try Row.fetchOne(d, sql: """
                SELECT (SELECT COUNT(*) FROM voice_speakers) AS a, (SELECT COALESCE(MAX(id), 0) FROM voice_speakers) AS b,
                    (SELECT COUNT(*) FROM voice_speaker_decisions) AS c, (SELECT COALESCE(SUM(id), 0) FROM voice_speaker_decisions) AS d,
                    (SELECT COUNT(*) FROM speaker_corrections) AS e, (SELECT COALESCE(MAX(createdAtMs), 0) FROM speaker_corrections) AS f,
                    (SELECT corpusRevision FROM voice_recognition_config WHERE id = 1) AS g,
                    (SELECT COALESCE(SUM(id),0) FROM voice_split_ranges) AS h
                """)!
            return "\(row["a"] as Int64):\(row["b"] as Int64):\(row["c"] as Int64):\(row["d"] as Int64):\(row["e"] as Int64):\(row["f"] as Int64):\(row["g"] as Int64):\(row["h"] as Int64)"
        }
    }

    /// Every speaker heard enough to compare, with what people have said about it. A name on some
    /// of a speaker's audio counts as a word about the speaker, for someone with a voice to go by.
    public func clusterInputs(minimumCrops: Int) async throws -> [VoiceSpeakerInput] {
        try await db.reader.read { d in
            let constraints = try VoiceSplitStore.constraints(d)
            var decisions: [Int64: (person: String?, rejected: Set<String>, ignored: Bool, excluded: Bool)] = [:]
            for row in try Row.fetchAll(d, sql: "SELECT speakerId, kind, personId FROM voice_speaker_decisions ORDER BY id") {
                let id: Int64 = row["speakerId"], person: String? = row["personId"]
                var entry = decisions[id] ?? (nil, [], false, false)
                switch DecisionKind(rawValue: row["kind"]) {
                case .confirmed: entry.person = person
                case .rejected: if let person { entry.rejected.insert(person) }
                case .ignored: entry.ignored = true
                case .excluded: entry.excluded = true
                case nil: break
                }
                decisions[id] = entry
            }
            let voiced = Set(try String.fetchAll(d, sql: """
                SELECT personId FROM voice_examples UNION
                SELECT personId FROM voice_speaker_decisions WHERE kind = 'confirmed' AND personId IS NOT NULL
                """))
            var labels: [String: [(range: Range<Int64>, person: String)]] = [:]
            for row in try Row.fetchAll(d, sql: """
                SELECT segmentId, startMediaMs, endMediaMs, personId FROM speaker_corrections WHERE personId IS NOT NULL
                UNION ALL SELECT segmentId, startMediaMs, endMediaMs, personId FROM voice_examples
                """) {
                let person: String = row["personId"]
                guard voiced.contains(person) else { continue }
                labels[row["segmentId"], default: []].append(
                    ((row["startMediaMs"] as Int64)..<(row["endMediaMs"] as Int64), person))
            }
            let rows = try Row.fetchAll(d, sql: """
                SELECT s.id, s.segmentId, s.cropCount, s.cropsJSON, s.voice, r.recipeJSON FROM voice_speakers s
                JOIN voice_print_recipes r ON r.id = s.recipe
                WHERE s.voice IS NOT NULL AND (s.cropCount >= ? OR EXISTS (SELECT 1 FROM voice_split_ranges x WHERE x.segmentId=s.segmentId))
                """, arguments: [minimumCrops])
            return rows.compactMap { row -> VoiceSpeakerInput? in
                let id: Int64 = row["id"], segmentId: String = row["segmentId"]
                let decision = decisions[id]
                if decision?.excluded == true { return nil }
                let separation = VoiceSplitConstraint.signature(for: Self.decode(row["cropsJSON"]), constraints: constraints[segmentId] ?? [])
                let requiresReview = !separation.isEmpty && decision?.person == nil
                var person = decision?.person
                if person == nil, !requiresReview, decision?.ignored != true, let onHere = labels[segmentId] {
                    let tally = Self.labelledCrops(Self.decode(row["cropsJSON"]), labels: onHere)
                    if let best = tally.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
                        person = best.key
                    }
                }
                if let rejected = decision?.rejected, let named = person, rejected.contains(named) { person = nil }
                var input = VoiceSpeakerInput(id: id, segmentId: segmentId, cropCount: row["cropCount"],
                    sealedVoice: row["voice"], recipeJSON: row["recipeJSON"], person: person,
                    rejected: decision?.rejected ?? [], ignored: decision?.ignored ?? false)
                input.separations = separation
                input.requiresReview = requiresReview
                return input
            }
        }
    }

    /// Crops mostly inside a labelled stretch, per person.
    static func labelledCrops(_ crops: [VoiceSpeakerCrop], labels: [(range: Range<Int64>, person: String)]) -> [String: Int] {
        var tally: [String: Int] = [:]
        for crop in crops {
            var shared: [String: Int64] = [:]
            for label in labels {
                let overlap = min(crop.endMs, label.range.upperBound) - max(crop.startMs, label.range.lowerBound)
                if overlap > 0 { shared[label.person, default: 0] += overlap }
            }
            guard let top = shared.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
                  top.value * 2 >= crop.endMs - crop.startMs else { continue }
            tally[top.key, default: 0] += 1
        }
        return tally
    }

    /// Writes what clustering decided, rebuilds the groups, and returns how many recordings'
    /// names it changed: those are marked to be named again.
    @discardableResult public func applyClusters(_ assignments: [VoiceSpeakerAssignment]) async throws -> Int {
        try await db.writer.write { d in
            let byId = Dictionary(uniqueKeysWithValues: assignments.map { ($0.speakerId, $0) })
            let splits = try VoiceSplitStore.constraints(d)
            var stale = Set<String>()
            for row in try Row.fetchAll(d, sql: "SELECT id, segmentId, cropsJSON, clusterId, personId, score, suggestedPersonId, suggestedScore, hidden FROM voice_speakers") {
                let id: Int64 = row["id"]
                let new = byId[id]
                // Unreadable repaired samples stay visible for manual review.
                if new == nil, !VoiceSplitConstraint.signature(for: Self.decode(row["cropsJSON"]), constraints: splits[row["segmentId"] as String] ?? []).isEmpty { continue }
                let personId: String? = row["personId"], suggested: String? = row["suggestedPersonId"]
                let clusterId: Int64? = row["clusterId"], hidden: Bool = row["hidden"]
                if personId != new?.personId || suggested != new?.suggestedPersonId { stale.insert(row["segmentId"]) }
                let score: Double? = row["score"], suggestedScore: Double? = row["suggestedScore"]
                if personId != new?.personId || suggested != new?.suggestedPersonId || clusterId != new?.clusterId
                    || score != new?.score || suggestedScore != new?.suggestedScore || hidden != (new?.ignored ?? false) {
                    try d.execute(sql: """
                        UPDATE voice_speakers SET clusterId = ?, personId = ?, score = ?, suggestedPersonId = ?, suggestedScore = ?, hidden = ?
                        WHERE id = ?
                        """, arguments: [new?.clusterId, new?.personId, new?.score, new?.suggestedPersonId, new?.suggestedScore,
                                         new?.ignored ?? false, id])
                }
            }
            for segmentId in stale { try VoicePrintStore.markStale(d, segmentId: segmentId) }
            return stale.count
        }
    }

    public func namingInputs(segmentIds: [String]) async throws -> [VoiceNamingRecording] {
        try await db.reader.read { d in
            let constraints = try VoiceSplitStore.constraints(d)
            return try segmentIds.map { segmentId in
                let speakers = try Row.fetchAll(d, sql: """
                    SELECT id, cropsJSON, personId, suggestedPersonId, score FROM voice_speakers WHERE segmentId = ? ORDER BY id
                    """, arguments: [segmentId]).map {
                    var speaker = VoiceNamingSpeaker(id: $0["id"], crops: Self.decode($0["cropsJSON"]), personId: $0["personId"],
                                       suggestedPersonId: $0["suggestedPersonId"], score: $0["score"])
                    speaker.repaired = !VoiceSplitConstraint.signature(for: speaker.crops, constraints: constraints[segmentId] ?? []).isEmpty
                    return speaker
                }
                let blocked = try Row.fetchAll(d, sql: """
                    SELECT startMediaMs, endMediaMs FROM speaker_corrections WHERE segmentId = ?
                    UNION ALL SELECT startMediaMs, endMediaMs FROM voice_suppressions WHERE segmentId = ?
                    """, arguments: [segmentId, segmentId]).map { ($0["startMediaMs"] as Int64)..<($0["endMediaMs"] as Int64) }
                return VoiceNamingRecording(segmentId: segmentId, speakers: speakers, blocked: blocked)
            }
        }
    }

    // --- what a person says ------------------------------------------------------------------

    public func decide(speakers: [Int64], kind: DecisionKind, personId: String?,
                       nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws {
        try await db.writer.write { d in
            for speaker in speakers {
                switch kind {
                case .confirmed:
                    // A new answer replaces what was said before about who this is.
                    try d.execute(sql: "DELETE FROM voice_speaker_decisions WHERE speakerId = ? AND kind IN ('confirmed','ignored')", arguments: [speaker])
                    try d.execute(sql: "DELETE FROM voice_speaker_decisions WHERE speakerId = ? AND kind = 'rejected' AND personId IS ?", arguments: [speaker, personId])
                case .rejected:
                    try d.execute(sql: "DELETE FROM voice_speaker_decisions WHERE speakerId = ? AND kind = 'confirmed' AND personId IS ?", arguments: [speaker, personId])
                case .ignored, .excluded: break
                }
                try d.execute(sql: "INSERT OR IGNORE INTO voice_speaker_decisions(speakerId,kind,personId,createdAtMs) VALUES (?,?,?,?)",
                              arguments: [speaker, kind.rawValue, personId, nowMs])
                try Self.applyAtOnce(d, speaker: speaker, kind: kind, personId: personId)
            }
        }
    }

    /// An answer shows straight away, ahead of the sort that follows from it: the question is
    /// gone and the recording is due its new names. The next sort has the final word.
    private static func applyAtOnce(_ d: Database, speaker: Int64, kind: DecisionKind, personId: String?) throws {
        switch kind {
        case .confirmed:
            try d.execute(sql: "UPDATE voice_speakers SET personId = ?, suggestedPersonId = NULL, suggestedScore = NULL, hidden = 0 WHERE id = ?",
                          arguments: [personId, speaker])
        case .rejected:
            try d.execute(sql: """
                UPDATE voice_speakers SET personId = CASE WHEN personId IS ?1 THEN NULL ELSE personId END,
                    suggestedScore = CASE WHEN suggestedPersonId IS ?1 THEN NULL ELSE suggestedScore END,
                    suggestedPersonId = CASE WHEN suggestedPersonId IS ?1 THEN NULL ELSE suggestedPersonId END
                WHERE id = ?2
                """, arguments: [personId, speaker])
        case .ignored:
            try d.execute(sql: "UPDATE voice_speakers SET personId = NULL, suggestedPersonId = NULL, suggestedScore = NULL, hidden = 1 WHERE id = ?",
                          arguments: [speaker])
        case .excluded:
            try d.execute(sql: "UPDATE voice_speakers SET clusterId = NULL, personId = NULL, suggestedPersonId = NULL, suggestedScore = NULL WHERE id = ?",
                          arguments: [speaker])
        }
        if let segmentId = try String.fetchOne(d, sql: "SELECT segmentId FROM voice_speakers WHERE id = ?", arguments: [speaker]) {
            try VoicePrintStore.markStale(d, segmentId: segmentId)
        }
    }

    /// Takes back "this is them" (and "this isn't them") for these speakers: the undo of an answer.
    public func undecide(speakers: [Int64], personId: String) async throws {
        try await db.writer.write { d in
            for speaker in speakers {
                try d.execute(sql: "DELETE FROM voice_speaker_decisions WHERE speakerId = ? AND personId IS ? AND kind IN ('confirmed','rejected')",
                              arguments: [speaker, personId])
                try d.execute(sql: "UPDATE voice_speakers SET personId = CASE WHEN personId IS ? THEN NULL ELSE personId END WHERE id = ?",
                              arguments: [personId, speaker])
                if let segmentId = try String.fetchOne(d, sql: "SELECT segmentId FROM voice_speakers WHERE id = ?", arguments: [speaker]) {
                    try VoicePrintStore.markStale(d, segmentId: segmentId)
                }
            }
        }
    }

    /// "Forget this voice": nothing said about them stands.
    public func forget(personId: String) async throws {
        try await db.writer.write { d in
            try d.execute(sql: "DELETE FROM voice_speaker_decisions WHERE personId = ?", arguments: [personId])
        }
    }

    public func speakers(inCluster clusterId: Int64) async throws -> [Int64] {
        try await db.reader.read { d in
            try Int64.fetchAll(d, sql: "SELECT id FROM voice_speakers WHERE clusterId = ?", arguments: [clusterId])
        }
    }

    /// The speakers of a recording whose crops touch this stretch.
    public func speakers(segmentId: String, overlapping range: Range<Int64>) async throws -> [Int64] {
        try await db.reader.read { d in
            try Row.fetchAll(d, sql: "SELECT id, cropsJSON FROM voice_speakers WHERE segmentId = ?", arguments: [segmentId]).compactMap { row in
                let crops = Self.decode(row["cropsJSON"])
                return crops.contains { $0.startMs < range.upperBound && $0.endMs > range.lowerBound } ? row["id"] as Int64 : nil
            }
        }
    }

    // --- reads for the screens ----------------------------------------------------------------

    /// Voices with no name, most heard first. A voice heard in one recording shows only when it
    /// might be someone: on its own it isn't worth asking about yet.
    public func unnamedClusters(limit: Int) async throws -> [VoiceCluster] {
        try await db.reader.read { d in
            let found = try Self.clusters(d, only: nil)
            return found
                .filter { $0.recordingCount >= 2 || $0.suggestedPersonId != nil || $0.repaired }
                .sorted { $0.repaired != $1.repaired ? $0.repaired : ($0.speechMs == $1.speechMs ? $0.id < $1.id : $0.speechMs > $1.speechMs) }
                .prefix(max(limit, found.filter(\.repaired).count))
                .map(Self.clearestFirst)
        }
    }

    /// One unnamed voice, whatever its place in the list.
    public func unnamedCluster(id: Int64) async throws -> VoiceCluster? {
        try await db.reader.read { d in try Self.clusters(d, only: id).first.map(Self.clearestFirst) }
    }

    private static func clearestFirst(_ cluster: VoiceCluster) -> VoiceCluster {
        var cluster = cluster
        cluster.clips.sort { ($0.confidencePercent, $0.speechMs) > ($1.confidencePercent, $1.speechMs) }
        return cluster
    }

    private static func clusters(_ d: Database, only: Int64?) throws -> [VoiceCluster] {
        var clusters: [Int64: VoiceCluster] = [:]
        let splitConstraints = try VoiceSplitStore.constraints(d)
        let scope = only == nil ? "" : "AND clusterId = ?"
        for row in try Row.fetchAll(d, sql: """
            SELECT id, segmentId, clusterId, cropsJSON, speechMs, suggestedPersonId, suggestedScore FROM voice_speakers
            WHERE clusterId IS NOT NULL AND personId IS NULL AND hidden = 0 \(scope)
            """, arguments: only.map { [$0] } ?? []) {
            let clusterId: Int64 = row["clusterId"], segmentId: String = row["segmentId"]
            let crops = decode(row["cropsJSON"])
            guard let best = crops.max(by: { ($0.confidencePercent, $0.endMs - $0.startMs) < ($1.confidencePercent, $1.endMs - $1.startMs) }) else { continue }
            let speech: Int64 = row["speechMs"]
            let heardAt = heardAt(segmentId)
            var cluster = clusters[clusterId] ?? VoiceCluster(id: clusterId, speechMs: 0, lastHeardMs: 0,
                suggestedPersonId: row["suggestedPersonId"], suggestedScore: row["suggestedScore"], clips: [])
            cluster.repaired = cluster.repaired || !VoiceSplitConstraint.signature(for: crops, constraints: splitConstraints[segmentId] ?? []).isEmpty
            cluster.speechMs += speech
            cluster.lastHeardMs = max(cluster.lastHeardMs, heardAt)
            cluster.clips.append(VoiceClusterClip(speakerId: row["id"], segmentId: segmentId, startMediaMs: best.startMs,
                endMediaMs: best.endMs, confidencePercent: best.confidencePercent, speechMs: speech, heardAtMs: heardAt))
            clusters[clusterId] = cluster
        }
        return Array(clusters.values)
    }

    /// Where these recordings hold a voice that might be someone or keeps coming back, for the
    /// conversation screen. A voice heard nowhere else and like no one isn't worth a mention.
    public func unnamedSpans(segmentIds: [String]) async throws -> [VoiceSpeakerSpan] {
        guard !segmentIds.isEmpty else { return [] }
        return try await db.reader.read { d in
            let marks = Array(repeating: "?", count: segmentIds.count).joined(separator: ",")
            let spans = try Row.fetchAll(d, sql: """
                SELECT id, segmentId, clusterId, cropsJSON, suggestedPersonId, suggestedScore FROM voice_speakers
                WHERE segmentId IN (\(marks)) AND clusterId IS NOT NULL AND personId IS NULL AND hidden = 0
                """, arguments: StatementArguments(segmentIds)).map {
                VoiceSpeakerSpan(speakerId: $0["id"], segmentId: $0["segmentId"], clusterId: $0["clusterId"],
                                 crops: Self.decode($0["cropsJSON"]), suggestedPersonId: $0["suggestedPersonId"],
                                 suggestedScore: $0["suggestedScore"])
            }
            var heardElsewhere = Set<Int64>()
            for clusterId in Set(spans.filter { $0.suggestedPersonId == nil }.map(\.clusterId)) {
                let recordings = try Int.fetchOne(d, sql: "SELECT COUNT(DISTINCT segmentId) FROM voice_speakers WHERE clusterId = ?",
                                                  arguments: [clusterId]) ?? 0
                if recordings >= 2 { heardElsewhere.insert(clusterId) }
            }
            return spans.filter { $0.suggestedPersonId != nil || heardElsewhere.contains($0.clusterId) }
        }
    }

    /// The conversations someone was recognized in, newest first.
    public func appearances(personId: String) async throws -> [VoicePersonAppearance] {
        try await db.reader.read { d in
            let speakers = try Row.fetchAll(d, sql: "SELECT id, segmentId, cropsJSON FROM voice_speakers WHERE personId = ?",
                                            arguments: [personId])
            guard !speakers.isEmpty else { return [] }
            struct Piece { var conversationId: String; var title: String?; var startMs: Int64; var range: Range<Int64> }
            var pieces: [String: [Piece]] = [:]
            for row in try Row.fetchAll(d, sql: """
                SELECT cs.segmentId, cs.conversationId, cs.startMediaMs, cs.endMediaMs, c.startMs, a.title
                FROM conversation_segments cs JOIN conversations c ON c.id = cs.conversationId
                LEFT JOIN annotations a ON a.conversationId = c.id
                WHERE cs.segmentId IN (SELECT segmentId FROM voice_speakers WHERE personId = ?)
                """, arguments: [personId]) {
                let start: Int64? = row["startMediaMs"], end: Int64? = row["endMediaMs"]
                pieces[row["segmentId"], default: []].append(Piece(conversationId: row["conversationId"], title: row["title"],
                    startMs: row["startMs"], range: (start ?? 0)..<max((start ?? 0) + 1, end ?? .max)))
            }
            var found: [String: VoicePersonAppearance] = [:]
            for speaker in speakers {
                let id: Int64 = speaker["id"], segmentId: String = speaker["segmentId"]
                let crops = Self.decode(speaker["cropsJSON"])
                for piece in pieces[segmentId] ?? [] {
                    let inside = crops.filter { $0.startMs < piece.range.upperBound && $0.endMs > piece.range.lowerBound }
                    guard let best = inside.max(by: { ($0.confidencePercent, $0.endMs - $0.startMs) < ($1.confidencePercent, $1.endMs - $1.startMs) }) else { continue }
                    let speech = inside.reduce(Int64(0)) { $0 + min($1.endMs, piece.range.upperBound) - max($1.startMs, piece.range.lowerBound) }
                    var appearance = found[piece.conversationId] ?? VoicePersonAppearance(conversationId: piece.conversationId, title: piece.title,
                        startMs: piece.startMs, speechMs: 0, speakerIds: [],
                        clip: VoiceClusterClip(speakerId: id, segmentId: segmentId, startMediaMs: best.startMs, endMediaMs: best.endMs,
                                               confidencePercent: best.confidencePercent, speechMs: speech, heardAtMs: Self.heardAt(segmentId)))
                    appearance.speechMs += speech
                    if !appearance.speakerIds.contains(id) { appearance.speakerIds.append(id) }
                    if best.confidencePercent > appearance.clip.confidencePercent {
                        appearance.clip = VoiceClusterClip(speakerId: id, segmentId: segmentId, startMediaMs: best.startMs, endMediaMs: best.endMs,
                                                           confidencePercent: best.confidencePercent, speechMs: speech, heardAtMs: Self.heardAt(segmentId))
                    }
                    found[piece.conversationId] = appearance
                }
            }
            return found.values.sorted { $0.startMs == $1.startMs ? $0.conversationId < $1.conversationId : $0.startMs > $1.startMs }
        }
    }

    /// How much of what's been said has a name, and whose.
    public func coverage() async throws -> VoiceCoverage {
        try await db.reader.read { d in
            let speech = try Int64.fetchOne(d, sql: "SELECT COALESCE(SUM(speechMs), 0) FROM voice_print_sources") ?? 0
            var people: [String: VoicePersonStats] = [:]
            for row in try Row.fetchAll(d, sql: """
                SELECT personId, SUM(ms) AS ms FROM (
                    SELECT personId, endMediaMs - startMediaMs AS ms FROM voice_auto_attributions WHERE disposition = 'recognized'
                    UNION ALL SELECT personId, endMediaMs - startMediaMs FROM speaker_corrections WHERE personId IS NOT NULL
                ) GROUP BY personId
                """) {
                let id: String = row["personId"]
                people[id] = VoicePersonStats(personId: id, speechMs: row["ms"], conversations: 0, lastHeardMs: nil, possibleMatches: 0)
            }
            for row in try Row.fetchAll(d, sql: """
                SELECT personId, COUNT(DISTINCT conversationId) AS conversations, MAX(startMs) AS last FROM (
                    SELECT a.personId, cs.conversationId, c.startMs FROM voice_auto_attributions a
                    JOIN conversation_segments cs ON cs.segmentId = a.segmentId
                        AND COALESCE(cs.startMediaMs, 0) < a.endMediaMs AND (cs.endMediaMs IS NULL OR cs.endMediaMs > a.startMediaMs)
                    JOIN conversations c ON c.id = cs.conversationId WHERE a.disposition = 'recognized'
                    UNION ALL SELECT a.personId, cs.conversationId, c.startMs FROM speaker_corrections a
                    JOIN conversation_segments cs ON cs.segmentId = a.segmentId
                        AND COALESCE(cs.startMediaMs, 0) < a.endMediaMs AND (cs.endMediaMs IS NULL OR cs.endMediaMs > a.startMediaMs)
                    JOIN conversations c ON c.id = cs.conversationId WHERE a.personId IS NOT NULL
                ) GROUP BY personId
                """) {
                let id: String = row["personId"]
                people[id]?.conversations = row["conversations"]
                people[id]?.lastHeardMs = row["last"]
            }
            for row in try Row.fetchAll(d, sql: """
                SELECT suggestedPersonId AS personId, COUNT(DISTINCT clusterId) AS n FROM voice_speakers
                WHERE suggestedPersonId IS NOT NULL AND personId IS NULL AND hidden = 0 GROUP BY suggestedPersonId
                """) {
                let id: String = row["personId"]
                if people[id] == nil { people[id] = VoicePersonStats(personId: id, speechMs: 0, conversations: 0, lastHeardMs: nil, possibleMatches: 0) }
                people[id]?.possibleMatches = row["n"]
            }
            let named = people.values.reduce(0) { $0 + $1.speechMs }
            return VoiceCoverage(speechMs: max(speech, named), namedMs: named,
                                 byPerson: people.values.sorted { $0.speechMs == $1.speechMs ? $0.personId < $1.personId : $0.speechMs > $1.speechMs })
        }
    }

    // --- codec --------------------------------------------------------------------------------

    /// A recording's id leads with when it began.
    static func heardAt(_ segmentId: String) -> Int64 {
        let parts = segmentId.split(separator: "-")
        guard parts.count >= 2, let ms = Int64(parts[1]) else { return 0 }
        return ms
    }

    static func encode(_ crops: [VoiceSpeakerCrop]) -> String {
        "[" + crops.map { "[\($0.startMs),\($0.endMs),\($0.confidencePercent)]" }.joined(separator: ",") + "]"
    }

    static func decode(_ json: String) -> [VoiceSpeakerCrop] {
        guard let rows = try? JSONDecoder().decode([[Int64]].self, from: Data(json.utf8)) else { return [] }
        return rows.compactMap { $0.count == 3 ? VoiceSpeakerCrop(startMs: $0[0], endMs: $0[1], confidencePercent: Int($0[2])) : nil }
    }
}
