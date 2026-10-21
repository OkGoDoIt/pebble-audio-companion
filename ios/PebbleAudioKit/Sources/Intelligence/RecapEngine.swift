import Foundation
import GRDB
import AppDB
import SegmentStore

// Port of `app/.../DailyRecapWorker.kt` (DailyRecapEngine + LogicalDay) and the digest half of
// `core/ai/DailyDigestStore.kt`, per plan Part 4.5 "Recap engine":
//  - digests persist in the DB `recaps` table (dateKey PK) instead of digest files;
//  - the 5 AM logical-day key AND the excerpt timeLabels are computed in each segment's
//    RECORDED zone (Q16 / plan 6.4 — supersedes the KMP `currentSystemDefault()` behavior);
//  - the AI run is an injected closure (the mode router lives elsewhere), and every digest
//    write fans out through `onRecapSaved` so the search index can upsert `day-<dateKey>`.
// LogicalDay itself is AppDB's (`LogicalDay.dateKey(forMs:timeZoneID:)`, boundary hour 5).

/// End-of-day AI digest aggregating segment transcripts for one logical day.
public struct DailyRecap: Equatable, Sendable, Codable {
    public var dateKey: String
    public var text: String
    public var segmentIds: [String]
    public var provider: String?
    public var model: String?
    public var updatedAtMs: Int64
    /// The condensed second-pass summary the Today card shows when `text` runs long. Nil when
    /// the digest is already short enough, when the pass has not run yet, or when it ran and
    /// could not produce anything shorter — in all three cases the card shows `text` whole.
    public var shortText: String?
    /// `RecapCondenser.fingerprint` of the `text` the condense pass last COMPLETED against
    /// (whether or not it produced usable output). Two jobs: it stops the pass re-running on
    /// every refresh, and it stops a stale `shortText` being shown over a regenerated digest.
    public var shortOfHash: String?
    /// History's week-row text for the day (`DayBrief`): a phrase naming what the day was about,
    /// and one line under it. Nil until the brief pass has run, or when it ran and the answer was
    /// unusable — the row then falls back to a conversation title and the recap itself.
    public var headline: String?
    public var lineSummary: String?
    /// `RecapCondenser.fingerprint` of the `text` the brief pass last COMPLETED against, with the
    /// same two jobs as `shortOfHash`: it is asked once per recap text, and a headline written
    /// about superseded text is never shown over the new one.
    public var briefOfHash: String?

    public init(
        dateKey: String, text: String, segmentIds: [String] = [],
        provider: String? = nil, model: String? = nil, updatedAtMs: Int64 = 0,
        shortText: String? = nil, shortOfHash: String? = nil,
        headline: String? = nil, lineSummary: String? = nil, briefOfHash: String? = nil
    ) {
        self.dateKey = dateKey
        self.text = text
        self.segmentIds = segmentIds
        self.provider = provider
        self.model = model
        self.updatedAtMs = updatedAtMs
        self.shortText = shortText
        self.shortOfHash = shortOfHash
        self.headline = headline
        self.lineSummary = lineSummary
        self.briefOfHash = briefOfHash
    }
}

public enum RecapIndex {
    /// Search-index document id for a day digest. Regenerations of the same day MUST land on
    /// the same id so the index holds one entry per day, not a copy per refresh.
    public static func documentId(dateKey: String) -> String { "day-\(dateKey)" }
}

// MARK: - DailyRecapStore (DB-backed, recaps table)

public struct DailyRecapStore: Sendable {
    public let db: AppDatabase
    private let nowMs: @Sendable () -> Int64
    /// Told the day key after a recap or its day brief (the headline) is written — the one
    /// point the recap-ready notification listens at, so it never has to poll.
    private let didWrite: (@Sendable (String) async -> Void)?

