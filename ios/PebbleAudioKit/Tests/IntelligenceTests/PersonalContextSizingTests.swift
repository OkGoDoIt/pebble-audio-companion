import Foundation
import Testing

@testable import Intelligence

// Stream PC: what of a person's stored context actually belongs in a prompt.
//
// These use realistic sizes on purpose. Every defect this work found only appears at scale —
// a 3,507-character bio and 3,082 imported contacts — and disappears entirely in a fixture
// with two people and one sentence, which is exactly why it shipped.

private enum Fixture {
    /// A bio the size of the one that motivated this work: ~500 words, sectioned with
    /// headings, names scattered through it rather than concentrated at the front.
    static let longProfile: String = {
        var sections: [String] = []
        sections.append("Speaking style")
        sections.append(
            "I dictate a lot and I speak punctuation out loud, so \"full stop\" in a "
                + "transcript usually means I said a period. Read past that.")
        sections.append("Overview")
        sections.append(
            String(
                repeating:
                    "I am a software engineer who travels and works on personal projects. ",
                count: 12))
        sections.append("Career")
        sections.append(
            String(repeating: "I have worked in this industry for a long time. ", count: 12))
        sections.append("Family")
        sections.append(
            "My neighbor is Lily Carter and my friend is Frank Carter. I work most "
                + "often with Daniel Reyes at Northwind.")
        return sections.joined(separator: "\n\n")
    }()

    /// 3,000 contacts in Contacts-export order — i.e. no order at all — including the junk a
    /// real address book carries and the handful of people who matter, buried deep.
    private static let givenNames = [
        "Aiden", "Bella", "Caleb", "Dahlia", "Ethan", "Freya", "Gideon", "Hana", "Ivan",
        "Juno", "Kiera", "Linus", "Mira", "Noor", "Otto", "Pilar", "Quinn", "Rosa", "Silas",
        "Tomas", "Ursula", "Viktor", "Wren", "Xavier", "Yara", "Zane",
    ]
    private static let surnames = [
        "Abara", "Beaumont", "Castellan", "Delacroix", "Espinosa", "Fairbanks", "Grigoryan",
        "Halvorsen", "Ibarra", "Jankowski", "Kowalczyk", "Lindqvist", "Mbeki", "Nakamura",
        "Okonkwo", "Pryce", "Quiroga", "Rasmussen", "Steinberg", "Toussaint",
    ]

    static func manyPeople(count: Int = 3_000) -> [KnownPerson] {
        var people: [KnownPerson] = []
        for index in 0..<count {
            switch index % 40 {
            case 7:
                people.append(
                    KnownPerson(
                        id: "p\(index)", name: "(555) 01\(index % 10)-\(1000 + index)"))
            case 13:
                people.append(KnownPerson(id: "p\(index)", name: "handle_\(index)99"))
            case 21:
                people.append(KnownPerson(id: "p\(index)", name: "Nick 🔥"))
            default:
                // Real contacts, in an order that carries no information whatsoever — the
                // uniqueness comes from combining the two lists, not from a digit suffix,
                // because a digit is itself a junk signal.
                let given = givenNames[index % givenNames.count]
                let surname = surnames[(index / givenNames.count) % surnames.count]
                let extra = surnames[(index / (givenNames.count * surnames.count)) % surnames.count]
                people.append(
                    KnownPerson(
                        id: "p\(index)",
                        name: "\(given) \(surname)\(index > 500 ? "-" + extra : "")",
                        aliases: [given],
                        organization: index % 3 == 0 ? "Company \(surname)" : nil))
            }
        }
        // The people the bio actually names, deliberately far past any prefix() a naive
        // formatter would take.
        let buried = [
            (900, KnownPerson(id: "lily", name: "Lily Carter", aliases: ["Lily"])),
            (1_700, KnownPerson(id: "frank", name: "Frank Carter", aliases: ["Frank"])),
            (
                2_400,
                KnownPerson(
                    id: "daniel", name: "Daniel Reyes", aliases: ["Daniel"],
                    organization: "Northwind")
            ),
        ]
        for (index, person) in buried {
            people.insert(person, at: min(index, people.count))
        }
        return people
    }

    /// The calendar importer writes event titles into `orgs`; this is what that looks like.
    static let junkOrgs = [
        "Sam Turner’s Birthday", "BOOKED - Garden Party", "Delta DL1234 — BOS to SEA",
        "Trivia night", "Mia OOO",
    ]

