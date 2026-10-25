import CompanionRuntime
import Intelligence
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
                // The cold tier right after it: nothing is moved that was about to be deleted.
                .coldStorage,
                // What the audio holds is decided before grouping reads its speech evidence.
                .classifyAudio,
                // Grouping precedes the AI layer and never waits on it — the whole UI reads the
                // grouped tables.
                .regroup,
                .recognizeVoices,
                .judgeAudio,
                .enrich,
                .donate,
                .followUps,
                .recap,
                // History's headlines and briefs read the recap just written.
                .briefs,
                .liveLocal,
                .liveCloudPrune,
                .wavExport,
                .idleModelRelease,
            ]
        )
    }

    @Test func foregroundVoiceStageWaitsForAnAlreadyRunningBackgroundCatchUp() async throws {
        let calls = CallRecorder(), stages = StageRecorder()
        let pass = pass(clock: TestClock(), recorder: stages) { steps in
            steps.isForeground = { true }
            steps.isCatchUpActive = { true }
            steps.drainQueue = { false } // The transcription processing mutex is held by the burst.
            steps.recognizeVoices = { calls.record("voice-model"); return true }
        }
        _ = try await pass.run()
        #expect(calls.calls.isEmpty)
        // Stage observation records even skipped steps; the model closure must not run.
        #expect(stages.stages.contains(.regroup))
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

    /// The one kind of transcription worth starting in the background, because WE do not do the
    /// work: the bytes go to `nsurlsessiond`, which transfers them on its own schedule and can do
    /// it while this app is suspended or not running at all.
    ///
    /// Uploads used to be submitted only on background ENTRY and in the rare BGProcessing window,
    /// so a night of recording closed a dozen segments that nobody handed to anything — and
    /// opening the app in the morning meant watching the whole backlog upload and transcribe at
    /// once. The deferring pass hands them over as they close.
    @Test func aBackgroundPassStillHandsFinishedSegmentsToTheUploader() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let pass = pass(clock: clock, recorder: recorder) { steps in
            steps.isForeground = { false }
            steps.releaseModel = { reason in calls.record("release:\(reason)") }
            steps.submitPendingUploads = { calls.record("submitUploads") }
            steps.drainQueue = {
                calls.record("drain")
                return false
            }
        }

        _ = try await pass.run()

        #expect(calls.calls.contains("submitUploads"))
        // ...and still no heavy work: the local model stays released and the queue is not drained.
        #expect(!calls.calls.contains("drain"))
        #expect(recorder.stages == [.backgroundDefer])
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
            steps.regroup = {
                calls.record("regroup")
                return true
            }
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
            steps.regroup = {
                calls.record("regroup")
                return true
            }
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
        steps.regroup = {
                calls.record("pass")
                return true
            }
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
        steps.regroup = {
                calls.record("regroup")
                return true
            }
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

extension PipelinePassTests {
    /// 2026-09-18/29: the local model released under an in-flight transcription (the app left
    /// the foreground) surfaced as a `CancellationError` from INSIDE the drain stage. The loop
    /// read that as its own cancellation and returned — nothing ran until the watchdog noticed
    /// ten minutes later. Only the loop's own cancellation may end it now.
    @Test func anInterruptionInsideAStageDoesNotEndTheLoop() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let health = PipelineHealthMonitor(nowMs: { clock.nowMs })
        var steps = PipelineSteps()
        steps.drainQueue = { throw CancellationError() }
        steps.regroup = {
            calls.record("regroup")
            return true
        }
        let loop = PipelineLoop(
            pass: PipelinePass(steps: steps, clock: clock, health: health),
            wake: WakeChannel(),
            clock: clock,
            health: health
        )
        let task = Task { await loop.run() }
        await TestClock.settle()
        // The pass carried on past the interrupted stage...
        #expect(calls.calls.count == 1)
        // ...and the loop is still turning.
        await clock.advance(by: PipelinePacing.idleMs)
        await TestClock.settle()
        #expect(calls.calls.count >= 2)
        // Not a stage failure: nothing about the drain is broken.
        #expect(health.health.failingStages.contains(.drainQueue) == false)
        task.cancel()
        await task.value
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
    private var _count = 0
    var count: Int {
        get { lock.withLock { _count } }
        set { lock.withLock { _count = newValue } }
    }
}

// Thermal hold: the FOREGROUND pass stops spending the CPU and the neural engine once the phone
// is hot, while everything cheap keeps running. The background policy already refused at
// `.serious`; the foreground did not, and that is how a backlog catch-up cooked the phone and got
// the process thermally jettisoned.
@Suite struct PipelineThermalHoldTests {
    @Test func aHotPhoneSkipsModelWorkButKeepsTheCheapStagesAndTheOrder() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        var steps = PipelineSteps()
        steps.isThermallyThrottled = { true }
        steps.drainQueue = {
            calls.record("drain")
            return true
        }
        steps.enrich = {
            calls.record("enrich")
            return ["conv-1"]
        }
        steps.extractFollowUps = {
            calls.record("followUps")
            return true
        }
        steps.refreshRecap = { calls.record("recap"); return false }
        steps.liveLocalPass = {
            calls.record("liveLocal")
            return true
        }
        steps.regroup = {
                calls.record("regroup")
                return true
            }
        steps.enforceRetentionIfDue = {
            calls.record("retention")
            return false
        }
        steps.refreshCoverageSnapshot = { calls.record("snapshot") }
        let pass = PipelinePass(steps: steps, clock: clock, onStage: { recorder.record($0) })

        let sleepMs = try await pass.run()

        // Nothing heavy ran...
        #expect(!calls.calls.contains("drain"))
        #expect(!calls.calls.contains("enrich"))
        #expect(!calls.calls.contains("followUps"))
        #expect(!calls.calls.contains("recap"))
        #expect(!calls.calls.contains("liveLocal"))
        // ...the cheap, product-critical stages did...
        #expect(calls.calls.contains("regroup"))
        #expect(calls.calls.contains("retention"))
        #expect(calls.calls.contains("snapshot"))
        // ...the announced order is the same contract as ever...
        #expect(
            recorder.stages == [
                .reconsiderDisabled, .enqueueClosedSegments, .drainQueue, .retention, .coldStorage,
                .classifyAudio, .regroup, .recognizeVoices, .judgeAudio,
                .enrich, .donate, .followUps, .recap, .briefs, .liveLocal, .liveCloudPrune, .wavExport,
                .idleModelRelease,
            ]
        )
        // ...and with nothing processed the loop settles into its idle cadence rather than
        // spinning on work it is refusing to do.
        #expect(sleepMs == PipelinePacing.idleMs)
    }

    @Test func aCoolPhoneRunsModelWorkAsBefore() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        var steps = PipelineSteps()
        steps.isThermallyThrottled = { false }
        steps.drainQueue = {
            calls.record("drain")
            return false
        }
        let pass = PipelinePass(steps: steps, clock: clock, onStage: { recorder.record($0) })

        _ = try await pass.run()

        #expect(calls.calls.contains("drain"))
    }
}

