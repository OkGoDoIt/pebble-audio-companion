import Foundation
import Intelligence

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
    /// Audio leaving for (or coming back from) the iCloud Drive cold tier, paced by
    /// `ColdAudioTier` — after retention, so a sweep never moves what retention is about to
    /// delete. See `ColdAudioTier`.
    case coldStorage
    /// Label what newly transcribed audio holds (conversation, or none) — before `regroup`,
    /// whose speech evidence and the AI stages behind it read the result. See
    /// `AudioContentService`.
    case classifyAudio
    /// Bounded acoustic identity work, foreground only, independent of ASR availability.
    case recognizeVoices
    /// Rebuild the conversation grouping. Cheap, local, AI-free — and its OWN stage, because
    /// the entire UI reads the grouped tables and must never wait on the AI layer to see them.
    case regroup
    /// Method 2 of the audio-content classification: an AI reading of what newly transcribed
    /// segments' words are (lyrics, TV, announcements). An AI stage — gated like `.enrich`.
    case judgeAudio
    case enrich
    case donate
    case followUps
    case recap
    /// History's words: a headline and line per day, then week and month briefs
    /// (`PeriodBriefEngine`). After `.recap`, whose output it reads; due only when something it
    /// reads changed or it left work (`PipelinePassMemory.briefsDueAtMs`).
    case briefs
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
    /// The cold tier's sweep, self-paced inside `ColdAudioTier`. Returns true when it moved,
    /// evicted or restored something.
    public var coldStorageIfDue: @Sendable () async -> Bool = { false }
    /// Classifies segments whose transcripts changed. Returns true when it wrote anything, so
    /// a backfill comes straight back for the rest.
    public var classifyAudio: @Sendable () async throws -> Bool
    public var recognizeVoices: @Sendable () async throws -> Bool
    /// Backgrounded, when the voice step may run its next slice (`VoiceBackgroundPace`).
    public var voiceSliceDueInMs: @Sendable () -> Int64 = { PipelinePacing.idleMs }
    /// One AI-reading pass (`AudioContentService.judgePass`). True when it saved a reading.
    public var judgeAudio: @Sendable () async throws -> Bool
    /// Rebuilds the conversation grouping the whole UI reads. Returns whether its STRUCTURE
    /// changed — a conversation appeared, gained or lost a member, a member's transcription
    /// state moved, or a conversation went live or closed. The live conversation's extent
    /// advancing while the watch records is not a structural change.
    public var regroup: @Sendable () async throws -> Bool
    /// Returns the conversation ids whose annotation changed.
    public var enrich: @Sendable () async throws -> [String]
    public var donate: @Sendable ([String]) async -> Void
    /// Follow-up extraction over finished conversations. Returns true when it wrote anything.
    public var extractFollowUps: @Sendable () async throws -> Bool
    /// Throws when a day's recap failed, so the `.recap` stage's health records it. Returns
    /// whether it wrote a digest or a condensation, which makes `.briefs` due.
    public var refreshRecap: @Sendable () async throws -> Bool
    /// One run of the brief pass. Returns when it is next due and any failure, which the pass
    /// records against `.briefs` after noting when to come back.
    public var refreshBriefs: @Sendable () async throws -> PeriodBriefPassOutcome
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
    /// Hands newly-closed cloud-primary segments to the background `URLSession`. Cheap, and the
    /// transfer itself is done by the system daemon rather than by us — see the background branch
    /// of `run()`.
    public var submitPendingUploads: @Sendable () async -> Void = {}
    /// The archive sync's change gate (`ArchiveSyncService.pipelinePassFinished`): called at the
    /// end of every pass with whether the pass changed anything the server holds — a
    /// transcription, the grouping, a title, follow-ups, a recap or a brief, a deletion. Not a
    /// `PipelineStage`: like the snapshot, it is a side effect at the end of the pass, and it
    /// does nothing at all when the answer is no and the outbox has not moved.
    public var syncArchive: @Sendable (_ changed: Bool) async -> Void = { _ in }
    /// Whether expensive catch-up (local STT, AI) may run while backgrounded, and why not when it
    /// may not. See `BackgroundWorkPolicy`.
    public var backgroundWorkDecision: @Sendable () -> BackgroundWorkDecision = {
        .hold(reason: .onBattery)
    }
    /// True while the phone is too hot for model work, in the FOREGROUND too.
    ///
    /// The background policy already refuses at thermal `.serious`; the foreground pass did not,
    /// and the flight recorder shows what that cost: the app comes forward, the local model
    /// starts on a backlog, the phone reaches `thermal=serious` on battery within minutes, and
    /// iOS then kills the process in the background (a thermal jettison), which relaunches it
    /// into another recovery sweep. Once the OS is throttling the CPU the work is slower AND
    /// hotter, so holding it is the faster path to a finished transcript as well as the cooler
    /// one. Receive, grouping and retention are never held -- they are cheap and they are the
    /// product.
    public var isThermallyThrottled: @Sendable () -> Bool = { false }

    public init(
        isForeground: @escaping @Sendable () -> Bool = { true },
        isCatchUpActive: @escaping @Sendable () -> Bool = { false },
        releaseModel: @escaping @Sendable (String) async -> Void = { _ in },
        reconsiderDisabled: @escaping @Sendable () async throws -> Bool = { false },
        enqueueClosedSegments: @escaping @Sendable () async throws -> Void = {},
        drainQueue: @escaping @Sendable () async throws -> Bool = { false },
        enforceRetentionIfDue: @escaping @Sendable () async -> Bool = { false },
        coldStorageIfDue: @escaping @Sendable () async -> Bool = { false },
        classifyAudio: @escaping @Sendable () async throws -> Bool = { false },
        recognizeVoices: @escaping @Sendable () async throws -> Bool = { false },
        judgeAudio: @escaping @Sendable () async throws -> Bool = { false },
        regroup: @escaping @Sendable () async throws -> Bool = { true },
        enrich: @escaping @Sendable () async throws -> [String] = { [] },
        donate: @escaping @Sendable ([String]) async -> Void = { _ in },
        extractFollowUps: @escaping @Sendable () async throws -> Bool = { false },
        refreshRecap: @escaping @Sendable () async throws -> Bool = { false },
        refreshBriefs: @escaping @Sendable () async throws -> PeriodBriefPassOutcome = { .nothingOwed },
        liveLocalPass: @escaping @Sendable () async throws -> Bool = { false },
        liveCloudPrune: @escaping @Sendable () async -> Void = {},
        exportWavIfEnabled: @escaping @Sendable () async throws -> Void = {},
        releaseModelIfIdle: @escaping @Sendable () async -> Void = {},
        isFollowingOpenSegment: @escaping @Sendable () async -> Bool = { false },
        nextRetryAtMs: @escaping @Sendable () async throws -> Int64? = { nil },
        onDiagnosticsDirty: @escaping @Sendable () async -> Void = {},
        refreshCoverageSnapshot: @escaping @Sendable () async -> Void = {},
        submitPendingUploads: @escaping @Sendable () async -> Void = {},
        syncArchive: @escaping @Sendable (_ changed: Bool) async -> Void = { _ in },
        backgroundWorkDecision: @escaping @Sendable () -> BackgroundWorkDecision = {
            .hold(reason: .onBattery)
        },
        isThermallyThrottled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.isForeground = isForeground
        self.isCatchUpActive = isCatchUpActive
        self.releaseModel = releaseModel
        self.reconsiderDisabled = reconsiderDisabled
        self.enqueueClosedSegments = enqueueClosedSegments
        self.drainQueue = drainQueue
        self.enforceRetentionIfDue = enforceRetentionIfDue
        self.coldStorageIfDue = coldStorageIfDue
        self.classifyAudio = classifyAudio
        self.recognizeVoices = recognizeVoices
        self.judgeAudio = judgeAudio
        self.regroup = regroup
        self.enrich = enrich
        self.donate = donate
        self.extractFollowUps = extractFollowUps
        self.refreshRecap = refreshRecap
        self.refreshBriefs = refreshBriefs
        self.liveLocalPass = liveLocalPass
        self.liveCloudPrune = liveCloudPrune
        self.exportWavIfEnabled = exportWavIfEnabled
        self.releaseModelIfIdle = releaseModelIfIdle
        self.isFollowingOpenSegment = isFollowingOpenSegment
        self.nextRetryAtMs = nextRetryAtMs
        self.onDiagnosticsDirty = onDiagnosticsDirty
        self.refreshCoverageSnapshot = refreshCoverageSnapshot
        self.submitPendingUploads = submitPendingUploads
        self.syncArchive = syncArchive
        self.backgroundWorkDecision = backgroundWorkDecision
        self.isThermallyThrottled = isThermallyThrottled
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
    /// How often the daily recap is reconsidered while backgrounded. It is a summary of the
    /// day; nobody is reading it while the app is not open, and the next foreground pass runs
    /// it regardless.
    public static let backgroundRecapIntervalMs: Int64 = 15 * 60_000
}

