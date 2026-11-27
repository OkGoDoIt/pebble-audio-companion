import Foundation
import Testing
@testable import SpeakerRecognition

@Suite struct VoiceClusteringTests {
    struct Noise: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }
    /// A pooled speaker in a recording: a person's voice, plus the recording's own noise. At 0.8
    /// two speakers of one person score about 0.65; two people, close to zero.
    static func voice(_ axis: Int, _ noise: inout Noise, signal: Float = 0.8) -> [Float] {
        let random = (0..<128).map { _ in Float.random(in: -1...1, using: &noise) }
        let norm = random.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let mixed = (0..<128).map { (($0 == axis) ? signal : 0) + (1 - signal) * 1.6 * random[$0] / norm }
        let length = mixed.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return mixed.map { $0 / length }
    }
    func item(_ axis: Int, _ source: Int, _ noise: inout Noise, person: String? = nil, rejected: Set<String> = [],
              ignored: Bool = false, signal: Float = 0.8) -> VoiceClustering.Item {
        VoiceClustering.Item(source: "r\(source)", voice: Self.voice(axis, &noise, signal: signal), cropCount: 10,
                             person: person, rejected: rejected, ignored: ignored)
    }

    @Test func eachVoiceBecomesOneGroupAcrossRecordings() {
        var noise = Noise(state: 11)
        var items = (0..<30).map { item(0, $0, &noise) }
        items += (0..<12).map { item(1, $0, &noise) }
        items += (0..<5).map { item(2, $0, &noise) }
        let groups = VoiceClustering.cluster(items).sorted { $0.members.count > $1.members.count }
        #expect(groups.map(\.members.count) == [30, 12, 5])
        for group in groups {
            #expect(Set(group.members.map { items[$0].voice.firstIndex(of: items[$0].voice.max()!)! }).count == 1)
        }
    }

    /// The Photos behaviour: one label names everything in the group.
    @Test func oneLabelNamesTheWholeGroup() {
        var noise = Noise(state: 3)
        var items = (0..<20).map { item(0, $0, &noise) }
        items[7].person = "dana"
        items += (0..<9).map { item(1, 100 + $0, &noise) }
        let groups = VoiceClustering.cluster(items)
        #expect(groups.first { $0.person == "dana" }?.members.count == 20)
        #expect(groups.first { $0.person == nil }?.members.count == 9)
    }

    /// One person, two labelled names: however alike, they never merge.
    @Test func twoPeopleNeverShareAGroup() {
        var noise = Noise(state: 5)
        var items = (0..<6).map { item(0, $0, &noise, person: "dana") }
        items += (0..<6).map { item(0, 50 + $0, &noise, person: "sam") }
        let groups = VoiceClustering.cluster(items)
        #expect(groups.allSatisfy { group in Set(group.members.map { items[$0].person }).count == 1 })
    }

    /// "That's not Dana" holds even when the voice sounds just like her.
    @Test func aRejectedSpeakerStaysOutOfThatPersonsGroup() {
        var noise = Noise(state: 7)
        var items = (0..<10).map { item(0, $0, &noise) }
        items[0].person = "dana"
        items.append(item(0, 99, &noise, rejected: ["dana"]))
        let groups = VoiceClustering.cluster(items)
        let dana = groups.first { $0.person == "dana" }!
        #expect(!dana.members.contains(10))
        #expect(dana.members.count == 10)
    }

    @Test func aVoiceYouStoppedAskingAboutStaysQuietAsItGrows() {
        var noise = Noise(state: 9)
        var items = (0..<8).map { item(3, $0, &noise) }
        items[0].ignored = true
        let groups = VoiceClustering.cluster(items)
        #expect(groups.count == 1)
        #expect(groups[0].ignored && groups[0].suggestion == nil)
    }

    /// A group close to a person but not close enough earns a question, not a name.
    @Test func aNearbyGroupIsSuggestedNotNamed() {
        var noise = Noise(state: 13)
        var items = (0..<10).map { item(0, $0, &noise, person: "dana") }
        // The same person, heard through something that blurs half of it into another voice.
        items += (0..<6).map { index -> VoiceClustering.Item in
            let a = Self.voice(0, &noise), b = Self.voice(4, &noise)
            let blend = zip(a, b).map { 0.50 * $0 + 0.87 * $1 }
            let length = blend.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return VoiceClustering.Item(source: "b\(index)", voice: blend.map { $0 / length }, cropCount: 10)
        }
        let groups = VoiceClustering.cluster(items)
        let other = groups.first { $0.person == nil }!
        #expect(other.members.allSatisfy { $0 >= 10 })
        #expect(other.suggestion?.person == "dana")
        #expect((other.suggestion?.score ?? 0) >= VoiceClustering.possibleVoice)
        #expect((other.suggestion?.score ?? 1) < VoiceClustering.sameVoice)
    }

    /// One slip on one speaker can't turn an established voice into someone else.
    @Test func aLabelThatSoundsLikeSomeoneElsesEstablishedVoiceIsNotBelieved() {
        var noise = Noise(state: 17)
        var items = (0..<8).map { item(0, $0, &noise, person: "you") }
        items.append(item(0, 50, &noise, person: "oliver"))
        items += (0..<20).map { item(0, 100 + $0, &noise) }
        let groups = VoiceClustering.cluster(items)
        #expect(groups.first { $0.person == "oliver" } == nil)
        #expect(groups.first { $0.person == "you" }?.members.count == 29)
    }

    /// Phone scale: thousands of speakers in a few seconds at most.
    @Test func thousandsOfSpeakersClusterQuickly() {
        var noise = Noise(state: 19)
        let items = (0..<3_000).map { item($0 % 40, $0, &noise) }
        let started = Date()
        let groups = VoiceClustering.cluster(items)
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(groups.count == 40)
    }
}

