import AppDB
import Foundation
import SpeakerRecognition

public struct VoiceSplitAtom: Sendable, Identifiable {
    public let id: String
    public let memberID: Int64
    public let cropIndex: Int
    public let segmentId: String
    public let startMs: Int64
    public let endMs: Int64
    public let confidence: Int
    let embedding: SpeakerEmbedding?
}

public struct VoiceSplitPreview: Sendable {
    public let snapshot: VoiceSplitSnapshot
    public let atoms: [VoiceSplitAtom]
    public var groups: [[String]]

    /// Subdivide only the selected child. Everything outside it stays exactly as reviewed.
    public func refined(group index: Int, individual: Bool = false) async throws -> Self {
        guard groups.indices.contains(index) else { throw VoiceSplitError.changed }
        let child = groups[index]
        let atomByID = Dictionary(uniqueKeysWithValues: atoms.map { ($0.id,$0) })
        let chosen = child.compactMap { atomByID[$0] }
        guard chosen.count == child.count else { throw VoiceSplitError.changed }
        let partitions = try await voiceSplitWork {
            try Self.partition(chosen, individual: individual)
        }
        try Task.checkCancellation()
        var result = self
        result.groups.replaceSubrange(index...index, with: partitions)
        return result
    }

    static func partition(_ atoms: [VoiceSplitAtom], individual: Bool) throws -> [[String]] {
        if individual { return atoms.map { [$0.id] } }
        let members = Dictionary(grouping: atoms, by: \.memberID)
        let ordered = members.keys.sorted()
        // First repair across recordings using the steadier pooled voices. Once down to one
        // local speaker, reopen its ORIGINAL prints; the bad pooling is no longer indivisible.
        if ordered.count > 1 {
            let pooled = ordered.map { id -> SpeakerEmbedding? in
                let samples = members[id]!.compactMap(\.embedding)
                guard samples.count == members[id]!.count else { return nil }
                return try? SpeakerEmbedding.pooled(samples)
            }
            return try VoiceSubdivision.split(pooled.map { $0?.values }).map { indices in
                indices.flatMap { members[ordered[$0]]!.map(\.id) }
            }
        }
        return try VoiceSubdivision.split(atoms.map { $0.embedding?.values }, minimumSimilarity: 0.55)
            .map { indices in indices.map { atoms[$0].id } }
    }
}

public struct VoiceSplitSaved: Sendable {
    public let undo: VoiceSplitUndo
    /// One per reviewed group, in the same order.
    public let groups: [VoiceRecognitionService.UnknownVoiceGroup]
}

extension VoiceRecognitionService {
    public func splitPreview(speakerIDs: [Int64]) async throws -> VoiceSplitPreview {
        let snapshot = try await VoiceSplitStore(db: store.db).snapshot(speakerIDs: speakerIDs)
        let protector = protector
        let preview = try await voiceSplitWork {
            var atoms: [VoiceSplitAtom] = []
            for member in snapshot.members {
                for (index,crop) in member.crops.enumerated() {
                    try Task.checkCancellation()
                    let print = member.prints.first { $0.startMediaMs == crop.startMs && $0.endMediaMs == crop.endMs }
                    let embedding = print.flatMap { try? Self.open($0,protector: protector) }
                    atoms.append(VoiceSplitAtom(id: "\(member.id):\(index)", memberID: member.id, cropIndex: index,
                        segmentId: member.segmentId,startMs: crop.startMs,endMs: crop.endMs,
                        confidence: crop.confidencePercent,embedding: embedding))
                }
            }
            guard atoms.count > 1 else { throw VoiceSplitError.unavailable }
            return VoiceSplitPreview(snapshot: snapshot, atoms: atoms,
                groups: try VoiceSplitPreview.partition(atoms,individual: false))
        }
        try Task.checkCancellation()
        return preview
    }

    public func saveSplit(_ preview: VoiceSplitPreview) async throws -> VoiceSplitUndo {
        try await saveSplitGroups(preview).undo
    }

    /// Saves the split and hands back each child, in the order reviewed, so one can be named in
    /// the same step. A child holds exactly its own new speakers: an answer about it says
    /// nothing about the other children.
    public func saveSplitGroups(_ preview: VoiceSplitPreview) async throws -> VoiceSplitSaved {
        let protector = protector
        let (parts, shown) = try await voiceSplitWork {
            let atoms = Dictionary(uniqueKeysWithValues: preview.atoms.map { ($0.id,$0) })
            var parts: [VoiceSplitPart] = []
            // The clearest sample of each part, to stand for its new speaker.
            var shown: [VoiceSplitAtom] = []
            for group in preview.groups {
                try Task.checkCancellation()
                let groupID = UUID().uuidString.lowercased()
                let chosen = group.compactMap { atoms[$0] }
                guard chosen.count == group.count else { throw VoiceSplitError.invalidPartition }
                for (memberID, local) in Dictionary(grouping: chosen, by: \.memberID).sorted(by: { $0.key < $1.key }) {
                    let vectors = local.compactMap(\.embedding)
                    var sealed: Data?, recipe: Data?
                    if vectors.count == local.count, let pooled = try? SpeakerEmbedding.pooled(vectors) {
                        let print = try VoicePrintCodec.save(pooled)
                        sealed = try protector.seal(print.bytes)
                        recipe = try JSONEncoder().encode(print.embedding.recipe)
                    }
                    parts.append(VoiceSplitPart(group: groupID,memberID: memberID,
                        cropIndices: local.map(\.cropIndex),sealedVoice: sealed,recipeJSON: recipe))
                    shown.append(local.max { $0.confidence < $1.confidence } ?? local[0])
                }
            }
            return (parts, shown)
        }
        try Task.checkCancellation()
        let undo = try await VoiceSplitStore(db: store.db).save(preview.snapshot, parts: parts)
        clusterKey = nil
        changed()
        // The store saves one speaker per part, in order.
        let atoms = Dictionary(uniqueKeysWithValues: preview.atoms.map { ($0.id,$0) })
        var crops: [String: [VoiceUnmatchedCrop]] = [:]
        var order: [String] = []
        for (index, part) in parts.enumerated() where undo.newIDs.indices.contains(index) {
            if crops[part.group] == nil { order.append(part.group) }
            crops[part.group, default: []].append(VoiceUnmatchedCrop(id: String(undo.newIDs[index]),
                segmentId: shown[index].segmentId, startMediaMs: shown[index].startMs, endMediaMs: shown[index].endMs,
                sourceRevision: "", recipeID: recipeID, embeddingJSON: Data(),
                speechConfidence: Double(shown[index].confidence) / 100))
        }
        let groups = zip(order, preview.groups).map { part, ids in
            var group = UnknownVoiceGroup(clusterId: Int64(crops[part]?.first?.id ?? "") ?? 0, crops: crops[part] ?? [],
                speechMs: ids.compactMap { atoms[$0] }.reduce(Int64(0)) { $0 + $1.endMs - $1.startMs })
            group.repaired = true
            return group
        }
        return VoiceSplitSaved(undo: undo, groups: groups)
    }

    public func undoSplit(_ undo: VoiceSplitUndo) async throws {
        try await VoiceSplitStore(db: store.db).undo(undo)
        clusterKey = nil
        changed()
    }
}

/// Cancellation follows the sheet's task into the detached comparisons.
private func voiceSplitWork<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated, operation: work)
    return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
}
