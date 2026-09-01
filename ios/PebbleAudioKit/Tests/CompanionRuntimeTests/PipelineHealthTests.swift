import CompanionRuntime
import Foundation
import Testing

// Stage isolation and what the app is allowed to say about it.
//
// The regression these exist for: the pass was one `try` chain, so the FIRST stage to throw
// abandoned every stage behind it — on every pass, indefinitely, with one line in the detailed
// log as the only trace. A storage error while enqueueing closed segments therefore stopped the
// live preview and the conversation grouping too, and the app went on saying "Recording".

@Suite struct PipelineHealthTests {

    private func pass(
        clock: TestClock,
        health: PipelineHealthMonitor,
        recorder: StageRecorder = StageRecorder(),
        configure: (inout PipelineSteps) -> Void = { _ in }
    ) -> PipelinePass {
        var steps = PipelineSteps()
        configure(&steps)
        return PipelinePass(
            steps: steps, clock: clock, health: health, onStage: { recorder.record($0) })
    }

    private func monitor(_ clock: TestClock) -> PipelineHealthMonitor {
        PipelineHealthMonitor(nowMs: { clock.nowMs })
    }

    @Test func aFailingStageDoesNotStarveTheStagesBehindIt() async throws {
        let clock = TestClock()
        let health = monitor(clock)
        let calls = CallRecorder()
        let pass = pass(clock: clock, health: health) { steps in
            steps.enqueueClosedSegments = {
                calls.record("enqueue")
                throw TestFailure()
            }
            steps.regroup = { calls.record("regroup") }
            steps.liveLocalPass = {
                calls.record("live")
                return false
            }
        }

        // The pass completes rather than throwing, and everything downstream still ran.
        _ = try await pass.run()

        #expect(calls.calls == ["enqueue", "regroup", "live"])
        #expect(health.health[.enqueueClosedSegments].consecutiveFailures == 1)
        #expect(health.health[.regroup].isFailing == false)
        #expect(health.health.failingStages == [.enqueueClosedSegments])
        #expect(health.health.lastPassCompletedAtMs == clock.nowMs)
    }

    @Test func aFailingStageBacksOffInsteadOfThrowingEveryPass() async throws {
        let clock = TestClock()
        let health = monitor(clock)
        let calls = CallRecorder()
        let pass = pass(clock: clock, health: health) { steps in
            steps.drainQueue = {
                calls.record("drain")
                throw TestFailure()
            }
        }

        _ = try await pass.run()
        #expect(calls.calls.count == 1)

        // Inside the 5 s backoff the stage is skipped entirely — no exception, no work.
        await clock.advance(by: 4_000)
        _ = try await pass.run()
        #expect(calls.calls.count == 1)

        // Past it, tried again; the second failure doubles the wait.
        await clock.advance(by: 1_500)
        _ = try await pass.run()
        #expect(calls.calls.count == 2)
        #expect(health.health[.drainQueue].consecutiveFailures == 2)

        await clock.advance(by: 9_000)
        _ = try await pass.run()
        #expect(calls.calls.count == 2)
        await clock.advance(by: 1_500)
        _ = try await pass.run()
        #expect(calls.calls.count == 3)
    }

    @Test func aStageThatRecoversIsHealthyAgainImmediately() async throws {
        let clock = TestClock()
        let health = monitor(clock)
        let fail = Recorder()
        fail.flag = true
        let pass = pass(clock: clock, health: health) { steps in
            steps.regroup = {
                if fail.flag { throw TestFailure() }
            }
        }

        _ = try await pass.run()
        #expect(health.health[.regroup].isFailing)
        #expect(health.health[.regroup].lastFailureSummary != nil)

        fail.flag = false
        await clock.advance(by: 6_000)
        _ = try await pass.run()

        #expect(health.health[.regroup].isFailing == false)
        #expect(health.health[.regroup].consecutiveFailures == 0)
        #expect(health.health[.regroup].nextAttemptAtMs == nil)
        // The count of everything that ever went wrong survives — one pass working again is not
        // evidence that a stage failing one pass in three is well.
        #expect(health.health[.regroup].totalFailures == 1)
        #expect(health.health.failingStages.isEmpty)
    }

