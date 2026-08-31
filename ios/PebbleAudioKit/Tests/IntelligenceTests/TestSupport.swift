import Foundation
import SegmentStore
import WireProtocol

@testable import Intelligence

// Shared harness pieces for the Intelligence suites. Virtual time follows the TestClock
// approach (Tests/ReceiverTests/TestClock.swift): an injected, manually-advanced clock — these
// suites drive engines by direct calls, so a lock-protected mutable "now" is all they need.

/// Manually-advanced wall clock for `nowMs` closures shared across @Sendable captures.
final class TestWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64

    init(ms: Int64) {
        _now = ms
    }

    var now: Int64 {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }

    func advance(byMs ms: Int64) {
        lock.withLock { _now += ms }
    }
}

/// Epoch ms of a UTC wall-clock moment (the KMP tests' `atUtc`).
func atUtc(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int
) -> Int64 {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let date = cal.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    return Int64(date.timeIntervalSince1970 * 1000)
}

/// Minimal closed segment for recap/ask tests (KMP DailyRecapEngineTest's addSegment shape).
func makeIntelligenceSegment(
    id: String,
    startTimeMs: Int64,
    transcribed: Bool,
    recordedTimeZone: String? = nil,
    gaps: [GapMeta] = [],
    closeReason: CloseReasonMeta? = .rotated
) -> SegmentMeta {
    SegmentMeta(
        segmentId: id,
        streamId: 1,
        protocolVersion: 1,
        codecIdRaw: 1,
        channels: 1,
        frameSamples: 320,
        sampleRateHz: 16_000,
        bitRateBps: 9_800,
        frameDurationMs: 20,
        startTimeMs: UInt64(startTimeMs),
        startMonotonicMs: 1,
        receivedAtMs: startTimeMs,
        gaps: gaps,
        closeReason: closeReason,
        transcriptionState: transcribed ? .complete : .pending,
        recordedTimeZone: recordedTimeZone
    )
}
