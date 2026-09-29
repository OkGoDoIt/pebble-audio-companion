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
    /// Read-change-write under the store's own lock. Supplied by the composition root
    /// (`FilePersonalContextStore.mutate`); nil falls back to `load()` … `save()`, which is what
    /// every construction did before this existed and is still fine for a single-writer test.
    private let mutate: (@Sendable ((inout PersonalContext) -> Void) throws -> Void)?
    private let extractor: PersonalContextTermExtractor
    private let nowMs: @Sendable () -> Int64
    private let retryAfterMs: Int64
    private let log: @Sendable (String) -> Void
    /// Where the failure memory persists; nil keeps it in memory (tests).
    private let failureFileURL: URL?

    private var running = false
    private var lastFailure: Failure?

    /// The last failed extraction for a given profile text, and how many in a row. Persisted:
    /// in memory it was forgotten on every launch, and iOS launches this app many times a day —
    /// each launch re-ran the extraction for a model that had just failed it.
    struct Failure: Codable, Equatable {
        var hash: String
        var atMs: Int64
        var count: Int
    }

    /// The longest a failed extraction waits before it is tried again.
    public static let maxRetryAfterMs: Int64 = 6 * 60 * 60 * 1000

    /// `log` has no default on purpose: a silenced default is what hid four other seams in this
    /// codebase. Pass `{ _ in }` explicitly if a caller really wants silence.
    public init(
        load: @escaping @Sendable () -> PersonalContext,
        save: @escaping @Sendable (PersonalContext) throws -> Void,
        extractor: PersonalContextTermExtractor,
        nowMs: @escaping @Sendable () -> Int64,
        retryAfterMs: Int64 = 10 * 60 * 1000,
        mutate: (@Sendable ((inout PersonalContext) -> Void) throws -> Void)? = nil,
        failureFileURL: URL? = nil,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.load = load
        self.save = save
        self.mutate = mutate
        self.extractor = extractor
        self.nowMs = nowMs
        self.retryAfterMs = retryAfterMs
        self.failureFileURL = failureFileURL
        self.log = log
        self.lastFailure = failureFileURL.flatMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Failure.self, from: $0) }
        }
    }

    /// 10 minutes, doubling per failure in a row, to six hours.
    private func waitMs(afterFailures count: Int) -> Int64 {
        min(retryAfterMs << Int64(min(max(count - 1, 0), 10)), Self.maxRetryAfterMs)
    }

    private func recordFailure(hash: String) {
        let count = lastFailure?.hash == hash ? (lastFailure?.count ?? 0) + 1 : 1
        let failure = Failure(hash: hash, atMs: nowMs(), count: count)
        lastFailure = failure
        guard let failureFileURL, let data = try? JSONEncoder().encode(failure) else { return }
        try? FileManager.default.createDirectory(
            at: failureFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: failureFileURL, options: .atomic)
    }

    private func clearFailure() {
        lastFailure = nil
        if let failureFileURL { try? FileManager.default.removeItem(at: failureFileURL) }
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
            nowMs() - failure.atMs < waitMs(afterFailures: failure.count)
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
            recordFailure(hash: hash)
            return context.derivedTerms
        }
        guard !terms.isEmpty else {
            // Either the model is unavailable or it found nothing worth biasing on. Both are
            // retryable, and both are worth a line: "About You produced no terms" is otherwise
            // indistinguishable from "About You is empty".
            recordFailure(hash: hash)
            let nextMinutes = waitMs(afterFailures: lastFailure?.count ?? 1) / 60_000
            log(
                "personal-context terms: no terms extracted (model unavailable or no proper "
                    + "nouns); next try in \(nextMinutes) min")
            return context.derivedTerms
        }
        clearFailure()
        persist(terms: terms, hash: hash, expecting: hash)
        return terms
    }

    /// Writes back ONLY the derived-term fields, and only if the profile text is still the one
    /// the terms were extracted from — a contacts import or a bio edit that landed during the
    /// model call must not be clobbered, and terms must never be stamped with a hash that no
    /// longer describes them.
    ///
    /// The hash check alone was not enough, and could not be. It closes the window from the START
    /// of the model call to here; it cannot close the window INSIDE this function, between reading
    /// the document and writing it back. That is a real race and not a narrow one — this file has
    /// several independent writers (the About You editor, the Contacts import, the Calendar
    /// import, and this refresher), an import writes the whole document, and a term refresh
    /// finishing mid-import would put the pre-import version back, silently dropping every name
    /// that had just been imported. So the read and the write go through the store's own lock via
    /// `mutate` when one is wired, and the hash check moves inside it.
    ///
    /// `mutate` cannot abort, so a stale-hash refusal costs one rewrite of an unchanged document
    /// under the lock. That is a single small JSON file, at most once per refresh, on the rare
    /// path where the profile changed while the model was running.
    private func persist(terms: [String], hash: String?, expecting: String?) {
        let apply: @Sendable (inout PersonalContext) -> Void = { context in
            guard context.profileTextHash() == expecting else { return }
            context.derivedTerms = terms
            context.derivedTermsSourceHash = hash
        }
        do {
            if let mutate {
                try mutate(apply)
            } else {
                var latest = load()
                guard latest.profileTextHash() == expecting else { return }
                apply(&latest)
                try save(latest)
            }
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
