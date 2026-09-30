import Foundation

// What the conversation segmenter reads out of a turn's text, computed ONCE when the speech
// evidence for a segment is built (`SegmentSpeechEvidence`) so a regroup never touches text.
//
// Deliberately small and language-agnostic: the segmenter needs to tell "the same stretch of
// talk" from "a different one", not to understand either. Content words become stable 32-bit
// ids (FNV-1a — `Hasher` is seeded per launch, and these ride in memoised evidence that must
// compare equal across rebuilds); everything else is a handful of flags about the MODE of the
// talk, which on real days turned out to carry more signal than the words do: dictating a
// message, talking with someone, and a bus announcement in another language are three different
// conversations even when the pauses between them are seconds long.

/// The segmenter's view of one turn. Carried by `SpeechSpan`; nil where a caller only has timings.
public struct TurnFeatures: Equatable, Sendable {
    /// Hashed content words, in order. Stop words and words under three letters are left out.
    public var terms: [UInt32]
    /// Hash of the diarization label, 0 when the provider gave none. Labels are per SEGMENT
    /// (speaker "1" in one rotation is not speaker "1" in the next), so this is only ever
    /// compared inside one segment.
    public var speaker: UInt32
    /// Most of the letters are outside ASCII — a different language or script from the wearer's
    /// usual one, which is how announcements, television and a bystander's call usually appear.
    public var isForeign: Bool
    /// Spoken punctuation ("full stop", "comma", "question mark"): the wearer is dictating.
    public var isDictation: Bool
    /// The turn opens with a greeting.
    public var opensWithGreeting: Bool

    public init(
        terms: [UInt32] = [], speaker: UInt32 = 0, isForeign: Bool = false,
        isDictation: Bool = false, opensWithGreeting: Bool = false
    ) {
        self.terms = terms
        self.speaker = speaker
        self.isForeign = isForeign
        self.isDictation = isDictation
        self.opensWithGreeting = opensWithGreeting
    }
}

public enum ConversationLexicon {
    /// Features of one turn.
    ///
    /// Written over the UTF-8 bytes rather than `Character`s or a lowercased copy: this runs
    /// for every turn of the library each time the app starts, and the obvious version (Unicode
    /// properties per scalar, a lowercased `String`, a `String` per word) took 7 µs a turn —
    /// a third of a second for two weeks of talk. ASCII letters are folded to lower case inline;
    /// every other non-ASCII scalar counts as a letter of whatever word it is in, except the
    /// General Punctuation block (dashes, curly quotes, ellipses), which separates words like
    /// its ASCII cousins — and the curly apostrophe, which does what the straight one does.
    public static func features(text: String, speaker: String?) -> TurnFeatures {
        var terms: [UInt32] = []
        var asciiLetters = 0
        var letters = 0
        var firstWords: [String] = []
        var isDictation = false

        var hash: UInt32 = fnvOffset
        var scalars = 0
        var previousWord: UInt32 = 0
        var wordBytes: [UInt8] = []

        func endWord() {
            guard scalars > 0 else { return }
            let word = hash
            if firstWords.count < 2 { firstWords.append(String(decoding: wordBytes, as: UTF8.self)) }
            if word == Hashed.comma || word == Hashed.period
                || (previousWord == Hashed.full && word == Hashed.stop)
                || (previousWord == Hashed.question && word == Hashed.mark)
                || (previousWord == Hashed.exclamation
                    && (word == Hashed.mark || word == Hashed.point))
                || (previousWord == Hashed.new
                    && (word == Hashed.line || word == Hashed.paragraph))
            {
                isDictation = true
            }
            if scalars >= 3, !stopWordHashes.contains(word) { terms.append(word) }
            previousWord = word
            hash = fnvOffset
            scalars = 0
            wordBytes.removeAll(keepingCapacity: true)
        }
        func add(_ byte: UInt8) {
            hash = (hash ^ UInt32(byte)) &* fnvPrime
            if firstWords.count < 2 { wordBytes.append(byte) }
        }

        var bytes = text.utf8.makeIterator()
        while let byte = bytes.next() {
            if byte < 0x80 {
                let lower = byte | 0x20
                if lower >= 0x61, lower <= 0x7A {
                    letters += 1
                    asciiLetters += 1
                    scalars += 1
                    add(lower)
                } else if byte == 0x27, scalars > 0 {
                    // Keep contractions whole ("don't"), as one word.
                    add(byte)
                } else {
                    endWord()
                }
                continue
            }
            // A multi-byte scalar. General Punctuation is E2 80 xx / E2 81 xx.
            if byte == 0xE2, let second = bytes.next() {
                if second == 0x80 || second == 0x81 {
                    let third = bytes.next() ?? 0
                    if second == 0x80, third == 0x99, scalars > 0 {
                        add(0x27)  // the curly apostrophe
                    } else {
                        endWord()
                    }
                    continue
                }
                letters += 1
                scalars += 1
                add(byte)
                add(second)
                continue
            }
            if byte & 0xC0 != 0x80 {
                // The lead byte of a scalar outside ASCII.
                letters += 1
                scalars += 1
            }
            add(byte)
        }
        endWord()

        let isForeign = letters > 0 && Double(asciiLetters) / Double(letters) < 0.7
        return TurnFeatures(
            terms: terms,
            speaker: speaker.map { $0.isEmpty ? 0 : max(fnv1a($0), 1) } ?? 0,
            isForeign: isForeign,
            isDictation: isDictation,
            opensWithGreeting: opensWithGreeting(firstWords))
    }

