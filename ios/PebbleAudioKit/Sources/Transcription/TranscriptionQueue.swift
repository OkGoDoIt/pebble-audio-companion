import AppDB
import Foundation
import GRDB

// Port of `core/transcription/.../TranscriptionQueue.kt` (FileTranscriptionQueue). The
// behavioral contract is identical; persistence moved from one-JSON-file-per-task to the AppDB
// `transcription_tasks` table (plan Part 3 / 4.4: "the queue's behavioral contract is kept but
// its persistence is a DB table"), so durability comes from SQLite transactions instead of
// temp-file + atomic rename.

/// Raw values match the Kotlin enum constant names — they are what the old app persisted and
/// what the `transcription_tasks.state` column stores.
public enum TaskState: String, Codable, CaseIterable, Sendable {
    case pending = "Pending"
    case running = "Running"

    /// Handed to the suspension-proof background upload transport. Distinct from `running` so
    /// process-restart recovery does NOT reset it (the OS may still be uploading); the upload
    /// coordinator reconciles it against the transport's in-flight set instead.
    case uploading = "Uploading"
    case complete = "Complete"
    case noSpeech = "NoSpeech"
    case failed = "Failed"
    case disabled = "Disabled"
}

/// One row of `transcription_tasks`.
public struct TranscriptionTask: Equatable, Sendable, Codable {
    public var segmentId: String
    public var state: TaskState
    public var attempts: Int
    public var retryable: Bool
    public var lastError: String?
    public var createdAtMs: Int64
    public var updatedAtMs: Int64
    /// Provenance: routing mode that produced the final transcript.
    public var modeUsed: TranscriptionMode?
    public var providerId: String?
    public var modelUsed: String?

    public init(
        segmentId: String,
        state: TaskState = .pending,
        attempts: Int = 0,
        retryable: Bool = true,
        lastError: String? = nil,
        createdAtMs: Int64,
        updatedAtMs: Int64,
        modeUsed: TranscriptionMode? = nil,
        providerId: String? = nil,
        modelUsed: String? = nil
    ) {
        self.segmentId = segmentId
        self.state = state
        self.attempts = attempts
        self.retryable = retryable
        self.lastError = lastError
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.modeUsed = modeUsed
        self.providerId = providerId
        self.modelUsed = modelUsed
    }
}

extension TranscriptionTask: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcription_tasks"
}

/// Durable transcription queue over the AppDB `transcription_tasks` table. Every mutation is
/// one SQLite transaction, so the queue survives process death; `recoverOnStart()` returns
/// tasks that died mid-run to Pending.
public final class TranscriptionQueue: Sendable {
    private let database: AppDatabase
    private let nowMs: @Sendable () -> Int64

    public init(database: AppDatabase, nowMs: @escaping @Sendable () -> Int64) {
        self.database = database
        self.nowMs = nowMs
    }

    /// Ascending creation order (rowid breaks `createdAtMs` ties in insertion order, matching
    /// the KMP stable sort over the in-memory index).
    private static let orderedQuery = TranscriptionTask
        .order(Column("createdAtMs").asc, Column.rowID.asc)

    /// Adds a Pending task for `segmentId`; no-op when a task already exists.
    @discardableResult
    public func enqueue(_ segmentId: String) throws -> TranscriptionTask {
        try database.writer.write { db in
            if let existing = try TranscriptionTask.fetchOne(db, key: segmentId) {
                return existing
            }
            let task = TranscriptionTask(
                segmentId: segmentId,
                createdAtMs: nowMs(),
                updatedAtMs: nowMs()
            )
            try task.insert(db)
            return task
        }
    }

    public func load(_ segmentId: String) throws -> TranscriptionTask? {
        try database.reader.read { db in
            try TranscriptionTask.fetchOne(db, key: segmentId)
        }
    }

    public func all() throws -> [TranscriptionTask] {
        try database.reader.read { db in
            try Self.orderedQuery.fetchAll(db)
        }
    }

    /// Newest Pending task, or — when none is pending — the newest retryable Failed one whose
    /// backoff has elapsed. Newest-first so the audio the user most likely cares about (their
    /// most recent conversation) transcribes first; the older backlog still drains once the
    /// recent work is clear, so everything is eventually transcribed. Failed tasks back off
    /// exponentially with `retryBackoffMs` so a persistently failing segment cannot spin the
    /// worker loop.
    public func nextRunnable() throws -> TranscriptionTask? {
        // all() is ascending by createdAtMs, so last(where:) is the newest matching task.
        let tasks = try all()
        if let pending = tasks.last(where: { $0.state == .pending }) {
            return pending
        }
        let now = nowMs()
        return tasks.last { task in
            task.state == .failed && task.retryable
                && now >= task.updatedAtMs + Self.retryBackoffMs(attempts: task.attempts)
        }
    }

    /// Soonest time a Failed-retryable task becomes runnable, or nil when nothing is waiting on
    /// backoff. Lets the worker sleep precisely instead of polling.
    public func nextRetryAtMs() throws -> Int64? {
        try all()
            .filter { $0.state == .failed && $0.retryable }
            .map { $0.updatedAtMs + Self.retryBackoffMs(attempts: $0.attempts) }
            .min()
    }

