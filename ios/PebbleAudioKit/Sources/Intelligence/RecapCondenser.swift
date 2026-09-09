import Foundation

// The second AI pass over a day digest (session: "Today so far is too long").
//
// `DailyRecapEngine` asks for 2–4 concise sentences, and on a quiet day that is what comes
// back. On a full one it is not: the digest grows to a screenful, and the Today card — which
// exists to be GLANCED at, above the coverage strip, the follow-ups and the conversations —
// becomes the tallest thing on the page. The detail was never the problem; its position was.
//
// So the long digest is kept whole (it is what the pushed recap detail shows, and what the
// search index holds) and a SECOND pass condenses it for the card. This is deliberately not a
// truncation: a digest cut at 400 characters ends mid-clause and drops whatever the afternoon
// was about, which is exactly the information the card is for.
//
// Three properties this file exists to guarantee:
//
//   1. It runs only when it is needed (`needsCondensing`), so an ordinary day costs no
//      second AI call at all.
//   2. Its output is cached against a FINGERPRINT of the digest it was made from, so the pass
//      runs once per digest rather than once per refresh — and a regenerated digest
//      invalidates its short form instead of silently keeping a summary of yesterday's text.
//   3. A result that is not actually shorter is refused. The card then shows the full digest,
//      which is honest; showing a "summary" the same length as its source would not be.

/// Threshold policy, prompt and acceptance rule for the condensed Today recap.
public enum RecapCondenser {

    // MARK: - Thresholds

    /// What "more than a medium paragraph" means here, in characters.
    ///
    /// `AiPromptTemplates.dailySummary` asks for "2-4 concise sentences". A concise sentence of
    /// this kind runs about 90–110 characters, so a well-behaved digest lands between roughly
    /// 200 and 450. 520 is therefore comfortably ABOVE the shape the digest prompt asks for
    /// (about 80–90 words, five sentences or more) — a digest that trips it has genuinely
    /// overrun, and no ordinary day pays for a second AI call.
    public static let mediumParagraphCharacters = 520

    /// What the condense pass aims for: about 65 words / three sentences. Named separately
    /// from the trigger so the prompt can ask for a comfortable target while acceptance is
    /// judged against the looser `mediumParagraphCharacters` bound below.
    public static let condensedTargetCharacters = 420

    /// How much shorter a condensation has to be before it is worth showing. A "summary" that
    /// saves a tenth of the height is not a summary; it is the same wall of text with facts
    /// missing, and the card is better off with the original.
    public static let minimumShorteningRatio = 0.75

    /// True when `text` is long enough that the Today card should show a condensed form.
    public static func needsCondensing(_ text: String) -> Bool {
        normalized(text).count > mediumParagraphCharacters
    }

    /// True when a condensation is worth showing in place of its source: non-empty,
    /// meaningfully shorter than what it replaces, and short enough to read as a card.
    ///
    /// "Short enough" is `mediumParagraphCharacters` OR half the source, whichever is LARGER.
    /// A flat 520-character ceiling refused the condensation of exactly the digests that need
    /// one most: a runaway 1,900-character day answered with a 700-character paragraph is a
    /// two-thirds cut and obviously worth showing, and refusing it stamped the day as attempted
    /// (`Outcome.notShorter`) so it was never asked again — the card kept the essay for good.
    public static func isUsable(_ condensed: String, source: String) -> Bool {
        let short = normalized(condensed)
        let long = normalized(source)
        guard !short.isEmpty, !long.isEmpty else { return false }
        guard short.count <= max(mediumParagraphCharacters, long.count / 2) else { return false }
        return Double(short.count) <= Double(long.count) * minimumShorteningRatio
    }

    /// Whitespace-collapsed text, so a digest that happens to arrive with hard line breaks is
    /// measured by what it says rather than by how it was wrapped.
    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cache key