    static func opensWithGreeting(_ firstWords: [String]) -> Bool {
        guard let first = firstWords.first else { return false }
        if greetings.contains(first) { return true }
        guard firstWords.count > 1 else { return false }
        return greetingPairs.contains("\(first) \(firstWords[1])")
    }

    static let fnvOffset: UInt32 = 2_166_136_261
    static let fnvPrime: UInt32 = 16_777_619

    /// FNV-1a over the UTF-8 bytes: stable across launches and platforms.
    static func fnv1a(_ text: String) -> UInt32 {
        var hash = fnvOffset
        for byte in text.utf8 {
            hash = (hash ^ UInt32(byte)) &* fnvPrime
        }
        return hash
    }

    /// The words spoken punctuation is made of.
    enum Hashed {
        static let comma = fnv1a("comma")
        static let period = fnv1a("period")
        static let full = fnv1a("full")
        static let stop = fnv1a("stop")
        static let question = fnv1a("question")
        static let exclamation = fnv1a("exclamation")
        static let mark = fnv1a("mark")
        static let point = fnv1a("point")
        static let new = fnv1a("new")
        static let line = fnv1a("line")
        static let paragraph = fnv1a("paragraph")
    }

    static let greetings: Set<String> = ["hello", "hi", "hey", "chào"]
    static let greetingPairs: Set<String> = [
        "good morning", "good afternoon", "good evening", "xin chào",
    ]

    /// Function words and conversational filler. A word here says nothing about WHAT is being
    /// talked about, and leaving it in would make every stretch of talk look like every other.
    static let stopWords: Set<String> = Set(
        """
        a about above after again against all am an and any are aren't as at be because been \
        before being below between both but by can can't cannot could couldn't did didn't do \
        does doesn't doing don't down during each few for from further had hadn't has hasn't \
        have haven't having he he'd he'll he's her here here's hers herself him himself his how \
        how's i i'd i'll i'm i've if in into is isn't it it's its itself let's me more most \
        mustn't my myself no nor not of off on once only or other ought our ours ourselves out \
        over own same shan't she she'd she'll she's should shouldn't so some such than that \
        that's the their theirs them themselves then there there's these they they'd they'll \
        they're they've this those through to too under until up very was wasn't we we'd we'll \
        we're we've were weren't what what's when when's where where's which while who who's \
        whom why why's with won't would wouldn't you you'd you'll you're you've your yours \
        yourself yourselves yeah yes yep ok okay um uh uhm hmm mm mhm oh ah like just know \
        think really well right got get gonna going go one kind sort thing things something \
        actually basically mean maybe also much lot little bit good great sure thanks thank \
        please sorry hey hi hello bye see say said want need look make take come back now \
        still even way time full stop comma period question mark
        """.split(separator: " ").map(String.init))

    static let stopWordHashes: Set<UInt32> = Set(stopWords.map(fnv1a))
}
