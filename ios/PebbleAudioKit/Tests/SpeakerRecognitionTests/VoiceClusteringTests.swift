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