// The charger-time pass. Measured 2026-09-11 on a phone on a desk charger: the pass ran every
// 5 s, and on each one the AI stages re-derived their whole work list from the library to find
// nothing to do — 10.5 of 21 CPU-s per 90 s — while the BLE keepalive under all that starved
// and dropped the link. The grouping stage already knows whether a single input changed; when
// it says no, the stages behind it have nothing new to look at.
@Suite struct PipelinePassChangeGateTests {

    private func chargerPass(
        clock: TestClock, recorder: StageRecorder, memory: PipelinePassMemory,
        configure: (inout PipelineSteps) -> Void
    ) -> PipelinePass {
        var steps = PipelineSteps()
        steps.isForeground = { false }
        steps.backgroundWorkDecision = { .run }
        configure(&steps)
        return PipelinePass(
            steps: steps, clock: clock, memory: memory, onStage: { recorder.record($0) })
    }

    @Test("an unchanged grouping skips the AI stages, announced but not run")
    func unchangedGroupingSkipsAiStages() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let memory = PipelinePassMemory()
        let pass = chargerPass(clock: clock, recorder: recorder, memory: memory) { steps in
            steps.regroup = { calls.record("regroup"); return false }
            steps.enrich = { calls.record("enrich"); return [] }
            steps.extractFollowUps = { calls.record("followUps"); return false }
            steps.refreshRecap = { calls.record("recap"); return false }
        }