    @Test func cancellationStillStopsTheWholePass() async throws {
        let clock = TestClock()
        let health = monitor(clock)
        let calls = CallRecorder()
        let pass = pass(clock: clock, health: health) { steps in
            steps.enrich = {
                calls.record("enrich")
                throw CancellationError()
            }
            steps.liveLocalPass = {
                calls.record("live")
                return false
            }
        }

        await #expect(throws: CancellationError.self) { _ = try await pass.run() }
        #expect(calls.calls == ["enrich"])
        // Cancellation is the loop going away, not a stage misbehaving.
        #expect(health.health[.enrich].isFailing == false)
    }

    @Test func troubleIsOnlyCalledPersistentAfterThreePassesOfIt() async throws {
        let clock = TestClock()
        let health = monitor(clock)
        let pass = pass(clock: clock, health: health) { steps in
            steps.extractFollowUps = { throw TestFailure() }
        }

        _ = try await pass.run()
        #expect(health.health.failingStages == [.followUps])
        #expect(health.health.persistentlyFailingStages.isEmpty)

        await clock.advance(by: 6_000)
        _ = try await pass.run()
        #expect(health.health.persistentlyFailingStages.isEmpty)

        await clock.advance(by: 11_000)
        _ = try await pass.run()
        #expect(health.health.persistentlyFailingStages == [.followUps])
    }

    @Test func aBackgroundPassCountsAsTheLoopStillTurning() async throws {
        // The watchdog reads `lastPassCompletedAtMs`; a deferring background pass is a finished
        // pass, and mistaking a pocketed phone for a wedged loop would restart the loop forever.
        let clock = TestClock()
        let health = monitor(clock)
        let pass = pass(clock: clock, health: health) { steps in
            steps.isForeground = { false }
        }

        _ = try await pass.run()

        #expect(health.health.lastPassCompletedAtMs == clock.nowMs)
        #expect(health.health.passIsStalled(nowMs: clock.nowMs) == false)
    }

    @Test func aPassThatNeverFinishesReadsAsStalled() async throws {
        let clock = TestClock()
        let health = PipelineHealthMonitor(nowMs: { clock.nowMs })

        health.passStarted()
        #expect(health.health.passIsStalled(nowMs: clock.nowMs) == false)
        // Still inside the bound: a slow pass is not a wedged one.
        #expect(health.health.passIsStalled(nowMs: clock.nowMs + PipelineHealth.passStallMs) == false)
        #expect(health.health.passIsStalled(nowMs: clock.nowMs + PipelineHealth.passStallMs + 1))

        health.passCompleted()
        #expect(health.health.passIsStalled(nowMs: clock.nowMs + PipelineHealth.passStallMs + 1) == false)
    }

    @Test func healthOnlyPublishesWhatAScreenWouldRedrawFor() async throws {
        // B17: this struct is observed by the UI, and a healthy pass touches every stage's
        // `lastSuccessAtMs` every second. Publishing that would make it a reload key.
        let clock = TestClock()
        let health = monitor(clock)
        let received = Box<[PipelineHealth]>([])
        let stream = health.updates()
        let observer = Task {
            for await value in stream { received.mutate { $0.append(value) } }
        }
        await TestClock.settle()
        #expect(received.value.count == 1)  // the current value

        health.succeeded(.regroup)
        health.succeeded(.regroup)
        await clock.advance(by: 1_000)
        health.succeeded(.regroup)
        await TestClock.settle()
        #expect(received.value.count == 1)

        health.failed(.regroup, TestFailure())
        await TestClock.settle()
        #expect(received.value.count == 2)
        #expect(received.value.last?.failingStages == [.regroup])

        observer.cancel()
    }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    var value: Value { lock.withLock { _value } }
    init(_ value: Value) { _value = value }
    func mutate(_ transform: (inout Value) -> Void) { lock.withLock { transform(&_value) } }
}