    public init(
        db: AppDatabase,
        nowMs: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000)
        },
        didWrite: (@Sendable (String) async -> Void)? = nil
    ) {
        self.db = db
        self.nowMs = nowMs
        self.didWrite = didWrite
    }

    static func recap(from row: Row) -> DailyRecap? {
        let idsJson: String = row["segmentIds"]
        let ids = (try? JSONDecoder().decode([String].self, from: Data(idsJson.utf8))) ?? []
        return DailyRecap(
            dateKey: row["dateKey"], text: row["text"], segmentIds: ids,
            provider: row["provider"], model: row["model"], updatedAtMs: row["updatedAtMs"],
            shortText: row["shortText"], shortOfHash: row["shortOfHash"],
            headline: row["headline"], lineSummary: row["lineSummary"],
            briefOfHash: row["briefOfHash"])
    }

    /// Upserts by dateKey, stamping `updatedAtMs` with the store clock (KMP `save` stamped
    /// `createdAtMs` the same way). Returns the stamped recap.
    ///
    /// `shortText`/`shortOfHash` are written from the value like every other column, so a
    /// regenerated digest — which `DailyRecapEngine` builds without them — CLEARS the previous
    /// condensation rather than leaving a summary of superseded text on the card. The day's
    /// brief (`headline`/`lineSummary`/`briefOfHash`) is cleared the same way.
    @discardableResult
    public func save(_ recap: DailyRecap) async throws -> DailyRecap {
        var stamped = recap
        stamped.updatedAtMs = nowMs()
        let toWrite = stamped
        let idsJson = String(
            decoding: try JSONEncoder().encode(toWrite.segmentIds), as: UTF8.self)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO recaps
                        (dateKey, text, segmentIds, provider, model, updatedAtMs,
                         shortText, shortOfHash, headline, lineSummary, briefOfHash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(dateKey) DO UPDATE SET
                        text = excluded.text, segmentIds = excluded.segmentIds,
                        provider = excluded.provider, model = excluded.model,
                        updatedAtMs = excluded.updatedAtMs,
                        shortText = excluded.shortText, shortOfHash = excluded.shortOfHash,
                        headline = excluded.headline, lineSummary = excluded.lineSummary,
                        briefOfHash = excluded.briefOfHash
                    """,
                arguments: [
                    toWrite.dateKey, toWrite.text, idsJson, toWrite.provider, toWrite.model,
                    toWrite.updatedAtMs, toWrite.shortText, toWrite.shortOfHash,
                    toWrite.headline, toWrite.lineSummary, toWrite.briefOfHash,
                ]
            )
        }
        await didWrite?(toWrite.dateKey)
        return toWrite
    }

    /// Records the outcome of one day-brief pass WITHOUT touching the recap, guarded on the text
    /// it read exactly as `saveCondensation` is (a recap regenerated while the call was in
    /// flight keeps its own, still-owed, state). Nil fields record a COMPLETED attempt that
    /// produced nothing usable, so the same text is not asked about again.
    public func saveDayBrief(
        dateKey: String, sourceText: String, headline: String?, lineSummary: String?
    ) async throws {
        let hash = RecapCondenser.fingerprint(sourceText)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE recaps SET headline = ?, lineSummary = ?, briefOfHash = ?
                    WHERE dateKey = ? AND text = ?
                    """,
                arguments: [headline, lineSummary, hash, dateKey, sourceText]
            )
        }
        await didWrite?(dateKey)
    }

    /// Records the outcome of one condense pass WITHOUT touching the digest.
    ///
    /// Guarded on the source text: a digest regenerated while the condense call was in flight
    /// must not be given the summary of the text it replaced. The guard is the whole point of
    /// this being a separate statement rather than a `save` of a mutated value — a read-modify-
    /// write of the row would silently roll the newer digest back.
    ///
    /// `shortText` may be nil: that records a COMPLETED attempt that produced nothing usable,
    /// so the same digest is not re-sent to the model on every pipeline pass.
    public func saveCondensation(
        dateKey: String, sourceText: String, shortText: String?
    ) async throws {
        let hash = RecapCondenser.fingerprint(sourceText)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE recaps SET shortText = ?, shortOfHash = ?
                    WHERE dateKey = ? AND text = ?
                    """,
                arguments: [shortText, hash, dateKey, sourceText]
            )
        }
    }

    /// Digests long enough to want a condensed form and NOT yet condensed for their current
    /// text, newest first.
    ///
    /// `length()` is SQLite's character count on a TEXT value, so the cheap half of
    /// `RecapCondenser.needsPass` runs in the query and only a handful of rows are decoded.
    ///
    /// The query used to stop there, and take the eight newest long days whatever their state —
    /// so once eight recent days had been condensed, the ninth and older were never offered
    /// again, and the backup had 09-05 and 09-07…09-10 sitting long on their cards for good. The
    /// fingerprint cannot be computed in SQL, but its SUFFIX is the text's UTF-8 byte count
    /// (`RecapCondenser.fingerprint`), which can: a row whose stamp ends in a different count
    /// was stamped for other text and is still owed a pass. The caller's `needsPass` then
    /// confirms the few that come back.
    public func longestFirstCandidates(minCharacters: Int, limit: Int) async throws -> [DailyRecap]
    {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM recaps
                    WHERE length(text) > ?
                        AND (shortOfHash IS NULL
                            OR shortOfHash NOT LIKE ('%-' || length(CAST(text AS BLOB))))
                    ORDER BY dateKey DESC LIMIT ?
                    """,
                arguments: [minCharacters, limit]
            ).compactMap(Self.recap(from:))
        }
    }

    public func load(dateKey: String) async throws -> DailyRecap? {
        try await db.reader.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM recaps WHERE dateKey = ?", arguments: [dateKey]
            ).flatMap(Self.recap(from:))
        }
    }

    /// Newest first (the current logical day backs the visible Today recap).
    public func list() async throws -> [DailyRecap] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM recaps ORDER BY updatedAtMs DESC, dateKey DESC"
            ).compactMap(Self.recap(from:))
        }
    }

    public func delete(dateKey: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM recaps WHERE dateKey = ?", arguments: [dateKey])
        }
    }

    public func deleteAll() async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM recaps")
        }
    }

    /// The Today card's live view of one day's recap.
    public func observe(dateKey: String) -> AsyncValueObservation<DailyRecap?> {
        ValueObservation.tracking { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM recaps WHERE dateKey = ?", arguments: [dateKey]
            ).flatMap(Self.recap(from:))
        }.values(in: db.reader)
    }
}