    /// A stable fingerprint of a digest, used as the cache key for its condensation.
    ///
    /// FNV-1a over the UTF-8 bytes plus the byte count. Deliberately NOT `hashValue`: Swift's
    /// hashing is seeded per process, so a cached value keyed on it would miss on every launch
    /// and re-run the AI pass forever.
    public static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var count = 0
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
            count += 1
        }
        return String(format: "%016llx-%d", hash, count)
    }

    /// The condensation to SHOW for this recap, or nil when the card should show the digest.
    ///
    /// Checks the fingerprint rather than trusting the stored text: a digest regenerated by a
    /// writer that did not clear the short form would otherwise put yesterday afternoon's
    /// summary on top of this afternoon's recap, and nothing on screen would say so.
    public static func condensation(of recap: DailyRecap) -> String? {
        guard let short = recap.shortText, !short.isEmpty,
            let hash = recap.shortOfHash, hash == fingerprint(recap.text)
        else { return nil }
        return short
    }

    /// True when this recap still owes a condense pass — long enough to need one, and without
    /// a completed attempt for its CURRENT text.
    ///
    /// A completed attempt that produced nothing usable also stamps `shortOfHash` (with a nil
    /// `shortText`), so a digest the model cannot shorten is asked once and then left alone.
    public static func needsPass(_ recap: DailyRecap) -> Bool {
        guard needsCondensing(recap.text) else { return false }
        return recap.shortOfHash != fingerprint(recap.text)
    }

    // MARK: - Prompt

    /// The condense prompt.
    ///
    /// Lives here rather than in `AiPromptTemplates` because it is not a template a user can
    /// pick: its input is our own generated prose, not a transcript, and its only reader is the
    /// Today card. The transcript rules the shared catalog opens with ("transcripts may contain
    /// transcription errors, annotated gaps…") would be a lie about this input.
    public static let prompt = AiPromptTemplate(
        id: "recap-condense",
        title: "Shorter daily recap",
        systemPrompt:
            "You are shortening a recap of one day that the user's own device already wrote. "
            + "The input is finished prose, not a transcript: every fact in it is already "
            + "established, so never add, infer, soften or re-interpret anything, and never "
            + "remark on the shortening. Keep the day's chronological shape and the things a "
            + "person would want to remember — who, what was decided, what is outstanding — and "
            + "drop elaboration, repeated detail and scene-setting. Write one paragraph of at "
            + "most three sentences and about \(condensedTargetCharacters / 7) words. Plain "
            + "text only: no Markdown, headings, bullets, bold text or numbered lists. Answer "
            + "with the shortened recap and nothing else.",
        userPrompt: "Shorten this recap of the day."
    )

    // MARK: - The pass

    /// What one condense attempt concluded.
    public enum Outcome: Equatable, Sendable {
        /// A shorter form worth showing.
        case condensed(String)
        /// The model answered, but not with anything shorter. Cached as an attempt so the same
        /// digest is not re-sent on every pipeline pass.
        case notShorter
    }

    /// Runs one condense pass over `recap`'s digest.
    ///
    /// Throws whatever `run` throws — a provider that is down, out of quota or without consent
    /// must NOT be recorded as an attempt, or a single bad afternoon would leave the card
    /// permanently showing the long digest with nothing left to retry it.
    public static func condense(
        _ recap: DailyRecap,
        run: (AiRunRequest) async throws -> RoutedAiResult,
        nowMs: Int64
    ) async throws -> Outcome {
        let result = try await run(
            AiRunRequest(
                requestId: "recap-condense-\(recap.dateKey)-\(nowMs)",
                prompt: prompt,
                transcripts: [
                    // `prebuilt` means "pass this body through untouched": the input is one
                    // block of our own prose, and wrapping it in a "Transcript segment
                    // <id>" header would teach the model a segment id it might quote back.
                    TranscriptExcerpt(
                        segmentId: AiTranscriptFormatting.prebuiltSegmentId,
                        text: recap.text,
                        startTimeMs: nil)
                ]))
        let text = normalized(result.text)
        return isUsable(text, source: recap.text) ? .condensed(text) : .notShorter
    }
}
