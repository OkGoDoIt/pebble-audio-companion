import AppDB
import Foundation
import Testing

@testable import Intelligence

// What an answer has to look like before History shows it (`HistoryBriefText`), and the inputs
// the week and month briefs are written from. The refusals are the point: each banned shape is
// one that was on Roger's screen on 2026-09-30 ("The day began with a long planning…" over
// "Later, you worked with friends…"; "The speaker also walked around Denver").

@Suite struct HistoryBriefTextTests {
    @Test("a good answer parses as written")
    func goodAnswer() {
        let answer = DayBrief.parse(
            #"{"headline":"Office in Unit 4 and Fernwood","lineSummary":"Signed a new office lease in Unit 4; weighed short terms."}"#)
        #expect(answer.headline == "Office in Unit 4 and Fernwood")
        #expect(answer.lineSummary == "Signed a new office lease in Unit 4; weighed short terms.")
    }

    @Test("a headline that opens like a sentence about the day is refused")
    func bannedHeadlineOpenings() {
        for bad in [
            "The day began with planning", "The speaker walked around Denver", "Today in Denver",
            "You deployed the site", "A day of meetings", "The user shopped", "They went to dinner",
        ] {
            #expect(HistoryBriefText.headline(bad) == nil, "\(bad)")
        }
        // Whole words only: these are fine.
        #expect(HistoryBriefText.headline("Youth football practice") == "Youth football practice")
        #expect(HistoryBriefText.headline("Daydreams and deadlines") == "Daydreams and deadlines")
        #expect(HistoryBriefText.headline("iPhone fixes and a bike") == "iPhone fixes and a bike")
    }

    @Test("a headline is a phrase: capped, two to seven words, never two sentences")
    func headlineShape() {
        #expect(HistoryBriefText.headline(String(repeating: "Apartment ", count: 4) + "hunting") == nil, "over 42")
        #expect(HistoryBriefText.headline("Packing") == nil, "one word")
        #expect(HistoryBriefText.headline("Ads, bank, flat, visa, curry, rain, dogs, bus") == nil, "eight words")
        #expect(HistoryBriefText.headline("Went to the bank. Then dinner") == nil)
        // Never a list of three, however it is punctuated; one comma is fine.
        #expect(HistoryBriefText.headline("Denver, work, birthday") == nil)
        #expect(HistoryBriefText.headline("Ads, the bank and a bike") == nil)
        #expect(HistoryBriefText.headline("Denver, then dinner") == "Denver, then dinner")
        // The prompt's own example of the form, echoed back, is refused.
        #expect(HistoryBriefText.headline(HistoryBriefText.exampleHeadline) == nil)
        #expect(HistoryBriefText.lineSummary(HistoryBriefText.exampleLine) == nil)
        #expect(HistoryBriefText.headline("  ") == nil)
        #expect(HistoryBriefText.headline(nil) == nil)
    }

    @Test("quotes, a full stop and Title Case minor words are fixed, not refused")
    func headlineCleanup() {
        #expect(HistoryBriefText.headline("\"Ad audits and a Denver walk.\"") == "Ad audits and a Denver walk")
        #expect(HistoryBriefText.headline("“Road Trip To Denver”") == "Road Trip to Denver")
        #expect(HistoryBriefText.headline("deploying the website changes") == "Deploying the website changes")
        #expect(HistoryBriefText.headline("**Office In Unit 4 And Fernwood**") == "Office in Unit 4 and Fernwood")
        // An acronym stays as written.
        #expect(HistoryBriefText.headline("Taxes AND the LLC") == "Taxes AND the LLC")
    }

    @Test("a line must stand on its own and never speak of the wearer from outside")
    func lineRules() {
        #expect(HistoryBriefText.lineSummary("Later, you worked with friends on the garden.") == nil)
        #expect(HistoryBriefText.lineSummary("Also discussed the neighbor's fence.") == nil)
        #expect(HistoryBriefText.lineSummary("The speaker also walked around Denver.") == nil)
        #expect(HistoryBriefText.lineSummary("Walked around Denver while the user shopped.") == nil)
        #expect(HistoryBriefText.lineSummary("The day began with lunch.") == nil)
        #expect(HistoryBriefText.lineSummary(String(repeating: "Walked. ", count: 20)) == nil, "over 150")
        #expect(
            HistoryBriefText.lineSummary("signed a new office lease in Unit 4; weighed short terms")
                == "Signed a new office lease in Unit 4; weighed short terms.")
        // "Laterally" is not "Later".
        #expect(HistoryBriefText.lineSummary("Laterally moved the desk.") == "Laterally moved the desk.")
    }