    /// Tasks parked as Disabled (no provider was usable when they ran) go back to Pending —
    /// called when transcription becomes available again (model downloaded, key added, mode
    /// changed). Returns the segment ids that were reset.
    @discardableResult
    public func resetDisabled() throws -> [String] {
        try resetToPending(from: .disabled)
    }

    @discardableResult
    public func markRunning(_ segmentId: String) throws -> TranscriptionTask? {
        try update(segmentId) { task in
            var next = task
            next.state = .running
            next.attempts += 1
            return next
        }
    }

    /// Hands a task to the background upload transport. Counts as an attempt (bounds retries).
    @discardableResult
    public func markUploading(_ segmentId: String) throws -> TranscriptionTask? {
        try update(segmentId) { task in
            var next = task
            next.state = .uploading
            next.attempts += 1
            return next
        }
    }

    /// Segment ids currently handed to the upload transport.
    public func uploadingSegmentIds() throws -> [String] {
        try all().filter { $0.state == .uploading }.map(\.segmentId)
    }

    /// Returns Uploading tasks whose id is not in `inFlight` to Pending (the transport forgot
    /// them, e.g. across a relaunch). Returns the reset ids.
    @discardableResult
    public func resetAbandonedUploads(inFlight: Set<String>) throws -> [String] {
        try resetToPending(from: .uploading) { !inFlight.contains($0.segmentId) }
    }

    @discardableResult
    public func markComplete(
        _ segmentId: String, result: RoutedTranscription
    ) throws -> TranscriptionTask? {
        try update(segmentId) { task in
            var next = task
            next.state = .complete
            next.lastError = nil
            next.modeUsed = result.modeUsed
            next.providerId = result.providerId
            next.modelUsed = result.modelUsed
            return next
        }
    }

    @discardableResult
    public func markNoSpeech(_ segmentId: String) throws -> TranscriptionTask? {
        try update(segmentId) { task in
            var next = task
            next.state = .noSpeech
            next.lastError = nil
            return next
        }
    }

    @discardableResult
    public func markFailed(
        _ segmentId: String, error: String, retryable: Bool
    ) throws -> TranscriptionTask? {
        try update(segmentId) { task in
            var next = task
            next.state = .failed
            next.lastError = error
            next.retryable = retryable && task.attempts < Self.maxAttempts
            return next
        }
    }

    @discardableResult
    public func markDisabled(_ segmentId: String) throws -> TranscriptionTask? {
        try update(segmentId) { task in
            var next = task
            next.state = .disabled
            return next
        }
    }

    /// Forces a task back to Pending for a user-requested re-transcribe, regardless of its
    /// current (possibly terminal) state, and clears the attempt count/error so it runs
    /// immediately under the current transcription mode. Returns nil when no task exists for
    /// `segmentId`.
    @discardableResult
    public func requeue(_ segmentId: String) throws -> TranscriptionTask? {
        try update(segmentId) { task in
            var next = task
            next.state = .pending
            next.attempts = 0
            next.retryable = true
            next.lastError = nil
            return next
        }
    }

    public func delete(_ segmentId: String) throws {
        _ = try database.writer.write { db in
            try TranscriptionTask.deleteOne(db, key: segmentId)
        }
    }

    public func deleteAll() throws {
        _ = try database.writer.write { db in
            try TranscriptionTask.deleteAll(db)
        }
    }

    /// Process-restart recovery: tasks that died mid-run go back to Pending. Uploading is left
    /// alone — the OS background transport may still be carrying it; `resetAbandonedUploads`
    /// reconciles that state against the transport instead.
    public func recoverOnStart() throws {
        try resetToPending(from: .running)
    }

    // MARK: - Internals

    @discardableResult
    private func resetToPending(
        from state: TaskState,
        where include: (TranscriptionTask) -> Bool = { _ in true }
    ) throws -> [String] {
        try database.writer.write { db in
            let matching = try Self.orderedQuery
                .filter(Column("state") == state.rawValue)
                .fetchAll(db)
                .filter(include)
            for task in matching {
                var next = task
                next.state = .pending
                next.updatedAtMs = nowMs()
                try next.update(db)
            }
            return matching.map(\.segmentId)
        }
    }

    private func update(
        _ segmentId: String,
        _ transform: (TranscriptionTask) -> TranscriptionTask
    ) throws -> TranscriptionTask? {
        try database.writer.write { db in
            guard let task = try TranscriptionTask.fetchOne(db, key: segmentId) else {
                return nil
            }
            var updated = transform(task)
            updated.updatedAtMs = nowMs()
            try updated.update(db)
            return updated
        }
    }

    // MARK: - Retry policy

    /// After this many attempts a failing task stops retrying and stays Failed.
    public static let maxAttempts = 8

    /// Exponential backoff: 30 s, 1 m, 2 m, … capped at 30 m.
    public static func retryBackoffMs(attempts: Int) -> Int64 {
        let exponent = min(max(attempts - 1, 0), 6)
        return min(Int64(30_000) << exponent, Int64(30 * 60_000))
    }
}
