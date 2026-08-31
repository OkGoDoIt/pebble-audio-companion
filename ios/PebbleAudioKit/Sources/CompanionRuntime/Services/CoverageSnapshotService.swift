import AppDB
import Foundation
import Receiver
import SegmentStore
import StatusUI

/// What the widget needs that coverage alone cannot say: which conversation is being recorded
/// right now, the last thing heard in it, and what is still open. Supplied by the app's
/// composition root, because it is the only place that holds both the database and the
/// enrichment layer.
public struct CoverageLiveContext: Sendable, Equatable {
    /// The conversation still being recorded, if there is one.
    public var conversationTitle: String?
    /// Its most recent transcript line.
    public var latestLine: String?
    /// Head of the open follow-up list, newest first.
    public var followUps: [CoverageSnapshot.FollowUpRef]
    /// How many are open in total.
    public var openFollowUpCount: Int

    public init(
        conversationTitle: String? = nil,
        latestLine: String? = nil,
        followUps: [CoverageSnapshot.FollowUpRef] = [],
        openFollowUpCount: Int = 0
    ) {
        self.conversationTitle = conversationTitle
        self.latestLine = latestLine
        self.followUps = followUps
        self.openFollowUpCount = openFollowUpCount
    }
}

/// Keeps `coverage_snapshot.json` current (plan 6.8). The widget reads the file and nothing else,
/// so the three required triggers — segment close, pause events, app background — must all land
/// here, and every write must be complete (spans AND headline AND live context together).
public actor CoverageSnapshotService {
    private let store: SegmentStore
    private let pauseJournal: PauseJournal?
    private let writer: CoverageSnapshotWriter
    private let clock: RuntimeClock
    private let statusOf: @Sendable () -> StatusModel
    /// `isRunning` lets the provider skip the conversation lookup when nothing is being
    /// recorded — the follow-up half is still wanted, the live half would only be discarded.
    private let liveContextOf: (@Sendable (Bool) async -> CoverageLiveContext)?
    private let timeZoneID: @Sendable () -> String
    private let log: RuntimeLog

    /// The recent-activity window the widget draws: the last ten minutes, in 20-second buckets.
    /// Long enough to show whether a conversation is actually alive, short enough that every
    /// bar is about *now* rather than about the day.
    public static let activityWindowMs: Int64 = 10 * 60 * 1000
    public static let activityBarMs: Int64 = 20 * 1000

    public init(
        store: SegmentStore,
        writer: CoverageSnapshotWriter,
        clock: RuntimeClock,
        statusOf: @escaping @Sendable () -> StatusModel,
        pauseJournal: PauseJournal? = nil,
        liveContextOf: (@Sendable (Bool) async -> CoverageLiveContext)? = nil,
        timeZoneID: @escaping @Sendable () -> String = { TimeZone.current.identifier },
        log: RuntimeLog = .silent
    ) {
        self.store = store
        self.writer = writer
        self.clock = clock
        self.statusOf = statusOf
        self.pauseJournal = pauseJournal
        self.liveContextOf = liveContextOf
        self.timeZoneID = timeZoneID
        self.log = log
    }

    /// The heartbeat refresh, rate-limited. Recomputing coverage re-reads the OPEN segment's
    /// frame log (its fingerprint changes with every frame, so the cache cannot help it), which
    /// is far too much work to do on every pipeline pass — foreground passes come round once a
    /// second while anything is being processed.
    ///
    /// Returns nil when the call was skipped, so a caller can tell "not due" from "written".
    @discardableResult
    public func refreshIfDue(
        _ trigger: CoverageSnapshotTrigger, minIntervalMs: Int64
    ) async -> CoverageSnapshot? {
        if let last = lastWriteMs, clock.nowMs - last < minIntervalMs { return nil }
        return await refresh(trigger)
    }

    /// Recomputes today's coverage and writes the snapshot. Records the trigger for tests and
    /// diagnostics — the plan names exactly three that must fire.
    @discardableResult
    public func refresh(_ trigger: CoverageSnapshotTrigger) async -> CoverageSnapshot {
        lastTrigger = trigger
        triggers.append(trigger)
        lastWriteMs = clock.nowMs

        let nowMs = clock.nowMs
        let zone = timeZoneID()
        let segments = await store.listSegments()
        let dateKey = LogicalDay.dateKey(forMs: nowMs, timeZoneID: zone)
        let bounds = LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: zone)

        var inputs: [SegmentCoverageInput] = []
        var freshCache: [String: CachedCoverage] = [:]
        for meta in segments {
            let segmentZone = meta.recordedTimeZone ?? zone
            guard LogicalDay.dateKey(forMs: Int64(meta.startTimeMs), timeZoneID: segmentZone)
                == dateKey
            else { continue }
            // Frame extents are what separate VAD-quiet from recorded time, and reading them is
            // the expensive part. A closed segment's frames never change, so they are read once
            // per process — otherwise every segment close would re-decode the whole day.
            let fingerprint = CachedCoverage.Fingerprint(
                frameCount: meta.frameCount, isOpen: meta.isOpen
            )
            if let cached = cache[meta.segmentId], cached.fingerprint == fingerprint {
                inputs.append(SegmentCoverageInput(meta: meta, frameSampleRanges: cached.ranges))
                freshCache[meta.segmentId] = cached
                continue
            }
            let frames = await store.readFrames(meta.segmentId)
            let input = SegmentCoverageInput.from(meta: meta, frames: frames)
            inputs.append(input)
            freshCache[meta.segmentId] = CachedCoverage(
                fingerprint: fingerprint, ranges: input.frameSampleRanges
            )
        }
        // Only today's segments stay cached; yesterday's drop out with the day.
        cache = freshCache

        var pauses: [PauseInterval] = []
        if let pauseJournal, let bounds {
            pauses =
                (try? await pauseJournal.intervals(
                    overlappingMs: bounds.startMs, bounds.endMs
                )) ?? []
        }

        let coverage = CoverageComputer.todaySoFar(
            nowMs: nowMs, timeZoneID: zone, segments: inputs, pauses: pauses
        )
        let status = statusOf()
        let isRunning = status.family == .recording
        // The live context is the only part that touches the database; `isRunning` lets the
        // provider skip the conversation lookup when its answer would be discarded anyway.
        let live = await liveContextOf?(isRunning) ?? CoverageLiveContext()
        let snapshot = CoverageSnapshot(
            generatedAtMs: nowMs,
            dateKey: coverage.dateKey,
            timeZoneID: coverage.timeZoneID,
            dayStartMs: bounds?.startMs ?? nowMs,
            nowMs: nowMs,
            spans: coverage.spans,
            totalRecordedMs: coverage.totalRecordedMs,
            totalMissingMs: coverage.totalMissingMs,
            headline: status.headline,
            detail: status.detail,
            dot: status.dot.snapshotValue,
            isRecording: isRunning,
            state: status.family.snapshotValue,
            // Only claim a running stretch while capture is actually running: a paused or
            // disconnected widget must not show a timer that keeps counting up.
            currentStartedAtMs: isRunning
                ? Self.runningStretchStartMs(spans: coverage.spans, nowMs: nowMs) : nil,
            liveTitle: isRunning ? live.conversationTitle : nil,
            liveLine: isRunning ? live.latestLine : nil,
            activity: Self.activityBars(spans: coverage.spans, nowMs: nowMs),
            activityWindowMs: Self.activityWindowMs,
            followUps: live.followUps,
            openFollowUpCount: live.openFollowUpCount
        )
        writer.write(snapshot)
        return snapshot
    }

    // MARK: - v2 derivations (pure — no I/O, no decode)

    /// Where the stretch of capture that is still running began: walk back from `nowMs` through
    /// contiguous `recorded` / `quiet` spans, and stop where capture genuinely stopped.
    ///
    /// Two kinds of non-capture are walked THROUGH rather than treated as a boundary, as long as
    /// they add up to less than `gapToleranceMs`:
    ///  - `missing`, because a short Bluetooth blip is loss inside a conversation, not a new one
    ///    — resetting the timer there would make an hour-long meeting read as "just started";
    ///  - `off` at the very end, because coverage is built from frames that have arrived and the
    ///    last few seconds of a live conversation legitimately have not yet.
    ///
    /// `paused` is always a boundary: the user said stop, so the next stretch is a new one.
    public static func runningStretchStartMs(
        spans: [CoverageSpan], nowMs: Int64, gapToleranceMs: Int64 = 2 * 60 * 1000
    ) -> Int64? {
        var start: Int64?
        var skipped: Int64 = 0
        for span in spans.reversed() {
            // Ignore anything that has not happened yet.
            guard span.startMs < nowMs else { continue }
            switch span.kind {
            case .recorded, .quiet:
                start = span.startMs
                skipped = 0
            case .paused:
                return start
            case .missing, .off:
                skipped += max(0, min(span.endMs, nowMs) - span.startMs)
                if skipped > gapToleranceMs { return start }
            }
        }
        return start
    }

    /// The recent-activity profile: `activityWindowMs` ending at `nowMs`, bucketed. Each bar
    /// takes the most severe kind that overlaps it (loss must never be averaged away) and a
    /// `level` equal to the share of the bucket that was recorded audio.
    public static func activityBars(
        spans: [CoverageSpan],
        nowMs: Int64,
        windowMs: Int64 = CoverageSnapshotService.activityWindowMs,
        barMs: Int64 = CoverageSnapshotService.activityBarMs
    ) -> [CoverageSnapshot.ActivityBar] {
        guard windowMs > 0, barMs > 0 else { return [] }
        let count = Int(windowMs / barMs)
        guard count > 0 else { return [] }
        let windowStart = nowMs - windowMs
        // Severity order — the first kind present in a bucket wins its color.
        let priority: [CoverageKind] = [.missing, .paused, .recorded, .quiet, .off]

        return (0..<count).map { index in
            let barStart = windowStart + Int64(index) * barMs
            let barEnd = barStart + barMs
            var overlap: [CoverageKind: Int64] = [:]
            for span in spans where span.endMs > barStart && span.startMs < barEnd {
                let ms = min(span.endMs, barEnd) - max(span.startMs, barStart)
                if ms > 0 { overlap[span.kind, default: 0] += ms }
            }
            let kind = priority.first { (overlap[$0] ?? 0) > 0 } ?? .off
            let level = Double(overlap[.recorded] ?? 0) / Double(barMs)
            return CoverageSnapshot.ActivityBar(kind: kind, level: level)
        }
    }

    /// The triggers seen so far (tests assert all three fire; the app ignores this).
    public private(set) var triggers: [CoverageSnapshotTrigger] = []
    public private(set) var lastTrigger: CoverageSnapshotTrigger?
    /// When the last write went out, for `refreshIfDue`'s rate limit.
    public private(set) var lastWriteMs: Int64?

    /// How often the pipeline-pass heartbeat may rewrite the snapshot.
    ///
    /// Foreground: often enough that a widget glanced at during a live conversation is current.
    /// Background: rarely enough that a ~10 s Bluetooth wake is not spent re-reading the open
    /// segment's frame log, while still landing well inside the widget's 30-minute staleness
    /// window — the receive-path triggers (segment open/close) carry the rest.
    public static let foregroundHeartbeatMs: Int64 = 60 * 1000
    public static let backgroundHeartbeatMs: Int64 = 10 * 60 * 1000

    private var cache: [String: CachedCoverage] = [:]

    private struct CachedCoverage {
        struct Fingerprint: Equatable {
            let frameCount: Int64
            let isOpen: Bool
        }
        let fingerprint: Fingerprint
        let ranges: [Range<UInt64>]?
    }

    public nonisolated var snapshotURL: URL { writer.url }
}
