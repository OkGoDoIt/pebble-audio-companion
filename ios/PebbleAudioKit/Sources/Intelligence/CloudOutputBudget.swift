import Foundation

/// How much a cloud AI call is allowed to write.
///
/// This exists because a prompt is a request and a ceiling is a guarantee, and the difference
/// cost a shipped feature. `ExtendedSummaryPrompt` asked for "considerably more for a long one"
/// and "do not stop partway"; against a real 1 h 23 m recording the model obliged with **7,089
/// output tokens — 5,797 words — in 70.4 seconds**. Nothing in the request said it could not,
/// because the Responses payload carried no `max_output_tokens` at all.
///
/// Seventy seconds is past `URLSession`'s default 60-second timeout, and that timeout is an
/// IDLE timer: a non-streaming Responses call sends no bytes at all while the model writes, so
/// the socket sat silent and the request died with `-1001` after a minute, every time. What the
/// person saw was "The request took too long and was given up on". The honest reading is that
/// the note was never going to arrive, and raising the timeout would only have made them wait
/// longer for something too long to want.
///
/// **Numbers here are measured, not chosen.** The one entry below was arrived at by running the
/// real recording against the real model. Do not add a template to this table on reasoning
/// alone — an underestimate truncates a note mid-sentence, which is the silent-wrong-answer
/// failure this app keeps removing. Anything not listed gets `backstop`, which is far above
/// what any template has ever been observed to write and is there only so that a future prompt
/// cannot run away the way this one did.
///
/// Not to be confused with `OnDeviceTemplateBudget.outputTokens(forTemplateId:)`, whose numbers
/// are squeezed to fit Apple's 4,096-token window and are therefore much smaller. Applying
/// those as cloud ceilings would truncate notes that work today.
public enum CloudOutputBudget {

    /// Measured: the rewritten `extended-summary` lands at **873 tokens (669 words) in 10.4 s**
    /// on a 1 h 23 m recording, and 430 tokens on a 15-minute one. 1,200 leaves ~27% headroom,
    /// so ordinary variation cannot truncate, while still capping the runaway at roughly a
    /// sixth of what was observed before.
    static let extendedSummaryTokens = 1_200

    /// For every template whose real output has not been measured. Deliberately generous: this
    /// is a runaway guard, not a length policy, and a ceiling that bites a working template
    /// would be worse than no ceiling at all.
    static let backstop = 4_000

    public static func maxOutputTokens(forTemplateId id: String) -> Int {
        id == "extended-summary" ? extendedSummaryTokens : backstop
    }
}
