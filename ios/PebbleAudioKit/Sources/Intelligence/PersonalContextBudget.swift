import Foundation

/// Every documented limit that governs how much "About You" a consumer can actually take,
/// in one place, each with the source it came from.
///
/// The reason this file exists: the four consumers of `PersonalContext` have budgets that
/// differ by two orders of magnitude — 224 tokens for one, 10,000 characters for another,
/// 100 phrases for a third — and they were previously all served from one pair of
/// hand-picked character constants. A person with a 500-word bio and 3,000 contacts
/// overflows one of them silently while another sits three-quarters empty.
///
/// The numbers are provider documentation, not guesses. Where a limit is *enforced*
/// differently (silent truncation vs. a rejected request) that is recorded too, because it
/// decides which end of a list we are allowed to lose.
public enum PersonalContextBudget {

    // MARK: - OpenAI file transcription (`POST /v1/audio/transcriptions`, `prompt`)

    /// `whisper-1` accepts a prompt of at most **224 tokens**.
    ///
    /// > "Whisper doesn't follow instructions like a general-purpose text model and accepts
    /// > prompts of up to 224 tokens."
    /// — https://developers.openai.com/api/docs/guides/speech-to-text
    ///
    /// The newer `gpt-4o-transcribe` / `gpt-4o-mini-transcribe` also accept `prompt` but
    /// publish no number, so we size everything to the one documented figure.
    /// `gpt-4o-transcribe-diarize` accepts no prompt at all — the provider already suppresses
    /// it for that model.
    public static let openAiSttPromptMaxTokens = 224

    /// What we actually fill, leaving headroom for the estimator below being an estimate.
    /// `estimatedPromptTokens` is deliberately pessimistic but not infallible on pathological
    /// input (phone numbers, handles), and 44 tokens of slack is cheaper than an overflow.
    public static let openAiSttPromptTokenBudget = 180

    /// Overflow is **truncated from the front**, not rejected:
    ///
    /// > "only the final 224 tokens of the prompt will be considered; all prior tokens will be
    /// > silently ignored."
    /// — https://cookbook.openai.com/examples/whisper_prompting_guide
    ///
    /// This is why `PersonalContextFormatting.openAiSttPrompt` emits terms in **ascending**
    /// order of importance: whatever the API drops is then the material we cared about least.
    /// (The current guide describes the newer `keywords` field as *rejecting* an over-length
    /// prompt instead. Both behaviours are survivable if we stay under the limit, which is the
    /// point of the budget above.)
    ///
    /// Recorded here rather than as a constant because nothing branches on it — it is the
    /// reason for an ordering decision, and the ordering is what the tests pin.

    // MARK: - Soniox (`context`)

    /// Soniox rejects an over-length context rather than trimming it:
    ///
    /// > "Maximum 8,000 tokens (~10,000 characters)." … "If you exceed the limit, the API will
    /// > return an error → trim or summarize first."
    /// — https://soniox.com/docs/stt/concepts/context
    ///
    /// The WebSocket reference shows the enforced message: `Context is too long (max length
    /// 10000).` So this is a hard gate on characters, and a request that trips it loses the
    /// whole transcription, not just the bias.
    public static let sonioxContextHardLimitChars = 10_000

    /// What we fill. The old code clamped to exactly the hard limit, which left no room at all
    /// for a separator, a field name, or a JSON escape — and a failure here is a failed
    /// transcription, so the margin is worth 1,000 characters we would rarely have used.
    public static let sonioxContextBudgetChars = 9_000

    // MARK: - Apple on-device speech (`AnalysisContext.contextualStrings`)

    /// > "Limit the total number of phrases across all tags to no more than 100."
    /// — https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings
    /// (the same sentence appears on the older `SFSpeechRecognitionRequest.contextualStrings`)
    ///
    /// Apple also asks for short phrases: "Keep phrases relatively brief, limiting them to one
    /// or two words whenever possible. Lengthy phrases are less likely to be recognized."
    ///
    /// Nothing reads this yet — the local `SpeechAnalyzerProvider` passes no contextual
    /// strings — so a local-transcription user currently gets no benefit at all from About
    /// You. `PersonalContextFormatting.appleContextualStrings` is the shape that path needs.
    public static let appleContextualStringsMaxPhrases = 100

    /// Apple's "one or two words" guidance, as a rule we can actually apply.
    public static let appleContextualStringMaxWords = 3

    // MARK: - On-device chat model (Apple Foundation Models)

