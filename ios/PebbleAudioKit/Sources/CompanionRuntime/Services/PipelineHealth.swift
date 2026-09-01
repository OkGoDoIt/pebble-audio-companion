import Foundation

// Whether each part of the processing pass is actually working — kept as evidence (what ran,
// what completed, what threw and when) rather than inference, in the same spirit as
// `Receiver.StreamEvidence` for the link.
//
// The pass used to run as one `try` chain: the FIRST stage to throw aborted everything behind
// it. A storage error in `enqueueClosedSegments` therefore stopped the live preview, the
// grouping, enrichment and follow-ups too — every pass, forever — while the only trace was one
// line in the detailed log and a UI that went on saying "Recording". The stages are isolated
// now, and this is what remembers which of them is unwell so the app can say so and act on it.

/// One stage's observed state. All fields are facts; the verdicts are derived.
public struct StageHealth: Sendable, Equatable {
    /// Last time the stage ran to completion (whether or not it had work to do).
    public var lastSuccessAtMs: Int64?
    public var lastFailureAtMs: Int64?
    /// Failures with no intervening success. Drives both the backoff and "is this persistent".
    public var consecutiveFailures: Int
    /// Total failures since launch — a stage that fails one pass in three is unwell even though
    /// `consecutiveFailures` keeps resetting.
    public var totalFailures: Int
    /// The thrown error, described. **Diagnostics only** — never rendered on a status card.
    public var lastFailureSummary: String?
    /// While backed off, when the stage may next be attempted.
    public var nextAttemptAtMs: Int64?
    /// Times a recovery action has been run for this stage since launch.
    public var recoveries: Int

    public init(
        lastSuccessAtMs: Int64? = nil,
        lastFailureAtMs: Int64? = nil,
        consecutiveFailures: Int = 0,
        totalFailures: Int = 0,
        lastFailureSummary: String? = nil,
        nextAttemptAtMs: Int64? = nil,
        recoveries: Int = 0
    ) {
        self.lastSuccessAtMs = lastSuccessAtMs
        self.lastFailureAtMs = lastFailureAtMs
        self.consecutiveFailures = consecutiveFailures
        self.totalFailures = totalFailures
        self.lastFailureSummary = lastFailureSummary
        self.nextAttemptAtMs = nextAttemptAtMs
        self.recoveries = recoveries
    }

    /// Has never run — a stage the pass has not reached yet, or one skipped in this mode.
    public var hasRun: Bool { lastSuccessAtMs != nil || lastFailureAtMs != nil }

    /// Failing right now: its last attempt threw.
    public var isFailing: Bool { consecutiveFailures > 0 }

    /// Failing often enough that it will not fix itself. This is the threshold the UI speaks
    /// at — one blip is a blip, and this product does not raise alarms for blips.
    public var isPersistentlyFailing: Bool {
        consecutiveFailures >= PipelineHealth.persistentFailureThreshold
    }
}

/// The whole pass's health: every stage, plus whether the loop itself is still turning.
public struct PipelineHealth: Sendable, Equatable {
    public var stages: [PipelineStage: StageHealth]
    /// Last time a pass ran all the way to its end. The loop watchdog's evidence.
    public var lastPassCompletedAtMs: Int64?
    /// Last time a pass began. A pass that starts and never completes is a wedged stage, which
    /// looks nothing like a pass that is failing fast and needs a different response.
    public var lastPassStartedAtMs: Int64?
    /// Passes abandoned by a throw that stage isolation did not contain (cancellation aside).
    public var abandonedPasses: Int
    /// Times the loop itself has been restarted by the watchdog.
    public var loopRestarts: Int

    public init(
        stages: [PipelineStage: StageHealth] = [:],
        lastPassCompletedAtMs: Int64? = nil,
        lastPassStartedAtMs: Int64? = nil,
        abandonedPasses: Int = 0,
        loopRestarts: Int = 0
    ) {
        self.stages = stages
        self.lastPassCompletedAtMs = lastPassCompletedAtMs
        self.lastPassStartedAtMs = lastPassStartedAtMs
        self.abandonedPasses = abandonedPasses
        self.loopRestarts = loopRestarts
    }

