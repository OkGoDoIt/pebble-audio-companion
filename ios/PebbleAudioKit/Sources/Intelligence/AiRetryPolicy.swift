import Foundation

// When a background AI job that failed may be tried again.
//
// WHY THIS EXISTS (2026-09-29)
//
// The enrichment worker gave a conversation three final attempts, with no time between them,
// and nothing ever reset the count; the follow-up curator the same; a candidate that used up its
// attempts stayed `pending` forever. So three passes during a flight — seconds apart — cost a
// conversation its title for the life of the database, and a rate-limited minute cost a batch
// of follow-ups their curation for good. The transcription side had already met this exact
// shape (`TranscriptionFailureKind.isWorthRevisiting`, the six-hour revival sweep).
//
// The rules, shared by every AI worker so they cannot drift:
//
//   • only a failure that BLAMES THE INPUT (`AiFailureKind.blamesTheInput`) spends a job's
//     attempt budget, and it waits `contentRetryMs` before the next one;
//   • a failure that is the world's (network, a busy or broke account, a model still loading)
//     spends nothing and backs off in time: 15 minutes, doubling, to 6 hours;
//   • a job that used its whole budget rests `exhaustedRetryMs` and is then tried again —
//     never abandoned;
//   • an answer a fallback wrote from part of the input (`RoutedAiResult.isProvisional`) is
//     kept on screen but not finalized, and redone after `provisionalRetryMs`;
//   • a change of AI key, mode, remote provider or model — or a held account taking work
//     again — resets all of it, because a different answer is now possible.

public enum AiRetryPolicy {
    /// First wait after a failure that was not the input's fault.
    public static let firstTransientRetryMs: Int64 = 15 * 60_000
    /// Ceiling for every wait here — the same six hours `FollowUpWorker.retryAfterMs` and the
    /// transcription revival sweep use.
    public static let maxRetryMs: Int64 = 6 * 60 * 60_000
    /// Between two attempts that each failed on the input itself. Long enough that a burst of
    /// passes cannot spend a whole budget in seconds.
    public static let contentRetryMs: Int64 = 10 * 60_000
    /// How long a job that spent its whole budget rests before it is tried again.
    public static let exhaustedRetryMs: Int64 = maxRetryMs
    /// When a provisional answer is redone. An hour: long enough that a fallback is not re-run
    /// on every pass, short enough that the preferred provider's answer replaces it the same
    /// day. A held account that takes work again resets it at once.
    public static let provisionalRetryMs: Int64 = 60 * 60_000

    /// 15 min, 30 min, 1 h, 2 h, 4 h, then 6 h — after `consecutive` failures that were the
    /// world's (1 for the first).
    public static func transientRetryMs(consecutive: Int) -> Int64 {
        let shift = Int64(min(max(consecutive - 1, 0), 5))
        return min(firstTransientRetryMs << shift, maxRetryMs)
    }

    /// Whether `error` may spend an attempt from a job's budget.
    public static func spendsAttempt(_ error: Error) -> Bool {
        AiFailure.classify(error).kind.blamesTheInput
    }
}