    static func realistic() -> PersonalContext {
        PersonalContext(
            profileText: longProfile,
            derivedTerms: ["Northwind", "Lily Carter", "Frank Carter", "Daniel Reyes"],
            people: manyPeople(),
            orgs: junkOrgs + ["Northwind"]
        )
    }
}

@Suite struct PersonalContextRankingTests {
    @Test func bioMentionOutranksImportOrder() {
        let ranked = PersonalContextSelection.rank(Fixture.realistic())
        let top = ranked.people.prefix(10).map(\.name)
        #expect(top.contains("Lily Carter"))
        #expect(top.contains("Frank Carter"))
        #expect(top.contains("Daniel Reyes"))
        // The point of the exercise: import order put all three past index 900, and the old
        // formatter's `people.prefix(50)` therefore shipped none of them.
        #expect(!top.contains("Contact0 Surname0"))
    }

    @Test func junkContactsAreNotTreatedAsNames() {
        let ranked = PersonalContextSelection.rank(Fixture.realistic())
        let names = Set(ranked.people.map(\.name))
        #expect(!names.contains(where: { $0.contains("(555)") }))
        #expect(!names.contains(where: { $0.hasPrefix("handle_") }))
        #expect(!names.contains("Nick 🔥"))
        // …and the same junk must not reach a cloud provider as a bias term either.
        let terms = Set(PersonalContextFormatting.transcriptionTerms(Fixture.realistic()))
        #expect(!terms.contains(where: { $0.contains("(555)") }))
        #expect(!terms.contains(where: { $0.contains("🔥") }))
    }

    @Test func uncorroboratedCalendarTitlesAreNotOrganizations() {
        let ranked = PersonalContextSelection.rank(Fixture.realistic())
        #expect(!ranked.orgs.contains("Trivia night"))
        #expect(!ranked.orgs.contains("Mia OOO"))
        #expect(!ranked.orgs.contains("BOOKED - Garden Party"))
        // "Northwind" is in the bio and in the derived terms, so it survives.
        #expect(ranked.orgs.contains("Northwind"))
    }

    @Test func lowercaseProseDoesNotPromoteACommonWordContact() {
        // A contact card called "Home" must not outrank a person because the bio says "home".
        let context = PersonalContext(
            profileText: "I work from home most days and travel with my neighbor Lily Carter.",
            people: [
                KnownPerson(id: "1", name: "Home"),
                KnownPerson(id: "2", name: "Lily Carter"),
            ])
        let ranked = PersonalContextSelection.rank(context)
        #expect(ranked.people.first?.name == "Lily Carter")
    }

    @Test func firstNameFragmentsDoNotOccupyASlot() {
        let context = PersonalContext(
            profileText: "I work with Owen Hughes every week.",
            people: [
                KnownPerson(id: "1", name: "Owen Hughes"),
                KnownPerson(id: "2", name: "Hughes"),
            ])
        let ranked = PersonalContextSelection.rank(context)
        #expect(ranked.people.map(\.name) == ["Owen Hughes"])
    }

    @Test func rankingIsDeterministic() {
        let context = Fixture.realistic()
        let first = PersonalContextSelection.rank(context).people.prefix(40).map(\.id)
        let second = PersonalContextSelection.rank(context).people.prefix(40).map(\.id)
        // Swift's sort is not stable; the import index is part of the sort key so that a
        // relaunch does not reshuffle equal-scoring contacts and churn the prompt.
        #expect(first == second)
    }
}

@Suite struct PersonalContextBudgetTests {
    /// The documented figure, so a future edit has to argue with the citation rather than
    /// quietly raise a number. https://developers.openai.com/api/docs/guides/speech-to-text
    @Test func openAiPromptStaysUnderTheDocumented224Tokens() {
        let prompt = PersonalContextFormatting.openAiSttPrompt(Fixture.realistic())
        let terms = try! #require(prompt).components(separatedBy: ", ")
        let estimate = PersonalContextBudget.estimatedTokens(forTerms: terms)
        #expect(estimate <= PersonalContextBudget.openAiSttPromptTokenBudget)
        #expect(estimate < PersonalContextBudget.openAiSttPromptMaxTokens)
    }