        // First pass: nothing is known yet, so the stages run and settle.
        _ = try await pass.run()
        #expect(calls.calls == ["regroup", "enrich", "followUps", "recap"])
        calls.reset()

        // Second pass, nothing changed: the grouping runs (it is what decides), the rest do not.
        _ = try await pass.run()
        #expect(calls.calls == ["regroup"])
        // ...but the ORDER contract is intact — every stage is still announced.
        #expect(recorder.stages.filter { $0 == .enrich }.count == 2)
        #expect(recorder.stages.filter { $0 == .followUps }.count == 2)
        #expect(recorder.stages.filter { $0 == .recap }.count == 2)
    }

    @Test("a changed grouping runs them again")
    func changedGroupingRunsAiStages() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let memory = PipelinePassMemory()
        let changed = Recorder()
        let pass = chargerPass(clock: clock, recorder: recorder, memory: memory) { steps in
            steps.regroup = { changed.flag }
            steps.enrich = { calls.record("enrich"); return [] }
            steps.extractFollowUps = { calls.record("followUps"); return false }
        }
        changed.flag = false
        _ = try await pass.run()
        _ = try await pass.run()
        #expect(calls.calls == ["enrich", "followUps"], "settled after the first pass")
        calls.reset()

        changed.flag = true  // a segment closed, a transcript landed, a pause was journaled…
        _ = try await pass.run()
        #expect(calls.calls == ["enrich", "followUps"])
    }

    @Test("a backlog keeps draining across passes even when the grouping is unchanged")
    func leftoverWorkKeepsTheStagesRunning() async throws {
        // Enrich is budgeted per pass. A library with 40 untitled conversations and a budget of
        // 3 must not stop after the first 3 just because no segment closed in between.
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let memory = PipelinePassMemory()
        let remaining = Recorder()
        remaining.count = 3
        let pass = chargerPass(clock: clock, recorder: recorder, memory: memory) { steps in
            steps.regroup = { false }
            steps.enrich = {
                calls.record("enrich")
                guard remaining.count > 0 else { return [] }
                remaining.count -= 1
                return ["conv-\(remaining.count)"]
            }
        }
        for _ in 0..<6 { _ = try await pass.run() }
        // Three passes wrote a title each, the fourth found nothing and settled, and the two
        // after that were skipped.
        #expect(calls.calls.count == 4)
    }

    @Test("a thrown regroup never silences the stages behind it")
    func thrownRegroupCountsAsChanged() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let memory = PipelinePassMemory()
        let pass = chargerPass(clock: clock, recorder: recorder, memory: memory) { steps in
            steps.regroup = { throw TestFailure() }
            steps.enrich = { calls.record("enrich"); return [] }
        }
        _ = try await pass.run()
        _ = try await pass.run()
        #expect(calls.calls == ["enrich", "enrich"])
    }

    @Test("the foreground never consults the gate")
    func foregroundAlwaysRunsAiStages() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let memory = PipelinePassMemory()
        var steps = PipelineSteps()
        steps.isForeground = { true }
        steps.regroup = { false }
        steps.enrich = { calls.record("enrich"); return [] }
        steps.refreshRecap = { calls.record("recap"); return false }
        let pass = PipelinePass(
            steps: steps, clock: clock, memory: memory, onStage: { recorder.record($0) })
        for _ in 0..<3 { _ = try await pass.run() }
        #expect(calls.calls.filter { $0 == "enrich" }.count == 3)
        #expect(calls.calls.filter { $0 == "recap" }.count == 3)
    }

    @Test("the recap is reconsidered on a long interval while backgrounded")
    func backgroundRecapIsPaced() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let memory = PipelinePassMemory()
        let pass = chargerPass(clock: clock, recorder: recorder, memory: memory) { steps in
            steps.regroup = { true }  // something changes every pass
            steps.refreshRecap = { calls.record("recap"); return false }
        }
        _ = try await pass.run()
        await clock.advance(by: 60_000)
        _ = try await pass.run()
        #expect(calls.calls == ["recap"], "a minute later is too soon")
        await clock.advance(by: PipelinePacing.backgroundRecapIntervalMs)
        _ = try await pass.run()
        #expect(calls.calls == ["recap", "recap"])
    }

    @Test("the live preview itself is a foreground stage")
    func backgroundDoesNotTranscribeTheLivePreview() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let calls = CallRecorder()
        let memory = PipelinePassMemory()
        let pass = chargerPass(clock: clock, recorder: recorder, memory: memory) { steps in
            steps.liveLocalPass = { calls.record("liveLocal"); return true }
        }
        let sleep = try await pass.run()
        #expect(calls.calls.isEmpty)
        #expect(recorder.stages.contains(.liveLocal), "announced, so the order is intact")
        // ...and with nothing having done work, the loop idles instead of spinning at 1 s.
        #expect(sleep == PipelinePacing.idleMs)
    }

    @Test("the 5 s live-preview cadence is a foreground cadence")
    func backgroundDoesNotFollowTheOpenSegmentEveryFiveSeconds() async throws {
        let clock = TestClock()
        let recorder = StageRecorder()
        let memory = PipelinePassMemory()
        let pass = chargerPass(clock: clock, recorder: recorder, memory: memory) { steps in
            steps.isFollowingOpenSegment = { true }
        }
        #expect(try await pass.run() == PipelinePacing.idleMs)

        var steps = PipelineSteps()
        steps.isForeground = { true }
        steps.isFollowingOpenSegment = { true }
        let foreground = PipelinePass(steps: steps, clock: clock, memory: memory)
        #expect(try await foreground.run() == PipelinePacing.followingOpenSegmentMs)
    }
}

