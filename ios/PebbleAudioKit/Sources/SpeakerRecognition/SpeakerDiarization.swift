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

    /// A crop's place in a recording and whose it is: all it takes to place a stretch of speech.
    public struct Span: Equatable, Sendable {
        public let startMs: Int64
        public let endMs: Int64
        public let speaker: Int
        public init(startMs: Int64, endMs: Int64, speaker: Int) {
            self.startMs = startMs; self.endMs = endMs; self.speaker = speaker
        }
    }

    /// Crops further apart than this aren't assumed to be one speaker's single breath.
    static let blockGapMs: Int64 = 2_000
    static let blockCrops = 4
    static let threshold = 0.30
    /// How far from the nearest crop a stretch with none of its own can still be placed.
    static let nearbyMs: Int64 = 5_000
    /// Below this much heard, a speaker is a fragment: too little to be sure of, but in a
    /// recording's one room still comparable with the speakers around it.
    public static let minimumCrops = 3
    static let fragmentSimilarity = 0.25
    static let fragmentMargin = 0.05

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
        return absorbingFragments(speaker, crops: crops)
    }

    /// A speaker too briefly heard joins the one it clearly resembles in the same recording.
    private static func absorbingFragments(_ speaker: [Int], crops: [Crop]) -> [Int] {
        var members: [Int: [Int]] = [:]
        for (index, id) in speaker.enumerated() { members[id, default: []].append(index) }
        func voice(_ ids: [Int]) -> SpeakerEmbedding? { try? SpeakerEmbedding.pooled(ids.map { crops[$0].embedding }) }
        let settled = members.filter { $0.value.count >= minimumCrops }.compactMapValues(voice)
        guard !settled.isEmpty else { return speaker }
        var out = speaker
        for (_, ids) in members where ids.count < minimumCrops {
            guard let fragment = voice(ids) else { continue }
            var ranked: [(id: Int, score: Double)] = []
            for (other, otherVoice) in settled {
                if let score = try? fragment.cosineSimilarity(to: otherVoice) { ranked.append((other, score)) }
            }
            ranked.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            guard let first = ranked.first, first.score >= fragmentSimilarity,
                  ranked.count == 1 || first.score - ranked[1].score >= fragmentMargin else { continue }
            for index in ids { out[index] = first.id }
        }
        return out
    }

    /// Which speaker a stretch belongs to: the one whose crops fill it, or with none inside it,
    /// the one on both sides of it. Nil when that isn't clear.
    public static func speaker(of range: Range<Int64>, spans: [Span]) -> Int? {
        var overlap: [Int: Int64] = [:]
        var before: Int?, after: Int?
        var beforeGap = Int64.max, afterGap = Int64.max
        for span in spans {
            let shared = min(range.upperBound, span.endMs) - max(range.lowerBound, span.startMs)
            if shared > 0 { overlap[span.speaker, default: 0] += shared }
            else if span.endMs <= range.lowerBound, range.lowerBound - span.endMs <= nearbyMs,
                    range.lowerBound - span.endMs < beforeGap {
                before = span.speaker; beforeGap = range.lowerBound - span.endMs
            } else if span.startMs >= range.upperBound, span.startMs - range.upperBound <= nearbyMs,
                      span.startMs - range.upperBound < afterGap {
                after = span.speaker; afterGap = span.startMs - range.upperBound
            }
        }
        if let best = overlap.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
            return Double(best.value) >= 0.6 * Double(overlap.values.reduce(0, +)) ? best.key : nil
        }
        if let before, let after { return before == after ? before : nil }
        return before ?? after
    }
}
