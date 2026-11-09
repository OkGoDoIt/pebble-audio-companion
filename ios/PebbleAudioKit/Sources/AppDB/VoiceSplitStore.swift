import Foundation
import GRDB

/// A human separation is tied to audio ranges, not the disposable IDs of derived speakers.
public struct VoiceSplitConstraint: Sendable, Equatable {
    public var operation: String
    public var part: String
    public var segmentId: String
    public var startMs: Int64
    public var endMs: Int64

    public static func signature(for crops: [VoiceSpeakerCrop], constraints: [Self]) -> [String: String] {
        var parts: [String: Set<String>] = [:]
        for constraint in constraints where crops.contains(where: {
            $0.startMs < constraint.endMs && $0.endMs > constraint.startMs
        }) { parts[constraint.operation, default: []].insert(constraint.part) }
        // A newly analyzed crop crossing an old boundary remains separate from BOTH sides.
        return parts.mapValues { $0.sorted().joined(separator: ",") }
    }
}

public struct VoiceSplitMember: Sendable {
    public let id: Int64
    public let segmentId: String
    public let crops: [VoiceSpeakerCrop]
    public let sealedVoice: Data?
    public let recipeJSON: Data?
    public let prints: [VoiceTurnPrint]
    public let clusterId: Int64?
    public let rejected: [String]
}

public struct VoiceSplitSnapshot: Sendable {
    public let members: [VoiceSplitMember]
    public let stamp: String
}

/// One child group can include several speakers/recordings. Crop indices address the immutable
/// snapshot; the writer checks exact partition coverage before changing anything.
public struct VoiceSplitPart: Sendable {
    public var group: String
    public var memberID: Int64
    public var cropIndices: [Int]
    public var sealedVoice: Data?
    public var recipeJSON: Data?
    public init(group: String, memberID: Int64, cropIndices: [Int], sealedVoice: Data?, recipeJSON: Data?) {
        self.group = group; self.memberID = memberID; self.cropIndices = cropIndices
        self.sealedVoice = sealedVoice; self.recipeJSON = recipeJSON
    }
}

public struct VoiceSplitUndo: Sendable {
    public let operation: String
    public let original: VoiceSplitSnapshot
    public let newIDs: [Int64]
    public let stamp: String
}

public enum VoiceSplitError: Error, LocalizedError {
    case changed, invalidPartition, unavailable
    public var errorDescription: String? {
        switch self {
        case .changed: "This voice changed while you were reviewing it. Open it again to see the latest clips."
        case .invalidPartition: "These clips couldn’t be separated. Try splitting the voice again."
        case .unavailable: "These voice samples are no longer available."
        }
    }
}