// The half that acts on all of the above.
@Suite struct PipelineSupervisorTests {

    @Test func aWedgedPassGetsTheLoopRestarted() async throws {
        // Per-stage isolation cannot help with a stage that never RETURNS — a provider call
        // with no timeout, a mutex held by a task that is gone. The pass stops mid-flight and
        // the live preview, the grouping and the whole processing half stop with it, while the
        // app goes on saying "Recording".
        let clock = TestClock()
        let health = PipelineHealthMonitor(nowMs: { clock.nowMs })
        let restarts = Counter()
        let supervisor = PipelineSupervisor(
            health: health, clock: clock, restartLoop: { restarts.increment() })

        health.passStarted()
        #expect(await supervisor.tick().isEmpty)

        await clock.advance(by: PipelineHealth.passStallMs + 1)
        #expect(await supervisor.tick() == ["restart-loop"])
        #expect(restarts.count == 1)
        #expect(health.health.loopRestarts == 1)

        // The replacement loop starts a pass, which clears the stall.
        health.passStarted()
        health.passCompleted()
        #expect(await supervisor.tick().isEmpty)
        #expect(restarts.count == 1)
    }

    @Test func aHealthyLoopIsNeverRestarted() async throws {
        let clock = TestClock()
        let health = PipelineHealthMonitor(nowMs: { clock.nowMs })
        let restarts = Counter()
        let supervisor = PipelineSupervisor(
            health: health, clock: clock, restartLoop: { restarts.increment() })

        for _ in 0..<10 {
            health.passStarted()
            health.passCompleted()
            await clock.advance(by: 30_000)
            #expect(await supervisor.tick().isEmpty)
        }
        #expect(restarts.count == 0)
    }

    @Test func aStageIsRepairedOnlyOnceItsOwnBackoffHasStoppedBeingAPlan() async throws {
        let clock = TestClock()
        let health = PipelineHealthMonitor(nowMs: { clock.nowMs })
        let repairs = Counter()
        let supervisor = PipelineSupervisor(
            health: health,
            clock: clock,
            recoveries: [PipelineRecovery(stage: .drainQueue) { repairs.increment() }],
            restartLoop: {}
        )

        health.failed(.drainQueue, TestFailure())
        health.failed(.drainQueue, TestFailure())
        #expect(await supervisor.tick().isEmpty)
        #expect(repairs.count == 0)

        health.failed(.drainQueue, TestFailure())
        #expect(await supervisor.tick() == ["recover-drainQueue"])
        #expect(repairs.count == 1)
        // The repair clears the stage's backoff: a fix nobody retries proves nothing.
        #expect(health.health[.drainQueue].nextAttemptAtMs == nil)
        #expect(health.health[.drainQueue].recoveries == 1)

        // ...and does not itself become a loop.
        health.failed(.drainQueue, TestFailure())
        #expect(await supervisor.tick().isEmpty)
        await clock.advance(by: 60_000)
        #expect(await supervisor.tick() == ["recover-drainQueue"])
        #expect(repairs.count == 2)
    }

    @Test func aStageThatRecoversNeedsNoRepair() async throws {
        let clock = TestClock()
        let health = PipelineHealthMonitor(nowMs: { clock.nowMs })
        let repairs = Counter()
        let supervisor = PipelineSupervisor(
            health: health,
            clock: clock,
            recoveries: [PipelineRecovery(stage: .drainQueue) { repairs.increment() }],
            restartLoop: {}
        )

        for _ in 0..<5 { health.failed(.drainQueue, TestFailure()) }
        health.succeeded(.drainQueue)
        #expect(await supervisor.tick().isEmpty)
        #expect(repairs.count == 0)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func increment() { lock.withLock { _count += 1 } }
}
