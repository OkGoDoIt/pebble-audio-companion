import Foundation

// The processing pass (plan Part 4.6). The ORDER here is load-bearing and ported verbatim from
// `AudioCompanionRuntime.runTranscriptionPass`; the reason it matters is at the end: a
// possibly single-instance native model must never be used concurrently, so the live
// transcriber only runs AFTER the durable closed-segment work is done.

/// One observable step of the pass, in execution order. Exposed so the ORDER can be asserted.
public enum PipelineStage: String, Sendable, Equatable, CaseIterable {
    /// Background early-return: release the model and defer everything heavy.
    case backgroundDefer
    case reconsiderDisabled
    case enqueueClosedSegments
    case drainQueue
    /// Age/size retention, paced by `RetentionService` — before `regroup` so the deletions are
    /// visible in the same pass that makes them.
    case retention
    /// Rebuild the conversation grouping. Cheap, local, AI-free — and its OWN stage, because
    /// the entire UI reads the grouped tables and must never wait on the AI layer to see them.
    case regroup
    case enrich
    case donate
    case followUps
    case recap
    case liveLocal
    case liveCloudPrune
    case wavExport
    case idleModelRelease
}

/// The pass's collaborators, as closures. The real composition wires these to the services;
/// tests wire them to recorders and assert the sequence.
public struct PipelineSteps: Sendable {
    /// Receive never stops; this only gates the heavy processing half.
    public var isForeground: @Sendable () -> Bool
    /// True while a sanctioned background catch-up burst holds the model, so the deferring
    /// background pass does not release it out from under the burst.
    public var isCatchUpActive: @Sendable () -> Bool
    public var releaseModel: @Sendable (String) async -> Void
    /// Returns true when anything became eligible again.
    public var reconsiderDisabled: @Sendable () async throws -> Bool
    public var enqueueClosedSegments: @Sendable () async throws -> Void
    /// Returns true when at least one task advanced.
    public var drainQueue: @Sendable () async throws -> Bool
    /// Retention sweep (age + size caps) INCLUDING the delete cascade, self-paced: the pass calls
    /// it every time and `RetentionService` decides whether anything actually runs. Returns true
    /// when it deleted something.
    public var enforceRetentionIfDue: @Sendable () async -> Bool
    /// Rebuilds the conversation grouping the whole UI reads.
    public var regroup: @Sendable () async throws -> Void
    /// Returns the conversation ids whose annotation changed.
    public var enrich: @Sendable () async throws -> [String]
    public var donate: @Sendable ([String]) async -> Void
    /// Follow-up extraction over finished conversations. Returns true when it wrote anything.
    public var extractFollowUps: @Sendable () async throws -> Bool
    public var refreshRecap: @Sendable () async -> Void
    /// `LiveTranscriber.processOnce()` + prune. Returns true when it did work.
    public var liveLocalPass: @Sendable () async throws -> Bool
    public var liveCloudPrune: @Sendable () async -> Void
    public var exportWavIfEnabled: @Sendable () async throws -> Void
    public var releaseModelIfIdle: @Sendable () async -> Void
    /// True when a segment is open AND a live transcriber is following it (the 5 s cadence).
    public var isFollowingOpenSegment: @Sendable () async -> Bool
    /// Absolute ms of the next queued retry, if any.
    public var nextRetryAtMs: @Sendable () async throws -> Int64?
    /// Fires whenever the pass changed something the diagnostics struct reports.
    public var onDiagnosticsDirty: @Sendable () async -> Void
    /// Rewrites the App Group snapshot the widget renders from — rate-limited by the runtime, so
    /// calling it every pass is cheap. Not a `PipelineStage`: it is a side effect at the end of
    /// the pass, not a step whose ORDER anything depends on.
    public var refreshCoverageSnapshot: @Sendable () async -> Void

