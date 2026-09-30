import Foundation
import Intelligence
import SearchKit

/// Wraps `DailyRecapEngine` (5 AM logical day, 30 min debounce, settled-day fingerprints) and
/// donates each saved recap into the index under the stable `day-<dateKey>` id — same-day
/// regenerations replace the entry instead of accumulating copies. Also owns the second pass
/// over the recaps History reads (`PeriodBriefEngine`: day headlines, week and month briefs).
public actor RecapService {
    private let engine: DailyRecapEngine?
    private let store: DailyRecapStore
    private let briefs: PeriodBriefEngine?
    private var engineTask = false
    /// A recap was deleted (the delete cascade) since the last `refresh`. The pass learns that
    /// the recaps changed from `refresh`'s answer, and a deleted day changes the week and month
    /// written from it as surely as a regenerated one does.
    private var deletedSinceRefresh = false

    public init(engine: DailyRecapEngine?, store: DailyRecapStore, briefs: PeriodBriefEngine? = nil) {
        self.engine = engine
        self.store = store
        self.briefs = briefs
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
    /// any digest that came out longer than the Today card can carry (`RecapCondenser`).
    ///
    /// THROWS when a day's recap failed (`RecapGenerationFailed` — the classified kind, never a
    /// provider body). It used to be `try?`, so a recap that failed on every pass for days was
    /// invisible to Diagnostics and to `PipelineHealth`; the `.recap` stage now records it like
    /// any other stage failure, and backs itself off. The audio pipeline is unaffected either
    /// way — each stage runs in its own failure boundary. A missing condensation still just
    /// means the card shows the full digest, and never throws.
    ///
    /// `onProgress` fires after each AI call, so a long map-reduce day reads as progress to the
    /// loop watchdog rather than as a wedged pass.
    ///
    /// Returns whether a digest or a condensation was written — what makes `.briefs` due.
    @discardableResult
    public func refresh(onProgress: (@Sendable () -> Void)? = nil) async throws -> Bool {
        let deleted = deletedSinceRefresh
        deletedSinceRefresh = false
        let wrote = try await engine?.refreshDigests(onProgress: onProgress) ?? false
        return wrote || deleted
    }

    /// One pipeline-pass run of the brief pass (`PeriodBriefEngine.refresh`). Without a brief
    /// engine nothing is ever owed.
    public func refreshBriefs(onProgress: (@Sendable () -> Void)? = nil) async throws -> PeriodBriefPassOutcome {
        try await briefs?.refresh(onProgress: onProgress) ?? .nothingOwed
    }

    /// Failed days may be tried again now — see `DailyRecapEngine.resetFailureBackoff`. The
    /// brief pass's failures with them.
    public func resetFailureBackoff() async {
        await engine?.resetFailureBackoff()
        await briefs?.resetFailureBackoff()
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
        deletedSinceRefresh = true
    }

    public func deleteAll() async throws {
        try await store.deleteAll()
        deletedSinceRefresh = true
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
