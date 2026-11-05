import AppDB
import SwiftUI

/// One colour per person, everywhere they appear, until they have a photo. You are always the
/// app's own colour. Everyone else keeps the colour their id picks, moving to the next free one
/// only when two people would share, so adding someone doesn't repaint the rest.
enum PersonPalette {
    private static let entries: [(fill: UInt32, darkText: UInt32)] = [
        (0x0E7C7B, 0x4CC7C5), (0xB45309, 0xE8A25A), (0xC2356B, 0xF07FA8), (0x2F7D32, 0x7FCB82),
        (0x1F6FB2, 0x6FB3EE), (0x8A3FB8, 0xC48BE8), (0x8A5A2B, 0xD0A273), (0x6F7B12, 0xBCCB5A),
    ]
    /// You. Everyone else counts from 1.
    static let youIndex = 0

    /// Behind an initial, in the coverage bar.
    static func fill(_ index: Int) -> Color {
        guard index != youIndex else { return Tokens.tint }
        let entry = entries[(index - 1) % entries.count]
        return Color(light: entry.fill, dark: entry.fill)
    }

    /// A name written in their colour, on a card.
    static func text(_ index: Int) -> Color {
        guard index != youIndex else { return Tokens.tint }
        let entry = entries[(index - 1) % entries.count]
        return Color(light: entry.fill, dark: entry.darkText)
    }

    /// Everyone's colour. Takes the whole list of people, so nobody shares while a colour is free.
    static func indices(of people: [Person]) -> [String: Int] {
        var taken = Set<Int>()
        var result: [String: Int] = [:]
        for person in people.sorted(by: { $0.id < $1.id }) {
            guard !person.isCurrentUser else { result[person.id] = youIndex; continue }
            var slot = hash(person.id) % entries.count
            for _ in entries.indices where taken.contains(slot) { slot = (slot + 1) % entries.count }
            taken.insert(slot)
            result[person.id] = slot + 1
        }
        return result
    }

    /// FNV-1a: stable across launches, which `hashValue` isn't.
    private static func hash(_ text: String) -> Int {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return Int(value % 1_000_003)
    }
}

/// "12 min", "6 h 20 min", or the shorter "6 h 20" where it's a tile's big number.
enum VoiceDuration {
    static func text(_ ms: Int64, compact: Bool = false) -> String {
        let minutes = Int((Double(ms) / 60_000).rounded())
        guard minutes >= 60 else { return minutes < 1 ? "Under 1 min" : "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        if rest == 0 { return "\(hours) h" }
        return compact ? "\(hours) h \(rest)" : "\(hours) h \(rest) min"
    }
}