    public init(
        isForeground: @escaping @Sendable () -> Bool = { true },
        isCatchUpActive: @escaping @Sendable () -> Bool = { false },
        releaseModel: @escaping @Sendable (String) async -> Void = { _ in },
        reconsiderDisabled: @escaping @Sendable () async throws -> Bool = { false },
        enqueueClosedSegments: @escaping @Sendable () async throws -> Void = {},
        drainQueue: @escaping @Sendable () async throws -> Bool = { false },
        enforceRetentionIfDue: @escaping @Sendable () async -> Bool = { false },
        regroup: @escaping @Sendable () async throws -> Void = {},
        enrich: @escaping @Sendable () async throws -> [String] = { [] },
        donate: @escaping @Sendable ([String]) async -> Void = { _ in },
        extractFollowUps: @escaping @Sendable () async throws -> Bool = { false },
        refreshRecap: @escaping @Sendable () async -> Void = {},
        liveLocalPass: @escaping @Sendable () async throws -> Bool = { false },
        liveCloudPrune: @escaping @Sendable () async -> Void = {},
        exportWavIfEnabled: @escaping @Sendable () async throws -> Void = {},
        releaseModelIfIdle: @escaping @Sendable () async -> Void = {},
        isFollowingOpenSegment: @escaping @Sendable () async -> Bool = { false },
        nextRetryAtMs: @escaping @Sendable () async throws -> Int64? = { nil },
        onDiagnosticsDirty: @escaping @Sendable () async -> Void = {},
        refreshCoverageSnapshot: @escaping @Sendable () async -> Void = {}
    ) {
        self.isForeground = isForeground
        self.isCatchUpActive = isCatchUpActive
        self.releaseModel = releaseModel
        self.reconsiderDisabled = reconsiderDisabled
        self.enqueueClosedSegments = enqueueClosedSegments
        self.drainQueue = drainQueue
        self.enforceRetentionIfDue = enforceRetentionIfDue
        self.regroup = regroup
        self.enrich = enrich
        self.donate = donate
        self.extractFollowUps = extractFollowUps
        self.refreshRecap = refreshRecap
        self.liveLocalPass = liveLocalPass
        self.liveCloudPrune = liveCloudPrune
        self.exportWavIfEnabled = exportWavIfEnabled
        self.releaseModelIfIdle = releaseModelIfIdle
        self.isFollowingOpenSegment = isFollowingOpenSegment
        self.nextRetryAtMs = nextRetryAtMs
        self.onDiagnosticsDirty = onDiagnosticsDirty
        self.refreshCoverageSnapshot = refreshCoverageSnapshot
    }
}

/// Adaptive schedule. Per plan Part 3, pacing is EVENT-DRIVEN; these numbers govern only the
/// FALLBACK timer and the retry clamps.
public enum PipelinePacing {
    /// Something advanced — come straight back for more.
    public static let afterWorkMs: Int64 = 1_000
    /// A live transcriber is following an open segment: keep the preview feeling live.
    public static let followingOpenSegmentMs: Int64 = 5_000
    /// Idle ceiling, and the upper clamp for a pending retry.
    public static let idleMs: Int64 = 30_000
    /// Lower clamp for a pending retry.
    public static let minRetryMs: Int64 = 1_000
    /// Long sleep while backgrounded; foreground entry wakes the loop.
    public static let backgroundMs: Int64 = 60_000
    /// A thrown pass backs off before retrying rather than spinning.
    public static let failureBackoffMs: Int64 = 5_000
    /// Foreground idle time after which the resident local model is released.
    public static let modelIdleTimeoutMs: Int64 = 30_000
    /// Cap on segments transcribed per background catch-up burst.
    public static let catchUpMaxSegments = 10
}

/// Runs one pass and reports how long to sleep before the next one.
public struct PipelinePass: Sendable {
    private let steps: PipelineSteps
    private let clock: RuntimeClock
    private let onStage: @Sendable (PipelineStage) -> Void

    public init(
        steps: PipelineSteps,
        clock: RuntimeClock,
        onStage: @escaping @Sendable (PipelineStage) -> Void = { _ in }
    ) {
        self.steps = steps
        self.clock = clock
        self.onStage = onStage
    }

