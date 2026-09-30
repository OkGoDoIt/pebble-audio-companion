import Foundation
import Testing

@testable import AppDB

// `ConversationLexicon` turns a turn's text into what the segmenter reads: hashed content words
// and three flags about the MODE of the talk. Two properties matter more than the rest:
//  - the hashes are the same on every launch and every platform (they ride in memoised evidence
//    that must compare equal across rebuilds, and `Hasher` is seeded per launch), which is why
//    the expected values below are literals and not calls to the function under test;
//  - the flags say what they claim. A turn flagged as dictation or as another language moves
//    where conversations are cut.
//
// The tokeniser works over UTF-8 bytes. What that means for a word, pinned below: ASCII letters
// are lower-cased; any scalar outside ASCII is a letter of the word it is in and is NOT
// case-folded; ASCII punctuation, digits and the General Punctuation block (dashes, curly
// quotes, the ellipsis) separate words — except the apostrophe, straight or curly, inside one.

@Suite struct ConversationLexiconTests {
    private func features(_ text: String, speaker: String? = nil) -> TurnFeatures {
        ConversationLexicon.features(text: text, speaker: speaker)
    }

    // MARK: - the hash

    @Test func fnv1aValuesAreStableLiterals() {
        // The published FNV-1a 32-bit test vectors …
        #expect(ConversationLexicon.fnv1a("") == 2_166_136_261)
        #expect(ConversationLexicon.fnv1a("a") == 3_826_002_220)
        #expect(ConversationLexicon.fnv1a("foobar") == 3_214_735_720)
        // … and words of the kind it is actually fed, over their UTF-8 bytes.
        #expect(ConversationLexicon.fnv1a("hello") == 1_335_831_723)
        #expect(ConversationLexicon.fnv1a("harbour") == 3_894_328_072)
        #expect(ConversationLexicon.fnv1a("chào") == 1_575_109_742)
        #expect(ConversationLexicon.fnv1a("привет") == 2_168_984_447)
    }

    @Test func aTurnsTermsAreThoseLiteralsSoEvidenceComparesEqualAcrossLaunches() {
        let turn = features("The harbour, the anchor — and the harbour again.", speaker: "1")
        #expect(turn.terms == [3_894_328_072, 1_122_880_180, 3_894_328_072])
        #expect(turn.speaker == 873_244_444)
        // Built twice, the features are equal — which is what lets a memoised grouping be
        // compared with a fresh one.
        #expect(turn == features("The harbour, the anchor — and the harbour again.", speaker: "1"))
    }

    // MARK: - tokenisation