/// What the previous pass learned that the next one needs, so a pass can tell "nothing has
/// changed since I last found nothing to do" from "I have not looked yet".
///
/// The AI stages — enrich, follow-ups, recap — each start by re-deriving their whole work list
/// from the library: every conversation's membership, every transcript's version, every day's
/// fingerprint. That is O(library) per pass, and on a charger the pass runs every few seconds.
/// It found nothing to do on almost every one of them: measured 2026-09-11, 10.5 of 21 CPU-s
/// per 90 s were those stages confirming that a library nobody had touched was still the same.
/// The grouping stage already computes the one fact needed to skip them — whether ITS inputs
/// changed — so this carries it, plus whether the AI stages themselves left work behind.
///
/// Foreground passes never consult it: the person is looking, the live title and the Today
/// card are expected to follow the conversation as it happens, and that freshness is what the
/// foreground cadence is for.
public final class PipelinePassMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var _aiStagesLeftWork = true
    private var _lastBackgroundRecapAtMs: Int64?
    private var _briefsDueAtMs: Int64? = 0

    public init() {}

    /// When the brief pass next has something to do; nil when nothing is owed. It starts due, so
    /// the first pass after a launch looks once (and an existing library's backfill begins).
    /// After that it is set only by the brief pass itself (its backlog, a current period's
    /// cadence, a failure's backoff) and by the things that change what it reads: a recap
    /// written, audio deleted by retention.
    var briefsDueAtMs: Int64? {
        get { lock.withLock { _briefsDueAtMs } }
        set { lock.withLock { _briefsDueAtMs = newValue } }
    }

    func noteBriefsOwed(atMs: Int64) {
        lock.withLock { _briefsDueAtMs = min(_briefsDueAtMs ?? atMs, atMs) }
    }

    func briefsDue(atMs: Int64) -> Bool {
        lock.withLock { _briefsDueAtMs.map { $0 <= atMs } ?? false }
    }

    /// True after a pass in which enrich or follow-ups actually wrote something — their per-pass
    /// budget means a backlog drains over several passes, and an unchanged grouping must not
    /// stall that drain.
    var aiStagesLeftWork: Bool {
        get { lock.withLock { _aiStagesLeftWork } }
        set { lock.withLock { _aiStagesLeftWork = newValue } }
    }

    /// Nil until the first backgrounded recap has run.
    var lastBackgroundRecapAtMs: Int64? {
        get { lock.withLock { _lastBackgroundRecapAtMs } }
        set { lock.withLock { _lastBackgroundRecapAtMs = newValue } }
    }
}

