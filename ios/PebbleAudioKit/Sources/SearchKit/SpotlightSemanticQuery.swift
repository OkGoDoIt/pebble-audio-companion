import Foundation
#if canImport(CoreSpotlight)
    import CoreSpotlight
#endif

// Semantic recall over the OS search index, for Ask.
//
// Ask reads the whole scope when it fits and sweeps it in batches when it does not; only past
// the sweep ceiling does relevance decide which batches to sacrifice (`AskCorpusPlanner`). That
// decision used to rest on the FTS index alone — a keyword match against titles, summaries,
// tags and transcript words — so a conversation whose relevance was not in its wording was
// dropped without a trace. Core Spotlight ranks the same donated items semantically (WWDC24
// "Support semantic search with Core Spotlight"): `CSUserQuery` over this app's own index, on
// device, no network. This file is the seam and the production implementation; the planner
// decides how the two signals combine, and it is ADDITIVE by policy — see `AskRecallPolicy`.
//
// SearchKit must not depend on Intelligence, so the hit type is defined here and the app maps
// it onto the retriever's own shape at the composition root.

/// One ranked hit from a semantic pass over the OS index: a conversation id (`conv-…`) and a
/// rank-derived score in (0, 1]. `CSUserQuery` exposes an order, not a number, so the score is
/// a monotone function of rank and comparable across queries only in that sense.
public struct SemanticRecallHit: Equatable, Sendable {
    public let id: String
    public let score: Double

    public init(id: String, score: Double) {
        self.id = id
        self.score = score
    }
}

/// The seam Ask talks to. Production is `CoreSpotlightSemanticRecall`; tests use a fake.
public protocol SemanticRecall: Sendable {
    /// The best `limit` conversations for `query`, best first. Never throws and never stalls:
    /// an unavailable index, an invalid query or a slow one all come back as fewer hits.
    func rank(query: String, limit: Int) async -> [SemanticRecallHit]
}

/// The pure parts of the Spotlight query: id parsing, the domain filter and the rank-to-score
/// mapping. Kept off the actor so they can be pinned by tests without an OS index.
public enum SpotlightSemanticQuery {
    /// Reverse of the donation's `"<kind>:<entityId>"` unique identifier, for conversations
    /// only: `"conversation:conv-abc"` → `"conv-abc"`. Notes, recaps and follow-ups come back
    /// nil — a hit on one of those can never resolve to a recording, so it is not a candidate.
    public static func conversationId(fromUniqueIdentifier uniqueIdentifier: String) -> String? {
        guard let parsed = SpotlightDonation.parse(uniqueIdentifier: uniqueIdentifier),
            parsed.kind == .conversation
        else { return nil }
        return parsed.entityId
    }

    /// The `CSSearchQuery` predicate restricting a query to this app's donations. The query
    /// already sees only this app's index; the filter is belt and braces against anything else
    /// the process ever donates under another domain.
    public static func filterQuery(domainIdentifier: String) -> String {
        "domainIdentifier == \"\(domainIdentifier)\""
    }

    /// Ranked unique identifiers → hits. Non-conversation ids and duplicates drop out; the
    /// survivors score linearly by rank, `(limit - rank) / limit`, so the first is 1.0 and the
    /// score of a rank does not depend on how many others happened to come back.
    public static func hits(
        rankedUniqueIdentifiers: [String], limit: Int
    ) -> [SemanticRecallHit] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var hits: [SemanticRecallHit] = []
        for uniqueIdentifier in rankedUniqueIdentifiers {
            guard hits.count < limit,
                let id = conversationId(fromUniqueIdentifier: uniqueIdentifier),
                seen.insert(id).inserted
            else { continue }
            let rank = hits.count
            hits.append(
                SemanticRecallHit(id: id, score: Double(limit - rank) / Double(limit)))
        }
        return hits
    }
}

/// What the collector and the deadline hand back: whatever arrived, and whether the deadline
/// cut it short. Ask uses a partial list exactly as it would a complete one.
public struct SemanticRecallOutcome: Equatable, Sendable {
    public var uniqueIdentifiers: [String]
    public var timedOut: Bool

    public init(uniqueIdentifiers: [String], timedOut: Bool) {
        self.uniqueIdentifiers = uniqueIdentifiers
        self.timedOut = timedOut
    }
}

