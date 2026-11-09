import Accelerate
import Foundation

/// Sorts every recording's speakers into voices across the whole archive, the way a photo library
/// sorts faces into people. The thing a person names is a group, not a clip: one answer names
/// everything in it, and what they haven't been asked about keeps sorting itself.
///
/// An item is one speaker in one recording, pooled (`SpeakerDiarization`). Groups form by average
/// linkage, which keeps one similar pair from chaining two people together; that matters because
/// a room inflates similarity (two people in one room can score 0.67 while the same person across
/// rooms scores 0.5). Measured on 223 real recordings (2026-11-05): 62% of speech is one group
/// holding every labelled sample of the wearer, the next groups each hold one other labelled
/// person, and in all 10 recordings where two speakers landed in one group the transcriber had
/// independently called them the same speaker.
public enum VoiceClustering {
    public struct Item: Sendable {
        /// The recording it came from: labels from one room say little about another.
        public let source: String
        public let voice: [Float]
        public let cropCount: Int
        /// Whose voice this is, by a person's own word; nil when nobody has said.
        public var person: String?
        /// People they've said this isn't.
        public var rejected: Set<String>
        /// They've said to stop asking about this voice.
        public var ignored: Bool
        public var separations: [String: String] = [:]
        public var requiresReview = false
        public init(source: String, voice: [Float], cropCount: Int, person: String? = nil,
                    rejected: Set<String> = [], ignored: Bool = false) {
            self.source = source; self.voice = voice; self.cropCount = cropCount
            self.person = person; self.rejected = rejected; self.ignored = ignored
        }
    }

    public struct Suggestion: Equatable, Sendable {
        public let person: String
        public let score: Double
    }

    public struct Group: Sendable {
        /// Indices into the items, with how alike each is to the group.
        public var members: [Int]
        public var similarity: [Double]
        public var person: String?
        public var ignored: Bool
        /// Who an unnamed group might be: not enough to name it, enough to ask.
        public var suggestion: Suggestion?
    }

    /// Average similarity at which two groups are the same voice. Measured: labelled pairs of one
    /// person across recordings mostly 0.5–0.9, different people mostly under 0.5.
    public static let sameVoice = 0.55
    /// Below `sameVoice`, how close to a named person earns the question "is this them?". A wrong
    /// guess costs one tap, so this is generous.
    public static let possibleVoice = 0.40
    /// A guess needs to be clearly the best one.
    static let suggestionMargin = 0.05
    /// Items this alike join before the exact pass, which is quadratic in what's left.
    static let microThresholds: [Float] = [0.75, 0.70, 0.65]
    static let maximumExactGroups = 3_000
    /// A well-established voice: a label that sounds clearly more like it than its own isn't believed.
    static let establishedSeeds = 3
    static let doubtMargin = 0.10

    public static func cluster(_ input: [Item]) -> [Group] {
        guard let dimensions = input.first?.voice.count, dimensions > 0 else { return [] }
        let items = believableLabels(input, dimensions: dimensions)
        var seeds: [Working] = []
        for threshold in microThresholds {
            seeds = microGroups(items, dimensions: dimensions, threshold: threshold)
            if seeds.count <= maximumExactGroups { break }
        }
        let merged = averageLinkage(seeds, dimensions: dimensions)
        return results(merged, items: items, dimensions: dimensions)
    }

    private struct Working {
        var members: [Int]
        var sum: [Float]
        var person: String?
        var ignored: Bool
        var rejected: Set<String>
        var separations: [String: String]
        var requiresReview: Bool

        func allows(_ other: Working) -> Bool {
            if separations.contains(where: { key, value in other.separations[key].map { $0 != value } ?? false }) { return false }
            if (requiresReview || other.requiresReview) && separations != other.separations { return false }
            if let person, let theirs = other.person, person != theirs { return false }
            if let person, other.rejected.contains(person) { return false }
            if let theirs = other.person, rejected.contains(theirs) { return false }
            if ignored != other.ignored, person != nil || other.person != nil { return false }
            return true
        }

        mutating func absorb(_ other: Working) {
            members += other.members
            vDSP.add(sum, other.sum, result: &sum)
            person = person ?? other.person
            ignored = ignored || other.ignored
            rejected.formUnion(other.rejected)
            separations.merge(other.separations) { old, _ in old }
            requiresReview = requiresReview || other.requiresReview
        }
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        vDSP.dot(a, b)
    }

    /// A label on a speaker the voice model hears as someone else's established voice doesn't
    /// define a voice: the diarizer may have merged two people there, or the label may be a
    /// slip. The labelled paragraphs keep their name either way; only the group ignores it.
    private static func believableLabels(_ input: [Item], dimensions: Int) -> [Item] {
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        var bySource: [String: [String: (sum: [Float], count: Int)]] = [:]
        for item in input {
            guard let person = item.person else { continue }
            sums[person, default: [Float](repeating: 0, count: dimensions)] =
                vDSP.add(sums[person] ?? [Float](repeating: 0, count: dimensions), item.voice)
            counts[person, default: 0] += 1
            var mine = bySource[person]?[item.source] ?? ([Float](repeating: 0, count: dimensions), 0)
            mine.sum = vDSP.add(mine.sum, item.voice); mine.count += 1
            bySource[person, default: [:]][item.source] = mine
        }
        guard sums.count > 1 else { return input }
        return input.map { item in
            guard let person = item.person else { return item }
            func alike(_ someone: String) -> (score: Float, count: Int) {
                let here = bySource[someone]?[item.source]
                let count = counts[someone]! - (here?.count ?? 0)
                guard count > 0 else { return (-1, 0) }
                let others = here.map { vDSP.subtract(sums[someone]!, $0.sum) } ?? sums[someone]!
                return (dot(item.voice, others) / Float(count), count)
            }
            let own = alike(person)
            let rival = sums.keys.filter { $0 != person }.map(alike)
                .filter { $0.count >= establishedSeeds }.map(\.score).max() ?? -1
            guard rival >= Float(sameVoice), rival > own.score + Float(doubtMargin) else { return item }
            var doubted = item
            doubted.person = nil
            return doubted
        }
    }

