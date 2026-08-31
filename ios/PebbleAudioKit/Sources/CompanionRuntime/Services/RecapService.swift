import Foundation
import Intelligence
import SearchKit

/// Wraps `DailyRecapEngine` (5 AM logical day, 30 min debounce, settled-day fingerprints) and
/// donates each saved recap into the index under the stable `day-<dateKey>` id — same-day
/// regenerations replace the entry instead of accumulating copies.
public actor RecapService {
    private let engine: DailyRecapEngine?
    private let store: DailyRecapStore
    private var engineTask = false

    public init(engine: DailyRecapEngine?, store: DailyRecapStore) {
        self.engine = engine
        self.store = store
    }

    /// Starts the engine's own debounce loop. Idempotent.
    public func start() async {
        guard let engine, !engineTask else { return }
        engineTask = true
        await engine.start()
    }

    public func stop() async {
        guard let engine, engineTask else { return }
        engineTask = false
        await engine.stop()
    }

    /// One pipeline-pass refresh. Never throws into the pass: a recap failure is a non-event for
    /// the audio pipeline.
    public func refresh() async {
        try? await engine?.refreshDigests()
    }

    public func list() async throws -> [DailyRecap] { try await store.list() }

    public func recap(dateKey: String) async throws -> DailyRecap? {
        try await store.load(dateKey: dateKey)
    }

    /// Delete-cascade helper: recaps whose source set includes this segment must go, along with
    /// their `day-<key>` index entries.
    public func recapsSourced(from segmentId: String) async -> [DailyRecap] {
        let all = (try? await store.list()) ?? []
        return all.filter { $0.segmentIds.contains(segmentId) }
    }

    public func delete(dateKey: String) async throws {
        try await store.delete(dateKey: dateKey)
    }

    public func deleteAll() async throws {
        try await store.deleteAll()
    }

    /// The index document id for a recap — `day-<dateKey>` (plan Part 4.6 cascade list).
    public nonisolated func indexId(dateKey: String) -> String {
        RecapIndex.documentId(dateKey: dateKey)
    }
}

/// Builds the recap engine's donation hook so a saved recap reaches Spotlight/FTS immediately.
public func makeRecapDonationHook(
    donator: SpotlightDonator?,
    clock: RuntimeClock,
    log: RuntimeLog = .silent
) -> @Sendable (DailyRecap) async -> Void {
    { recap in
        guard let donator else { return }
        do {
            try await donator.donateRecap(
                dateKey: recap.dateKey, text: recap.text, createdAtMs: clock.nowMs
            )
        } catch {
            log.failure("recap donation", error)
        }
    }
}
