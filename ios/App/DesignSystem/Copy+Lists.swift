import Foundation

// Lists the code assembles out of names ("ChatGPT, Claude, and Codex on Mac"), and small counts
// written as words ("three places"). One helper, so every list in the app carries the Oxford
// comma and no screen builds its own.

extension Copy {
    /// "A", "A and B", "A, B, and C". `conjunction` is "and" or "or". Duplicates are kept: a
    /// caller that means one name once removes them first (`uniqueNames`).
    static func list(_ items: [String], conjunction: String = "and") -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) \(conjunction) \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", \(conjunction) " + items[items.count - 1]
        }
    }

    /// The names in order, each once.
    static func uniqueNames(_ names: [String]) -> [String] {
        names.reduce(into: [String]()) { list, name in
            if !list.contains(name) { list.append(name) }
        }
    }

    /// "two" … "nine", then digits. One is "one".
    static func countWord(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return (0..<words.count).contains(n) ? words[n] : "\(n)"
    }

    /// "1 conversation", "412 conversations".
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}
