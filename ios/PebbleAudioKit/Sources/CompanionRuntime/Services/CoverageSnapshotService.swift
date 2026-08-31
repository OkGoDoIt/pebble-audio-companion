import AppDB
import Foundation
import Receiver
import SegmentStore
import StatusUI

/// Keeps `coverage_snapshot.json` current (plan 6.8). The widget reads the file and nothing else,
/// so the three required triggers — segment close, pause events, app background — must all land
/// here, and every write must be complete (spans AND headline together).
public actor CoverageSnapshotService {
    private let store: SegmentStore
    private let pauseJournal: PauseJournal?
    private let writer: CoverageSnapshotWriter
    private let clock: RuntimeClock
    private let statusOf: @Sendable () -> StatusModel
    private let timeZoneID: @Sendable () -> String
    private let log: RuntimeLog

    public init(
        store: SegmentStore,
        writer: CoverageSnapshotWriter,
        clock: RuntimeClock,
        statusOf: @escaping @Sendable () -> StatusModel,
        pauseJournal: PauseJournal? = nil,
        timeZoneID: @escaping @Sendable () -> String = { TimeZone.current.identifier },
        log: RuntimeLog = .silent
    ) {
        self.store = store
        self.writer = writer
        self.clock = clock
        self.statusOf = statusOf
        self.pauseJournal = pauseJournal
        self.timeZoneID = timeZoneID
        self.log = log
    }

    /// Recomputes today's coverage and writes the snapshot. Records the trigger for tests and
    /// diagnostics — the plan names exactly three that must fire.
    @discardableResult
    public func refresh(_ trigger: CoverageSnapshotTrigger) async -> CoverageSnapshot {
        lastTrigger = trigger
        triggers.append(trigger)

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
            isRecording: status.family == .recording
        )
        writer.write(snapshot)
        return snapshot
    }

    /// The triggers seen so far (tests assert all three fire; the app ignores this).
    public private(set) var triggers: [CoverageSnapshotTrigger] = []
    public private(set) var lastTrigger: CoverageSnapshotTrigger?

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
