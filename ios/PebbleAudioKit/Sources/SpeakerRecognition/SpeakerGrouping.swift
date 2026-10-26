import Foundation

/// Groups voice crops that sound alike, for "who is this?" questions. Average linkage: two
/// groups join only when their crops are alike on average, so one stray similar pair can't chain
/// two people together. Deliberately strict — naming a group that mixes two people would teach
/// the wrong voice, while one person split into two groups just means being asked twice.
public enum SpeakerGrouping {
    public struct Item: Sendable {
        public let id: String
        public let sourceID: String
        public let embedding: SpeakerEmbedding
        public init(id: String, sourceID: String, embedding: SpeakerEmbedding) {
            self.id = id; self.sourceID = sourceID; self.embedding = embedding
        }
    }

    /// Groups of item IDs, largest first. A group needs `minimumItems` crops from at least
    /// `minimumSources` different recordings: one recording's voice is already in front of the
    /// person, and a voice heard once is not worth asking about.
    public static func group(_ items: [Item], threshold: Double = 0.6, minimumItems: Int = 3,
                             minimumSources: Int = 2) -> [[String]] {
        let n = items.count
        guard n >= minimumItems else { return [] }
        var similarity = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let s = (try? items[i].embedding.cosineSimilarity(to: items[j].embedding)) ?? -1
                similarity[i][j] = s; similarity[j][i] = s
            }
        }
        // Cluster-level sums of pairwise similarity; average = sum / (|a| * |b|).
        var members: [[Int]?] = (0..<n).map { [$0] }
        var sums = similarity
        while true {
            var best = (a: -1, b: -1, average: threshold)
            for a in 0..<n {
                guard let ma = members[a] else { continue }
                for b in (a + 1)..<n {
                    guard let mb = members[b] else { continue }
                    let average = sums[a][b] / Double(ma.count * mb.count)
                    if average >= best.average { best = (a, b, average) }
                }
            }
            guard best.a >= 0, let ma = members[best.a], let mb = members[best.b] else { break }
            members[best.a] = ma + mb
            members[best.b] = nil
            for c in 0..<n where c != best.a && members[c] != nil {
                sums[best.a][c] += sums[best.b][c]
                sums[c][best.a] = sums[best.a][c]
            }
        }
        return members.compactMap { $0 }
            .filter { $0.count >= minimumItems && Set($0.map { items[$0].sourceID }).count >= minimumSources }
            .sorted { $0.count > $1.count }
            .map { $0.map { items[$0].id } }
    }
}
