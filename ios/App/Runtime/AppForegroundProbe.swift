import Foundation
import UIKit

/// "Is the app on screen right now?", readable synchronously from any thread.
///
/// The local-model code needs this in two places that cannot reach `CompanionRuntime`'s
/// `RuntimeForegroundState`: `SelectableLocalTranscriptionProvider` (built in `AppComposition
/// .init` before that state exists) and `ParakeetModelStore.shared` (a kit singleton). Both ask
/// one question — may a cold Core AI specialization pass run now? — and the honest answer is
/// UIKit's own application state: `.active`/`.inactive` are on screen, `.background` is not.
/// The runtime's copy adds a "launched in the background" latch for the pipeline's cadence;
/// for this question the raw state is the right one.
final class AppForegroundProbe: @unchecked Sendable {
    static let shared = AppForegroundProbe()

    private let lock = NSLock()
    /// Optimistic until `install()` reads the real state: a probe that has never been installed
    /// (previews, tests) must not make every local model "unavailable in the background".
    private var onScreen = true
    private var observers: [NSObjectProtocol] = []

    var isForeground: Bool { lock.withLock { onScreen } }

    /// Seeds from `UIApplication` and follows its lifecycle notifications from then on.
    /// Idempotent; called from the composition on the main actor.
    @MainActor
    func install() {
        lock.withLock { onScreen = UIApplication.shared.applicationState != .background }
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let set: @Sendable (Bool) -> Void = { [weak self] value in
            self?.lock.withLock { self?.onScreen = value }
        }
        observers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
            ) { _ in set(false) },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
            ) { _ in set(true) },
            // A cold launch straight to the foreground posts only this one.
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
            ) { _ in set(true) },
        ]
    }
}
