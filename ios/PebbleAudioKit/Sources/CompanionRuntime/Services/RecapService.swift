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
    ///
    /// NOT called by the runtime: that loop ignores the background, charger and thermal rules
    /// the pipeline's `.recap` stage applies (see `CompanionRuntime.start`). Kept for tests and
    /// tools that drive the engine without a pipeline.
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

    /// One pipeline-pass refresh: regenerate any day whose transcripts changed, then condense
    /// any digest that came out longer than the Today card can carry (`RecapCondenser`). Never
    /// throws into the pass: a recap failure is a non-event for the audio pipeline, and a
    /// missing condensation just means the card shows the full digest.
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
///
/// `log` is NOT defaulted. A donation that fails is otherwise invisible from every angle: the
/// recap exists in the app, never appears in search or Spotlight, and Detailed Logs has no line
/// about it — the same silent-default shape that hid four other failures in this layer.
public func makeRecapDonationHook(
    donator: SpotlightDonator?,
    clock: RuntimeClock,
    log: RuntimeLog
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
