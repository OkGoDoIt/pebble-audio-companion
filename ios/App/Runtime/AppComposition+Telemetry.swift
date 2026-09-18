import CompanionRuntime
import Foundation
import UIKit

// Owned by the telemetry workstream. Starts MetricKit report collection and StateReporting
// (iOS 27) so the battery gate can read cost per app state. No-op on iOS 26.
extension AppComposition {
    /// Held statically because an extension cannot add stored properties; there is one
    /// composition per process, so one holder is the right count. Replaced (and the old one
    /// stopped) if a retried bootstrap builds a second graph.
    @MainActor private static var telemetryHolder: AnyObject?

    func installTelemetry() {
        guard #available(iOS 27, *) else {
            // Below iOS 27 there is no StateReporting and no per-state MetricKit; the heartbeat's
            // cpu= deltas remain the whole battery gate. Nothing to start, nothing to log.
            return
        }
        if let previous = Self.telemetryHolder as? TelemetryHolder { previous.stop() }
        let holder = TelemetryHolder(
            receiver: receiver,
            metricsDirectory: containerRoot
                .appendingPathComponent("diagnostics", isDirectory: true)
                .appendingPathComponent("metrics", isDirectory: true),
            log: { AppRuntimeLog.shared.record($0) })
        Self.telemetryHolder = holder
        holder.start()
    }
}

/// Keeps the iOS 27 telemetry objects alive and wires the activity tracker to its four sources.
///
/// The observers here obey the two rules the 2026-09-09 drain taught: none of them publishes the
/// thing it observes (the tracker feeds StateReporting and the log, never the receiver or the
/// hooks), and none of them does anything while nothing changes (every source is a conflated
/// stream or a notification, so an idle night costs no wake-ups beyond the sources' own).
@available(iOS 27, *)
@MainActor
final class TelemetryHolder {
    private let reporter: AppStateReporter
    private let tracker: AppActivityTracker
    private let collector: MetricReportsCollector
    private let receiver: ReceiverService
    private var tasks: [Task<Void, Never>] = []
    private var tokens: [NSObjectProtocol] = []

    init(receiver: ReceiverService, metricsDirectory: URL, log: @escaping @Sendable (String) -> Void) {
        self.receiver = receiver
        let reporter = AppStateReporter(log: log)
        self.reporter = reporter
        self.tracker = AppActivityTracker(
            initial: .init(foreground: Self.sceneIsActive()),
            sink: { state, inputs in reporter.report(state, inputs: inputs) })
        self.collector = MetricReportsCollector(
            directory: metricsDirectory, domain: AppStateReporter.domain, log: log)
    }

    func start() {
        // MetricKit first: the domain has to be enabled before the first transition is worth
        // anything, and the subscription is what receives yesterday's report at launch.
        collector.start()

        // Foreground. Seeded from the scenes rather than `applicationState` — a launch behind
        // the lock screen reads `.active` at this point (measured 2026-09-08) while its one scene
        // sits in `.background`, and only the scene says whether a person can see anything.
        // After the seed, UIKit's own edges: `didBecomeActive` is the promotion, and
        // `didEnterBackground` the demotion. `willResignActive` (the app switcher, a banner) is
        // transient and deliberately not a transition.
        let tracker = self.tracker
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            tracker.update { $0.foreground = true }
        })
        tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            tracker.update { $0.foreground = false }
        })

        // Streaming: the receiver's session state, the same subject residency keys off.
        let receiver = self.receiver
        tasks.append(Task.detached(priority: .utility) {
            for await state in receiver.state.stream() {
                tracker.update { $0.streaming = state.isStreaming }
            }
        })

        // Pipeline windows and playback, from the static hooks the BGTask handlers and the
        // player call (see `TelemetryEvents` for the two integration points).
        tasks.append(Task.detached(priority: .utility) {
            for await hooks in TelemetryEvents.state.stream() {
                tracker.update {
                    $0.pipelineWindowOpen = hooks.pipelineWindowOpen
                    $0.playback = hooks.playbackActive
                }
            }
        })

        // The first label, so the domain has a state from now rather than from the first change.
        tracker.prime()
    }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        collector.stop()
        reporter.clear()
    }

    /// True when a scene is in front and interactive. `UIApplication.applicationState` is not
    /// consulted: at composition time it has been measured to say `.active` for headless wakes.
    private static func sceneIsActive() -> Bool {
        UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
    }
}
