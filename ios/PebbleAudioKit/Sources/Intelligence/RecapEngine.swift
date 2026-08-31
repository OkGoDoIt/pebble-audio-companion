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

    public init(
        dateKey: String, text: String, segmentIds: [String] = [],
        provider: String? = nil, model: String? = nil, updatedAtMs: Int64 = 0
    ) {
        self.dateKey = dateKey
        self.text = text
        self.segmentIds = segmentIds
        self.provider = provider
        self.model = model
        self.updatedAtMs = updatedAtMs
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
            provider: row["provider"], model: row["model"], updatedAtMs: row["updatedAtMs"])
    }

    /// Upserts by dateKey, stamping `updatedAtMs` with the store clock (KMP `save` stamped
    /// `createdAtMs` the same way). Returns the stamped recap.
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
                    INSERT INTO recaps (dateKey, text, segmentIds, provider, model, updatedAtMs)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(dateKey) DO UPDATE SET
                        text = excluded.text, segmentIds = excluded.segmentIds,
                        provider = excluded.provider, model = excluded.model,
                        updatedAtMs = excluded.updatedAtMs
                    """,
                arguments: [
                    toWrite.dateKey, toWrite.text, idsJson, toWrite.provider, toWrite.model,
                    toWrite.updatedAtMs,
                ]
            )
        }
        return toWrite
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
        self.sleepMs = sleepMs
    }

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

    /// Rebuilds any logical-day digest whose segment set changed. Serialized: concurrent calls
    /// queue behind the in-flight pass instead of interleaving.
    public func refreshDigests() async throws {
        let previous = refreshChain
        let task = Task {
            _ = try? await previous?.value
            try await self.performRefresh()
        }
        refreshChain = task
        try await task.value
    }

    private func performRefresh() async throws {
        guard let run else { return }
        let segments = listSegments().filter { !$0.isOpen }
        var byDay: [String: [SegmentMeta]] = [:]
        for meta in segments {
            byDay[dayKey(of: meta), default: []].append(meta)
        }
        // Newest day first: the current logical day is the user-visible Today recap.
        for (day, daySegments) in byDay.sorted(by: { $0.key > $1.key }) {
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
                .sorted { $0.startTimeMs < $1.startTimeMs }
                .compactMap { meta -> TranscriptExcerpt? in
                    guard
                        let text = transcriptTextOf(meta.segmentId)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        !text.isEmpty
                    else { return nil }
                    let startMs = Int64(meta.startTimeMs)
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
            await onRecapSaved(saved)
        }
    }

    private func zoneID(of meta: SegmentMeta) -> String {
        meta.recordedTimeZone ?? fallbackTimeZoneID
    }

    private func dayKey(of meta: SegmentMeta) -> String {
        LogicalDay.dateKey(forMs: Int64(meta.startTimeMs), timeZoneID: zoneID(of: meta))
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