public struct VoiceSplitStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static func installSchema(_ d: Database) throws {
        try d.execute(sql: """
            CREATE TABLE voice_split_ranges (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                operation TEXT NOT NULL, part TEXT NOT NULL,
                segmentId TEXT NOT NULL REFERENCES voice_sources(segmentId) ON DELETE CASCADE,
                startMs INTEGER NOT NULL, endMs INTEGER NOT NULL,
                CHECK(startMs >= 0 AND endMs > startMs),
                UNIQUE(operation,segmentId,startMs,endMs)
            );
            CREATE INDEX voice_split_ranges_source ON voice_split_ranges(segmentId);
            CREATE INDEX voice_split_ranges_operation ON voice_split_ranges(operation);
            CREATE TRIGGER voice_split_source_retired AFTER UPDATE OF state ON voice_sources
            WHEN NEW.state IN ('deleted','expired') BEGIN
                DELETE FROM voice_split_ranges WHERE segmentId = NEW.segmentId;
            END;
            """)
    }

    public func constraints() async throws -> [String: [VoiceSplitConstraint]] {
        try await db.reader.read { try Self.constraints($0) }
    }
    static func constraints(_ d: Database) throws -> [String: [VoiceSplitConstraint]] {
        try Dictionary(grouping: Row.fetchAll(d, sql: "SELECT * FROM voice_split_ranges ORDER BY id").map {
            VoiceSplitConstraint(operation: $0["operation"], part: $0["part"], segmentId: $0["segmentId"],
                                 startMs: $0["startMs"], endMs: $0["endMs"])
        }, by: \.segmentId)
    }

    public func snapshot(speakerIDs: [Int64]) async throws -> VoiceSplitSnapshot {
        try await db.reader.read { d in
            let ids = Array(Set(speakerIDs)).sorted()
            guard !ids.isEmpty else { throw VoiceSplitError.unavailable }
            let stamp = try Self.stamp(d, ids: ids, requireUnnamed: true)
            var members: [VoiceSplitMember] = []
            for id in ids {
                guard let row = try Row.fetchOne(d, sql: """
                    SELECT s.*, r.recipeJSON FROM voice_speakers s
                    LEFT JOIN voice_print_recipes r ON r.id = s.recipe WHERE s.id = ?
                    """, arguments: [id]) else { throw VoiceSplitError.changed }
                let segment: String = row["segmentId"]
                let crops = VoiceSpeakerStore.decode(row["cropsJSON"])
                let prints = try Row.fetchAll(d, sql: """
                    SELECT t.*,r.recipeJSON FROM voice_turn_prints t
                    JOIN voice_print_recipes r ON r.id = t.recipe WHERE t.segmentId = ? ORDER BY t.startMediaMs,t.id
                    """, arguments: [segment]).map(VoicePrintStore.print).filter { print in
                        crops.contains { $0.startMs == print.startMediaMs && $0.endMs == print.endMediaMs }
                    }
                let rejected = try String.fetchAll(d, sql: "SELECT personId FROM voice_speaker_decisions WHERE speakerId = ? AND kind = 'rejected' AND personId IS NOT NULL ORDER BY personId", arguments: [id])
                members.append(VoiceSplitMember(id: id, segmentId: segment, crops: crops,
                    sealedVoice: row["voice"], recipeJSON: row["recipeJSON"], prints: prints,
                    clusterId: row["clusterId"], rejected: rejected))
            }
            return VoiceSplitSnapshot(members: members, stamp: stamp)
        }
    }

    /// Includes source/config generation and human decisions. Background score updates don't
    /// invalidate an open review, but naming, reanalysis, and another split do.
    private static func stamp(_ d: Database, ids: [Int64], requireUnnamed: Bool) throws -> String {
        let config = try VoiceIdentityStore.configuration(d)
        guard config.mode == .local else { throw VoiceSplitError.changed }
        var bits = [String(config.generation)]
        for id in ids.sorted() {
            guard let row = try Row.fetchOne(d, sql: """
                SELECT s.segmentId,s.cropsJSON,s.personId,s.hidden,p.sourceRevision,p.sourceGeneration,
                  (SELECT COUNT(*) FROM voice_speaker_decisions WHERE speakerId=s.id) AS decisions,
                  (SELECT COALESCE(SUM(id),0) FROM voice_speaker_decisions WHERE speakerId=s.id) AS decisionIDs,
                  (SELECT COUNT(*) FROM voice_speaker_decisions WHERE speakerId=s.id AND kind IN ('confirmed','ignored','excluded')) AS decided,
                  (SELECT COUNT(*) FROM voice_split_ranges WHERE segmentId=s.segmentId) AS splits,
                  (SELECT COALESCE(SUM(id),0) FROM voice_split_ranges WHERE segmentId=s.segmentId) AS splitIDs
                FROM voice_speakers s JOIN voice_print_sources p ON p.segmentId=s.segmentId
                JOIN voice_sources v ON v.segmentId=s.segmentId
                WHERE s.id=? AND v.state NOT IN ('deleted','expired')
                  AND v.generation=p.sourceGeneration AND v.revision=p.sourceRevision
                """, arguments: [id]) else { throw VoiceSplitError.changed }
            if requireUnnamed {
                guard row["personId"] == nil, !(row["hidden"] as Bool), (row["decided"] as Int) == 0 else { throw VoiceSplitError.changed }
            }
            bits += [String(id), row["segmentId"] as String, row["cropsJSON"] as String,
                     row["sourceRevision"] as String, String(row["sourceGeneration"] as Int64),
                     String(row["decisions"] as Int), String(row["decisionIDs"] as Int64),
                     String(row["splits"] as Int), String(row["splitIDs"] as Int64)]
        }
        return bits.joined(separator: "|")
    }

    public func save(_ snapshot: VoiceSplitSnapshot, parts: [VoiceSplitPart]) async throws -> VoiceSplitUndo {
        try await db.writer.write { d in
            let ids = snapshot.members.map(\.id)
            guard try Self.stamp(d, ids: ids, requireUnnamed: true) == snapshot.stamp else { throw VoiceSplitError.changed }
            guard Set(parts.map(\.group)).count > 1 else { throw VoiceSplitError.invalidPartition }
            let members = Dictionary(uniqueKeysWithValues: snapshot.members.map { ($0.id, $0) })
            var seen = Set<String>()
            for part in parts {
                guard let member = members[part.memberID], !part.cropIndices.isEmpty, !part.group.isEmpty else { throw VoiceSplitError.invalidPartition }
                for index in part.cropIndices {
                    guard member.crops.indices.contains(index), seen.insert("\(member.id):\(index)").inserted else { throw VoiceSplitError.invalidPartition }
                }
            }
            guard seen.count == snapshot.members.reduce(0, { $0 + $1.crops.count }) else { throw VoiceSplitError.invalidPartition }
            let operation = UUID().uuidString.lowercased()
            var newIDs: [Int64] = []
            var clusterIDs: [String: Int64] = [:]
            for part in parts {
                let member = members[part.memberID]!
                let crops = part.cropIndices.sorted().map { member.crops[$0] }
                let id = try Self.insert(d, id: nil, segment: member.segmentId, crops: crops,
                    voice: part.sealedVoice, recipe: part.recipeJSON, cluster: clusterIDs[part.group], rejected: member.rejected)
                newIDs.append(id)
                if clusterIDs[part.group] == nil {
                    clusterIDs[part.group] = id
                    try d.execute(sql: "UPDATE voice_speakers SET clusterId=? WHERE id=?", arguments: [id,id])
                }
                for crop in crops {
                    try d.execute(sql: "INSERT INTO voice_split_ranges(operation,part,segmentId,startMs,endMs) VALUES (?,?,?,?,?)",
                                  arguments: [operation,part.group,member.segmentId,crop.startMs,crop.endMs])
                }
            }
            for id in ids { try d.execute(sql: "DELETE FROM voice_speakers WHERE id=?", arguments: [id]) }
            for segment in Set(snapshot.members.map(\.segmentId)) { try VoicePrintStore.markStale(d, segmentId: segment) }
            return VoiceSplitUndo(operation: operation, original: snapshot, newIDs: newIDs,
                                 stamp: try Self.stamp(d, ids: newIDs, requireUnnamed: false))
        }
    }

    public func undo(_ undo: VoiceSplitUndo) async throws {
        try await db.writer.write { d in
            guard try Self.stamp(d, ids: undo.newIDs, requireUnnamed: false) == undo.stamp else { throw VoiceSplitError.changed }
            try d.execute(sql: "DELETE FROM voice_split_ranges WHERE operation=?", arguments: [undo.operation])
            for id in undo.newIDs { try d.execute(sql: "DELETE FROM voice_speakers WHERE id=?", arguments: [id]) }
            for member in undo.original.members {
                _ = try Self.insert(d, id: member.id, segment: member.segmentId, crops: member.crops,
                    voice: member.sealedVoice, recipe: member.recipeJSON, cluster: member.clusterId, rejected: member.rejected)
                try VoicePrintStore.markStale(d, segmentId: member.segmentId)
            }
        }
    }

    private static func insert(_ d: Database, id: Int64?, segment: String, crops: [VoiceSpeakerCrop],
                               voice: Data?, recipe: Data?, cluster: Int64?, rejected: [String]) throws -> Int64 {
        var recipeID: Int64?
        if let recipe {
            try d.execute(sql: "INSERT OR IGNORE INTO voice_print_recipes(recipeJSON) VALUES (?)", arguments: [recipe])
            recipeID = try Int64.fetchOne(d, sql: "SELECT id FROM voice_print_recipes WHERE recipeJSON=?", arguments: [recipe])
        }
        try d.execute(sql: """
            INSERT INTO voice_speakers(id,segmentId,cropsJSON,cropCount,speechMs,voice,recipe,clusterId)
            VALUES (?,?,?,?,?,?,?,?)
            """, arguments: [id,segment,VoiceSpeakerStore.encode(crops),crops.count,
                             crops.reduce(Int64(0)) { $0 + $1.endMs - $1.startMs },voice,recipeID,cluster])
        let saved = id ?? d.lastInsertedRowID
        for person in rejected {
            try d.execute(sql: "INSERT INTO voice_speaker_decisions(speakerId,kind,personId,createdAtMs) VALUES (?,'rejected',?,?)",
                          arguments: [saved,person,Int64(Date().timeIntervalSince1970 * 1_000)])
        }
        return saved
    }
}
