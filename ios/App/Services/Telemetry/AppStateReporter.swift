import Foundation
import StateReporting

/// The iOS 27 half of the activity tracker: hands each distinct label to StateReporting.
///
/// StateReporting is a system-wide, rate-limited channel (a few transitions a minute is the
/// intended scale — "human-interaction timescales"); the tracker in front of it guarantees one
/// call per actual change, so nothing here throttles. The domain is registered with MetricKit by
/// `MetricReportsCollector`, which is what makes a day's CPU arrive already split by these labels.
///
/// No stable or volatile metadata: every distinct metadata value is another aggregation bucket,
/// and the six labels are the whole vocabulary on purpose (see `AppActivityState`). The same
/// domain must always be requested with the same metadata types — asking for it later with
/// different generics is a runtime fatal error — so `Never`/`Never` is fixed here and nowhere
/// else in the app requests this domain.
@available(iOS 27, *)
final class AppStateReporter: Sendable {
    /// Reverse-DNS, as StateReporting expects. One domain for the app; the label carries the
    /// state. `MetricReportsCollector` and the cost report both key off this exact string.
    static let domain = "dev.audiocompanion.app.activity"

    private let reporter: StateReporter<Never, Never>
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) {
        self.reporter = StateReporter<Never, Never>.reporter(for: Self.domain)
        self.log = log
    }

    /// The tracker's sink. One StateReporting transition and one flight-log line per call — the
    /// line is what a log reader correlates a heartbeat's `cpu=` against, and what the console
    /// grep on a simulator proves the reporter is alive with.
    func report(_ state: AppActivityState, inputs: AppActivityState.Inputs) {
        reporter.reportTransition(to: state.rawValue)
        log("activity state=\(state.rawValue) \(AppActivityState.describe(inputs))")
    }

    /// Clears the active state. Called when the composition is torn down (tests, a rebuilt
    /// graph) so the domain does not keep attributing time to a label nobody maintains.
    func clear() {
        reporter.reportTransition(to: nil)
        log("activity state=none")
    }
}
