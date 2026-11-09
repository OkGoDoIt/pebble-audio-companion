import Accelerate
import Foundation

/// An on-demand repair favors precision: every pair in a child must pass, rather than only the
/// average. No micro-cluster is irreversible, no fragment is forced into a bigger voice, and an
/// unreadable sample remains its own child. This does not change ordinary recognition policy.
public enum VoiceSubdivision {
    public static func split(_ vectors: [[Float]?], minimumSimilarity: Float = 0.65) throws -> [[Int]] {
        guard vectors.count > 1 else { return vectors.indices.map { [$0] } }
        func score(_ a: Int, _ b: Int) -> Float {
            guard let x = vectors[a], let y = vectors[b], !x.isEmpty, x.count == y.count else { return -1 }
            let result = vDSP.dot(x,y)
            return result.isFinite ? min(1, max(-1,result)) : -1
        }
        // Tighten relative to THIS group. Repeated splitting always makes progress, even where
        // a noisy room makes all the samples unusually alike. It never asserts distinct people.
        var weakest: Float = 1
        for a in vectors.indices {
            try Task.checkCancellation()
            for b in vectors.indices where b < a { weakest = min(weakest,score(a,b)) }
        }
        let threshold = max(minimumSimilarity, weakest + 0.02)
        var groups: [[Int]] = []
        for index in vectors.indices {
            try Task.checkCancellation()
            guard vectors[index] != nil else { groups.append([index]); continue }
            var best: Int?, bestScore: Float = -1
            for g in groups.indices {
                var minimum: Float = 1
                for other in groups[g] {
                    minimum = min(minimum,score(index,other))
                    if minimum < threshold { break }
                }
                if minimum >= threshold, minimum > bestScore { best = g; bestScore = minimum }
            }
            if let best { groups[best].append(index) } else { groups.append([index]) }
        }
        return groups
    }
}
