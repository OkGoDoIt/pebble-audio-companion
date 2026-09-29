import Foundation

// How much of a conversation the on-device model may be shown, and how much it may write back.
//
// There used to be two numbers for this, both constants, both wrong for most of what they were
// applied to: `defaultMaxInputChars` and `defaultMaxOutputTokens = 256`. The output cap in
// particular was written when the only on-device job was "title + 1-3 sentence summary", and it
// stayed at 256 tokens — about 190 words — when Extended summary arrived, whose entire reason to
// exist is being LONGER than the 1-3 sentence summary already on the conversation header. So on
// the on-device path the long summary was capped below the short one.
//
// The real constraint is one window shared by everything, measured against Apple's model rather
// than assumed:
//
//   • The window is 4,096 tokens TOTAL — input and output together. Handing it 12,000 characters
//     with 256 output tokens reserved throws `exceededContextWindowSize`; so does handing it
//     11,437 with grounding on. This is not a prefill check either: at 12,000 characters with no
//     grounding block the call ran for four seconds, generated, and died mid-answer at "4090
//     tokens, which exceeds the maximum allowed context size of 4096". Output is not free.
//   • Binary-searched against the real model on a real four-hour recording, with the Extended
//     summary prompt (2,823 chars) and a grounding block (737 chars):
//         256 output tokens  → 10,851 characters of transcript fit
//        1600 output tokens  →  5,968 characters of transcript fit
//     Fitting a line through those two points: 3.63 characters per token, ±69 (the search step).
//
// So the budget is derived, per request, from what the request actually costs: the template's own
// system prompt, the grounding block the user's About You produces THIS launch, and the output
// the template needs. `AskBudget.charsPerToken` (3, "deliberately pessimistic: overshooting the
// window fails the whole call, undershooting only reads a little less than it could") is reused
// rather than tuned to the measured 3.63 — the measurement is one transcript, and the 17% it
// gives up buys the margin that makes the number safe on transcripts that tokenize worse.
//
// The honest consequence, which is the point of the whole exercise: a template can want more
// than 4,096 tokens can hold. Extended summary of a four-hour recording does — its transcript is
// 157,639 characters and its allowance is under 5,000. That request now fails saying THAT, in
// those words, instead of producing a confident 200-word "full account" of the first 3% of the
// day, and instead of the generic "On-device AI generation failed" it produced before.

/// The on-device window, and what one request is allowed to take of it.
public struct OnDeviceContextBudget: Sendable, Equatable {
    /// Apple Foundation Models' context window ON iOS 26 — the floor, and the default a model
    /// that cannot report its own is budgeted against. Measured, not documented: the framework
    /// reports it in the `exceededContextWindowSize` error text ("the maximum allowed context
    /// size of 4096") and the binary search above agrees with it.
    ///
    /// No longer the only number. iOS 27's `SystemLanguageModel.contextSize` reports 8,192 (the
    /// same error there reads "exceeds the maximum allowed context size of 8192"), and
    /// `OnDeviceLanguageModel.contextWindowTokens()` carries whatever the model says into
    /// `forRequest(windowTokens:)`. Everything in the comment above about the ratio and the
    /// safety margin holds at either size; only the window moved.
    public static let windowTokens = 4_096

    /// Held back from the window. Covers the framing the framework adds around instructions and
    /// prompt, and the ±69-token resolution of the measurement the ratio came from.
    public static let safetyTokens = 96

    /// Below this there is no point running: a "note" written from 1,200 characters of a
    /// conversation is a sentence about its first two minutes. Refusing is more useful than
    /// answering, because the refusal names the cloud model, which can do it.
    public static let minimumInputChars = 1_200

    /// Output tokens for a template that names none. Enough for a paragraph or two.
    public static let defaultOutputTokens = 512

    /// Characters of transcript this request may be shown.
    public let inputChars: Int
    /// Tokens the model may write back.
    public let outputTokens: Int
    /// Whether `inputChars` is even worth using. False when the fixed costs — a long system
    /// prompt, a full grounding block, a long answer — leave less room than
    /// `minimumInputChars`.
    public let fits: Bool

