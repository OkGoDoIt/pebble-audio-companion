import Foundation

// Owned by the telemetry workstream. Starts MetricKit report collection and StateReporting
// (iOS 27) so the battery gate can read cost per app state. No-op on iOS 26.
extension AppComposition {
    func installTelemetry() {
        // Filled in by the telemetry workstream.
    }
}