extension VoiceClusteringTests {
    @Test func savedSeparationsSurviveMicroClusteringAndAnUnmarkedBridge() {
        var noise = Noise(state: 43)
        var items = (0..<7).map { item(0, $0, &noise) }
        items[0].separations = ["split":"left"]
        items[1].separations = ["split":"right"]
        let groups = VoiceClustering.cluster(items)
        #expect(!groups.contains { $0.members.contains(0) && $0.members.contains(1) })
        // Until reviewed, no outsider can quietly supply a name to either child.
        items[0].requiresReview = true
        items[1].requiresReview = true
        items[2].person = "dana"
        let reviewed = VoiceClustering.cluster(items)
        #expect(reviewed.first { $0.members.contains(0) }?.person == nil)
        #expect(reviewed.first { $0.members.contains(1) }?.person == nil)
    }

    @Test func subdivisionRejectsWeakPairsAndKeepsUnreadableSamples() throws {
        let a: [Float] = [1,0], b: [Float] = [0.8,0.6], c: [Float] = [0.28,0.96]
        let vectors: [[Float]?] = [a,b,c,nil]
        let groups = try VoiceSubdivision.split(vectors)
        #expect(groups.flatMap { $0 }.sorted() == [0,1,2,3])
        #expect(!groups.contains { $0.contains(0) && $0.contains(2) })
        #expect(groups.contains([3]))
        #expect(try VoiceSubdivision.split([a,a,a]).count == 3, "Explicit repeated splitting reaches individual prints")
    }
}

/// Sorting the archive again for a new speaker must not move speakers it says nothing about. On the
/// phone (2026-11-25..27), with no answers given, each re-sort moved hundreds of old speakers in and
/// out of groups, most of them back and forth, and each move rewrote names and re-sent transcripts.
extension VoiceClusteringTests {
    /// Voices as rooms make them: a component every voice shares, the person, the room's
    /// colouring and noise, so one person across rooms and two people in one room both land near
    /// the line between "same voice" and not. Most speech is the wearer's.
    struct Archive {
        var noise: Noise
        let common: [Float], people: [[Float]], rooms: [[Float]]
        var items: [VoiceClustering.Item] = []
        static func unit(_ noise: inout Noise) -> [Float] {
            let v = (0..<64).map { _ in Float.random(in: -1...1, using: &noise) }
            let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return v.map { $0 / n }
        }
        init(seed: UInt64) {
            var noise = Noise(state: seed)
            common = Self.unit(&noise)
            people = (0..<40).map { _ in Self.unit(&noise) }
            rooms = (0..<400).map { _ in Self.unit(&noise) }
            self.noise = noise
        }
        mutating func add(_ count: Int) {
            for _ in 0..<count {
                let i = items.count, r = Int(noise.next() % 100)
                let person = r < 55 ? 0 : r < 80 ? 1 + r % 5 : 6 + Int(noise.next() % 34)
                let room = Int(noise.next() % UInt64(rooms.count))
                let n = Self.unit(&noise)
                var v = (0..<64).map { 0.6 * common[$0] + people[person][$0] + 0.7 * rooms[room][$0] + 0.9 * n[$0] }
                let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot(); v = v.map { $0 / length }
                var item = VoiceClustering.Item(source: "r\(room)", voice: v, cropCount: 3 + Int(noise.next() % 40))
                if person == 0 && i % 30 == 0 { item.person = "you" }
                if person == 1 && i % 20 == 1 { item.person = "dana" }
                if person == 2 && i % 20 == 2 { item.person = "sam" }
                items.append(item)
            }
        }
        /// What the store keeps of a sort: each speaker's group and that group's suggestion.
        mutating func remember(_ groups: [VoiceClustering.Group]) {
            for group in groups {
                let id = Int64(group.members.min()!)
                for member in group.members {
                    items[member].previousGroup = id
                    items[member].previousSuggestion = group.suggestion?.person
                }
            }
        }
    }
    static func named(_ groups: [VoiceClustering.Group], count: Int) -> [String] {
        var out = [String](repeating: "", count: count)
        for group in groups { for member in group.members where member < count {
            out[member] = "\(group.person ?? "-")/\(group.suggestion?.person ?? "-")"
        } }
        return out
    }
    static func together(_ groups: [VoiceClustering.Group], count: Int) -> [Int] {
        var out = [Int](repeating: -1, count: count)
        for (index, group) in groups.enumerated() { for member in group.members where member < count { out[member] = index } }
        return out
    }