/// Runs one pass and reports how long to sleep before the next one.
///
/// **Stages are isolated.** The pass used to be one `try` chain, so the first stage to throw
/// abandoned every stage behind it — a storage error while enqueueing closed segments stopped
/// the live preview, the conversation grouping, enrichment and follow-ups as well, on every
/// pass, indefinitely, with a single line in the detailed log as the only trace. Each stage now
/// runs inside its own failure boundary, reports the outcome to `PipelineHealthMonitor`, and
/// the pass carries on. Cancellation is the one thing that still stops everything, because it
/// means the loop itself is going away.
public struct PipelinePass: Sendable {
    private let steps: PipelineSteps
    private let clock: RuntimeClock
    private let onStage: @Sendable (PipelineStage) -> Void
    private let health: PipelineHealthMonitor?
    private let memory: PipelinePassMemory

    public init(
        steps: PipelineSteps,
        clock: RuntimeClock,
        health: PipelineHealthMonitor? = nil,
        memory: PipelinePassMemory = PipelinePassMemory(),
        onStage: @escaping @Sendable (PipelineStage) -> Void = { _ in }
    ) {
        self.steps = steps
        self.clock = clock
        self.health = health
        self.memory = memory
        self.onStage = onStage
    }

    /// Runs one stage inside its failure boundary.
    ///
    /// Returns `fallback` when the stage is skipped (inside its backoff) or when it threw, so
    /// every call site reads as the plain value it wanted. The stage is still announced through
    /// `onStage` in both cases: the ORDER of the pass is a fixed contract, and a stage that is
    /// unwell must not silently vanish from the sequence tests assert on.
    private func stage<Value>(
        _ stage: PipelineStage,
        fallback: Value,
        heavy: Bool = false,
        when due: Bool = true,
        _ body: () async throws -> Value
    ) async throws -> Value {
        onStage(stage)
        health?.stageStarted(stage)
        if let health, !health.shouldRun(stage) { return fallback }
        // Nothing for this stage to look at has changed since it last found nothing. Announced
        // like every other skip; not a failure, because nothing failed.
        if !due { return fallback }
        // Model work waits for the phone to cool down. Announced like every other skip, so the
        // stage order the tests assert on is unchanged; not recorded as a failure, because
        // nothing failed.
        if heavy, steps.isThermallyThrottled() { return fallback }
        do {
            let value = try await body()
            health?.succeeded(stage)
            return value
        } catch is CancellationError {
            // Only the PASS being cancelled ends the pass. A cancellation that comes up from
            // inside a stage while this task is still running is work that was interrupted —
            // the local model released under a transcription when the app went to the
            // background, a memory warning — and it used to propagate straight out of the loop,
            // which returned for good: nothing ran until the watchdog noticed ten minutes later
            // ("pipeline pass wedged in drainQueue", 2026-09-18 17:37). The interrupted work has
            // already put itself back (see `TranscriptionProcessor.processNext`); this pass
            // simply carries on without it. Not a failure, so the stage's backoff is untouched.
            if Task.isCancelled { throw CancellationError() }
            return fallback
        } catch {
            health?.failed(stage, error)
            return fallback
        }
    }

