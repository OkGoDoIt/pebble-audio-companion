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
    public static func features(text: String, speaker: String?) -> TurnFeatures {
        let lowered = text.lowercased()
        var terms: [UInt32] = []
        var asciiLetters = 0
        var letters = 0
        var word = String.UnicodeScalarView()
        var firstWords: [String] = []

        func flush() {
            guard !word.isEmpty else { return }
            let text = String(word)
            word.removeAll(keepingCapacity: true)
            if firstWords.count < 2 { firstWords.append(text) }
            guard text.unicodeScalars.count >= 3, !stopWords.contains(text) else { return }
            terms.append(fnv1a(text))
        }
        for scalar in lowered.unicodeScalars {
            if scalar.properties.isAlphabetic {
                letters += 1
                if scalar.isASCII { asciiLetters += 1 }
                word.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}", !word.isEmpty {
                // Keep contractions whole ("don't"), as one word.
                word.append("'")
            } else {
                flush()
            }
        }
        flush()

        let isForeign = letters > 0 && Double(asciiLetters) / Double(letters) < 0.7
        return TurnFeatures(
            terms: terms,
            speaker: speaker.map { $0.isEmpty ? 0 : max(fnv1a($0), 1) } ?? 0,
            isForeign: isForeign,
            isDictation: dictationMarkers.contains { lowered.contains($0) },
            opensWithGreeting: opensWithGreeting(firstWords))
    }

    static func opensWithGreeting(_ firstWords: [String]) -> Bool {
        guard let first = firstWords.first else { return false }
        if greetings.contains(first) { return true }
        guard firstWords.count > 1 else { return false }
        return greetingPairs.contains("\(first) \(firstWords[1])")
    }

    /// FNV-1a over the UTF-8 bytes: stable across launches and platforms.
    static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    static let greetings: Set<String> = ["hello", "hi", "hey", "chào"]
    static let greetingPairs: Set<String> = [
        "good morning", "good afternoon", "good evening", "xin chào",
    ]

    static let dictationMarkers: [String] = [
        "full stop", "comma", "question mark", "exclamation mark", "exclamation point",
        "new line", "new paragraph", "period",
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
}