    @Test func openAiPromptStaysUnderBudgetWithExpensiveNonLatinNames() {
        // Non-Latin names cost up to ~2 tokens per character; a character budget cannot see
        // that, which is why this one is measured in tokens.
        let suffixes = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        let people = (0..<400).map {
            KnownPerson(id: "\($0)", name: "菜蔡陳林黃張李王吳劉" + suffixes[$0 % 10])
        }
        let context = PersonalContext(profileText: "Notes.", people: people)
        let prompt = PersonalContextFormatting.openAiSttPrompt(context)
        let terms = try! #require(prompt).components(separatedBy: ", ")
        #expect(
            PersonalContextBudget.estimatedTokens(forTerms: terms)
                <= PersonalContextBudget.openAiSttPromptTokenBudget)
    }

    /// OpenAI keeps only the FINAL 224 tokens of a prompt, so the list is emitted
    /// least-important-first. https://cookbook.openai.com/examples/whisper_prompting_guide
    @Test func mostImportantTermsAreLastBecauseTheApiTruncatesTheFront() {
        let context = PersonalContext(
            profileText: "Working on Pebble with Sarah Chen.",
            derivedTerms: ["Pebble"],
            people: [KnownPerson(id: "1", name: "Sarah Chen")],
            orgs: ["Pebble"],
            terms: [VocabTerm(text: "Speex")]
        )
        let prompt = try! #require(PersonalContextFormatting.openAiSttPrompt(context))
        let terms = prompt.components(separatedBy: ", ")
        #expect(terms.last == "Speex")  // hand-typed vocabulary is the most deliberate signal
        #expect(terms.firstIndex(of: "Sarah Chen")! < terms.firstIndex(of: "Speex")!)
    }

    @Test func openAiPromptNeverEndsInAHalfWrittenName() {
        for budget in [8, 16, 32, 64, 180] {
            let prompt = PersonalContextFormatting.openAiSttPrompt(
                Fixture.realistic(), tokenBudget: budget)
            guard let prompt, !prompt.isEmpty else { continue }
            let allTerms = Set(PersonalContextSelection.rank(Fixture.realistic()).terms)
            for term in prompt.components(separatedBy: ", ") {
                #expect(allTerms.contains(term), "\(term) is not a whole stored term")
            }
        }
    }

    /// Soniox rejects the request above 10,000 characters rather than trimming.
    /// https://soniox.com/docs/stt/concepts/context
    @Test func sonioxContextStaysUnderTheHardLimit() {
        var context = Fixture.realistic()
        context.profileText = String(repeating: "Detail about my life. ", count: 3_000)
        let text = try! #require(PersonalContextFormatting.transcriptionText(context))
        #expect(text.count <= PersonalContextBudget.sonioxContextBudgetChars)
        #expect(text.count < PersonalContextBudget.sonioxContextHardLimitChars)
    }

    /// https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings
    @Test func appleContextualStringsRespectPhraseAndWordLimits() {
        let phrases = PersonalContextFormatting.appleContextualStrings(Fixture.realistic())
        #expect(phrases.count <= PersonalContextBudget.appleContextualStringsMaxPhrases)
        #expect(!phrases.isEmpty)
        for phrase in phrases {
            #expect(
                phrase.split(separator: " ").count
                    <= PersonalContextBudget.appleContextualStringMaxWords)
        }
        // Most important first here — Apple's list has no documented truncation behaviour, so
        // the ordering that matters is "if the recognizer weights early entries, weight ours".
        #expect(phrases.first == "Daniel Reyes" || phrases.first == "Lily Carter")
    }
}