    /// Executes the pass in order and returns the fallback sleep in ms.
    public func run() async throws -> Int64 {
        health?.passStarted()
        // 1. Background early-return. Receive-only: defer local STT, live preview, AI enrichment
        //    and WAV export, and release the local model so a ~10 s Bluetooth wake stays cheap and
        //    the app is not a jetsam target. Pending segments stay queued.
        // Backgrounded, but the phone may be in a state where expensive work is free — plugged
        // in, cool, and not in Low Power Mode. `BackgroundWorkPolicy` owns that judgement; when it
        // says yes we fall through to the ordinary pass instead of deferring, which is what lets a
        // phone on a desk charger clear its backlog before the user next opens the app.
        //
        // The receive path is never what gets traded here: it does not run on this loop.
        if !steps.isForeground(), !steps.backgroundWorkDecision().isRun {
            onStage(.backgroundDefer)
            if !steps.isCatchUpActive() {
                await steps.releaseModel("background")
            }
            // Still worth a (heavily rate-limited) snapshot: backgrounded IS when this product
            // records, and a widget that freezes the moment the app leaves the foreground is
            // exactly the widget Roger called useless.
            await steps.refreshCoverageSnapshot()
            // ...and worth handing finished segments to the background URLSession.
            //
            // This is the one kind of transcription that is genuinely cheap to start while
            // backgrounded, because WE DO NOT DO THE WORK: the bytes go to `nsurlsessiond`, which
            // transfers them on its own schedule and can do it while this app is suspended or not
            // running at all. What it costs us is bounded — `submitPending` stops at
            // `maxConcurrentUploads` and returns immediately when nothing is pending — and it is
            // once per closed segment, which is every 15 minutes or 16 MB.
            //
            // Without it, uploads were submitted only on background ENTRY and in the rare
            // BGProcessing window, so a night of recording closed a dozen segments that nobody
            // handed to anything. Opening the app in the morning then meant watching the whole
            // backlog upload and transcribe at once, which is exactly the wait this avoids.
            await steps.submitPendingUploads()
            // ...and what the outbox gained while deferred (a transcription the background
            // session finished, a request applied) to the archive sync's own background session.
            await steps.syncArchive(false)
            // A deferring pass is still a completed pass: the loop is turning, and the watchdog
            // must not mistake a backgrounded app for a wedged one.
            health?.passCompleted()
            return PipelinePacing.backgroundMs
        }

        var processed = false
        /// Whether this pass changed something the archive server holds (see `syncArchive`).
        var archiveChanged = false

        // 2. Segments parked while no provider was usable become eligible the moment one is.
        if try await stage(.reconsiderDisabled, fallback: false, steps.reconsiderDisabled) {
            await steps.onDiagnosticsDirty()
        }

        // 3. Anything closed since the last pass joins the queue.
        try await stage(.enqueueClosedSegments, fallback: (), steps.enqueueClosedSegments)

        // 4. Drain, under the processing mutex owned by TranscriptionService.
        if try await stage(.drainQueue, fallback: false, heavy: true, steps.drainQueue) {
            processed = true
            archiveChanged = true
            await steps.onDiagnosticsDirty()
        }

        // 5. Retention. Self-paced (see `RetentionService`): normally a no-op, sweeping on its
        //    interval or as soon as the user changes "Keep audio". It sits here — after the
        //    queue work, before the regroup — so a sweep's deletions are reflected by the same
        //    pass that made them, instead of leaving the Library listing rows whose audio,
        //    transcript and follow-ups are already gone.
        if try await stage(.retention, fallback: false, steps.enforceRetentionIfDue) {
            processed = true
            archiveChanged = true
            // Deleted audio takes its recaps with it; the weeks and months written from them
            // are owed a look.
            memory.noteBriefsOwed(atMs: clock.nowMs)
            await steps.onDiagnosticsDirty()
        }

        // 5a. The cold tier: audio old enough and transcribed leaves for iCloud, confirmed
        //     uploads are evicted, a restore in progress advances. Self-paced inside the tier;
        //     after retention so nothing is moved that was about to be deleted.
        if try await stage(.coldStorage, fallback: false, steps.coldStorageIfDue) {
            processed = true
            await steps.onDiagnosticsDirty()
        }

        // 5b. What the newly transcribed audio holds. Cheap (turn timings, no model) and
        //     O(changed); ahead of the regroup so the boundary evidence and every AI stage in
        //     this pass read verdicts about the same transcripts they are about to use.
        if try await stage(.classifyAudio, fallback: false, steps.classifyAudio) {
            processed = true
            archiveChanged = true
        }

        // 6. Rebuild the conversation grouping — BEFORE the AI layer and never behind it.
        //    Library, Today's list, the live row and the Recording-now screen all read the
        //    grouped tables, so this is the step that makes a just-closed segment visible and
        //    shows the open one as live. It used to be the first line of `enrich`, which meant
        //    a long AI backfill froze the user's entire view of reality while recording
        //    continued.
        //    A thrown regroup reports "changed", so a grouping that could not be rebuilt never
        //    silences the stages behind it.
        let groupingChanged = try await stage(.regroup, fallback: true, steps.regroup)
        if groupingChanged { archiveChanged = true }

        // Voice identification: at most two short windows per call, and only on a charger
        // (`BackgroundWorkPolicy.decideVoiceRecognition`, applied inside the step, which also
        // paces itself while backgrounded). No speech is uploaded. A backgrounded slice does not
        // bring the next pass forward: its own pace decides when the next one runs.
        var voiceSliceRan = false
        if try await stage(.recognizeVoices, fallback: false, heavy: true,
                           when: !steps.isCatchUpActive(), steps.recognizeVoices) {
            if steps.isForeground() { processed = true } else { voiceSliceRan = true }
            archiveChanged = true
        }

        // 7-10 run only when there is something new for them to see. In the FOREGROUND that is
        //      always: the person is looking, and the live title and Today card are expected to
        //      follow the conversation as it happens. Backgrounded, the only readers are the
        //      widget and Spotlight, and the grouping stage has just established whether a
        //      single input changed. See `PipelinePassMemory`.
        let foreground = steps.isForeground()
        let aiStagesDue = foreground || groupingChanged || memory.aiStagesLeftWork

        // 6b. What the new transcripts' words are, before anything is titled from them. Its
        //     verdicts land in the NEXT pass's classification (and so the next enrich), which
        //     keeps this pass's inputs consistent with each other.
        let judged = try await stage(
            .judgeAudio, fallback: false, heavy: true, when: aiStagesDue, steps.judgeAudio)
        if judged { processed = true }

        // 7/8. Titles + summaries, then search/Spotlight donation of exactly what changed.
        //      BOUNDED per pass: the backlog drains over many passes rather than holding this
        //      one open for minutes.
        let enriched = try await stage(
            .enrich, fallback: [], heavy: true, when: aiStagesDue, steps.enrich)
        try await stage(.donate, fallback: ()) {
            guard !enriched.isEmpty else { return }
            processed = true
            await steps.donate(enriched)
            await steps.onDiagnosticsDirty()
        }

        // 9. Follow-up extraction over finished conversations (plan Part 4.5) — after enrich,
        //    on the same durable transcripts, and bounded the same way.
        let followUpsWrote = try await stage(
            .followUps, fallback: false, heavy: true, when: aiStagesDue, steps.extractFollowUps)
        if followUpsWrote {
            processed = true
            await steps.onDiagnosticsDirty()
        }
        if aiStagesDue {
            memory.aiStagesLeftWork = !enriched.isEmpty || followUpsWrote || judged
        }
        if !enriched.isEmpty || followUpsWrote || judged { archiveChanged = true }

        // 10. Daily recap (its own debounce decides whether anything actually runs). A summary of
        //     the day that nobody reads while the app is closed: backgrounded, it is reconsidered
        //     on a long interval and only once the grouping has changed since.
        let recapDue: Bool
        if foreground {
            recapDue = true
        } else {
            recapDue =
                aiStagesDue
                && memory.lastBackgroundRecapAtMs.map {
                    clock.nowMs - $0 >= PipelinePacing.backgroundRecapIntervalMs
                } ?? true
        }
        let recapWrote = try await stage(
            .recap, fallback: false, heavy: true, when: recapDue, steps.refreshRecap)
        if recapDue, !foreground { memory.lastBackgroundRecapAtMs = clock.nowMs }
        if recapWrote {
            memory.noteBriefsOwed(atMs: clock.nowMs)
            archiveChanged = true
        }

        // 10b. History's headlines and briefs, from the recaps just written. Change-gated in
        //      BOTH states: the stage does nothing at all unless a recap changed or it said it
        //      has work left (a backlog, a current period's cadence, a failure's backoff) — so a
        //      pass where nothing changed costs it nothing. Backgrounded, it also keeps the
        //      recap's long interval: nobody is reading History with the app closed.
        let briefsDue = memory.briefsDue(atMs: clock.nowMs) && (foreground || recapDue)
        let briefs = try await stage(
            .briefs, fallback: PeriodBriefPassOutcome?.none, heavy: true, when: briefsDue
        ) { () async throws -> PeriodBriefPassOutcome? in
            let outcome = try await steps.refreshBriefs()
            // When to come back is noted BEFORE a failure is reported, so a failing brief waits
            // out its own backoff instead of being asked again next pass.
            memory.briefsDueAtMs = outcome.nextDueAtMs
            if let failure = outcome.failure { throw failure }
            return outcome
        }
        if (briefs?.calls ?? 0) > 0 {
            processed = true
            archiveChanged = true
        }

        // 11. Live preview of the OPEN segment — after the durable closed-segment work, in the
        //     same loop, so a possibly single-instance native model is never used concurrently.
        //
        //     Foreground only. The preview is the Recording-now screen's; on battery the
        //     background branch above already skips it, and on a charger it was the thing that
        //     kept the loop at a 1 s cadence all night — it does work on every pass while the
        //     watch streams, so every pass reported `processed`, and in RemoteFirst that work
        //     was a FLAC encode and a Soniox call per chunk, for text nobody could see. Foreground
        //     entry wakes the loop and the preview catches up.
        if try await stage(
            .liveLocal, fallback: false, heavy: true, when: foreground, steps.liveLocalPass)
        {
            processed = true
        }

        // 12. Cloud live previews are pruned once the durable transcript supersedes them.
        try await stage(.liveCloudPrune, fallback: (), steps.liveCloudPrune)

        // 13. Mirror closed segments to WAV when the user asked for it.
        try await stage(.wavExport, fallback: (), steps.exportWavIfEnabled)

        // 14. Shrink the foreground footprint between bursts: release the resident model once it
        //     has been idle. It reloads lazily on the next segment, which is also how a
        //     selected-model change takes effect.
        try await stage(.idleModelRelease, fallback: ()) {
            guard !processed else { return }
            await steps.releaseModelIfIdle()
        }

        // 14b. The archive sync, behind the same change gate as everything above: a pass that
        //      changed nothing the server holds costs it one in-memory read.
        await steps.syncArchive(archiveChanged)

        // 15. Hand the widget what this pass just produced — a new transcript line, a title
        //     enrichment finally wrote, a follow-up that appeared. The widget has no other way
        //     to learn any of it.
        await steps.refreshCoverageSnapshot()

        health?.passCompleted()
        return try await sleepMs(processed: processed, voiceSliceRan: voiceSliceRan)
    }