/// A day's recap failed. What the pipeline's `.recap` stage records — the classified kind, never
/// the provider's own message (an OpenAI 401 body quotes the request and part of the key, and
/// `PipelineHealthMonitor` writes whatever it is given to the flight recorder). The detail is
/// in the engine's own log line, key-redacted.
public struct RecapGenerationFailed: Error, Equatable, CustomStringConvertible {
    public let dateKey: String
    public let kind: AiFailureKind

    public init(dateKey: String, kind: AiFailureKind) {
        self.dateKey = dateKey
        self.kind = kind
    }

    public var description: String { "recap for \(dateKey) failed (\(kind.rawValue))" }
}

extension Array where Element: Hashable {
    /// First occurrences, in order.
    func uniquedInOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - DailyRecapEngine

/// Keeps one rolling AI digest per logical day (5 AM – 5 AM, Q16 recorded-zone) built from
/// closed, transcribed segments. A day's digest regenerates whenever new transcripts land for
/// it — debounced to `minRefreshIntervalMs` — so the Today recap follows the day instead of
/// freezing on the first conversation of the morning. Runs on a slow interval and after
/// transcription/enrichment passes (`refreshDigests()` is the post-pass trigger).
///
/// A day longer than the first provider can read in one call is recapped MAP-REDUCE: its
/// recordings are cut, in order, into pieces that fit, each piece is recapped with the same
/// prompt, and the partial recaps — labelled with the recordings they cover — are recapped once
/// more into the day's. It used to be one call whatever the day's size, and on 2026-09-22 and 23
/// that one call reached the on-device model, which read the first ~8,000 of ~232,000 and
/// ~285,000 characters and wrote a recap of the morning that was saved as covering all 51 and 45
/// recordings. A day is never saved from an input a provider cut (`AiInputPolicy` refuses the
/// daily summary rather than cutting it), and a day whose recap FAILED waits out a backoff
/// instead of being re-sent whole on every pass.
public actor DailyRecapEngine {
    public typealias RunAi = @Sendable (AiRunRequest) async throws -> RoutedAiResult

    /// Async so the production wiring can answer from `SegmentStore`'s in-memory index rather
    /// than parsing every sidecar off disk on each refresh.
    private let listSegments: @Sendable () async -> [SegmentMeta]
    private let transcriptTextOf: @Sendable (String) -> String?
    private let store: DailyRecapStore
    /// Nil = no AI configured; refresh passes are no-ops (mirrors the KMP nil router).
    private let run: RunAi?
    /// The DailySummary template, injected so this file has no dependency on the prompt
    /// catalog.
    private let prompt: AiPromptTemplate
    /// Receives every digest write so callers can fan it out (search index upsert of
    /// `RecapIndex.documentId`, diagnostics).
    private let onRecapSaved: @Sendable (DailyRecap) async -> Void
    private let fallbackTimeZoneID: String
    private let nowMs: @Sendable () -> Int64
    private let intervalMs: Int64
    private let minRefreshIntervalMs: Int64
    private let maxGenerationsPerRefresh: Int
    private let maxCondensationsPerRefresh: Int
    /// Diagnostics for the condense pass. Whether the Today card is long because the pass has
    /// not run, because the provider was down, or because the model would not shorten the day
    /// is invisible from the outside — and it was unanswerable from the flight recorder, which
    /// is where a question about a shipped build gets answered.
    private let log: @Sendable (String) -> Void
    private let sleepMs: @Sendable (Int64) async throws -> Void
    /// Characters of transcript the provider that runs FIRST can be handed in one call
    /// (`AiModeRouter.firstCallInputChars`), asked per refresh because the mode and the model
    /// can change. Nil — or a nil answer — means one call per day whatever its size, as before.
    private let singleCallCapacityChars: (@Sendable () async -> Int?)?

    /// Days whose segment set was fully handled by a previous pass (digest current, or nothing
    /// usable yet). Lets the steady-state pass skip per-day digest/transcript reads entirely.
    private var settledDays: [String: Set<SegmentFingerprint>] = [:]

    /// Days whose last recap attempt FAILED, and when they may be tried again. The debounce
    /// below is keyed on the last SUCCESS, so without this a day whose provider kept failing
    /// was re-sent whole on every pass. In memory: a relaunch costs one attempt, not a loop.
    private var failures: [String: DayFailure] = [:]

    /// Partial recaps of a map-reduce day that is still being built, by day and by the
    /// fingerprint of the piece they cover. A long day on the on-device model is dozens of
    /// calls; they are spread over several refreshes (`maxGenerationsPerRefresh` calls each),
    /// and a piece whose recordings have not changed is never recapped twice.
    private var partials: [String: [String: PartialRecap]] = [:]

    struct DayFailure: Equatable {
        var count: Int
        var nextAttemptAtMs: Int64
    }

    struct PartialRecap: Equatable {
        /// "2026-09-22 08:02" — the first recording the piece covers.
        let from: String
        /// The last recording's start.
        let to: String
        let text: String
        let providerId: String
        let modelUsed: String?
    }

    /// Serialization chain: refreshes never overlap (the KMP engine's refresh mutex).
    private var refreshChain: Task<Bool, Error>?
    private var loopTask: Task<Void, Never>?

    struct SegmentFingerprint: Hashable {
        let segmentId: String
        let state: TranscriptionState
    }

    public init(
        listSegments: @escaping @Sendable () async -> [SegmentMeta],
        transcriptTextOf: @escaping @Sendable (String) -> String?,
        store: DailyRecapStore,
        run: RunAi?,
        prompt: AiPromptTemplate,
        onRecapSaved: @escaping @Sendable (DailyRecap) async -> Void = { _ in },
        fallbackTimeZoneID: String = TimeZone.current.identifier,
        nowMs: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000)
        },
        intervalMs: Int64 = 15 * 60 * 1000,
        minRefreshIntervalMs: Int64 = 30 * 60 * 1000,
        maxGenerationsPerRefresh: Int = DailyRecapEngine.defaultMaxGenerationsPerRefresh,
        maxCondensationsPerRefresh: Int = DailyRecapEngine.defaultMaxCondensationsPerRefresh,
        log: @escaping @Sendable (String) -> Void = { _ in },
        sleepMs: @escaping @Sendable (Int64) async throws -> Void = { ms in
            try await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
        },
        singleCallCapacityChars: (@Sendable () async -> Int?)? = nil
    ) {
        self.singleCallCapacityChars = singleCallCapacityChars
        self.listSegments = listSegments
        self.transcriptTextOf = transcriptTextOf
        self.store = store
        self.run = run
        self.prompt = prompt
        self.onRecapSaved = onRecapSaved
        self.fallbackTimeZoneID = fallbackTimeZoneID
        self.nowMs = nowMs
        self.intervalMs = intervalMs
        self.minRefreshIntervalMs = minRefreshIntervalMs
        self.maxGenerationsPerRefresh = maxGenerationsPerRefresh
        self.maxCondensationsPerRefresh = maxCondensationsPerRefresh
        self.log = log
        self.sleepMs = sleepMs
    }

    /// How many AI calls one refresh may make before yielding — one per day recapped in a single
    /// call, one per piece or merge of a map-reduce day. Steady state never hits this (only the
    /// current day is ever due), but a freshly migrated library is due for every day it holds —
    /// dozens — and a long day on the on-device model is dozens of calls on its own, and this
    /// pass runs inline in the processing pass. Bounding it keeps one pass from monopolising the
    /// pipeline while the backlog drains newest-day-first over the following passes; unfinished
    /// days stay unsettled (and a map-reduce day keeps its finished pieces), so nothing is
    /// skipped and nothing is recapped twice.
    public static let defaultMaxGenerationsPerRefresh = 4

    /// The first wait after a day's recap failed; doubles per consecutive failure.
    public static let firstFailureBackoffMs: Int64 = 30 * 60_000
    /// Ceiling for that wait.
    public static let maxFailureBackoffMs: Int64 = 6 * 60 * 60_000

    static func failureBackoffMs(afterFailures count: Int) -> Int64 {
        min(firstFailureBackoffMs << Int64(min(max(count - 1, 0), 8)), maxFailureBackoffMs)
    }

    /// Every failed day may be tried again now — the AI configuration changed (a key, a mode, a
    /// model, a held account taking work again), so a different answer is possible.
    public func resetFailureBackoff() {
        failures.removeAll()
    }

    /// Starts the slow 15-minute loop. Idempotent while running.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [intervalMs, sleepMs] in
            while !Task.isCancelled {
                _ = try? await self.refreshDigests()
                do { try await sleepMs(intervalMs) } catch { break }
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// How many digests one refresh may CONDENSE before yielding, and how deep it looks for
    /// them. Two, because the only digest that grows during a day is the current one and the
    /// day before it can still be re-generated by a late transcript; a migrated library's older
    /// long days drain over the following passes, newest first, like the digests themselves.
    public static let defaultMaxCondensationsPerRefresh = 2
    static let condensationCandidateDepth = 8

    /// Rebuilds any logical-day digest whose segment set changed, then condenses any digest
    /// that came out longer than the Today card can carry. Serialized: concurrent calls queue
    /// behind the in-flight pass instead of interleaving.
    ///
    /// Throws when a day's recap FAILED (`RecapGenerationFailed`), so the pipeline's `.recap`
    /// stage records it: this used to be swallowed (`try?` in `RecapService`), and Diagnostics
    /// had no way to know the recap had been failing for days. `onProgress` fires after every
    /// AI call, so a long map-reduce day is progress to the loop watchdog rather than a wedge.
    ///
    /// Honours cancellation: the work runs in a serialization `Task`, which does not inherit the
    /// caller's cancellation, so a pass that was cancelled (background entry, a loop restart)
    /// used to wait for a whole day's recap to finish anyway.
    ///
    /// Returns whether it wrote anything — a digest or a condensation. The pass reads that to
    /// know History's day headlines and briefs have something new to read (`.briefs`), instead
    /// of that stage re-reading every recap on every pass to find out.
    @discardableResult
    public func refreshDigests(onProgress: (@Sendable () -> Void)? = nil) async throws -> Bool {
        let previous = refreshChain
        let task = Task { () throws -> Bool in
            _ = try? await previous?.value
            let saved = try await self.performRefresh(onProgress: onProgress)
            let condensed = try await self.performCondensation()
            return saved || condensed
        }
        refreshChain = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The second pass: a shorter form of any digest that overran, for the Today card.
    ///
    /// Never throws into the caller's pass — a condensation is a nicety, and the card falls
    /// back to the full digest without it. A THROWN provider error is deliberately not recorded
    /// as an attempt, so an afternoon without connectivity does not permanently strand a day on
    /// its long form; only a completed call stamps the fingerprint.
    private func performCondensation() async throws -> Bool {
        guard let run else { return false }
        let candidates = try await store.longestFirstCandidates(
            minCharacters: RecapCondenser.mediumParagraphCharacters,
            limit: Self.condensationCandidateDepth)
        var condensed = 0
        var wrote = false
        for recap in candidates {
            if condensed >= maxCondensationsPerRefresh { break }
            try Task.checkCancellation()
            guard RecapCondenser.needsPass(recap) else { continue }
            let outcome: RecapCondenser.Outcome
            do {
                outcome = try await RecapCondenser.condense(recap, run: run, nowMs: nowMs())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Provider down / no consent / out of quota. Leave the day unstamped so the
                // next pass tries again, and stop: the rest would fail the same way.
                log("recap condense failed \(recap.dateKey) — \(error.localizedDescription)")
                return wrote
            }
            condensed += 1
            switch outcome {
            case .condensed(let text):
                log("recap condensed \(recap.dateKey) \(recap.text.count) → \(text.count) chars")
                try await store.saveCondensation(
                    dateKey: recap.dateKey, sourceText: recap.text, shortText: text)
                wrote = true
            case .notShorter:
                log("recap condense refused \(recap.dateKey) — not shorter than \(recap.text.count) chars")
                try await store.saveCondensation(
                    dateKey: recap.dateKey, sourceText: recap.text, shortText: nil)
            }
        }
        return wrote
    }

    private func performRefresh(onProgress: (@Sendable () -> Void)?) async throws -> Bool {
        guard let run else { return false }
        var wrote = false
        let segments = await listSegments().filter { !$0.isOpen }
        var byDay: [String: [SegmentMeta]] = [:]
        for meta in segments {
            byDay[dayKey(of: meta), default: []].append(meta)
        }
        // Newest day first: the current logical day is the user-visible Today recap, and a
        // migration backlog therefore fills in from today backwards.
        var calls = 0
        for (day, daySegments) in byDay.sorted(by: { $0.key > $1.key }) {
            if calls >= maxGenerationsPerRefresh { break }
            try Task.checkCancellation()
            let fingerprint = Set(daySegments.map {
                SegmentFingerprint(segmentId: $0.segmentId, state: $0.transcriptionState)
            })
            if settledDays[day] == fingerprint { continue }
            // A day whose recap failed waits out its backoff. Skipped, not settled: its
            // segments have not been handled, and the next pass after the wait tries again.
            if let failure = failures[day], nowMs() < failure.nextAttemptAtMs { continue }
            if let existing = try await store.load(dateKey: day) {
                // The debounce FIRST, and only then the transcripts. It used to be the other
                // way round, so every pass inside the 30-minute window decoded the day's new
                // recordings to learn something the clock had already decided.
                if nowMs() - existing.updatedAtMs < minRefreshIntervalMs { continue }
                let covered = Set(existing.segmentIds)
                let fresh = daySegments.filter { !covered.contains($0.segmentId) }
                // Only genuinely new transcript content justifies an AI rerun: segments removed
                // by retention must never churn (or degrade) an already-complete digest, and
                // no-speech segments never become content.
                let hasNewContent = fresh.contains { meta in
                    let text = transcriptTextOf(meta.segmentId)
                    return !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if !hasNewContent {
                    settledDays[day] = fingerprint
                    continue
                }
            }
            let excerpts = daySegments
                // Ordered on the same anchor they are bucketed and labelled with. Sorting on
                // the raw `startTimeMs` ordered the day's recordings by when their STREAMS
                // began, which is a different sequence entirely once a stream spans a day: over
                // the 2026-09-08 backup 602 of 774 segments carry an anchor that is not their
                // own, 594 of them by more than a minute. A recap read out of order narrates
                // the evening before the morning.
                .sorted { $0.startWallMs < $1.startWallMs }
                .compactMap { meta -> TranscriptExcerpt? in
                    guard
                        let text = transcriptTextOf(meta.segmentId)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        !text.isEmpty
                    else { return nil }
                    // `startTimeMs` anchors the STREAM, not this segment: on a resumed or
                    // rotated segment the two differ by a median of 1 h and a max of 24.4 h.
                    let startMs = meta.startWallMs
                    return TranscriptExcerpt(
                        segmentId: meta.segmentId,
                        text: text,
                        startTimeMs: startMs,
                        timeLabel: timeLabel(epochMs: startMs, timeZoneID: zoneID(of: meta)))
                }
            if excerpts.isEmpty {
                settledDays[day] = fingerprint
                continue
            }
            let written: PartialRecap
            do {
                guard
                    let recap = try await recapDay(
                        day, excerpts: excerpts, run: run, calls: &calls, onProgress: onProgress)
                else {
                    // A map-reduce day that used up this refresh's calls. Its finished pieces
                    // are kept; the next refresh carries on from them.
                    break
                }
                written = recap
            } catch let error where error is CancellationError {
                throw error
            } catch {
                throw noteFailure(day, error)
            }
            let saved = try await store.save(
                DailyRecap(
                    dateKey: day,
                    text: written.text,
                    // Every recording of the day was read — in one call, or piece by piece.
                    segmentIds: excerpts.map(\.segmentId).uniquedInOrder(),
                    provider: written.providerId,
                    model: written.modelUsed))
            settledDays[day] = fingerprint
            failures[day] = nil
            partials[day] = nil
            wrote = true
            await onRecapSaved(saved)
        }
        return wrote
    }

    // MARK: - One day

    /// The day's recap: one call when the day fits the first provider, map-reduce when it does
    /// not. Nil when a map-reduce day ran out of this refresh's calls before it finished.
    private func recapDay(
        _ day: String, excerpts: [TranscriptExcerpt], run: RunAi, calls: inout Int,
        onProgress: (@Sendable () -> Void)?
    ) async throws -> PartialRecap? {
        let capacity = await singleCallCapacityChars?()
        let budget = capacity.map { Self.chunkBudget(capacity: $0, userPrompt: prompt.userPrompt) }
        guard let budget, Self.renderedChars(excerpts) > budget else {
            calls += 1
            let result = try await run(
                AiRunRequest(
                    requestId: "digest-\(day)-\(nowMs())", prompt: prompt, transcripts: excerpts))
            onProgress?()
            return try Self.partial(result, from: excerpts)
        }

        // Map: each piece of the day, in order, recapped on its own — unless an earlier
        // refresh already did it for exactly these recordings.
        let pieces = Self.chunk(excerpts, budget: budget)
        var cache = partials[day] ?? [:]
        var level: [PartialRecap] = []
        var live: [String: PartialRecap] = [:]
        for (index, piece) in pieces.enumerated() {
            let key = Self.fingerprint(piece)
            if let done = cache[key] {
                level.append(done)
                live[key] = done
                continue
            }
            guard calls < maxGenerationsPerRefresh else {
                partials[day] = live.merging(cache) { kept, _ in kept }
                return nil
            }
            calls += 1
            let result = try await run(
                AiRunRequest(
                    requestId: "digest-\(day)-part-\(index + 1)-of-\(pieces.count)-\(nowMs())",
                    prompt: prompt, transcripts: piece))
            onProgress?()
            let partial = try Self.partial(result, from: piece)
            cache[key] = partial
            live[key] = partial
            level.append(partial)
        }
        log("recap \(day): read in \(pieces.count) pieces of up to \(budget) characters")

        // Reduce: the partial recaps, labelled with the recordings they cover, recapped into the
        // day's — in rounds, if even the partials are more than one call can hold.
        let merge = Self.mergePrompt(prompt)
        for round in 0..<Self.maxMergeRounds {
            let groups = Self.group(level, budget: budget, userPrompt: merge.userPrompt)
            var next: [PartialRecap] = []
            for (index, group) in groups.enumerated() {
                if group.count == 1, groups.count > 1 {
                    next.append(group[0])
                    continue
                }
                let body = Self.render(group)
                let key = "merge-\(round)-" + RecapCondenser.fingerprint(body)
                if let done = cache[key] {
                    next.append(done)
                    live[key] = done
                    continue
                }
                guard calls < maxGenerationsPerRefresh else {
                    partials[day] = live.merging(cache) { kept, _ in kept }
                    return nil
                }
                calls += 1
                let result = try await run(
                    AiRunRequest(
                        requestId: "digest-\(day)-merge-\(round + 1)-\(index + 1)-\(nowMs())",
                        prompt: merge,
                        transcripts: [
                            TranscriptExcerpt(
                                segmentId: AiTranscriptFormatting.prebuiltSegmentId, text: body)
                        ]))
                onProgress?()
                guard !result.inputTruncated else { throw Self.cutInput(day) }
                let merged = PartialRecap(
                    from: group.first?.from ?? "", to: group.last?.to ?? "",
                    text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    providerId: result.providerId, modelUsed: result.modelUsed)
                cache[key] = merged
                live[key] = merged
                next.append(merged)
            }
            if groups.count == 1 { return next.first }
            level = next
        }
        throw AiError.providerFailed(
            "The recap of \(day) did not come together in \(Self.maxMergeRounds) rounds of merging")
    }

    /// Rounds of merging before a day is given up on. Each round divides the partials by the
    /// number that fit one call (dozens), so two is already more than any real day needs.
    static let maxMergeRounds = 4

    /// The recap of one call's input, refusing one the provider cut: a recap is saved as
    /// covering every recording it was handed, so it may only be written from all of them.
    private static func partial(
        _ result: RoutedAiResult, from excerpts: [TranscriptExcerpt]
    ) throws -> PartialRecap {
        guard !result.inputTruncated else {
            throw cutInput(excerpts.first.flatMap(\.timeLabel) ?? "this day")
        }
        return PartialRecap(
            from: excerpts.first?.timeLabel ?? "", to: excerpts.last?.timeLabel ?? "",
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            providerId: result.providerId, modelUsed: result.modelUsed)
    }

    private static func cutInput(_ what: String) -> AiError {
        .providerFailed("The provider read only part of the recordings for \(what); not saved")
    }

    /// Records a failed day and returns what the caller throws: the day waits out a backoff
    /// (30 minutes, doubling to 6 hours) and the refresh stops — the days behind it would ask
    /// the same failing provider the same question. The error the pipeline records is the
    /// CLASSIFIED one, never the provider's raw body.
    private func noteFailure(_ day: String, _ error: Error) -> RecapGenerationFailed {
        let count = (failures[day]?.count ?? 0) + 1
        let wait = Self.failureBackoffMs(afterFailures: count)
        failures[day] = DayFailure(count: count, nextAttemptAtMs: nowMs() + wait)
        let kind = AiFailure.classify(error).kind
        log(
            "recap \(day) failed (\(kind.rawValue)); next try in \(wait / 60_000) min — "
                + AiFailureLog.detail(of: error).prefix(200))
        return RecapGenerationFailed(dateKey: day, kind: kind)
    }

    // MARK: - Cutting a day into pieces

    /// Characters of transcript one call's excerpts may add up to: the provider's figure, less
    /// a tenth for the estimate's error, less the prompt's own instruction line.
    static func chunkBudget(capacity: Int, userPrompt: String) -> Int {
        max(1_000, capacity * 9 / 10 - userPrompt.count - 2)
    }

    /// What `AiTranscriptFormatting` spends on one excerpt beyond its text: the
    /// "--- Transcript segment <id> (starts <label>) ---" header and the blank line after.
    static func excerptCost(_ excerpt: TranscriptExcerpt) -> Int {
        excerpt.text.count + 40 + excerpt.segmentId.count + (excerpt.timeLabel?.count ?? 0)
    }

    static func renderedChars(_ excerpts: [TranscriptExcerpt]) -> Int {
        excerpts.reduce(0) { $0 + excerptCost($1) }
    }

    /// Consecutive pieces of the day, each within `budget`. Order is never disturbed, and a
    /// single recording longer than a piece is split at word boundaries into parts of its own —
    /// a fifteen-minute recording is about 13,000 characters, more than the iOS 26 on-device
    /// model can take at once.
    static func chunk(_ excerpts: [TranscriptExcerpt], budget: Int) -> [[TranscriptExcerpt]] {
        var pieces: [[TranscriptExcerpt]] = []
        var current: [TranscriptExcerpt] = []
        var used = 0
        for excerpt in excerpts.flatMap({ split($0, budget: budget) }) {
            let cost = excerptCost(excerpt)
            if !current.isEmpty, used + cost > budget {
                pieces.append(current)
                current = []
                used = 0
            }
            current.append(excerpt)
            used += cost
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// One recording, as parts that each fit `budget`, cut at whitespace.
    static func split(_ excerpt: TranscriptExcerpt, budget: Int) -> [TranscriptExcerpt] {
        let room = max(200, budget - (excerptCost(excerpt) - excerpt.text.count))
        guard excerpt.text.count > room else { return [excerpt] }
        var parts: [TranscriptExcerpt] = []
        var rest = Substring(excerpt.text)
        while !rest.isEmpty {
            var cut = rest.index(rest.startIndex, offsetBy: room, limitedBy: rest.endIndex)
                ?? rest.endIndex
            if cut < rest.endIndex,
                let space = rest[rest.startIndex..<cut].lastIndex(where: { $0.isWhitespace }),
                rest.distance(from: rest.startIndex, to: space) > room / 2
            {
                cut = space
            }
            let text = rest[rest.startIndex..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(
                    TranscriptExcerpt(
                        segmentId: excerpt.segmentId, text: text,
                        startTimeMs: excerpt.startTimeMs, endTimeMs: excerpt.endTimeMs,
                        timeLabel: excerpt.timeLabel))
            }
            rest = rest[cut...].drop(while: { $0.isWhitespace })
        }
        return parts
    }

    /// Identifies a piece by the recordings and the words in it, so a piece recapped by an
    /// earlier refresh is reused and a piece that changed is not.
    static func fingerprint(_ piece: [TranscriptExcerpt]) -> String {
        RecapCondenser.fingerprint(
            piece.map { "\($0.segmentId)\u{1}\($0.text)" }.joined(separator: "\u{2}"))
    }

    // MARK: - Merging

    /// The same daily-summary template — so the same output budget and the same whole-input
    /// rule apply — asked to combine partial recaps instead of reading transcripts.
    static func mergePrompt(_ base: AiPromptTemplate) -> AiPromptTemplate {
        AiPromptTemplate(
            id: base.id, title: base.title, systemPrompt: base.systemPrompt,
            userPrompt: "These are recaps of consecutive parts of this one day, in order, each "
                + "labelled with the recordings it covers. Combine them into a single recap of "
                + "the whole day under the same rules. Do not mention the parts.")
    }

    static func render(_ group: [PartialRecap]) -> String {
        group.map { "Recordings from \($0.from) to \($0.to):\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    /// Consecutive partials, grouped so each group's rendering fits `budget`.
    static func group(
        _ level: [PartialRecap], budget: Int, userPrompt: String
    ) -> [[PartialRecap]] {
        var groups: [[PartialRecap]] = []
        var current: [PartialRecap] = []
        for partial in level {
            if !current.isEmpty, render(current + [partial]).count + userPrompt.count > budget {
                groups.append(current)
                current = []
            }
            current.append(partial)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func zoneID(of meta: SegmentMeta) -> String {
        meta.recordedTimeZone ?? fallbackTimeZoneID
    }

    private func dayKey(of meta: SegmentMeta) -> String {
        LogicalDay.dateKey(forMs: meta.startWallMs, timeZoneID: zoneID(of: meta))
    }

    /// "YYYY-MM-DD HH:mm" in the segment's recorded zone (Q16 / plan 6.4).
    private func timeLabel(epochMs: Int64, timeZoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return formatter.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000))
    }
}
