import Foundation

/// The missing producer for `PersonalContext.derivedTerms`.
///
/// `PersonalContextTermExtractor` was ported whole and then never constructed, so
/// `derivedTerms` stayed permanently empty and `derivedTermsSourceHash` was never written.
/// The consequence was invisible: `PersonalContextFormatting.openAiSttPrompt` is built ONLY
/// from `transcriptionTerms` (derived terms + people + orgs + vocab), so a user on the OpenAI
/// backend who pasted an "About you" bio and never imported contacts sent `prompt = nil` —
/// zero name/jargon bias, which is exactly the accuracy the About You screen promises (plan
/// Part 4.5: "≤40 derived terms", "OpenAI STT prompt 800, keyword-list only"). Soniox was
/// unaffected because it receives the whole profile as `context.text` by another path, which
/// is why the hole never showed up as "About You does nothing".
///
/// Refreshing is deliberately cheap to ask for: it is hash-guarded (no model call while the
/// text is unchanged), single-flight, and backs off after a failure so an unavailable model is
/// not re-asked on every transcription. Call `refreshIfNeeded()` freely — at startup and from
/// the read sites — rather than trying to find the one moment the bio changed.
public actor PersonalContextTermRefresher {
    private let load: @Sendable () -> PersonalContext
    private let save: @Sendable (PersonalContext) throws -> Void
    private let extractor: PersonalContextTermExtractor
    private let nowMs: @Sendable () -> Int64
    private let retryAfterMs: Int64
    private let log: @Sendable (String) -> Void

    private var running = false
    private var lastFailure: (hash: String, atMs: Int64)?

    /// `log` has no default on purpose: a silenced default is what hid four other seams in this
    /// codebase. Pass `{ _ in }` explicitly if a caller really wants silence.
    public init(
        load: @escaping @Sendable () -> PersonalContext,
        save: @escaping @Sendable (PersonalContext) throws -> Void,
        extractor: PersonalContextTermExtractor,
        nowMs: @escaping @Sendable () -> Int64,
        retryAfterMs: Int64 = 10 * 60 * 1000,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.load = load
        self.save = save
        self.extractor = extractor
        self.nowMs = nowMs
        self.retryAfterMs = retryAfterMs
        self.log = log
    }

    /// Brings `derivedTerms` up to date with the pasted profile text. Never throws: a model
    /// that is unavailable (no consent, no on-device model, offline) leaves the cached terms
    /// exactly as they were and is retried after the cooldown.
    @discardableResult
    public func refreshIfNeeded() async -> [String] {
        let context = load()

        // No profile text: any cached terms describe text that no longer exists. Dropping them
        // needs no model call, so it happens even while one is in flight elsewhere.
        guard let hash = context.profileTextHash() else {
            if !context.derivedTerms.isEmpty || context.derivedTermsSourceHash != nil {
                persist(terms: [], hash: nil, expecting: nil)
            }
            return []
        }
        if context.derivedTermsSourceHash == hash, !context.derivedTerms.isEmpty {
            return context.derivedTerms
        }
        // Bias is off, so nothing downstream would read the terms: do not spend a model call.
        guard context.biasTranscription else { return [] }
        if running { return context.derivedTerms }
        if let failure = lastFailure, failure.hash == hash,
            nowMs() - failure.atMs < retryAfterMs
        {
            return context.derivedTerms
        }

        running = true
        defer { running = false }

        let terms: [String]
        do {
            terms = try await extractor.extract(profileText: context.profileText ?? "")
        } catch {
            // Only cancellation reaches here; the extractor swallows provider failures.
            lastFailure = (hash, nowMs())
            return context.derivedTerms
        }
        guard !terms.isEmpty else {
            // Either the model is unavailable or it found nothing worth biasing on. Both are
            // retryable, and both are worth a line: "About You produced no terms" is otherwise
            // indistinguishable from "About You is empty".
            lastFailure = (hash, nowMs())
            log("personal-context terms: no terms extracted (model unavailable or no proper nouns)")
            return context.derivedTerms
        }
        lastFailure = nil
        persist(terms: terms, hash: hash, expecting: hash)
        return terms
    }

    /// Writes back ONLY the derived-term fields, and only if the profile text is still the one
    /// the terms were extracted from — a contacts import or a bio edit that landed during the
    /// model call must not be clobbered, and terms must never be stamped with a hash that no
    /// longer describes them.
    private func persist(terms: [String], hash: String?, expecting: String?) {
        var latest = load()
        guard latest.profileTextHash() == expecting else { return }
        latest.derivedTerms = terms
        latest.derivedTermsSourceHash = hash
        do {
            try save(latest)
        } catch {
            log("personal-context terms: save failed: \(error)")
        }
    }
}

/// Late-bound trigger for a `PersonalContextTermRefresher`.
///
/// The refresher needs the AI router, which a composition root builds well after the closures
/// that read personal context for transcription. This handle lets those read sites ask for a
/// refresh without knowing when the refresher was created; before one is installed, `nudge()`
/// does nothing at all.
public final class PersonalContextTermRefreshHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var refresher: PersonalContextTermRefresher?

    public init() {}

    public func install(_ refresher: PersonalContextTermRefresher) {
        lock.withLock { self.refresher = refresher }
    }

    /// Fire-and-forget: the refresher itself decides whether there is anything to do.
    public func nudge() {
        guard let refresher = lock.withLock({ refresher }) else { return }
        Task { await refresher.refreshIfNeeded() }
    }
}