    public subscript(stage: PipelineStage) -> StageHealth {
        stages[stage] ?? StageHealth()
    }

    /// Stages whose last attempt threw, worst first. Stable order for equal counts so the UI
    /// does not reshuffle between refreshes.
    public var failingStages: [PipelineStage] {
        stages
            .filter { $0.value.isFailing }
            .sorted { a, b in
                if a.value.consecutiveFailures != b.value.consecutiveFailures {
                    return a.value.consecutiveFailures > b.value.consecutiveFailures
                }
                return a.key.rawValue < b.key.rawValue
            }
            .map(\.key)
    }

    /// Stages failing persistently — what a user-facing surface is allowed to talk about.
    public var persistentlyFailingStages: [PipelineStage] {
        failingStages.filter { self[$0].isPersistentlyFailing }
    }

    /// True when the loop has not finished a pass within `passStallMs`. Only meaningful while
    /// the pass is supposed to be running at all (foreground); the caller knows that, this does
    /// not.
    public func passIsStalled(nowMs: Int64, stallMs: Int64 = PipelineHealth.passStallMs) -> Bool {
        guard let started = lastPassStartedAtMs else { return false }
        guard let completed = lastPassCompletedAtMs else { return nowMs - started > stallMs }
        return completed < started && nowMs - started > stallMs
    }

    /// The steps that turn recorded audio into words. Failing here means transcripts stop
    /// appearing for finished recordings — the one processing failure that changes what a
    /// person sees on Today, which is why it (and nothing else) may reach the status card.
    ///
    /// `liveLocal` is deliberately absent: the live transcript has its own honest line on the
    /// live row (`LiveTranscriptStatus.liveTranscriptionDown`), and the final transcript of the
    /// same audio is a different path that is still running.
    public static let transcriptionStages: [PipelineStage] = [.enqueueClosedSegments, .drainQueue]

    /// True when transcription has been failing long enough that it will not fix itself.
    /// Recording is unaffected either way — this says nothing about capture.
    public var transcriptionIsPersistentlyFailing: Bool {
        PipelineHealth.transcriptionStages.contains { self[$0].isPersistentlyFailing }
    }

    /// Consecutive failures before a stage's trouble is called persistent.
    public static let persistentFailureThreshold = 3

    /// How long a pass may be in flight before the loop is presumed wedged. Well past the
    /// slowest legitimate pass (a bounded enrichment bite over a cold model).
    public static let passStallMs: Int64 = 180_000
}

/// Records stage outcomes, paces retries of a failing stage, and publishes the result.
///
/// Deliberately a plain class with an injected clock (like `CloudHealthMonitor`): the pass calls
/// it from inside its own task and the UI observes it, so it can be neither an actor nor
/// MainActor-bound.
public final class PipelineHealthMonitor: @unchecked Sendable {
    private let nowMs: @Sendable () -> Int64
    private let backoffMs: @Sendable (Int) -> Int64
    private let log: RuntimeLog

    private let lock = NSLock()
    private var _health = PipelineHealth()
    private var continuations: [UUID: AsyncStream<PipelineHealth>.Continuation] = [:]

    /// First retry delay for a failing stage, doubling per consecutive failure.
    public static let baseBackoffMs: Int64 = 5_000
    /// Ceiling for that backoff. A stage that has been failing for five minutes is still
    /// retried every five minutes — the fix for most of them arrives from outside (a network
    /// that comes back, a key that gets fixed, space that gets freed).
    public static let maxBackoffMs: Int64 = 300_000

    public static func defaultBackoff(consecutiveFailures: Int) -> Int64 {
        guard consecutiveFailures > 0 else { return 0 }
        let shift = min(consecutiveFailures - 1, 16)
        return min(baseBackoffMs << shift, maxBackoffMs)
    }

    public init(
        nowMs: @escaping @Sendable () -> Int64,
        backoffMs: @escaping @Sendable (Int) -> Int64 = PipelineHealthMonitor.defaultBackoff,
        log: RuntimeLog = .silent
    ) {
        self.nowMs = nowMs
        self.backoffMs = backoffMs
        self.log = log
    }