/// Collects ranked ids from a producer and lets exactly one of {producer finished, deadline
/// passed} release the waiter. The waiter is never awaited on the producer: when the deadline
/// fires the partial list is returned at once and the producer is left to wind down on its own,
/// which is what makes the timeout hard rather than advisory.
final class SemanticRecallCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    private var done = false
    private var timedOut = false
    private var waiter: CheckedContinuation<SemanticRecallOutcome, Never>?

    /// Appends and returns the new count, so the producer can stop at its limit.
    @discardableResult
    func append(_ id: String) -> Int {
        lock.withLock {
            guard !done else { return ids.count }
            ids.append(id)
            return ids.count
        }
    }

    /// First call wins; every later one is a no-op.
    func finish(timedOut: Bool) {
        let waiter: CheckedContinuation<SemanticRecallOutcome, Never>?
        let outcome: SemanticRecallOutcome
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        self.timedOut = timedOut
        outcome = SemanticRecallOutcome(uniqueIdentifiers: ids, timedOut: timedOut)
        waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: outcome)
    }

    /// Suspends until `finish` — or returns immediately if it already happened.
    func wait() async -> SemanticRecallOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if done {
                let outcome = SemanticRecallOutcome(uniqueIdentifiers: ids, timedOut: timedOut)
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

#if canImport(CoreSpotlight)
    /// Production semantic recall: `CSUserQuery` over this app's Core Spotlight index, the same
    /// donations `CoreSpotlightIndexer` makes (`kind:entityId` unique ids, our domain).
    ///
    /// An actor for the same reason `CoreSpotlightIndexer` is one: `CSUserQuery` is a
    /// thread-safe Objective-C class the framework has not marked `Sendable`, and isolating the
    /// handle says so without a `@preconcurrency` import. Each call builds its own query; the
    /// only shared state is the one-time `prepare()`.
    ///
    /// Semantic ranking is an OS capability, not something this code can switch on: on hardware
    /// or a runtime without it the same call returns lexical matches ranked by Spotlight, which
    /// is still a valid second signal. Whether the semantic path actually fired is measured, not
    /// assumed — see the `ask recall:` experiment line and the Diagnostics replay.
    public actor CoreSpotlightSemanticRecall: SemanticRecall {
        public static let defaultTimeout: Duration = .milliseconds(1_500)

        private let domainIdentifier: String?
        private let timeout: Duration
        private let log: (@Sendable (String) -> Void)?

        /// `domainIdentifier` nil drops the domain filter — for the DEBUG probe that tells a
        /// broken filter from an index that cannot be queried at all; production always
        /// filters.
        public init(
            domainIdentifier: String? = CoreSpotlightIndexer.domainIdentifier,
            timeout: Duration = CoreSpotlightSemanticRecall.defaultTimeout,
            log: (@Sendable (String) -> Void)? = nil
        ) {
            self.domainIdentifier = domainIdentifier
            self.timeout = timeout
            self.log = log
        }

        /// `CSUserQuery.prepare()` warms the ranking models once per process; a lazily
        /// evaluated static is the cheapest once-only there is, and it is thread-safe.
        private static let prepared: Void = { CSUserQuery.prepare() }()

        public nonisolated var isAvailable: Bool { CSSearchableIndex.isIndexingAvailable() }

        public func rank(query: String, limit: Int) async -> [SemanticRecallHit] {
            let outcome = await ranked(query: query, limit: limit)
            return SpotlightSemanticQuery.hits(
                rankedUniqueIdentifiers: outcome.uniqueIdentifiers, limit: limit)
        }

        /// The raw ranked unique identifiers, for the DEBUG probe that checks the semantic path
        /// on a real index. Everything Ask uses goes through `rank`.
        public func ranked(query: String, limit: Int) async -> SemanticRecallOutcome {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard limit > 0, !trimmed.isEmpty, CSSearchableIndex.isIndexingAvailable() else {
                return SemanticRecallOutcome(uniqueIdentifiers: [], timedOut: false)
            }
            _ = Self.prepared

            let context = CSUserQueryContext()
            // The unique identifier is on the item itself; no attributes need fetching.
            context.fetchAttributes = []
            if let domainIdentifier {
                context.filterQueries = [
                    SpotlightSemanticQuery.filterQuery(domainIdentifier: domainIdentifier)
                ]
            }
            context.enableRankedResults = true
            context.disableSemanticSearch = false
            context.maxResultCount = limit
            context.maxRankedResultCount = limit
            let userQuery = CSUserQuery(userQueryString: trimmed, userQueryContext: context)
            let responses = userQuery.responses

            let collector = SemanticRecallCollector()
            let started = ContinuousClock.now
            let log = self.log
            // Detached: the actor must not be held while the OS streams results in, and the
            // sequence is `Sendable` so nothing isolated crosses into the task.
            let producer = Task.detached(priority: .userInitiated) {
                do {
                    for try await response in responses {
                        guard case .item(let item) = response else { continue }
                        if collector.append(item.item.uniqueIdentifier) >= limit { break }
                    }
                } catch {
                    // Cancelled (ours, after the deadline) or a query the index refused:
                    // either way the partial list stands. Named, because an invalid query
                    // would otherwise look exactly like an index with nothing in it.
                    if !Task.isCancelled {
                        log?("ask semantic: query failed \((error as NSError).domain) "
                            + "\((error as NSError).code)")
                    }
                }
                collector.finish(timedOut: false)
            }
            let timeout = self.timeout
            let deadline = Task.detached {
                try? await Task.sleep(for: timeout)
                collector.finish(timedOut: true)
            }
            let outcome = await collector.wait()
            userQuery.cancel()
            producer.cancel()
            deadline.cancel()
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            log?(
                "ask semantic: hits=\(outcome.uniqueIdentifiers.count) limit=\(limit) "
                    + "ms=\(ms) timeout=\(outcome.timedOut)")
            return outcome
        }
    }
#endif
