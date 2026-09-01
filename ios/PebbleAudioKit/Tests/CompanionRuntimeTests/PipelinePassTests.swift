import CompanionRuntime
import Foundation
import Testing

// The pass ORDER is the contract (plan Part 4.6). These tests pin the sequence itself, not just
// its effects, because the reason for the order — never using a single-instance native model
// concurrently — is invisible in any single step.

@Suite struct PipelinePassTests {

    private func pass(
        clock: TestClock,
        recorder: StageRecorder,
        configure: (inout PipelineSteps) -> Void = { _ in }
    ) -> PipelinePass {
        var steps = PipelineSteps()
        configure(&steps)
        return PipelinePass(steps: steps, clock: clock, onStage: { recorder.record($0) })
    }

    @Test func foregroundPassRunsEveryStageInPlanOrder() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let pass = pass(clock: clock, recorder: recorder) { steps in
            steps.enrich = { ["conv-1"] }
        }

        _ = try await pass.run()

        #expect(
            recorder.stages == [
                .reconsiderDisabled,
                .enqueueClosedSegments,
                .drainQueue,
                // Retention runs BEFORE the regroup, so a sweep's deletions are reflected by the
                // same pass that made them.
                .retention,
                // Grouping precedes the AI layer and never waits on it — the whole UI reads the
                // grouped tables.
                .regroup,
                .enrich,
                .donate,
                .followUps,
                .recap,
                .liveLocal,
                .liveCloudPrune,
                .wavExport,
                .idleModelRelease,
            ]
        )
    }

    @Test func backgroundPassEarlyReturnsBeforeAnyHeavyWork() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let pass = pass(clock: clock, recorder: recorder) { steps in
            steps.isForeground = { false }
            steps.releaseModel = { reason in calls.record("release:\(reason)") }
            steps.drainQueue = {
                calls.record("drain")
                return false
            }
            steps.enrich = {
                calls.record("enrich")
                return []
            }
        }

        let sleepMs = try await pass.run()

        #expect(recorder.stages == [.backgroundDefer])
        #expect(calls.calls == ["release:background"])
        #expect(sleepMs == PipelinePacing.backgroundMs)
    }

    @Test func backgroundPassYieldsModelToAnInProgressCatchUpBurst() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let pass = pass(clock: clock, recorder: recorder) { steps in
            steps.isForeground = { false }
            steps.isCatchUpActive = { true }
            steps.releaseModel = { reason in calls.record("release:\(reason)") }
        }

        _ = try await pass.run()

        #expect(calls.calls.isEmpty, "must not release the model under a running burst")
    }

    @Test func donationOnlyRunsForConversationsThatChanged() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let pass = pass(clock: clock, recorder: recorder) { steps in
            steps.enrich = { [] }
            steps.donate = { ids in calls.record("donate:\(ids.count)") }
        }

        _ = try await pass.run()

        #expect(calls.calls.isEmpty)
        // The stage is still visited, so the ORDER assertion above stays stable.
        #expect(recorder.stages.contains(.donate))
    }

    /// Regression: grouping used to be the first line of `enrich`, so a long AI backfill froze
    /// the user's entire view of reality — Library, Today's conversation list, the live row and
    /// the Recording-now screen all read the grouped tables — while recording carried on. The
    /// grouping is its own stage now, ahead of the AI layer and independent of whether it works.
    @Test func groupingRunsBeforeTheAiLayerAndSurvivesItsFailure() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let pass = pass(clock: clock, recorder: recorder) { steps in
            steps.regroup = { calls.record("regroup") }
            steps.enrich = {
                calls.record("enrich")
                throw CancellationError()
            }
        }

        _ = try? await pass.run()

        #expect(calls.calls == ["regroup", "enrich"])
        #expect(recorder.stages.contains(.regroup))
    }

    /// A pass that annotated something counts as having done work, so the loop comes straight
    /// back for the next bite of the backlog instead of idling for 30 s between mouthfuls.
    @Test func aPassThatAnnotatedOrExtractedComesBackPromptly() async throws {
        let clock = TestClock()
        let annotated = pass(clock: clock, recorder: StageRecorder()) { steps in
            steps.enrich = { ["conv-1"] }
        }
        #expect(try await annotated.run() == PipelinePacing.afterWorkMs)

        let extracted = pass(clock: clock, recorder: StageRecorder()) { steps in
            steps.extractFollowUps = { true }
        }
        #expect(try await extracted.run() == PipelinePacing.afterWorkMs)

        // A retention sweep that deleted something changed what every storage/library surface
        // shows, so it counts as work too.
        let swept = pass(clock: clock, recorder: StageRecorder()) { steps in
            steps.enforceRetentionIfDue = { true }
        }
        #expect(try await swept.run() == PipelinePacing.afterWorkMs)
    }

    /// Retention has to be visible in the same pass that performs it: the grouping the whole UI
    /// reads is rebuilt AFTER the sweep, so the Library never lists a conversation whose audio,
    /// transcript and follow-ups retention just deleted.
    @Test func retentionSweepsBeforeTheRegroupAndMarksDiagnosticsDirty() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let pass = pass(clock: clock, recorder: StageRecorder()) { steps in
            steps.drainQueue = {
                calls.record("drain")
                return false
            }
            steps.enforceRetentionIfDue = {
                calls.record("retention")
                return true
            }
            steps.regroup = { calls.record("regroup") }
            steps.onDiagnosticsDirty = { calls.record("diagnostics") }
        }

        _ = try await pass.run()

        #expect(calls.calls == ["drain", "retention", "diagnostics", "regroup"])
    }

    @Test func idleModelReleaseIsSkippedWhenThePassDidWork() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let pass = pass(clock: clock, recorder: recorder) { steps in
            steps.drainQueue = { true }
            steps.releaseModelIfIdle = { calls.record("idleRelease") }
        }

        _ = try await pass.run()

        #expect(calls.calls.isEmpty)
    }

    // MARK: - Adaptive pacing (fallback timer + retry clamps only)

    @Test func afterWorkSleepsOneSecond() async throws {
        let clock = TestClock()
        let pass = pass(clock: clock, recorder: StageRecorder()) { steps in
            steps.drainQueue = { true }
        }
        #expect(try await pass.run() == 1_000)
    }

    @Test func followingAnOpenSegmentSleepsFiveSeconds() async throws {
        let clock = TestClock()
        let pass = pass(clock: clock, recorder: StageRecorder()) { steps in
            steps.isFollowingOpenSegment = { true }
            // A pending retry must NOT win over the live cadence.
            steps.nextRetryAtMs = { 25_000 }
        }
        #expect(try await pass.run() == 5_000)
    }

    @Test func idlePassSleepsThirtySecondsWithNoPendingRetry() async throws {
        let clock = TestClock()
        let pass = pass(clock: clock, recorder: StageRecorder())
        #expect(try await pass.run() == 30_000)
    }

    @Test func pendingRetryIsClampedIntoOneToThirtySeconds() async throws {
        let clock = TestClock()
        await clock.advance(by: 10_000)

        // Retry already due (negative delta) clamps up to the 1 s floor.
        let due = pass(clock: clock, recorder: StageRecorder()) { steps in
            steps.nextRetryAtMs = { 5_000 }
        }
        #expect(try await due.run() == 1_000)

        // A retry inside the window is honoured exactly.
        let soon = pass(clock: clock, recorder: StageRecorder()) { steps in
            steps.nextRetryAtMs = { 10_000 + 7_500 }
        }
        #expect(try await soon.run() == 7_500)

        // A distant retry clamps down to the 30 s ceiling.
        let far = pass(clock: clock, recorder: StageRecorder()) { steps in
            steps.nextRetryAtMs = { 10_000 + 10 * 60_000 }
        }
        #expect(try await far.run() == 30_000)
    }

    // MARK: - The conflated wake channel

    @Test func wakeChannelConflatesSignalsAndCutsTheFallbackSleepShort() async throws {
        let clock = TestClock()
        let wake = WakeChannel()
        wake.signal()
        wake.signal()

        // A pending signal returns immediately without touching the clock.
        await wake.wait(timeoutMs: 30_000, clock: clock)
        #expect(clock.nowMs == 0)

        // The conflation means the second signal did not queue a second wake: this wait must
        // now depend on the timer.
        let waiter = Task { await wake.wait(timeoutMs: 30_000, clock: clock) }
        await TestClock.settle()
        wake.signal()
        await waiter.value
        #expect(clock.nowMs == 0, "a signalled wait must not consume the fallback timeout")
    }

    @Test func wakeChannelFallsBackToTheTimerWithoutSignals() async throws {
        let clock = TestClock()
        let wake = WakeChannel()
        let done = Recorder()
        let waiter = Task {
            await wake.wait(timeoutMs: 5_000, clock: clock)
            done.flag = true
        }
        await TestClock.settle()
        #expect(!done.flag)
        await clock.advance(by: 5_000)
        await waiter.value
        #expect(done.flag)
    }

    /// The loop-level backstop. With per-stage isolation a throwing STAGE no longer reaches
    /// here (`PipelineHealthTests` covers that); what still can is a failure outside every
    /// stage boundary — here the retry-schedule read that decides how long to sleep.
    @Test func loopBacksOffAfterAnAbandonedPassInsteadOfSpinning() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let health = PipelineHealthMonitor(nowMs: { clock.nowMs })
        var steps = PipelineSteps()
        steps.regroup = { calls.record("pass") }
        steps.nextRetryAtMs = { throw TestFailure() }
        let loop = PipelineLoop(
            pass: PipelinePass(steps: steps, clock: clock, health: health),
            wake: WakeChannel(),
            clock: clock,
            health: health
        )
        let task = Task { await loop.run() }
        await TestClock.settle()
        #expect(calls.calls.count == 1)

        // Nothing runs again until the 5 s failure backoff elapses.
        await clock.advance(by: 4_000)
        #expect(calls.calls.count == 1)
        await clock.advance(by: 1_000)
        #expect(calls.calls.count >= 2)
        #expect(health.health.abandonedPasses >= 1)
        task.cancel()
    }

    /// And the shape that used to end the same way but must not: one stage failing is now
    /// contained, so the loop keeps its normal cadence and every other stage keeps running.
    @Test func aFailingStageDoesNotStopTheLoop() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let health = PipelineHealthMonitor(nowMs: { clock.nowMs })
        var steps = PipelineSteps()
        steps.reconsiderDisabled = { throw TestFailure() }
        steps.regroup = { calls.record("regroup") }
        let loop = PipelineLoop(
            pass: PipelinePass(steps: steps, clock: clock, health: health),
            wake: WakeChannel(),
            clock: clock,
            health: health
        )
        let task = Task { await loop.run() }
        await TestClock.settle()
        #expect(calls.calls.count == 1)

        // Idle cadence, not failure backoff: the pass itself is fine.
        await clock.advance(by: PipelinePacing.idleMs)
        await TestClock.settle()
        #expect(calls.calls.count >= 2)
        #expect(health.health.abandonedPasses == 0)
        #expect(health.health.failingStages == [.reconsiderDisabled])
        task.cancel()
    }
}

struct TestFailure: Error {}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _flag = false
    var flag: Bool {
        get { lock.withLock { _flag } }
        set { lock.withLock { _flag = newValue } }
    }
}