    private func sleepMs(processed: Bool, voiceSliceRan: Bool = false) async throws -> Int64 {
        if processed { return PipelinePacing.afterWorkMs }
        // A backgrounded voice slice comes back when its pace allows the next one.
        if voiceSliceRan {
            return min(max(steps.voiceSliceDueInMs(), PipelinePacing.minRetryMs), PipelinePacing.idleMs)
        }
        // The 5 s cadence exists so the live preview FEELS live. Backgrounded — which on a
        // charger is where this loop spends its nights — nobody is watching the preview, and
        // the idle cadence is what a segment that closes every 15 minutes actually needs.
        if steps.isForeground(), await steps.isFollowingOpenSegment() {
            return PipelinePacing.followingOpenSegmentMs
        }
        guard let retryAtMs = try await steps.nextRetryAtMs() else { return PipelinePacing.idleMs }
        let delta = retryAtMs - clock.nowMs
        return min(max(delta, PipelinePacing.minRetryMs), PipelinePacing.idleMs)
    }
}

/// The loop that runs `PipelinePass` forever, sleeping on the conflated wake channel between
/// passes. Cancellation ends the loop.
///
/// A thrown pass still backs off rather than spinning, but with per-stage isolation this is now
/// a backstop rather than the normal shape of failure: a stage that throws is contained,
/// recorded and retried on its own schedule, and the rest of the pass runs. Reaching the catch
/// below means something outside every stage boundary failed, which is worth counting
/// separately (`abandonedPasses`).
public struct PipelineLoop: Sendable {
    private let pass: PipelinePass
    private let wake: WakeChannel
    private let clock: RuntimeClock
    private let health: PipelineHealthMonitor?
    private let log: RuntimeLog

    public init(
        pass: PipelinePass,
        wake: WakeChannel,
        clock: RuntimeClock,
        health: PipelineHealthMonitor? = nil,
        log: RuntimeLog = .silent
    ) {
        self.pass = pass
        self.wake = wake
        self.clock = clock
        self.health = health
        self.log = log
    }

    public func run() async {
        while !Task.isCancelled {
            var sleepMs = PipelinePacing.failureBackoffMs
            do {
                sleepMs = try await pass.run()
            } catch is CancellationError {
                // The loop ends when IT is cancelled (a watchdog restart, `stop()`), never because
                // something inside a pass was — see `PipelinePass.stage`.
                if Task.isCancelled { return }
                if let health {
                    health.passAbandoned(CancellationError())
                } else {
                    log.failure("pipeline pass", CancellationError())
                }
            } catch {
                if let health {
                    health.passAbandoned(error)
                } else {
                    log.failure("pipeline pass", error)
                }
            }
            if Task.isCancelled { return }
            await wake.wait(timeoutMs: sleepMs, clock: clock)
        }
    }
}
