import CompanionRuntime
import Foundation
import Testing

// Retention's pacing contract. The defect these pin: `enforce()` had no place in the pipeline at
// all, so lowering "Keep audio" appeared to do nothing until the app was killed and relaunched.

@Suite struct RetentionServiceTests {

    private final class Policy: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: RetentionConfigInputs
        init(days: Int) {
            _value = RetentionConfigInputs(
                maxAgeMs: Int64(days) * 24 * 60 * 60 * 1_000, maxTotalBytes: 1_000)
        }
        var value: RetentionConfigInputs {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private func service(
        clock: TestClock,
        policy: Policy,
        calls: CallRecorder,
        deletes: [String] = ["seg-1"]
    ) -> RetentionService {
        RetentionService(
            enforce: {
                calls.record("enforce")
                return deletes
            },
            cascadeDeleted: { id in calls.record("cascade:\(id)") },
            policy: { policy.value },
            clock: clock
        )
    }

    @Test func firstSweepRunsAndCascadesEveryEvictedSegment() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let service = service(
            clock: clock, policy: Policy(days: 30), calls: calls, deletes: ["a", "b"])

        let deleted = await service.sweepIfDue()

        #expect(deleted == ["a", "b"])
        #expect(calls.calls == ["enforce", "cascade:a", "cascade:b"])
    }

    @Test func sweepsAreSpacedByTheInterval() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let service = service(clock: clock, policy: Policy(days: 30), calls: calls, deletes: [])

        await service.sweepIfDue()
        #expect(calls.calls == ["enforce"])

        // Retention is durable I/O: a pass a second later must not repeat it.
        await clock.advance(by: 60_000)
        await service.sweepIfDue()
        #expect(calls.calls == ["enforce"], "a sweep every pass would stat every segment log")

        await clock.advance(by: RetentionService.sweepIntervalMs)
        await service.sweepIfDue()
        #expect(calls.calls == ["enforce", "enforce"])
    }

    /// The point of the whole exercise: someone who tightens "Keep audio" sees it happen, without
    /// polling and without waiting out the interval. The settings write wakes the pipeline, and
    /// the changed policy is itself the trigger.
    @Test func aChangedPolicySweepsOnTheVeryNextPass() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let policy = Policy(days: 365)
        let service = service(clock: clock, policy: policy, calls: calls, deletes: [])

        await service.sweepIfDue()
        #expect(calls.calls == ["enforce"])

        policy.value = RetentionConfigInputs(
            maxAgeMs: 7 * 24 * 60 * 60 * 1_000, maxTotalBytes: 1_000)
        await clock.advance(by: 1_000)
        await service.sweepIfDue()
        #expect(calls.calls == ["enforce", "enforce"])
    }

    /// The same trigger covers the opposite move — raising the window — so the first sweep after
    /// the change runs under the NEW policy rather than a stale, tighter one.
    @Test func raisingTheWindowAlsoTriggersOneSweepUnderTheNewPolicy() async throws {
        let clock = TestClock()
        let seen = CallRecorder()
        let policy = Policy(days: 7)
        let service = RetentionService(
            enforce: {
                seen.record("age:\(policy.value.maxAgeMs)")
                return []
            },
            cascadeDeleted: { _ in },
            policy: { policy.value },
            clock: clock
        )

        await service.sweepIfDue()
        policy.value = RetentionConfigInputs(
            maxAgeMs: 365 * 24 * 60 * 60 * 1_000, maxTotalBytes: 1_000)
        await service.sweepIfDue()

        #expect(
            seen.calls == [
                "age:\(7 * 24 * 60 * 60 * 1_000)", "age:\(365 * 24 * 60 * 60 * 1_000)",
            ])
    }

    @Test func backgroundMaintenanceSweepIgnoresTheInterval() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let service = service(clock: clock, policy: Policy(days: 30), calls: calls, deletes: [])

        await service.sweep()
        await service.sweep()

        #expect(calls.calls == ["enforce", "enforce"])
    }

    @Test func aSweepRunElsewhereCountsAsThisIntervalsSweep() async throws {
        let clock = TestClock()
        let calls = CallRecorder()
        let service = service(clock: clock, policy: Policy(days: 30), calls: calls, deletes: [])

        // Launch: the StartupSequencer already enforced retention.
        await service.noteSweptElsewhere()
        await service.sweepIfDue()

        #expect(calls.calls.isEmpty, "the first pass must not repeat the startup sweep")
    }

    @Test func aFailedSweepIsReportedAsNothingDeletedRatherThanThrowing() async throws {
        let clock = TestClock()
        let logged = CallRecorder()
        let service = RetentionService(
            enforce: { throw TestFailure() },
            cascadeDeleted: { _ in },
            policy: { RetentionConfigInputs(maxAgeMs: 1, maxTotalBytes: 1) },
            clock: clock,
            log: RuntimeLog { logged.record($0) }
        )

        #expect(await service.sweepIfDue().isEmpty)
        #expect(logged.calls.count == 1)
        #expect(logged.calls[0].contains("retention sweep"))
    }
}
