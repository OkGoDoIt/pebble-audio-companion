import Foundation

/// Who spoke when in one recording, from its own audio alone: no transcriber's speaker labels,
/// so it works the same for every transcription provider, including those with no labels at all.
///
/// A 2–3 s crop of watch audio is too noisy to compare directly: two crops of one person in one
/// recording score a median of 0.34, against 0.01 for two people, with the tails overlapping. So
/// neighbouring crops are pooled into blocks first, and blocks are grouped by average linkage.
/// Against real recordings with hand-labelled voices (2026-11-05) this kept 42 of 46 same-person
/// pairs together and all 8 different-person pairs apart, including a pair the transcriber had
/// filed under one speaker. It agrees with the transcriber's labels about 85% of the time.
public enum SpeakerDiarization {
    public struct Crop: Sendable {
        public let startMs: Int64
        public let endMs: Int64
        public let embedding: SpeakerEmbedding
        public init(startMs: Int64, endMs: Int64, embedding: SpeakerEmbedding) {
            self.startMs = startMs; self.endMs = endMs; self.embedding = embedding
        }
    }

    /// Crops further apart than this aren't assumed to be one speaker's single breath.
    static let blockGapMs: Int64 = 2_000
    static let blockCrops = 4
    static let threshold = 0.30
    /// How far from the nearest crop a stretch with none of its own can still be placed.
    static let nearbyMs: Int64 = 5_000

    /// The speakers of a recording: for each crop in `crops` (in time order), which speaker it is.
    public static func speakers(_ crops: [Crop]) -> [Int] {
        guard !crops.isEmpty else { return [] }
        var blocks: [[Int]] = [[0]]
        for index in crops.indices.dropFirst() {
            let last = blocks[blocks.count - 1]
            if crops[index].startMs - crops[last[last.count - 1]].endMs > blockGapMs || last.count >= blockCrops {
                blocks.append([index])
            } else { blocks[blocks.count - 1].append(index) }
        }
        let voices = blocks.compactMap { block in
            try? SpeakerEmbedding.pooled(block.map { crops[$0].embedding })
        }
        guard voices.count == blocks.count else { return crops.indices.map { $0 } }
        var speaker = [Int](repeating: 0, count: crops.count)
        for (id, group) in SpeakerGrouping.averageLinkage(voices, threshold: threshold).enumerated() {
            for block in group { for crop in blocks[block] { speaker[crop] = id } }
        }
        return speaker
    }

    /// Which speaker a stretch belongs to: the one whose crops fill it, or with none inside it,
    /// the one on both sides of it. Nil when that isn't clear.
    public static func speaker(of range: Range<Int64>, crops: [Crop], speakers: [Int]) -> Int? {
        var overlap: [Int: Int64] = [:]
        var before: Int?, after: Int?
        for (index, crop) in crops.enumerated() {
            let shared = min(range.upperBound, crop.endMs) - max(range.lowerBound, crop.startMs)
            if shared > 0 { overlap[speakers[index], default: 0] += shared }
            else if crop.endMs <= range.lowerBound, range.lowerBound - crop.endMs <= nearbyMs { before = speakers[index] }
            else if after == nil, crop.startMs >= range.upperBound, crop.startMs - range.upperBound <= nearbyMs { after = speakers[index] }
        }
        if let best = overlap.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
            return Double(best.value) >= 0.6 * Double(overlap.values.reduce(0, +)) ? best.key : nil
        }
        if let before, let after { return before == after ? before : nil }
        return before ?? after
    }
}
