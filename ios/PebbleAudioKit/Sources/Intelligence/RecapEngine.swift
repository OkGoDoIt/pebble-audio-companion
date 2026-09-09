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

    public init(
        dateKey: String, text: String, segmentIds: [String] = [],
        provider: String? = nil, model: String? = nil, updatedAtMs: Int64 = 0,
        shortText: String? = nil, shortOfHash: String? = nil
    ) {
        self.dateKey = dateKey
        self.text = text
        self.segmentIds = segmentIds
        self.provider = provider
        self.model = model
        self.updatedAtMs = updatedAtMs
        self.shortText = shortText
        self.shortOfHash = shortOfHash
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

    public init(
        db: AppDatabase,
        nowMs: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000)
        }
    ) {
        self.db = db
        self.nowMs = nowMs
    }

    static func recap(from row: Row) -> DailyRecap? {
        let idsJson: String = row["segmentIds"]
        let ids = (try? JSONDecoder().decode([String].self, from: Data(idsJson.utf8))) ?? []
        return DailyRecap(
            dateKey: row["dateKey"], text: row["text"], segmentIds: ids,
            provider: row["provider"], model: row["model"], updatedAtMs: row["updatedAtMs"],
            shortText: row["shortText"], shortOfHash: row["shortOfHash"])
    }

    /// Upserts by dateKey, stamping `updatedAtMs` with the store clock (KMP `save` stamped
    /// `createdAtMs` the same way). Returns the stamped recap.
    ///
    /// `shortText`/`shortOfHash` are written from the value like every other column, so a
    /// regenerated digest — which `DailyRecapEngine` builds without them — CLEARS the previous
    /// condensation rather than leaving a summary of superseded text on the card.
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
                         shortText, shortOfHash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(dateKey) DO UPDATE SET
                        text = excluded.text, segmentIds = excluded.segmentIds,
                        provider = excluded.provider, model = excluded.model,
                        updatedAtMs = excluded.updatedAtMs,
                        shortText = excluded.shortText, shortOfHash = excluded.shortOfHash
                    """,
                arguments: [
                    toWrite.dateKey, toWrite.text, idsJson, toWrite.provider, toWrite.model,
                    toWrite.updatedAtMs, toWrite.shortText, toWrite.shortOfHash,
                ]
            )
        }
        return toWrite
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

    /// Digests long enough to want a condensed form, newest first.
    ///
    /// `length()` is SQLite's character count on a TEXT value, so the cheap half of
    /// `RecapCondenser.needsPass` runs in the query and only a handful of rows are decoded.
    /// The fingerprint half cannot be expressed in SQL, so the caller filters what comes back.
    public func longestFirstCandidates(minCharacters: Int, limit: Int) async throws -> [DailyRecap]
    {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM recaps WHERE length(text) > ?
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

// MARK: - DailyRecapEngine

/// Keeps one rolling AI digest per logical day (5 AM – 5 AM, Q16 recorded-zone) built from
/// closed, transcribed segments. A day's digest regenerates whenever new transcripts land for
/// it — debounced to `minRefreshIntervalMs` — so the Today recap follows the day instead of
/// freezing on the first conversation of the morning. Runs on a slow interval and after
/// transcription/enrichment passes (`refreshDigests()` is the post-pass trigger).
public actor DailyRecapEngine {
    public typealias RunAi = @Sendable (AiRunRequest) async throws -> RoutedAiResult

    private let listSegments: @Sendable () -> [SegmentMeta]
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

    /// Days whose segment set was fully handled by a previous pass (digest current, or nothing
    /// usable yet). Lets the steady-state pass skip per-day digest/transcript reads entirely.
    private var settledDays: [String: Set<SegmentFingerprint>] = [:]

    /// Serialization chain: refreshes never overlap (the KMP engine's refresh mutex).
    private var refreshChain: Task<Void, Error>?
    private var loopTask: Task<Void, Never>?

    struct SegmentFingerprint: Hashable {
        let segmentId: String
        let state: TranscriptionState
    }

    public init(
        listSegments: @escaping @Sendable () -> [SegmentMeta],
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
        }
    ) {
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

    /// How many day digests one refresh may GENERATE before yielding. Steady state never hits
    /// this (only the current day is ever due), but a freshly migrated library is due for every
    /// day it holds — dozens — and this pass runs inline in the processing pass. Bounding it
    /// keeps one pass from monopolising the pipeline while the backlog drains newest-day-first
    /// over the following passes; unfinished days stay unsettled, so nothing is skipped.
    public static let defaultMaxGenerationsPerRefresh = 4

    /// Starts the slow 15-minute loop. Idempotent while running.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [intervalMs, sleepMs] in
            while !Task.isCancelled {
                try? await self.refreshDigests()
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
    public func refreshDigests() async throws {
        let previous = refreshChain
        let task = Task {
            _ = try? await previous?.value
            try await self.performRefresh()
            try await self.performCondensation()
        }
        refreshChain = task
        try await task.value
    }

    /// The second pass: a shorter form of any digest that overran, for the Today card.
    ///
    /// Never throws into the caller's pass — a condensation is a nicety, and the card falls
    /// back to the full digest without it. A THROWN provider error is deliberately not recorded
    /// as an attempt, so an afternoon without connectivity does not permanently strand a day on
    /// its long form; only a completed call stamps the fingerprint.
    private func performCondensation() async throws {
        guard let run else { return }
        let candidates = try await store.longestFirstCandidates(
            minCharacters: RecapCondenser.mediumParagraphCharacters,
            limit: Self.condensationCandidateDepth)
        var condensed = 0
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
                return
            }
            condensed += 1
            switch outcome {
            case .condensed(let text):
                log("recap condensed \(recap.dateKey) \(recap.text.count) → \(text.count) chars")
                try await store.saveCondensation(
                    dateKey: recap.dateKey, sourceText: recap.text, shortText: text)
            case .notShorter:
                log("recap condense refused \(recap.dateKey) — not shorter than \(recap.text.count) chars")
                try await store.saveCondensation(
                    dateKey: recap.dateKey, sourceText: recap.text, shortText: nil)
            }
        }
    }

    private func performRefresh() async throws {
        guard let run else { return }
        let segments = listSegments().filter { !$0.isOpen }
        var byDay: [String: [SegmentMeta]] = [:]
        for meta in segments {
            byDay[dayKey(of: meta), default: []].append(meta)
        }
        // Newest day first: the current logical day is the user-visible Today recap, and a
        // migration backlog therefore fills in from today backwards.
        var generated = 0
        for (day, daySegments) in byDay.sorted(by: { $0.key > $1.key }) {
            if generated >= maxGenerationsPerRefresh { break }
            try Task.checkCancellation()
            let fingerprint = Set(daySegments.map {
                SegmentFingerprint(segmentId: $0.segmentId, state: $0.transcriptionState)
            })
            if settledDays[day] == fingerprint { continue }
            if let existing = try await store.load(dateKey: day) {
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
                if nowMs() - existing.updatedAtMs < minRefreshIntervalMs { continue }
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
            let result = try await run(
                AiRunRequest(
                    requestId: "digest-\(day)-\(nowMs())",
                    prompt: prompt,
                    transcripts: excerpts))
            let saved = try await store.save(
                DailyRecap(
                    dateKey: day,
                    text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    segmentIds: excerpts.map(\.segmentId),
                    provider: result.providerId,
                    model: result.modelUsed))
            settledDays[day] = fingerprint
            generated += 1
            await onRecapSaved(saved)
        }
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