    /// Measured on this machine, from the framework's own error text: a session that exceeds
    /// it throws `exceededContextWindowSize` — "Content contains 7688 tokens, which exceeds the
    /// maximum allowed context size of 4096."
    ///
    /// Everything shares this window: grounding block + system prompt + transcript + output.
    /// Binary-searching the largest transcript that still fits (macOS 26.6, Sept 2026):
    ///
    /// | grounding block | transcript that still fits |
    /// |---|---|
    /// | none (654 char instructions) | 11,047 chars |
    /// | 2,000 chars (what shipped)   |  9,946 chars |
    /// |   950 chars                  | 10,367 chars |
    ///
    /// So a 2,000-character grounding block is not free: it costs about 1,100 characters of
    /// the user's actual conversation. That is the whole argument for spending the block on
    /// names rather than prose.
    public static let onDeviceContextWindowTokens = 4_096

    // MARK: - The AI grounding block

    /// Total grounding block budget, down from the 2,000 that shipped.
    ///
    /// Partitioned rather than first-come-first-served, which is the bug this replaces: with a
    /// 3,507-character bio the profile text consumed the entire 2,000, so `people` — the one
    /// part of About You that measurably changes an answer — never reached the model at all.
    /// Measured on Apple Foundation Models over 8 runs of a name-correction task (a transcript
    /// with three misheard names, asked to correct them from known people):
    ///
    /// | grounding | names recovered | latency | invented people |
    /// |---|---|---|---|
    /// | none                          | 0.00 | 1.26s | 0.00/run |
    /// | 2,000 chars of bio (shipped)  | 0.00 | 1.55s | 0.00/run |
    /// | bio extract + 15 ranked people| 0.33 | 1.53s | 0.12/run |
    /// | bio extract + 200 contacts    | 0.33 | 3.88s | 0.12/run |
    /// | bio extract + 450 contacts    | — exceeded the 4,096-token window, every run failed  |
    ///
    /// Fifteen ranked names buy exactly what two hundred unranked ones buy, at 40% of the
    /// latency; four hundred and fifty break the provider outright. Bulk is not a strategy.
    public static let aiGroundingBudgetChars = 1_600

    /// The share of the block the free-text profile may take. The rest is reserved.
    public static let aiGroundingProfileChars = 900

    /// Reserved for known people, so a long bio can never crowd them out again.
    public static let aiGroundingPeopleChars = 560

    /// A hard ceiling on named people regardless of characters. See the table above: past a
    /// couple of dozen, added names cost latency and invented attributions without adding
    /// accuracy. Consistent with the wider evidence that irrelevant context is actively
    /// harmful rather than merely wasteful — Shi et al. (ICML 2023) measured a 22.6-point
    /// accuracy drop from a *single* irrelevant sentence (https://arxiv.org/abs/2302.00093),
    /// and Liu et al. found long-context performance falling below the no-context baseline
    /// (https://arxiv.org/abs/2307.03172).
    public static let aiGroundingMaxPeople = 24

    /// Organizations / topics / vocabulary get what is left.
    public static let aiGroundingExtrasChars = 140

    // MARK: - Token estimation

    /// Conservative token estimate for a short term (a name, an organization, a keyword),
    /// including the ", " that will join it to its neighbour.
    ///
    /// Calibrated against `tiktoken`'s GPT-2 BPE — Whisper's tokenizer is that vocabulary
    /// extended for multilingual use — over this product's real data (3,164 stored names,
    /// organizations and derived terms):
    ///
    ///  - names tokenize far denser than prose: 3.48 characters per token, not the usual ~4;
    ///  - non-ASCII names are brutal — 86 of the sample averaged 9.4 tokens for ~10 characters,
    ///    with a worst case of 23 tokens for a 24-character name;
    ///  - dividing ASCII length by 2.5 with a 2-token floor and charging 2 tokens per non-ASCII
    ///    scalar over-estimates a realistic 40-term list every time, by ~11% in aggregate.
    ///
    /// Over-estimating is the safe direction: it costs a few terms we could have sent, where
    /// under-estimating costs a truncated or rejected request.
    public static func estimatedTokens(forTerm term: String) -> Int {
        var asciiCount = 0
        var otherCount = 0
        for scalar in term.unicodeScalars {
            if scalar.isASCII {
                asciiCount += 1
            } else {
                otherCount += 1
            }
        }
        let asciiTokens = max(2, Int((Double(asciiCount) / 2.5).rounded(.up)))
        return asciiTokens + otherCount * 2 + 1
    }

    /// Estimated tokens for a comma-joined list of terms.
    public static func estimatedTokens(forTerms terms: [String]) -> Int {
        terms.reduce(0) { $0 + estimatedTokens(forTerm: $1) }
    }
}
