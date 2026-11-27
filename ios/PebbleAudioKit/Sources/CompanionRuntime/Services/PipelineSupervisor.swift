import Foundation

// The half that acts. `PipelineHealthMonitor` knows what is wrong; this decides when knowing is
// not enough and something has to be done about it.
//
// Two escalations, and deliberately only two — every other recovery in this system belongs to
// the thing that failed (the link's own reconnect backoff, the queue's per-task retries, the
// live socket's handover to the chunk path), and duplicating those here would fight them:
//
//  1. A pass that STARTED and never finished. Per-stage isolation cannot help with a stage that
//     never returns — a provider call with no timeout, a mutex held by a task that is gone — and
//     a wedged pass takes the live preview, the grouping and the whole processing half down with
//     it while the app cheerfully goes on saying "Recording". The loop is restarted.
//  2. A stage whose own backoff has stopped being plausible: it has failed N times in a row, so
//     "wait longer and try the identical thing" is no longer a strategy. Each such stage may
//     name one repair to run before the next attempt.

/// One escalation: what to run when a stage keeps failing, and how often it may run.
public struct PipelineRecovery: Sendable {
    public let stage: PipelineStage
    /// Consecutive failures before this runs. At or above the persistent-failure threshold, so
    /// a blip never triggers a repair.
    public let afterConsecutiveFailures: Int
    /// Floor between two runs, so a recovery that does not fix anything is not itself a loop.
    public let minIntervalMs: Int64
    public let run: @Sendable () async -> Void

    public init(
        stage: PipelineStage,
        afterConsecutiveFailures: Int = PipelineHealth.persistentFailureThreshold,
        minIntervalMs: Int64 = 60_000,
        run: @escaping @Sendable () async -> Void
    ) {
        self.stage = stage
        self.afterConsecutiveFailures = afterConsecutiveFailures
        self.minIntervalMs = minIntervalMs
        self.run = run
    }
}

/// Drives the escalations on a timer. The runtime owns one and ticks it; tests tick it directly.
public actor PipelineSupervisor {
    private let health: PipelineHealthMonitor
    private let clock: RuntimeClock
    private let recoveries: [PipelineRecovery]
    private let restartLoop: @Sendable () async -> Void
    private let log: RuntimeLog

    private var lastRecoveryAtMs: [PipelineStage: Int64] = [:]

    /// How often the supervisor looks. Long: everything it watches is measured in minutes, and
    /// a tick costs a clock read and a dictionary walk.
    public static let tickMs: Int64 = 30_000
    /// A tick this late is a resumed process, not a slow one.
    public static let suspensionGapMs: Int64 = 3 * tickMs
    /// The last moment this process was known to be running: the previous tick, or — before the
    /// first one — when the supervisor was created or its timer started. It used to be nil until
    /// the first tick, so a process suspended within its first 30 s (iOS relaunches this app in
    /// the background and suspends it again seconds later, many times a day) came back with no
    /// reference to measure the gap against: 2026-09-26 06:39 and 07:40, "pipeline pass wedged
    /// in drainQueue (1804s without progress)" — a healthy pass cancelled for a suspension.
    private var lastTickAtMs: Int64

    public init(
        health: PipelineHealthMonitor,
        clock: RuntimeClock,
        recoveries: [PipelineRecovery] = [],
        restartLoop: @escaping @Sendable () async -> Void,
        log: RuntimeLog = .silent
    ) {
        self.health = health
        self.clock = clock
        self.recoveries = recoveries
        self.restartLoop = restartLoop
        self.log = log
        self.lastTickAtMs = clock.nowMs
    }

    /// One supervision round. Returns what it did, for tests and the detailed log.
    @discardableResult
    public func tick() async -> [String] {
        var actions: [String] = []
        let now = clock.nowMs
        // A tick that arrives much later than its interval means the process was suspended in
        // between, not that a pass ran for that long. Judge the stall from now on.
        if now - lastTickAtMs > Self.suspensionGapMs {
            health.passRebasedAfterSuspension()
        }
        lastTickAtMs = now
        let current = health.health

        if current.passIsStalled(nowMs: now) {
            // The pass has gone without progress past every plausible duration. Whatever it is
            // waiting on is not coming back on its own. Name the stage: the log is the only
            // witness to which call it was.
            let stage = current.inFlightStage?.rawValue ?? "between stages"
            let quiet = (current.msWithoutProgress(nowMs: now) ?? 0) / 1000
            log.write("pipeline pass wedged in \(stage) (\(quiet)s without progress); restarting the loop")
            await restartLoop()
            health.loopRestarted()
            actions.append("restart-loop")
        }

        for recovery in recoveries {
            let stage = health.health[recovery.stage]
            guard stage.consecutiveFailures >= recovery.afterConsecutiveFailures else { continue }
            if let last = lastRecoveryAtMs[recovery.stage], now - last < recovery.minIntervalMs {
                continue
            }
            lastRecoveryAtMs[recovery.stage] = now
            log.write("pipeline stage \(recovery.stage.rawValue): running recovery")
            await recovery.run()
            // Clears the stage's backoff too: a repair is only worth running if the next attempt
            // happens soon enough to show whether it worked.
            health.recoveryRan(for: recovery.stage)
            actions.append("recover-\(recovery.stage.rawValue)")
        }
        return actions
    }

    /// The timer loop. Cancellation ends it.
    public func run() async {
        lastTickAtMs = clock.nowMs
        while !Task.isCancelled {
            do { try await clock.sleep(ms: Self.tickMs) } catch { return }
            if Task.isCancelled { return }
            await tick()
        }
    }
}

/// Waiting on a task that may never come back.
public enum BoundedTaskWait {
    /// Waits for `task` to finish, for at most `milliseconds`. True when it finished in time.
    ///
    /// Returns as soon as either the task or the time is up, without waiting for the other. A
    /// task group cannot do this: it returns only once every child has, so the one child that
    /// awaits a task ignoring cancellation holds the caller for as long as that task runs. That
    /// is how a loop restart that promised "a moment" took 4 min 16 s (2026-11-27 15:08).
    public static func finished(
        _ task: Task<Void, Never>, withinMs milliseconds: Int64, clock: RuntimeClock
    ) async -> Bool {
        // The first outcome is kept and the second dropped.
        let (outcomes, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let watcher = Task {
            await task.value
            continuation.yield(true)
            continuation.finish()
        }
        let timer = Task {
            try? await clock.sleep(ms: milliseconds)
            continuation.yield(false)
            continuation.finish()
        }
        var finished = false
        for await outcome in outcomes {
            finished = outcome
            break
        }
        // Neither is awaited: the watcher ends when the task does, whenever that is.
        watcher.cancel()
        timer.cancel()
        return finished
    }
}