@Suite struct PersonalContextGroundingTests {
    /// The regression this whole stream exists for: with a real bio the profile text consumed
    /// the entire 2,000-character block, so "Known people" — the only part of About You
    /// measured to change an answer — never reached a single prompt.
    @Test func longBioStillLeavesRoomForKnownPeople() {
        let block = try! #require(
            PersonalContextFormatting.aiGroundingBlock(Fixture.realistic()))
        #expect(block.contains("Known people:"))
        #expect(block.contains("Lily Carter"))
        #expect(block.contains("Daniel Reyes"))
    }

    @Test func groundingBlockStaysWithinItsBudget() {
        var context = Fixture.realistic()
        context.profileText = String(repeating: "A sentence about my life. ", count: 2_000)
        let block = try! #require(PersonalContextFormatting.aiGroundingBlock(context))
        #expect(block.count <= PersonalContextBudget.aiGroundingBudgetChars)
    }

    @Test func groundingBlockNamesAtMostTheMeasuredUsefulNumberOfPeople() {
        let block = try! #require(
            PersonalContextFormatting.aiGroundingBlock(Fixture.realistic()))
        let rows = block.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        #expect(rows.count <= PersonalContextBudget.aiGroundingMaxPeople)
        #expect(rows.count > 4)
    }

    @Test func everyPersonRowIsAWholeRow() {
        let context = Fixture.realistic()
        let block = try! #require(PersonalContextFormatting.aiGroundingBlock(context))
        let storedNames = Set(context.people.map(\.name))
        for row in block.components(separatedBy: "\n") where row.hasPrefix("- ") {
            let name = row.dropFirst(2).prefix(while: { $0 != ":" })
                .components(separatedBy: " (aka ").first!
                .trimmingCharacters(in: .whitespaces)
            #expect(storedNames.contains(name), "\(name) is not a whole stored name")
        }
    }

    @Test func profileExtractEndsOnASentenceOrParagraph() {
        let block = try! #require(
            PersonalContextFormatting.aiGroundingBlock(Fixture.realistic()))
        let profilePart = block
            .replacingOccurrences(of: "About the user / known context:\n", with: "")
            .components(separatedBy: "\nKnown people:").first!
        #expect(profilePart.hasSuffix("…"))
        let body = String(profilePart.dropLast())
        // A cut that lands mid-word is the failure mode; the surviving text must be a prefix
        // of what the user wrote, ending where a word ends.
        #expect(Fixture.longProfile.hasPrefix(body))
        let nextIndex = Fixture.longProfile.index(
            Fixture.longProfile.startIndex, offsetBy: body.count)
        #expect(
            nextIndex == Fixture.longProfile.endIndex
                || Fixture.longProfile[nextIndex].isWhitespace)
    }

    @Test func profileExtractNeverEndsOnADanglingHeading() {
        let profile = [
            "Overview", "I travel and build software for a living, mostly on my own schedule.",
            "Career and Technical Work", "A long passage that will not fit in the budget below.",
        ].joined(separator: "\n\n")
        let extract = PersonalContextSelection.profileExtract(profile, maxChars: 110)
        #expect(!extract.hasSuffix("Career and Technical Work…"))
        #expect(extract.hasPrefix("Overview"))
    }

    @Test func shortProfileIsNotTruncatedAtAll() {
        let profile = "I am a software engineer. I travel a lot."
        #expect(PersonalContextSelection.profileExtract(profile, maxChars: 900) == profile)
        let block = try! #require(
            PersonalContextFormatting.aiGroundingBlock(
                PersonalContext(profileText: profile)))
        #expect(block.contains(profile))
        #expect(!block.contains("…"))
    }

    @Test func groundingSpendsUnusedProfileBudgetOnPeople() {
        // A two-line bio should buy more names, not a shorter block.
        let short = PersonalContext(
            profileText: "I run a small bakery.", people: Fixture.manyPeople(count: 200))
        let long = PersonalContext(
            profileText: Fixture.longProfile, people: Fixture.manyPeople(count: 200))
        func rows(_ context: PersonalContext) -> Int {
            (PersonalContextFormatting.aiGroundingBlock(context) ?? "")
                .components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count
        }
        #expect(rows(short) >= rows(long))
    }

    @Test func groundingIsNilWhenTheUserTurnedItOff() {
        var context = Fixture.realistic()
        context.groundAi = false
        #expect(PersonalContextFormatting.aiGroundingBlock(context) == nil)
    }
}

@Suite struct PersonalContextTokenEstimateTests {
    @Test func estimateIsMonotonicAndCountsNonAsciiAsExpensive() {
        let short = PersonalContextBudget.estimatedTokens(forTerm: "Sarah")
        let long = PersonalContextBudget.estimatedTokens(forTerm: "Sarah Chen Whitfield")
        #expect(long > short)
        // Measured against tiktoken's GPT-2 BPE on 3,164 real names: non-Latin names average
        // ~9.4 tokens for ~10 characters, so they must not be charged like ASCII.
        #expect(
            PersonalContextBudget.estimatedTokens(forTerm: "菜蔡陳林")
                > PersonalContextBudget.estimatedTokens(forTerm: "Chen"))
    }

    @Test func fitTermsKeepsTheImportantTailAndWholeTerms() {
        let ascending = ["least", "middle", "Sarah Chen", "Speex"]
        let fitted = PersonalContextSelection.fitTerms(ascending, tokenBudget: 12)
        #expect(fitted.last == "Speex")
        #expect(fitted.allSatisfy { ascending.contains($0) })
        #expect(fitted.count < ascending.count)
    }
}