    @Test func newSpeakersMoveNoOldSpeakerBackAndForth() {
        func run(remembering: Bool) -> (moved: Int, back: Int, split: Int, unnamed: Int) {
            var archive = Archive(seed: 101)
            archive.add(500)
            var groups = VoiceClustering.cluster(archive.items)
            var earlier: [String]?
            var moved = 0, back = 0, split = 0, unnamed = 0
            for _ in 0..<8 {
                let count = archive.items.count
                let before = Self.named(groups, count: count), mates = Self.together(groups, count: count)
                if remembering { archive.remember(groups) }
                archive.add(3)
                groups = VoiceClustering.cluster(archive.items)
                let after = Self.named(groups, count: count), now = Self.together(groups, count: count)
                moved += zip(before, after).filter { $0 != $1 }.count
                if let earlier { back += (0..<count).filter { before[$0] != after[$0] && earlier[$0] == after[$0] }.count }
                unnamed += (0..<count).filter { !before[$0].hasPrefix("-/") && after[$0].hasPrefix("-/") }.count
                var byGroup: [Int: Set<Int>] = [:]
                for member in 0..<count { byGroup[mates[member], default: []].insert(now[member]) }
                split += byGroup.values.filter { $0.count > 1 }.count
                earlier = before
            }
            return (moved, back, split, unnamed)
        }
        let afresh = run(remembering: false)
        #expect(afresh.moved > 20 && afresh.split > 0, "Sorting from scratch moves old speakers between groups")
        let kept = run(remembering: true)
        #expect(kept.back == 0, "No speaker goes back to where it was")
        #expect(kept.split == 0, "Speakers sorted together stay together")
        #expect(kept.unnamed == 0, "A named speaker keeps its name")
        #expect(kept.moved * 10 < afresh.moved)
    }

    /// Kept groups still answer to what a person says.
    @Test func aKeptGroupStillHonoursAnAnswer() {
        var noise = Noise(state: 61)
        var items = (0..<10).map { item(0, $0, &noise) }
        items[0].person = "dana"
        for index in items.indices { items[index].previousGroup = 1 }
        items[5].rejected = ["dana"]
        let groups = VoiceClustering.cluster(items)
        let dana = groups.first { $0.person == "dana" }!
        #expect(dana.members.count == 9 && !dana.members.contains(5))
        // Two names in one kept group part it.
        items[5].rejected = []; items[5].person = "sam"
        let parted = VoiceClustering.cluster(items)
        #expect(parted.first { $0.person == "sam" }?.members == [5])
    }

    /// Two kept groups of one voice still join, and a new speaker of that voice joins them.
    @Test func keptGroupsStillJoinWhenTheySoundAlike() {
        var noise = Noise(state: 67)
        var items = (0..<12).map { item(0, $0, &noise) }
        for index in items.indices { items[index].previousGroup = index < 6 ? 1 : 2 }
        items.append(item(0, 99, &noise))
        let groups = VoiceClustering.cluster(items)
        #expect(groups.count == 1 && groups[0].members.count == 13)
    }

    /// A question already asked isn't withdrawn on a margin that only just moved.
    @Test func anAskedQuestionStaysWhileItStillHolds() {
        var noise = Noise(state: 71)
        var items = (0..<8).map { item(0, $0, &noise, person: "dana") }
        items += (0..<8).map { item(1, 20 + $0, &noise, person: "sam") }
        // Between the two, a shade closer to Dana: too close to call for a new question.
        let blends = (0..<5).map { index -> VoiceClustering.Item in
            let a = Self.voice(0, &noise), b = Self.voice(1, &noise), c = Self.voice(5, &noise)
            let blend = (0..<a.count).map { 0.52 * a[$0] + 0.50 * b[$0] + 0.55 * c[$0] }
            let length = blend.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return VoiceClustering.Item(source: "b\(index)", voice: blend.map { $0 / length }, cropCount: 10)
        }
        items += blends
        let fresh = VoiceClustering.cluster(items).first { $0.person == nil }
        #expect(fresh?.suggestion == nil, "Too close to call: no question")
        for index in 16..<items.count { items[index].previousGroup = 16; items[index].previousSuggestion = "sam" }
        let asked = VoiceClustering.cluster(items).first { $0.person == nil }
        #expect(asked?.suggestion?.person == "sam", "Already asked, still about as likely: still asked")
        // Not when it stops being likely.
        for index in 0..<8 { items[index].person = nil }
        for index in 8..<16 { items[index].person = "oliver" }
        let gone = VoiceClustering.cluster(items).first { $0.members.contains(16) }
        #expect(gone?.suggestion?.person != "sam")
    }
}
