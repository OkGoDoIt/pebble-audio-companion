import Foundation
import Testing

@testable import Intelligence

// The half of on-device follow-up extraction that needs no model at all: which sentences are
// worth a call, which written items may ship, and the two JSON bodies the existing parsers
// consume. Every case here is a rule that was earned by a real false positive during the
// measurement run, so each one names the line it came from.
@Suite struct LocalFollowUpSiftTests {

    // MARK: - Choosing candidate sentences

    @Test func keepsAnExplicitFirstPersonUndertaking() {
        #expect(
            LocalFollowUpSift.isCandidate(
                "I will pick up Oliver from school today after the meeting."))
        #expect(
            LocalFollowUpSift.isCandidate(
                "In five days, remind me to pay Owen what I owe him for the print job."))
        // The cue can be anywhere in the sentence, not just at the front — this one is the
        // real quote behind a labelled follow-up, and its only cue is the "I'll" two clauses in.
        #expect(
            LocalFollowUpSift.isCandidate(
                "So I could take what we have tomorrow to them, and if they don't like it, "
                    + "then I guess I'll call you both and come over with the blue folder."))
    }

    /// The three phrasings the strict cue set deliberately gives up. They are how people think
    /// out loud, they were where nearly every false positive came in, and the recall this costs
    /// is exactly why the UI calls the on-device reader the cautious one.
    @Test func dropsTheThinkingAloudPhrasingsOnPurpose() {
        #expect(!LocalFollowUpSift.isCandidate("I can enable it for one of us and export it."))
        #expect(!LocalFollowUpSift.isCandidate("Let's wrap up anything that is dangling today."))
        #expect(
            !LocalFollowUpSift.isCandidate(
                "We'll be able to show up there at eight in the morning."))
    }

    @Test func dropsQuestionsAndRequestsAimedAtSomebodyElse() {
        #expect(
            !LocalFollowUpSift.isCandidate("Can you send me the paperwork before Thursday?"),
            "a question is somebody asking, not somebody undertaking")
        #expect(
            !LocalFollowUpSift.isCandidate(
                "Please let me know if I need to change it to a different time."),
            "an imperative aimed outward is a request even with a cue in it")
    }

    /// "But we'll see", "We'll need the key somewhere", "Take a look" — every fragment that
    /// survived to the shipped list in the measurement runs was wrong.
    @Test func dropsFragmentsShorterThanTheFloor() {
        #expect(!LocalFollowUpSift.isCandidate("I'll take a look."))
        #expect(!LocalFollowUpSift.isCandidate("I need to go now."))
    }

    @Test func splitsTurnsIntoSentencesAndCarriesContext() {
        let rendered = """
            Recorded: Monday, 2026-06-29 at 2:31 PM

            --- Mon 2:31 PM ---
            S1: Hey, how did it go.
            S2: Fine, mostly.
            S1: I will pick up Oliver from school today, so do not worry about it.
            S2: Great, thank you.
            """
        let candidates = LocalFollowUpSift.candidates(in: rendered)
        #expect(candidates.count == 1)
        let candidate = try! #require(candidates.first)
        #expect(candidate.sentence.hasPrefix("I will pick up Oliver"))
        #expect(
            candidate.context.contains("Fine, mostly."),
            "the turns either side are what make a bare 'I'll do it' judgeable")
        #expect(candidate.context.contains("Great, thank you."))
        #expect(
            !candidate.context.contains("Recorded:"),
            "header lines are not turns and must not be judged as sentences")
    }

    @Test func boundsWhatOneConversationCanCost() {
        let turn = "S1: I will send the paperwork over to the office in the morning."
        let rendered = (0..<200).map { _ in turn }.joined(separator: "\n")
        let candidates = LocalFollowUpSift.candidates(in: rendered)
        #expect(
            candidates.count <= LocalFollowUpSift.maxCandidatesPerConversation,
            "each candidate is a model call on a phone, in the background, on battery")
    }

    @Test func doesNotJudgeTheSameSentenceTwice() {
        let rendered = """
            S1: I will send the paperwork over to the office in the morning.
            S2: Okay.
            S1: I will send the paperwork over to the office in the morning.
            """
        #expect(LocalFollowUpSift.candidates(in: rendered).count == 1)
    }

    // MARK: - Judging what came back

    @Test func acceptsAWellFormedItem() {
        #expect(
            LocalFollowUpSift.rejection(
                task: "Pay Owen what you owe him for the print job",
                quote: "In five days, remind me to pay Owen what I owe him for the print job.") == nil)
    }

    /// The model returns "finish", "pay" and "make reservation" as tasks, freely.
    @Test func rejectsATaskTooShortToActOn() {
        #expect(LocalFollowUpSift.rejection(task: "finish", quote: "I'll finish it later.") != nil)
        #expect(
            LocalFollowUpSift.rejection(
                task: "make reservation", quote: "I will make a reservation for 9:00 PM.") != nil)
    }

    /// "Show S3 the text message group" — the diarizer's label quoted back as a person.
    @Test func rejectsATaskThatNamesASpeakerLabel() {
        let rejection = LocalFollowUpSift.rejection(
            task: "Show S3 the text message group from earlier",
            quote: "I'll show you the text message group in a minute.")
        #expect(rejection == "task names a speaker label")
    }

    /// A task that says it happens now is by definition not a follow-up.
    @Test func rejectsATaskThatHappensNow() {
        let rejection = LocalFollowUpSift.rejection(
            task: "Take a taxi back to the hotel now",
            quote: "I'm taking a taxi to head back to the hotel now.")
        #expect(rejection == "task happens now")
    }

    /// The single most effective filter measured: it doubles precision without costing a
    /// correct item, because it is also a cheap entailment check — a task whose verb appears
    /// nowhere in its own quote was invented rather than read.
    @Test func requiresAConcreteActionInBothTheTaskAndItsQuote() {
        #expect(
            LocalFollowUpSift.rejection(
                task: "Think about the garden plan properly",
                quote: "I have to think about the garden plan properly.")
                == "task does not open with a concrete action")
        #expect(
            LocalFollowUpSift.rejection(
                task: "Send the revised contract to the office",
                quote: "I'm going to have a look at the situation and see how it feels.")
                == "the quote does not contain the action")
    }

    /// A task is an imperative sentence, so its verb is its first word. Anchoring there rather
    /// than anywhere in the string is what removed the panel's last false positive: the only
    /// errand word in "Show up in the text message group" is the NOUN "text".
    @Test func requiresTheTaskToOpenWithItsVerb() {
        #expect(
            LocalFollowUpSift.rejection(
                task: "Show up in the text message group",
                quote: "If you're in the text message group, I'll show up there as well.")
                == "task does not open with a concrete action")
        #expect(
            LocalFollowUpSift.rejection(
                task: "Text the gym about the membership card",
                quote: "I need to text the gym about the membership card.") == nil)
    }

    /// "take", "get", "make" and "move" are verbs of doing anything at all, and every remaining
    /// false positive on the panel arrived through one of them.
    @Test func doesNotTreatTheVerbsOfDoingAnythingAsErrands() {
        #expect(
            LocalFollowUpSift.rejection(
                task: "Take a look at the draft", quote: "If it's a good fit, I'll take a look.")
                != nil)
        #expect(
            LocalFollowUpSift.rejection(
                task: "Get the garage sorted out",
                quote: "I have to get the garage sorted out.") != nil)
    }

    @Test func rejectsMarkdownAndFieldLabelsTheWayTheCloudParserDoes() {
        #expect(
            LocalFollowUpSift.rejection(
                task: "**Send** the contract to the office",
                quote: "I'll send the contract to the office tomorrow.") != nil)
        #expect(
            LocalFollowUpSift.rejection(
                task: "Owner: send the contract to the office",
                quote: "I'll send the contract to the office tomorrow.") != nil)
    }

    @Test func rejectsAQuoteTooDamagedToBeSureOf() {
        let rejection = LocalFollowUpSift.rejection(
            task: "Send the paperwork to the office",
            quote: "I'm going to send the paperwork to the—")
        #expect(rejection == "the quote is too damaged to be sure of")
    }

    // MARK: - The bodies the existing parsers read

    /// The whole point of the seam: what the on-device path produces is the same JSON the
    /// cloud path produces, so nothing downstream knows which model wrote it.
    @Test func extractionJsonRoundTripsThroughTheProductionParser() throws {
        let json = LocalFollowUpSift.extractionJSON([
            LocalFollowUpSift.Item(
                task: "Pay Owen what you owe him for the print job",
                quote: "In five days, remind me to pay Owen what I owe him for the print job.",
                ifForgotten: "Owen is still owed the money")
        ])
        let parsed = try #require(FollowUpExtractionParser.parse(raw: json))
        #expect(parsed.count == 1)
        #expect(parsed[0].task == "Pay Owen what you owe him for the print job")
        // The on-device model stamped the recording's own date on every item it returned, so
        // it is never asked for one: a valid-looking wrong date is worse than no date.
        #expect(parsed[0].dueDate.isEmpty)
        #expect(parsed[0].confidence == "low", "which is the truth, and the curator is shown it")
    }

    @Test func curationJsonRoundTripsThroughTheProductionParser() throws {
        let json = LocalFollowUpSift.curationJSON(decisions: [
            (index: 1, keep: true, reason: ""),
            (index: 2, keep: false, reason: "narration of the moment"),
        ])
        let parsed = try #require(FollowUpCurationParser.parse(raw: json))
        #expect(parsed.count == 2)
        #expect(parsed[0].decision == "keep")
        #expect(parsed[1].decision == "drop")
        #expect(parsed[1].reason == "narration of the moment")
        #expect(
            parsed.allSatisfy { $0.task.isEmpty && $0.dueDate.isEmpty },
            "on-device curation may only subtract: it never rewrites a task and never dates one")
        #expect(parsed.allSatisfy { $0.priority == "normal" })
    }

    @Test func readsTheCuratorsOwnBatchBackOutOfItsPrompt() throws {
        let body = """
            Today is Tuesday, 2026-09-08.

            ALREADY ON THIS PERSON'S LIST:
            - Renew the passport

            CANDIDATES:
            1. Pay Owen what you owe him for the print job
               heard: "In five days, remind me to pay Owen what I owe him."
               if forgotten: Owen is still owed the money
               recorded: Friday, 2026-08-14
               how sure the reader was: low
            2. Sign up for the swimming class waitlist
               heard: "she's sending me some information to sign up"
               recorded: Tuesday, 2026-08-25
               how sure the reader was: low
            """
        let candidates = LocalFollowUpSift.numberedCandidates(in: body)
        #expect(candidates.count == 2)
        #expect(candidates[0].index == 1)
        #expect(candidates[0].block.hasPrefix("Pay Owen"))
        #expect(
            candidates[0].block.contains("heard:"),
            "the quote is the only thing curation is allowed to judge by")
        #expect(candidates[1].index == 2)
        #expect(
            !candidates[1].block.contains("Pay Owen"),
            "a candidate's block must stop at the next candidate")
    }
}