    public var health: PipelineHealth { lock.withLock { _health } }

    /// Current value first, then every change.
    public func updates() -> AsyncStream<PipelineHealth> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                continuations[id] = continuation
                continuation.yield(_health)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    // --- what the pass reports -------------------------------------------------------------

    /// False while a failing stage is inside its backoff, so one broken stage costs the pass one
    /// comparison rather than an exception per pass forever.
    public func shouldRun(_ stage: PipelineStage) -> Bool {
        let now = nowMs()
        return lock.withLock {
            guard let next = _health[stage].nextAttemptAtMs else { return true }
            return now >= next
        }
    }

    public func succeeded(_ stage: PipelineStage) {
        let now = nowMs()
        update { health in
            var entry = health[stage]
            entry.lastSuccessAtMs = now
            entry.consecutiveFailures = 0
            entry.nextAttemptAtMs = nil
            entry.lastFailureSummary = nil
            health.stages[stage] = entry
        }
    }

    public func failed(_ stage: PipelineStage, _ error: Error) {
        let now = nowMs()
        let summary = String(describing: error)
        var delay: Int64 = 0
        var count = 0
        update { health in
            var entry = health[stage]
            entry.lastFailureAtMs = now
            entry.consecutiveFailures += 1
            entry.totalFailures += 1
            entry.lastFailureSummary = summary
            delay = backoffMs(entry.consecutiveFailures)
            count = entry.consecutiveFailures
            entry.nextAttemptAtMs = now + delay
            health.stages[stage] = entry
        }
        log.write(
            "pipeline stage \(stage.rawValue) failed (\(count)x, retry in \(delay / 1000)s): \(summary)"
        )
    }

    public func passStarted() {
        let now = nowMs()
        update { $0.lastPassStartedAtMs = now }
    }

    public func passCompleted() {
        let now = nowMs()
        update { $0.lastPassCompletedAtMs = now }
    }

    /// A pass that ended by throwing past the per-stage isolation.
    public func passAbandoned(_ error: Error) {
        update { $0.abandonedPasses += 1 }
        log.failure("pipeline pass", error)
    }

    public func loopRestarted() {
        update { $0.loopRestarts += 1 }
        log.write("pipeline loop restarted by the watchdog")
    }

    /// Records that a recovery action ran for a stage, and clears its backoff so the retry
    /// happens on the next pass rather than at the end of a five-minute wait.
    public func recoveryRan(for stage: PipelineStage) {
        update { health in
            var entry = health[stage]
            entry.recoveries += 1
            entry.nextAttemptAtMs = nil
            health.stages[stage] = entry
        }
    }

    private func update(_ transform: (inout PipelineHealth) -> Void) {
        let (next, changed, observers) = lock.withLock {
            () -> (PipelineHealth, Bool, [AsyncStream<PipelineHealth>.Continuation]) in
            let before = Signature(_health)
            transform(&_health)
            return (_health, before != Signature(_health), Array(continuations.values))
        }
        guard changed else { return }
        for continuation in observers { continuation.yield(next) }
    }

    /// What a UI observer actually cares about. A healthy pass touches `lastSuccessAtMs` on
    /// every stage every second or so; publishing that would make this struct a reload key and
    /// recompose the tree continuously, which is precisely the anti-goal (B17) the diagnostics
    /// snapshot was reshaped to avoid. Timestamps are still there for anyone who reads
    /// `health` directly — the Diagnostics screen does, on its own cadence.
    private struct Signature: Equatable {
        var failures: [String: Int]
        var recoveries: [String: Int]
        var abandonedPasses: Int
        var loopRestarts: Int

        init(_ health: PipelineHealth) {
            failures = [:]
            recoveries = [:]
            for (stage, entry) in health.stages {
                if entry.consecutiveFailures > 0 { failures[stage.rawValue] = entry.consecutiveFailures }
                if entry.recoveries > 0 { recoveries[stage.rawValue] = entry.recoveries }
            }
            abandonedPasses = health.abandonedPasses
            loopRestarts = health.loopRestarts
        }
    }
}
