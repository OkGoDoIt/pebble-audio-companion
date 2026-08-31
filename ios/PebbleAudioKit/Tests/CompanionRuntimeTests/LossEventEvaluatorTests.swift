import CompanionRuntime
import Foundation
import SegmentStore
import Testing
import WireProtocol

// Q9 trigger mechanics (plan 6.10). The whole point of this notification is that it is rare and
// always deserved, so every exclusion gets its own case.

@Suite struct LossEventEvaluatorTests {

    private func evaluator(
        notifier: RecordingLossNotifier,
        active: Bool = true,
        paused: Bool = false
    ) -> LossEventEvaluator {
        LossEventEvaluator(
            notifier: notifier,
            captureIsActive: { active },
            isPaused: { paused }
        )
    }

    @Test func thirtySecondVisibleLossFires() async throws {
        let notifier = RecordingLossNotifier()
        let subject = evaluator(notifier: notifier)
        // 1500 frames * 20 ms = 30 000 ms, exactly at the threshold.
        let gap = Fixture.watchGap(reason: .transportReset, missingFrames: 1_500)
        let meta = Fixture.meta(gaps: [gap])

        let fired = await subject.gapPersisted(
            meta: meta, gap: gap, isSegmentOpen: false, nowMs: 1_000
        )

        #expect(fired?.cause == .interruption)
        #expect(fired?.durationMs == 30_000)
        #expect(notifier.events.count == 1)
    }

    @Test func twentyFiveSecondVisibleLossDoesNotFire() async throws {
        let notifier = RecordingLossNotifier()
        let subject = evaluator(notifier: notifier)
        let gap = Fixture.watchGap(reason: .transportReset, missingFrames: 1_250)  // 25 s
        let meta = Fixture.meta(gaps: [gap])

        let fired = await subject.gapPersisted(
            meta: meta, gap: gap, isSegmentOpen: false, nowMs: 1_000
        )

        #expect(fired == nil)
        #expect(notifier.events.isEmpty)
    }

    @Test func spoolOverflowFiresAtAnyLengthAndEvenWhileTheSegmentIsOpen() async throws {
        let notifier = RecordingLossNotifier()
        let subject = evaluator(notifier: notifier)
        // One single frame — far under the 30 s threshold.
        let gap = Fixture.watchGap(reason: .spoolOverflow, missingFrames: 1)
        let meta = Fixture.meta(gaps: [gap], isOpen: true)

        let fired = await subject.gapPersisted(
            meta: meta, gap: gap, isSegmentOpen: true, nowMs: 1_000
        )

        #expect(fired?.cause == .spoolOverflow)
        #expect(notifier.events.count == 1)
    }

    @Test func rateLimitAllowsAtMostOneNotificationPerHour() async throws {
        let notifier = RecordingLossNotifier()
        let subject = evaluator(notifier: notifier)
        let gap = Fixture.watchGap(reason: .transportReset, missingFrames: 3_000)  // 60 s
        let meta = Fixture.meta(gaps: [gap])

        _ = await subject.gapPersisted(meta: meta, gap: gap, isSegmentOpen: false, nowMs: 0)
        // 59 minutes later: still inside the window.
        _ = await subject.gapPersisted(
            meta: meta, gap: gap, isSegmentOpen: false, nowMs: 59 * 60_000
        )
        #expect(notifier.events.count == 1)

        // One hour after the first: allowed again.
        _ = await subject.gapPersisted(
            meta: meta, gap: gap, isSegmentOpen: false, nowMs: 60 * 60_000
        )
        #expect(notifier.events.count == 2)
    }

    @Test func quietIsNeverLoss() async throws {
        let notifier = RecordingLossNotifier()
        let subject = evaluator(notifier: notifier)
        // A long silence-suppressed span — the watch withheld known-quiet audio on purpose.
        let gap = Fixture.watchGap(reason: .silenceSuppressed, missingFrames: 30_000)
        let meta = Fixture.meta(gaps: [gap])

        let fired = await subject.gapPersisted(
            meta: meta, gap: gap, isSegmentOpen: false, nowMs: 1_000
        )

        #expect(fired == nil)
        #expect(notifier.events.isEmpty)
    }

    @Test func aSequenceSkipCoveredByASilenceGapIsQuietNotLoss() async throws {
        let notifier = RecordingLossNotifier()
        let subject = evaluator(notifier: notifier)
        let silence = Fixture.watchGap(
            reason: .silenceSuppressed, missingFrames: 2_000, firstSequence: 100
        )
        let skip = Fixture.sequenceSkipGap(missingFrames: 2_000, firstSequence: 100)
        let meta = Fixture.meta(gaps: [silence, skip])

        let fired = await subject.gapPersisted(
            meta: meta, gap: skip, isSegmentOpen: false, nowMs: 1_000
        )

        #expect(fired == nil)
    }

