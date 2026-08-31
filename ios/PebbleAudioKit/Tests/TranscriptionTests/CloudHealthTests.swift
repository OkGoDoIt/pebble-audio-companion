import Foundation
import Testing

@testable import Transcription

// Port of `app/src/commonTest/.../CloudHealthMonitorTest.kt` — all 5 cases, same names.
@Suite struct CloudHealthTests {

    private func monitor() -> CloudHealthMonitor {
        CloudHealthMonitor(nowMs: { 1_000 }, failureThreshold: 3)
    }

    @Test func transientFailuresBelowThresholdAreNotSurfaced() {
        let monitor = monitor()
        monitor.report(.failed(message: "Request timeout"))
        monitor.report(.failed(message: "Request timeout"))
        // Two back-to-back failures still look transient — banner stays clear.
        #expect(monitor.state.status == .unknown)
    }

    @Test func repeatedFailuresSurfaceAsFailed() {
        let monitor = monitor()
        for _ in 0..<3 {
            monitor.report(.failed(message: "Request timeout"))
        }
        #expect(monitor.state.status == .failed)
        #expect(monitor.state.message == "Request timeout")
    }

    @Test func successResetsTheFailureStreak() {
        let monitor = monitor()
        monitor.report(.failed(message: "blip"))
        monitor.report(.failed(message: "blip"))
        monitor.report(.ok(detail: "connected"))
        #expect(monitor.state.status == .ok)
        // Streak reset: the next two failures are again treated as transient.
        monitor.report(.failed(message: "blip"))
        monitor.report(.failed(message: "blip"))
        #expect(monitor.state.status == .ok)
    }

    @Test func notConfiguredSurfacesImmediately() {
        let monitor = monitor()
        monitor.report(.notConfigured(message: "Add an API key"))
        #expect(monitor.state.status == .notConfigured)
    }

    @Test func explicitProbeReportsImmediately() {
        let monitor = monitor()
        monitor.reportImmediate(.failed(message: "rejected the API key"))
        #expect(monitor.state.status == .failed)
        // And one more automatic failure keeps it visible (the streak was primed).
        monitor.report(.failed(message: "Request timeout"))
        #expect(monitor.state.status == .failed)
    }
}