    @Test func wordsAreLowercasedSplitOnAnythingThatIsNotALetterAndKeptInOrder() {
        #expect(
            features("Anchor/harbour... ANCHOR\n(harbour)").terms
                == [1_122_880_180, 3_894_328_072, 1_122_880_180, 3_894_328_072])
        // Case never makes a different word.
        #expect(features("HARBOUR").terms == features("harbour").terms)
        // Digits are not letters: they separate words and are never terms themselves.
        #expect(features("2026 harbour7anchor 15").terms == [3_894_328_072, 1_122_880_180])
        #expect(features("").terms.isEmpty)
        #expect(features("  ...  ").terms.isEmpty)
        #expect(features("123 456").terms.isEmpty)
    }

    @Test func stopWordsAndWordsUnderThreeLettersAreLeftOut() {
        // Function words and filler say nothing about what is being talked about.
        #expect(features("yeah so I think it was like really good you know").terms.isEmpty)
        #expect(features("um uh ok okay hmm").terms.isEmpty)
        // Two letters or fewer: out, whatever they are.
        #expect(features("go ox at xy q").terms.isEmpty)
        // Three letters and not a stop word: in.
        #expect(features("jib").terms == [ConversationLexicon.fnv1a("jib")])
        // A content word among them survives alone.
        #expect(features("so the harbour was, like, really good").terms == [3_894_328_072])
        // The list is lowercase and is matched after lowercasing.
        #expect(features("THE And BUT").terms.isEmpty)
    }

    @Test func contractionsStayWholeAndBothApostrophesAreTheSameWord() {
        // "don't" is one word — a stop word — not "don" + "t".
        #expect(features("don't").terms.isEmpty)
        #expect(features("I can't, you won't, they're").terms.isEmpty)
        // The typographic apostrophe a transcriber emits is the same word.
        #expect(features("don\u{2019}t worry") == features("don't worry"))
        #expect(features("don\u{2019}t worry").terms == [1_322_331_238])
        // A contraction that is not a stop word is hashed whole.
        #expect(features("y'all").terms == [1_511_088_912])
        #expect(features("y\u{2019}all").terms == [1_511_088_912])
        #expect(features("rock'n'roll").terms == [3_736_437_097])
        // An apostrophe that opens a word is punctuation, not part of it.
        #expect(features("'harbour").terms == [3_894_328_072])
    }

    @Test func wordsInOtherScriptsAreTermsToo() {
        #expect(features("привет").terms == [2_168_984_447])
        #expect(features("naïve").terms == [2_577_008_683])
        #expect(features("你好吗").terms == [2_784_804_419])
    }

    @Test func aWordNeedsThreeScalarsNotThreeBytes() {
        // "né" is three bytes and two letters; "née" is three letters.
        #expect(features("né").terms.isEmpty)
        #expect(features("née").terms == [2_190_414_904])
        #expect(features("你好").terms.isEmpty)
        // The apostrophe holds a contraction together but is not one of its letters.
        #expect(features("a's").terms.isEmpty)
    }

    @Test func onlyASCIILettersAreCaseFolded() {
        // Folding is done inline on the bytes, so it stops at ASCII: a capital outside it is a
        // different byte sequence and therefore a different word.
        #expect(features("ПРИВЕТ").terms == [556_236_191])
        #expect(features("ПРИВЕТ").terms != features("привет").terms)
        // The ASCII letters of a word are folded even beside ones that are not.
        #expect(features("NAÏVE").terms == [4_230_361_803])  // "naÏve"
        #expect(features("Émile").terms == [3_499_312_172])  // "Émile"
        #expect(features("émile").terms == [1_984_869_836])
    }

    @Test(arguments: [
        "\u{2014}", "\u{2013}", "\u{2026}", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2022}",
        "\u{2009}", "\u{200B}", "\u{2060}", " \u{2014} ", ", ", "/", "-", "_", "7", "\n", "\t",
    ])
    func punctuationDigitsAndGeneralPunctuationSeparateWords(separator: String) {
        #expect(
            features("harbour\(separator)anchor").terms == [3_894_328_072, 1_122_880_180],
            "\(separator.unicodeScalars.map { String($0.value, radix: 16) })")
    }

    @Test func curlyQuotesAroundAWordAreNotPartOfIt() {
        #expect(features("\u{201C}harbour\u{201D}").terms == [3_894_328_072])
        #expect(features("\u{201C}Hello,\u{201D} she said").opensWithGreeting)
        // An opening single quote, straight or curly, is punctuation too.
        #expect(features("\u{2018}harbour").terms == [3_894_328_072])
    }

    /// An apostrophe is part of a word when it is INSIDE one ("don't"). After the last letter it
    /// is a closing quote or a plural possessive, and the word is the same word: `'harbour'` is
    /// "harbour", and a quoted stop word is still a stop word. (The tokeniser used to hash a
    /// trailing apostrophe into the word — "harbour'", "the'"; fixed in 25f14fe.)
    @Test func aClosingQuoteIsNotPartOfTheWord() {
        #expect(features("'harbour'").terms == [3_894_328_072])
        #expect(features("\u{2018}harbour\u{2019}").terms == [3_894_328_072])
        #expect(features("he said 'the'").terms.isEmpty)
        // A plural possessive is the plural.
        #expect(features("the harbours' walls").terms == features("the harbours walls").terms)
        #expect(features("harbour' anchor").terms == [3_894_328_072, 1_122_880_180])
        #expect(features("harbour\u{2019}, anchor").terms == [3_894_328_072, 1_122_880_180])
        // Inside a word it still holds the word together, before a letter of any script.
        #expect(features("y'all").terms == [1_511_088_912])
        #expect(features("l'été").terms == [ConversationLexicon.fnv1a("l'été")])
        // A quoted greeting is still a greeting, and a quoted dictation mark still a mark.
        #expect(features("'Hello' she said").opensWithGreeting)
        #expect(features("he wrote 'comma'").isDictation)
        // Two apostrophes in a row are not a contraction.
        #expect(features("harbour''anchor").terms == [3_894_328_072, 1_122_880_180])
    }

    // MARK: - the speaker

    @Test func theSpeakerIsHashedAndAbsentOrEmptyIsZero() {
        #expect(features("hello", speaker: nil).speaker == 0)
        #expect(features("hello", speaker: "").speaker == 0)
        #expect(features("hello", speaker: "1").speaker == 873_244_444)
        #expect(features("hello", speaker: "A").speaker == 3_289_118_412)
        #expect(features("hello", speaker: "B").speaker == 3_339_451_269)
        // Two labels are two voices; a label is never confused with "no label".
        #expect(features("x", speaker: "A").speaker != features("x", speaker: "B").speaker)
        #expect(features("x", speaker: "0").speaker != 0)
    }

    // MARK: - the three flags

    @Test func foreignMeansMostOfTheLettersAreOutsideASCII() {
        #expect(features("Привет, как дела?").isForeign)
        #expect(features("你好吗").isForeign)
        #expect(features("Tôi đang ở nhà").isForeign)
        #expect(!features("The harbour was busy this morning").isForeign)
        // A borrowed word or a name with an accent does not make a turn foreign …
        #expect(!features("We had a naïve plan for the café").isForeign)
        // … and neither does a turn with no letters in it at all.
        #expect(!features("").isForeign)
        #expect(!features("123 456 !!!").isForeign)
        // The line is 70% ASCII letters: below it is foreign, at or above it is not.
        #expect(features("abcdefж" + "жжж").isForeign)  // 6 of 10
        #expect(!features("abcdefg" + "жжж").isForeign)  // 7 of 10
    }

    @Test(arguments: [
        "Dear Sam comma thanks for the note full stop",
        "is that right question mark",
        "what a day exclamation mark",
        "what a day exclamation point",
        "first item new line second item",
        "and that is all new paragraph",
        "FULL STOP",
    ])
    func spokenPunctuationMarksDictation(text: String) {
        #expect(features(text).isDictation, "\(text)")
    }

    @Test func ordinaryTalkIsNotDictation() {
        #expect(!features("we should stop for lunch and then mark the route").isDictation)
        #expect(!features("the harbour was full").isDictation)
        #expect(!features("").isDictation)
        // "Period" on its own is not spoken punctuation: it is also an ordinary noun ("the
        // trial period", "a period of time"), so it marks nothing, however it is written.
        #expect(!features("See you Monday period").isDictation)
        #expect(!features("hello, PERIOD.").isDictation)
        #expect(!features("the trial period ends on Friday").isDictation)
        // The two-word marks are PAIRS: either word alone, or the two apart, is ordinary talk.
        #expect(!features("the tank is full so we can stop").isDictation)
        #expect(!features("the question he asked was about the mark").isDictation)
        #expect(!features("draw a line under the new idea").isDictation)
        #expect(!features("what an exclamation").isDictation)
        #expect(!features("stop full").isDictation)
        #expect(!features("mark the question").isDictation)
    }

    @Test func dictationIsReadFromWholeWordsWhateverTheirCase() {
        #expect(features("Comma").isDictation)
        #expect(features("hello, FULL STOP.").isDictation)
        #expect(features("Question Mark").isDictation)
        #expect(features("new\nparagraph").isDictation)
        #expect(features("exclamation-point").isDictation)
    }

    /// Spoken punctuation is a WORD the wearer says. A longer word that merely contains one —
    /// "command", "commander", "periodically" — is ordinary talk: somebody describing a shell
    /// command is not dictating a message.
    @Test(arguments: [
        "run the command again and check the output",
        "the commander gave the order",
        "we meet periodically to review it",
        "the periodic table hangs in the classroom",
    ])
    func aWordThatMerelyContainsAMarkerIsNotDictation(text: String) {
        #expect(!features(text).isDictation, "\(text)")
    }

    @Test func greetingIsDetectedOnlyAtTheOpeningOfTheTurn() {
        for text in [
            "Hello", "hello there", "Hi, how are you", "Hey!", "HEY you", "Good morning everyone",
            "good afternoon", "Good evening, all", "Xin chào", "Chào anh", "...hello",
        ] {
            #expect(features(text).opensWithGreeting, "\(text)")
        }
        for text in [
            "", "Oh hi there", "well hello", "Good grief", "Good", "morning", "Say hello to her",
            "The harbour says hi", "Goodbye", "Highway", "heya", "xin",
        ] {
            #expect(!features(text).opensWithGreeting, "\(text)")
        }
    }

    @Test func theGreetingHelperReadsTheFirstTwoWordsOnly() {
        #expect(ConversationLexicon.opensWithGreeting(["hello"]))
        #expect(ConversationLexicon.opensWithGreeting(["good", "morning"]))
        #expect(ConversationLexicon.opensWithGreeting(["hi", "morning"]))
        #expect(!ConversationLexicon.opensWithGreeting([]))
        #expect(!ConversationLexicon.opensWithGreeting(["good"]))
        #expect(!ConversationLexicon.opensWithGreeting(["morning", "good"]))
    }

    @Test func aGreetingWordIsAStopWordSoItIsAFlagAndNeverATerm() {
        let turn = features("Hello harbour")
        #expect(turn.opensWithGreeting)
        #expect(turn.terms == [3_894_328_072])
    }

    // MARK: - the word count beside the features

    @Test func aSpeechSpanBuiltFromTextCarriesTheWordCountAndTheFeatures() {
        let span = SpeechSpan(
            startMs: 1_000, endMs: 4_000, text: "Hello  the harbour\nwas busy comma", speaker: "A")
        // Whitespace-separated words, stop words included: it is how much was said.
        #expect(span.wordCount == 6)
        #expect(span.features == features("Hello  the harbour\nwas busy comma", speaker: "A"))
        #expect(span.features?.opensWithGreeting == true)
        #expect(span.features?.isDictation == true)
        // A span built from timings alone has none, and the two are not equal.
        #expect(SpeechSpan(startMs: 1_000, endMs: 4_000).features == nil)
        #expect(SpeechSpan(startMs: 1_000, endMs: 4_000, wordCount: 6) != span)
        // An end before the start is clamped, never negative-length.
        #expect(SpeechSpan(startMs: 5_000, endMs: 4_000).endMs == 5_000)
    }
}