    @Test func pausedTimeNeverTriggers() async throws {
        let notifier = RecordingLossNotifier()
        // Intent is paused: the "missing" audio is the user's own choice.
        let subject = evaluator(notifier: notifier, active: false)
        let gap = Fixture.watchGap(reason: .transportReset, missingFrames: 6_000)  // 120 s
        let meta = Fixture.meta(gaps: [gap])

        _ = await subject.gapPersisted(meta: meta, gap: gap, isSegmentOpen: false, nowMs: 1_000)

        #expect(notifier.events.isEmpty)
    }

    @Test func anOpenPauseIntervalAlsoSuppresses() async throws {
        let notifier = RecordingLossNotifier()
        let subject = evaluator(notifier: notifier, active: true, paused: true)
        let gap = Fixture.watchGap(reason: .transportReset, missingFrames: 6_000)
        let meta = Fixture.meta(gaps: [gap])

        _ = await subject.gapPersisted(meta: meta, gap: gap, isSegmentOpen: false, nowMs: 1_000)

        #expect(notifier.events.isEmpty)
    }

    @Test func aUserDisabledWatchGapIsPausedTimeInWireForm() async throws {
        let notifier = RecordingLossNotifier()
        let subject = evaluator(notifier: notifier)
        let gap = Fixture.watchGap(reason: .userDisabled, missingFrames: 6_000)
        let meta = Fixture.meta(gaps: [gap])

        _ = await subject.gapPersisted(meta: meta, gap: gap, isSegmentOpen: false, nowMs: 1_000)

        #expect(notifier.events.isEmpty)
    }

    @Test func openSegmentSuppressesUntilTheSegmentCloses() async throws {
        let notifier = RecordingLossNotifier()
        let subject = evaluator(notifier: notifier)
        let gap = Fixture.watchGap(reason: .transportReset, missingFrames: 3_000)  // 60 s
        let meta = Fixture.meta(segmentId: "seg-open", gaps: [gap], isOpen: true)

        // B21: nothing while the segment is still recording…
        let deferred = await subject.gapPersisted(
            meta: meta, gap: gap, isSegmentOpen: true, nowMs: 1_000
        )
        #expect(deferred == nil)
        #expect(notifier.events.isEmpty)

        // …and exactly one notification when it closes.
        let fired = await subject.segmentClosed(segmentId: "seg-open", nowMs: 2_000)
        #expect(fired?.cause == .interruption)
        #expect(fired?.detectedAtMs == 2_000)
        #expect(notifier.events.count == 1)

        // The candidate is consumed; closing again is a no-op.
        _ = await subject.segmentClosed(segmentId: "seg-open", nowMs: 3_000)
        #expect(notifier.events.count == 1)
    }

    @Test func deferredCandidatesKeepTheLongestLossForTheSegment() async throws {
        let notifier = RecordingLossNotifier()
        let subject = evaluator(notifier: notifier)
        let short = Fixture.watchGap(
            reason: .transportReset, missingFrames: 1_600, firstSequence: 100)  // 32 s
        let long = Fixture.watchGap(
            reason: .transportReset, missingFrames: 4_000, firstSequence: 9_000)  // 80 s
        let meta = Fixture.meta(segmentId: "seg-open", gaps: [short, long], isOpen: true)

        _ = await subject.gapPersisted(meta: meta, gap: short, isSegmentOpen: true, nowMs: 1_000)
        _ = await subject.gapPersisted(meta: meta, gap: long, isSegmentOpen: true, nowMs: 2_000)
        let fired = await subject.segmentClosed(segmentId: "seg-open", nowMs: 3_000)

        #expect(fired?.durationMs == 80_000)
        #expect(notifier.events.count == 1)
    }

    @Test func forgettingASegmentDropsItsDeferredCandidate() async throws {
        let notifier = RecordingLossNotifier()
        let subject = evaluator(notifier: notifier)
        let gap = Fixture.watchGap(reason: .transportReset, missingFrames: 3_000)
        let meta = Fixture.meta(segmentId: "seg-open", gaps: [gap], isOpen: true)

        _ = await subject.gapPersisted(meta: meta, gap: gap, isSegmentOpen: true, nowMs: 1_000)
        await subject.forget(segmentId: "seg-open")
        _ = await subject.segmentClosed(segmentId: "seg-open", nowMs: 2_000)

        #expect(notifier.events.isEmpty)
    }
}
