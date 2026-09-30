import Foundation

// Which requests a provider may cut to fit its window, and which it must refuse instead.
//
// WHY THIS EXISTS (2026-09-29)
//
// Every provider had its own backstop for a body larger than its window: the on-device model cut
// everything except Extended summary, Apple Private Cloud Compute and OpenAI cut everything. A
// cut is harmless for a title — the gist of the first hour is still a fine title — and it is the
// most convincing wrong answer this app can produce for a template whose output CLAIMS the whole
// input. The database showed it twice: the recaps for 2026-09-22 and 09-23 were written by
// `apple-foundation-models` and stored as covering 51 and 45 recordings, ~232,000 and ~285,000
// characters of transcript. The model had been handed about 8,000 characters of each — the
// first hour of the morning — and the recap was saved with every segment id and settled forever.
// Nothing on the Today card said so. It got there because Remote first handed a failed cloud
// call's whole-day input to the on-device fallback, and the fallback quietly took 3% of it.
//
// Ask had the same hole one level up: the plan is sized for the provider that runs FIRST (a
// million-token model), the prompt tells the model "you are being shown ALL … in full", and a
// fallback that cut the body to its own window answered a whole-archive question from its
// first few pages while the prompt still said it was everything.
//
// So there is one rule for all three providers, here:
//
//   • a template in `wholeInputTemplateIds` is REFUSED when it does not fit, with a message
//     that says so ("too long for …"), which the router and the copy both understand; and
//   • anything else may be cut, and the provider reports that it was (`inputTruncated`), so a
//     caller can decline to finalize an answer drawn from part of its input.

public enum AiInputPolicy {
    /// Templates whose answer is false if the input was cut.
    ///
    ///  • `extended-summary` — "the full account", walks every subject to the end.
    ///  • `daily-summary` — the day's recap, saved with every recording's id and settled.
    ///  • `ask` — its prompt carries a COVERAGE line computed before the call ("ALL … in full").
    ///  • `ask-sweep-findings` / `ask-sweep-answer` — the two halves of a sweep, which exists
    ///    precisely so every word of the range is read; a cut part is a silently unread part.
    ///  • `day-brief` / `week-brief` / `month-brief` — History's headlines and briefs, stored
    ///    against a fingerprint of their whole input and settled on it. The inputs are sized to
    ///    fit the on-device window (`PeriodBriefWriter.maxInputCharacters`), so this refuses only
    ///    what should never happen.
    public static let wholeInputTemplateIds: Set<String> = [
        "extended-summary", "daily-summary", "ask", "ask-sweep-findings", "ask-sweep-answer",
        "day-brief", "week-brief", "month-brief",
    ]

    public static func requiresWholeInput(templateId: String) -> Bool {
        wholeInputTemplateIds.contains(templateId)
    }

    /// The literal a cloud provider's refusal carries. `AiFailure` reads it back as
    /// `.tooLongForModel`; the on-device refusal keeps its own marker
    /// (`AiFailure.Marker.tooLongForDevice`), because its sentence names the on-device model.
    public static let tooLongForModelMarker = "too long for this model"

    /// A request body, fitted to one call.
    public struct Fitted: Sendable, Equatable {
        /// What the model is sent.
        public let content: String
        /// True when `content` is a cut of the full body.
        public let truncated: Bool
        /// The full body's length, for the refusal and the log.
        public let fullChars: Int
    }

    /// The body for `request`, cut to `maxInputChars` when its template allows that, or a
    /// refusal when it does not.
    ///
    /// - Parameter modelName: named in the refusal — "Apple Private Cloud Compute", "gpt-5.6-luna".
    public static func fit(
        _ request: AiRunRequest, maxInputChars: Int, modelName: String
    ) throws -> Fitted {
        let full = AiTranscriptFormatting.buildUserContent(request, maxInputChars: Int.max)
        guard full.count > maxInputChars else {
            return Fitted(content: full, truncated: false, fullChars: full.count)
        }
        guard !requiresWholeInput(templateId: request.prompt.id) else {
            throw tooLong(
                request, readable: maxInputChars, total: full.count, modelName: modelName)
        }
        return Fitted(
            content: AiTranscriptFormatting.buildUserContent(
                request, maxInputChars: maxInputChars),
            truncated: true,
            fullChars: full.count)
    }

    /// The refusal a cloud provider throws for a whole-input template that does not fit. Written
    /// in the same shape as the on-device one — what would fit, what there is, and which
    /// template needed all of it — so the flight recorder reads the same either way.
    public static func tooLong(
        _ request: AiRunRequest, readable: Int, total: Int, modelName: String
    ) -> AiError {
        .providerFailed(
            "This request is \(tooLongForModelMarker) (\(modelName)). It would fit about "
                + "\(max(0, readable)) of its \(total) characters, and \"\(request.prompt.title)\" "
                + "has to read all of it.")
    }
}