    /// The budget for one request.
    ///
    /// - Parameters:
    ///   - outputTokens: what the template needs to write. Comes out of the same window.
    ///   - systemPromptChars: the template's instructions, as they will be sent.
    ///   - groundingChars: the About You block prepended to them, measured at call time — a
    ///     person with a long bio and 24 known names pays 1,600 characters here, and a person
    ///     with grounding switched off pays none.
    ///   - windowTokens: the model's whole window, from `OnDeviceLanguageModel
    ///     .contextWindowTokens()`. Defaults to the iOS 26 floor.
    public static func forRequest(
        outputTokens: Int,
        systemPromptChars: Int,
        groundingChars: Int,
        charsPerToken: Int = AskBudget.charsPerToken,
        windowTokens: Int = OnDeviceContextBudget.windowTokens
    ) -> OnDeviceContextBudget {
        let usableTokens = max(0, windowTokens - safetyTokens - outputTokens)
        let promptChars = systemPromptChars + groundingChars
        let inputChars = usableTokens * charsPerToken - promptChars
        return OnDeviceContextBudget(
            inputChars: max(0, inputChars),
            outputTokens: outputTokens,
            fits: inputChars >= minimumInputChars
        )
    }

    /// The same arithmetic in the model's own tokens, for a model that can count them: what is
    /// left for transcript once the answer, the safety margin and the instructions (grounding
    /// included, already measured) are paid for. Zero, never negative.
    public static func inputTokens(
        windowTokens: Int, outputTokens: Int, instructionTokens: Int
    ) -> Int {
        max(0, windowTokens - safetyTokens - outputTokens - instructionTokens)
    }
}

/// What each template wants out of the on-device model.
///
/// Keyed by template id rather than declared on `AiPromptTemplate` on purpose: `AiPromptTemplate`
/// is the shared provider seam (its Kotlin twin persists into stored notes), and how many tokens
/// APPLE'S model may write is not a property of a prompt — it is a property of this one provider.
/// A template nobody listed here gets `defaultOutputTokens`, which is the right failure mode for
/// a custom prompt somebody typed.
public enum OnDeviceTemplateBudget {
    /// Output tokens, by template id.
    ///
    /// The numbers are what the template's own instructions ask for, read literally:
    ///
    ///  • "1-3 plain sentences" and "2-4 concise sentences" want ~200.
    ///  • "topic, discussion points, decisions, and open questions" over a conversation wants
    ///    several hundred.
    ///  • Extended summary says "several paragraphs for a short recording, and considerably more
    ///    for a long one" — 900 tokens is ~650 words. It is not "considerably more", and it
    ///    cannot be: 900 tokens of answer already costs 2,700 characters of the transcript it is
    ///    describing. Where the recording is long enough that this matters, the request fails
    ///    over to the cloud instead of pretending (see `readsWholeConversation`).
    ///  • Ask answers are "one short paragraph where that is enough, and never more than about
    ///    three"; the sweep's gathering pass is "deliberately exhaustive" bullets.
    public static func outputTokens(forTemplateId id: String) -> Int {
        switch id {
        case SegmentAnnotationPrompt.templateId, SegmentAnnotationPrompt.liveTemplateId:
            return 200
        case "daily-summary", "recap-condense":
            return 224
        case "personal-context-terms":
            return 256
        case "extended-summary":
            return 900
        case "meeting-notes", "decisions", "study-notes", "interview-highlights":
            return 640
        case "follow-up-email":
            return 420
        case "ask", "ask-sweep-answer":
            return 512
        case "ask-sweep-findings":
            return 700
        default:
            return OnDeviceContextBudget.defaultOutputTokens
        }
    }

    /// Templates whose answer is a lie if the transcript was truncated.
    ///
    /// This used to be Extended summary alone, on the reasoning that everything else
    /// "summarizes or extracts from what it was given". The daily recap and Ask proved that
    /// wrong in production: both claim the whole of their input (a recap is saved as covering
    /// every recording of the day; Ask's prompt says "you are being shown ALL … in full"), and
    /// a fallback that read the first 3% of either produced a confident answer about all of it.
    /// The list now lives in `AiInputPolicy`, shared by every provider, so the on-device model
    /// and the two cloud ones cannot disagree about which answers may be drawn from a slice.
    public static func readsWholeConversation(templateId id: String) -> Bool {
        AiInputPolicy.requiresWholeInput(templateId: id)
    }
}