    /// One pass, most certain first: labelled items, then the longest speakers.
    private static func microGroups(_ items: [Item], dimensions: Int, threshold: Float) -> [Working] {
        let order = items.indices.sorted { a, b in
            let la = items[a].person != nil || items[a].ignored, lb = items[b].person != nil || items[b].ignored
            if la != lb { return la }
            if items[a].cropCount != items[b].cropCount { return items[a].cropCount > items[b].cropCount }
            return a < b
        }
        var groups: [Working] = []
        for index in order {
            let item = items[index]
            let single = Working(members: [index], sum: item.voice, person: item.person,
                                 ignored: item.ignored, rejected: item.rejected, separations: item.separations, requiresReview: item.requiresReview)
            var best: Float = -.infinity
            var bestGroup = -1
            for k in groups.indices where groups[k].allows(single) {
                let alike = dot(item.voice, groups[k].sum) / Float(groups[k].members.count)
                if alike > best { best = alike; bestGroup = k }
            }
            if best >= threshold { groups[bestGroup].absorb(single) } else { groups.append(single) }
        }
        return groups
    }

    /// Exact average linkage over those groups, by the Lance–Williams update: the pair matrix is
    /// computed once, each merge touches one row of it, and each row remembers its best partner.
    private static func averageLinkage(_ start: [Working], dimensions: Int) -> [Working] {
        var groups = start
        let n = groups.count
        guard n > 1 else { return groups }
        var pairs = [Float](repeating: 0, count: n * n)
        for a in 0..<n {
            for b in (a + 1)..<max(a + 1, n) {
                let alike = dot(groups[a].sum, groups[b].sum) / Float(groups[a].members.count * groups[b].members.count)
                pairs[a * n + b] = alike; pairs[b * n + a] = alike
            }
        }
        var active = [Bool](repeating: true, count: n)
        var bestOf = [Int](repeating: -1, count: n)
        var bestScore = [Float](repeating: -.infinity, count: n)
        func refresh(_ row: Int) {
            var top: Float = -.infinity
            var who = -1
            for other in 0..<n where other != row && active[other] && pairs[row * n + other] > top {
                if groups[row].allows(groups[other]) { top = pairs[row * n + other]; who = other }
            }
            bestOf[row] = who; bestScore[row] = top
        }
        for row in 0..<n { refresh(row) }
        while true {
            var a = -1
            var top = Float(sameVoice)
            for row in 0..<n where active[row] && bestScore[row] >= top && bestOf[row] >= 0 {
                top = bestScore[row]; a = row
            }
            guard a >= 0 else { break }
            let b = bestOf[a]
            let na = Float(groups[a].members.count), nb = Float(groups[b].members.count)
            for c in 0..<n where active[c] && c != a && c != b {
                let alike = (pairs[a * n + c] * na + pairs[b * n + c] * nb) / (na + nb)
                pairs[a * n + c] = alike; pairs[c * n + a] = alike
            }
            groups[a].absorb(groups[b])
            active[b] = false
            refresh(a)
            for c in 0..<n where active[c] && c != a {
                if bestOf[c] == a || bestOf[c] == b { refresh(c) }
                else if pairs[c * n + a] > bestScore[c], groups[c].allows(groups[a]) {
                    bestScore[c] = pairs[c * n + a]; bestOf[c] = a
                }
            }
        }
        return (0..<n).filter { active[$0] }.map { groups[$0] }
    }

    private static func results(_ groups: [Working], items: [Item], dimensions: Int) -> [Group] {
        var people: [String: (sum: [Float], count: Int)] = [:]
        for group in groups {
            guard let person = group.person else { continue }
            var mine = people[person] ?? ([Float](repeating: 0, count: dimensions), 0)
            mine.sum = vDSP.add(mine.sum, group.sum); mine.count += group.members.count
            people[person] = mine
        }
        return groups.map { group in
            let n = Float(group.members.count)
            let similarity = group.members.map { Double(dot(items[$0].voice, group.sum) / n) }
            var suggestion: Suggestion?
            if group.person == nil, !group.ignored, !group.requiresReview {
                var ranked: [(person: String, score: Double)] = []
                for (person, heard) in people where !group.rejected.contains(person) {
                    let alike = dot(group.sum, heard.sum) / (n * Float(heard.count))
                    ranked.append((person, Double(alike)))
                }
                ranked.sort { $0.score == $1.score ? $0.person < $1.person : $0.score > $1.score }
                if let first = ranked.first, first.score >= possibleVoice,
                   ranked.count == 1 || first.score - ranked[1].score >= suggestionMargin {
                    suggestion = Suggestion(person: first.person, score: first.score)
                }
            }
            return Group(members: group.members, similarity: similarity, person: group.person,
                         ignored: group.ignored, suggestion: suggestion)
        }
    }
}