    @Test("a reply in a code fence or a sentence still parses; no object is an empty answer")
    func lenientParsing() {
        let fenced = DayBrief.parse(
            "Here it is:\n```json\n{\"headline\": \"Road trip to Denver\", \"lineSummary\": \"Trains and a taxi in the rain.\"}\n```")
        #expect(fenced.headline == "Road trip to Denver")
        #expect(fenced.lineSummary == "Trains and a taxi in the rain.")
        #expect(DayBrief.parse("The day began with planning.").isEmpty)
        #expect(DayBrief.parse(#"{"headline": 3, "lineSummary": null}"#).isEmpty)
        // One field refused, the other kept.
        let half = DayBrief.parse(#"{"headline":"The day was busy","lineSummary":"Ad audits, then a walk."}"#)
        #expect(half.headline == nil && half.lineSummary == "Ad audits, then a walk.")
    }

    @Test("a period brief keeps each usable field")
    func periodParsing() {
        let answer = PeriodBriefWriter.parse(
            #"{"text":"Garden work took most of the week. A shed was built.","headline":"Gardening and a road trip","lineSummary":"A shed built; a road trip to Denver."}"#)
        #expect(answer.text == "Garden work took most of the week. A shed was built.")
        #expect(answer.headline == "Gardening and a road trip")
        #expect(answer.lineSummary == "A shed built; a road trip to Denver.")
        let refused = PeriodBriefWriter.parse(#"{"text":"The speaker planted tomatoes.","headline":"The week","lineSummary":""}"#)
        #expect(refused.isEmpty)
        // A paragraph is at least two sentences: the headline again, or one run-on clause, is
        // not a summary (both came back from the on-device model on real weeks).
        #expect(HistoryBriefText.briefText("Software fixes and garden work.") == nil)
        #expect(
            HistoryBriefText.briefText(
                "Software fixes and garden work you fixed data issues and walked the city") == nil)
        #expect(HistoryBriefText.briefText("Gardening took the week. A shed was built.") != nil)
        // Line breaks inside the model's strings are read as spaces, not as a broken answer.
        let broken = PeriodBriefWriter.parse("{\"text\":\"Gardening took the week.\nA shed was built.\",\"headline\":\"Gardening and a shed\",\"lineSummary\":\"\"}")
        #expect(broken.text == "Gardening took the week. A shed was built.")
        #expect(broken.headline == "Gardening and a shed")
    }
}

@Suite struct DayBriefStateTests {
    @Test("owed once per recap text; a regenerated recap is owed again and hides the old headline")
    func fingerprintGuard() {
        var recap = DailyRecap(dateKey: "2026-09-27", text: "A day of packing.")
        #expect(DayBrief.needsPass(recap))
        #expect(DayBrief.current(recap).isEmpty)
        recap.headline = "Errands in town"
        recap.lineSummary = "Lists and errands."
        recap.briefOfHash = RecapCondenser.fingerprint(recap.text)
        #expect(!DayBrief.needsPass(recap))
        #expect(DayBrief.current(recap).headline == "Errands in town")
        // A refused answer stamps the hash with nothing: asked once.
        var refused = recap
        refused.headline = nil
        refused.lineSummary = nil
        #expect(!DayBrief.needsPass(refused))
        // Regenerated: a headline about the old text is never shown over the new.
        recap.text = "A day of packing, then a flight."
        #expect(DayBrief.needsPass(recap))
        #expect(DayBrief.current(recap).isEmpty)
        // Nothing to read, nothing owed.
        #expect(!DayBrief.needsPass(DailyRecap(dateKey: "2026-09-28", text: "  ")))
    }

    @Test("the input is the condensed recap when it is current, else the recap")
    func input() {
        var recap = DailyRecap(dateKey: "2026-09-27", text: String(repeating: "Long day. ", count: 80))
        #expect(DayBrief.input(recap) == recap.text.trimmingCharacters(in: .whitespaces))
        recap.shortText = "Short day."
        recap.shortOfHash = RecapCondenser.fingerprint(recap.text)
        #expect(DayBrief.input(recap) == "Short day.")
    }
}

@Suite struct PeriodBriefInputTests {
    @Test("a week's input keeps every headline and line, and fits the budget")
    func weekInputFits() {
        let days = (20...26).map { day in
            PeriodBriefWriter.DayEntry(
                dateKey: "2026-09-\(day)", headline: "Headline \(day)", lineSummary: "Line \(day).",
                recap: String(repeating: "Something happened on the \(day)th. ", count: 60))
        }
        let input = PeriodBriefWriter.weekInput(days)
        #expect(input.count <= PeriodBriefWriter.maxInputCharacters)
        for day in 20...26 {
            #expect(input.contains("Headline: Headline \(day)"))
            #expect(input.contains("In one line: Line \(day)."))
        }
        #expect(input.hasPrefix("Sunday 20 September 2026"))
        // Cut at a sentence end where one is in reach, not mid-word.
        #expect(input.contains("th. \n\n") || input.contains("th.\n\n"))
    }

    @Test("short recaps are given whole; the long one takes what they leave")
    func sharesAreFair() {
        let long = String(repeating: "A long account of the day. ", count: 300)
        let input = PeriodBriefWriter.weekInput([
            .init(dateKey: "2026-09-20", headline: "A", lineSummary: nil, recap: "Short one."),
            .init(dateKey: "2026-09-21", headline: "B", lineSummary: nil, recap: long),
        ])
        #expect(input.contains("Recap: Short one."))
        #expect(input.count <= PeriodBriefWriter.maxInputCharacters)
        #expect(input.count > PeriodBriefWriter.maxInputCharacters - 200, "the long one used the room")
    }

    @Test("a month's input names each week and carries its brief")
    func monthInput() {
        let input = PeriodBriefWriter.monthInput([
            .init(
                firstDateKey: "2026-09-27", lastDateKey: "2026-10-03", headline: "Road trip and Fernwood",
                lineSummary: "A shed built.", text: "The fair, then Denver.")
        ])
        #expect(input.contains("Week of Sunday 27 September 2026 to Saturday 3 October 2026"))
        #expect(input.contains("Headline: Road trip and Fernwood"))
        #expect(input.contains("Summary: The fair, then Denver."))
    }

    @Test("the day label is fixed English whatever the phone's language")
    func dayLabel() {
        #expect(PeriodBriefWriter.dayLabel("2026-09-27") == "Sunday 27 September 2026")
        #expect(PeriodBriefWriter.dayLabel("nonsense") == "nonsense")
    }

    @Test("the three templates must read their whole input and fit the on-device window")
    func policy() {
        for id in [DayBrief.templateId, PeriodBriefWriter.weekTemplateId, PeriodBriefWriter.monthTemplateId] {
            #expect(AiInputPolicy.requiresWholeInput(templateId: id))
        }
        // The iOS 26 window, a full About You block (1,600 characters): the week's input fits.
        let budget = OnDeviceContextBudget.forRequest(
            outputTokens: OnDeviceTemplateBudget.outputTokens(forTemplateId: PeriodBriefWriter.weekTemplateId),
            systemPromptChars: PeriodBriefWriter.weekPrompt.systemPrompt.count, groundingChars: 1_600)
        #expect(budget.inputChars >= PeriodBriefWriter.maxInputCharacters + PeriodBriefWriter.weekPrompt.userPrompt.count)
    }
}
