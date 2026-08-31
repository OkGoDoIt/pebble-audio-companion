import Foundation
import SegmentStore

/// Paced retention enforcement: the `RetentionManager` sweep plus the delete cascade over
/// whatever it evicted, with the "is it worth running again yet?" decision in one place.
///
/// Why this exists: `enforce()` used to have exactly two callers — `StartupSequencer` (behind a
/// once-per-process guard) and `runBackgroundMaintenance` (an opportunistic BGProcessing wake iOS
/// may not grant for hours). There was no retention stage in `PipelinePass` at all. So a user who
/// lowered "Keep audio" from 365 days to 7 watched the recordings count on that same screen sit
/// perfectly still, the Library keep listing everything, and reasonably concluded the control was
/// another placebo — the audio they had just asked to be deleted stayed on the phone until the
/// app was killed and relaunched.
///
/// It is also I/O — it stats every segment log and can delete many of them — so it is emphatically
/// not something to run every pass. Hence two triggers:
///
///  - **the interval** (`sweepIntervalMs`), the ordinary background cadence; and
///  - **a policy change**: the retention config differs from the one the last sweep ran under.
///
/// The second is what makes the setting feel real without polling. Every settings write wakes the
/// pipeline (`CompanionRuntime.notifyConfigChanged`), the next pass sees a policy it has not swept
/// under, and the deletion lands about a second after the tap. It is equally the guard for the
/// opposite move: someone who RAISES the window (recovering old audio, then setting "Keep audio"
/// to a year) gets one sweep under the NEW policy rather than a stale one holding the old, tighter
/// window.
public actor RetentionService {
    /// Ordinary cadence between sweeps when nothing changed. Long on purpose: retention is
    /// durable I/O, and nothing about it is urgent while the policy stands still.
    public static let sweepIntervalMs: Int64 = 15 * 60 * 1_000

    private let enforce: @Sendable () async throws -> [String]
    private let cascadeDeleted: @Sendable (String) async -> Void
    private let policy: @Sendable () -> RetentionConfigInputs
    private let clock: RuntimeClock
    private let intervalMs: Int64
    private let log: RuntimeLog

    private var lastSweepAtMs: Int64?
    private var lastSweptPolicy: RetentionConfigInputs?

    public init(
        enforce: @escaping @Sendable () async throws -> [String],
        cascadeDeleted: @escaping @Sendable (String) async -> Void,
        policy: @escaping @Sendable () -> RetentionConfigInputs,
        clock: RuntimeClock,
        intervalMs: Int64 = RetentionService.sweepIntervalMs,
        log: RuntimeLog = .silent
    ) {
        self.enforce = enforce
        self.cascadeDeleted = cascadeDeleted
        self.policy = policy
        self.clock = clock
        self.intervalMs = intervalMs
        self.log = log
    }

    /// True when the next pass should sweep: the policy moved, or the interval elapsed.
    public var isDue: Bool {
        if lastSweptPolicy != policy() { return true }
        guard let lastSweepAtMs else { return true }
        return clock.nowMs - lastSweepAtMs >= intervalMs
    }

    /// The pipeline stage. Returns the segment ids deleted (empty when nothing was due).
    @discardableResult
    public func sweepIfDue() async -> [String] {
        guard isDue else { return [] }
        return await sweep()
    }

    /// An unconditional sweep — the BGProcessing maintenance window, which exists precisely to do
    /// this kind of work and should not be turned away by the interval.
    @discardableResult
    public func sweep() async -> [String] {
        // Stamped BEFORE the work: a policy the user changes mid-sweep is then still newer than
        // the one recorded here, so the change gets its own sweep rather than being swallowed.
        lastSweepAtMs = clock.nowMs
        lastSweptPolicy = policy()
        do {
            let deleted = try await enforce()
            for segmentId in deleted {
                // Audio alone is not enough: the transcript, follow-ups, single-source AI outputs,
                // recap membership and index rows have to go with it, or content the user asked to
                // expire stays findable.
                await cascadeDeleted(segmentId)
            }
            return deleted
        } catch {
            log.failure("retention sweep", error)
            return []
        }
    }

    /// Records that an equivalent sweep just ran somewhere else — the `StartupSequencer`'s own
    /// retention step — so the first pipeline pass after launch does not immediately repeat it.
    public func noteSweptElsewhere() {
        lastSweepAtMs = clock.nowMs
        lastSweptPolicy = policy()
    }
}