    /// Executes the pass in order and returns the fallback sleep in ms.
    public func run() async throws -> Int64 {
        // 1. Background early-return. Receive-only: defer local STT, live preview, AI enrichment
        //    and WAV export, and release the local model so a ~10 s Bluetooth wake stays cheap and
        //    the app is not a jetsam target. Pending segments stay queued.
        if !steps.isForeground() {
            onStage(.backgroundDefer)
            if !steps.isCatchUpActive() {
                await steps.releaseModel("background")
            }
            // Still worth a (heavily rate-limited) snapshot: backgrounded IS when this product
            // records, and a widget that freezes the moment the app leaves the foreground is
            // exactly the widget Roger called useless.
            await steps.refreshCoverageSnapshot()
            return PipelinePacing.backgroundMs
        }

        var processed = false

        // 2. Segments parked while no provider was usable become eligible the moment one is.
        onStage(.reconsiderDisabled)
        if try await steps.reconsiderDisabled() {
            await steps.onDiagnosticsDirty()
        }

        // 3. Anything closed since the last pass joins the queue.
        onStage(.enqueueClosedSegments)
        try await steps.enqueueClosedSegments()

        // 4. Drain, under the processing mutex owned by TranscriptionService.
        onStage(.drainQueue)
        if try await steps.drainQueue() {
            processed = true
            await steps.onDiagnosticsDirty()
        }

        // 5. Retention. Self-paced (see `RetentionService`): normally a no-op, sweeping on its
        //    interval or as soon as the user changes "Keep audio". It sits here — after the
        //    queue work, before the regroup — so a sweep's deletions are reflected by the same
        //    pass that made them, instead of leaving the Library listing rows whose audio,
        //    transcript and follow-ups are already gone.
        onStage(.retention)
        if await steps.enforceRetentionIfDue() {
            processed = true
            await steps.onDiagnosticsDirty()
        }

        // 6. Rebuild the conversation grouping — BEFORE the AI layer and never behind it.
        //    Library, Today's list, the live row and the Recording-now screen all read the
        //    grouped tables, so this is the step that makes a just-closed segment visible and
        //    shows the open one as live. It used to be the first line of `enrich`, which meant
        //    a long AI backfill froze the user's entire view of reality while recording
        //    continued.
        onStage(.regroup)
        try await steps.regroup()

        // 7/8. Titles + summaries, then search/Spotlight donation of exactly what changed.
        //      BOUNDED per pass: the backlog drains over many passes rather than holding this
        //      one open for minutes.
        onStage(.enrich)
        let enriched = try await steps.enrich()
        onStage(.donate)
        if !enriched.isEmpty {
            processed = true
            await steps.donate(enriched)
            await steps.onDiagnosticsDirty()
        }

        // 9. Follow-up extraction over finished conversations (plan Part 4.5) — after enrich,
        //    on the same durable transcripts, and bounded the same way.
        onStage(.followUps)
        if try await steps.extractFollowUps() {
            processed = true
            await steps.onDiagnosticsDirty()
        }

        // 10. Daily recap (its own debounce decides whether anything actually runs).
        onStage(.recap)
        await steps.refreshRecap()

        // 11. Live preview of the OPEN segment — after the durable closed-segment work, in the
        //     same loop, so a possibly single-instance native model is never used concurrently.
        onStage(.liveLocal)
        if try await steps.liveLocalPass() { processed = true }

        // 12. Cloud live previews are pruned once the durable transcript supersedes them.
        onStage(.liveCloudPrune)
        await steps.liveCloudPrune()

        // 13. Mirror closed segments to WAV when the user asked for it.
        onStage(.wavExport)
        try await steps.exportWavIfEnabled()

        // 14. Shrink the foreground footprint between bursts: release the resident model once it
        //     has been idle. It reloads lazily on the next segment, which is also how a
        //     selected-model change takes effect.
        onStage(.idleModelRelease)
        if !processed {
            await steps.releaseModelIfIdle()
        }

        // 15. Hand the widget what this pass just produced — a new transcript line, a title
        //     enrichment finally wrote, a follow-up that appeared. The widget has no other way
        //     to learn any of it.
        await steps.refreshCoverageSnapshot()

        return try await sleepMs(processed: processed)
    }

    private func sleepMs(processed: Bool) async throws -> Int64 {
        if processed { return PipelinePacing.afterWorkMs }
        if await steps.isFollowingOpenSegment() { return PipelinePacing.followingOpenSegmentMs }
        guard let retryAtMs = try await steps.nextRetryAtMs() else { return PipelinePacing.idleMs }
        let delta = retryAtMs - clock.nowMs
        return min(max(delta, PipelinePacing.minRetryMs), PipelinePacing.idleMs)
    }
}

/// The loop that runs `PipelinePass` forever, sleeping on the conflated wake channel between
/// passes. A thrown pass backs off instead of spinning; cancellation ends the loop.
public struct PipelineLoop: Sendable {
    private let pass: PipelinePass
    private let wake: WakeChannel
    private let clock: RuntimeClock
    private let log: RuntimeLog

    public init(pass: PipelinePass, wake: WakeChannel, clock: RuntimeClock, log: RuntimeLog = .silent) {
        self.pass = pass
        self.wake = wake
        self.clock = clock
        self.log = log
    }

    public func run() async {
        while !Task.isCancelled {
            var sleepMs = PipelinePacing.failureBackoffMs
            do {
                sleepMs = try await pass.run()
            } catch is CancellationError {
                return
            } catch {
                log.failure("pipeline pass", error)
            }
            if Task.isCancelled { return }
            await wake.wait(timeoutMs: sleepMs, clock: clock)
        }
    }
}