// The `.briefs` stage (History's headlines and briefs). Change-gated in BOTH states: it runs when
// a recap was written or when it said it had work left, and a pass where neither holds does not
// call it at all — the whole point, after the 2026-09-11 charger measurements, of every AI stage
// learning what changed before it looks.
@Suite struct PipelineBriefsStageTests {
    private func pass(
        clock: TestClock, recorder: StageRecorder = StageRecorder(), memory: PipelinePassMemory,
        health: PipelineHealthMonitor? = nil, configure: (inout PipelineSteps) -> Void
    ) -> PipelinePass {
        var steps = PipelineSteps()
        configure(&steps)
        return PipelinePass(
            steps: steps, clock: clock, health: health, memory: memory, onStage: { recorder.record($0) })
    }

    @Test("it looks once at launch; after that, nothing owed and nothing changed means no call")
    func nothingOwedNoCalls() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let recorder = StageRecorder()
        let memory = PipelinePassMemory()
        let pass = pass(clock: clock, recorder: recorder, memory: memory) { steps in
            steps.refreshRecap = { calls.record("recap"); return false }
            steps.refreshBriefs = { calls.record("briefs"); return .nothingOwed }
        }
        _ = try await pass.run()
        #expect(calls.calls == ["recap", "briefs"])
        calls.reset()
        for _ in 0..<5 {
            await clock.advance(by: 60_000)
            _ = try await pass.run()
        }
        // The foreground recap runs every pass (its own debounce decides); the briefs never.
        #expect(calls.calls == Array(repeating: "recap", count: 5))
        // ...while the ORDER contract holds: announced every time, right after the recap.
        let order = recorder.stages.filter { $0 == .recap || $0 == .briefs }
        #expect(order == Array(repeating: [PipelineStage.recap, .briefs], count: 6).flatMap { $0 })
    }

    @Test("a recap written makes it due in the same pass")
    func recapWriteMakesItDue() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let memory = PipelinePassMemory()
        let wrote = Recorder()
        let pass = pass(clock: clock, memory: memory) { steps in
            steps.refreshRecap = { wrote.flag }
            steps.refreshBriefs = { calls.record("briefs"); return .nothingOwed }
        }
        _ = try await pass.run()  // the launch look
        _ = try await pass.run()
        #expect(calls.calls == ["briefs"])
        wrote.flag = true
        _ = try await pass.run()
        #expect(calls.calls == ["briefs", "briefs"])
    }

    @Test("a backlog comes straight back, capped a run at a time; a cadence waits for its time")
    func backlogAndCadence() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let memory = PipelinePassMemory()
        let left = Recorder()
        left.count = 2
        let pass = pass(clock: clock, memory: memory) { steps in
            steps.refreshBriefs = {
                calls.record("briefs")
                if left.count > 0 {
                    left.count -= 1
                    return PeriodBriefPassOutcome(calls: 8, wrote: true, nextDueAtMs: clock.nowMs)
                }
                // Only the current week's cadence is left: three hours from now.
                return PeriodBriefPassOutcome(calls: 1, wrote: true, nextDueAtMs: clock.nowMs + 3 * 3_600_000)
            }
        }
        let sleep = try await pass.run()
        #expect(sleep == PipelinePacing.afterWorkMs, "calls made: come straight back")
        _ = try await pass.run()
        _ = try await pass.run()
        #expect(calls.calls.count == 3)
        for _ in 0..<4 {
            await clock.advance(by: 30 * 60_000)
            _ = try await pass.run()
        }
        #expect(calls.calls.count == 3, "two hours in, the cadence is not due")
        await clock.advance(by: 60 * 60_000)
        _ = try await pass.run()
        #expect(calls.calls.count == 4)
    }

    @Test("a failure is recorded against the stage and waits out the brief's own backoff")
    func failureWaits() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let memory = PipelinePassMemory()
        let health = PipelineHealthMonitor(nowMs: { clock.nowMs })
        let pass = pass(clock: clock, memory: memory, health: health) { steps in
            steps.refreshBriefs = {
                calls.record("briefs")
                return PeriodBriefPassOutcome(
                    calls: 1, nextDueAtMs: clock.nowMs + 30 * 60_000,
                    failure: PeriodBriefFailed(key: "day:2026-09-22", kind: .noConnection))
            }
        }
        _ = try await pass.run()
        #expect(health.health[.briefs].consecutiveFailures == 1)
        for _ in 0..<5 {
            await clock.advance(by: 5 * 60_000)
            _ = try await pass.run()
        }
        #expect(calls.calls.count == 1)
        await clock.advance(by: 5 * 60_000)
        _ = try await pass.run()
        #expect(calls.calls.count == 2)
    }

    @Test("backgrounded on a charger it keeps the recap's long interval")
    func backgroundKeepsTheRecapsPace() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let memory = PipelinePassMemory()
        let pass = pass(clock: clock, memory: memory) { steps in
            steps.isForeground = { false }
            steps.backgroundWorkDecision = { .run }
            steps.regroup = { true }
            steps.refreshBriefs = {
                calls.record("briefs")
                return PeriodBriefPassOutcome(calls: 8, wrote: true, nextDueAtMs: clock.nowMs)
            }
        }
        _ = try await pass.run()
        await clock.advance(by: 60_000)
        _ = try await pass.run()
        #expect(calls.calls.count == 1, "owed, but a minute later is too soon in the background")
        await clock.advance(by: PipelinePacing.backgroundRecapIntervalMs)
        _ = try await pass.run()
        #expect(calls.calls.count == 2)
    }

    @Test("a hot phone holds it without losing what is owed")
    func thermalHoldKeepsItOwed() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let memory = PipelinePassMemory()
        let hot = Recorder()
        hot.flag = true
        let pass = pass(clock: clock, memory: memory) { steps in
            steps.isThermallyThrottled = { hot.flag }
            steps.refreshBriefs = { calls.record("briefs"); return .nothingOwed }
        }
        _ = try await pass.run()
        #expect(calls.calls.isEmpty)
        hot.flag = false
        _ = try await pass.run()
        #expect(calls.calls == ["briefs"])
    }
}
