import Foundation
import UIKit

/// "Is the app on screen right now?", readable synchronously from any thread.
///
/// The local-model code needs this in two places that cannot reach `CompanionRuntime`'s
/// `RuntimeForegroundState`: `SelectableLocalTranscriptionProvider` (built in `AppComposition
/// .init` before that state exists) and `ParakeetModelStore.shared` (a kit singleton). Both ask
/// one question — may a cold Core AI specialization pass (~1.1 GB written, ~2 GB peak memory)
/// run now?
///
/// NOT seeded from `UIApplication.applicationState`: that reads `.active` on headless
/// background relaunches (21 of 22 process starts in the 2026-09-08 recorder, plainly headless
/// 30-minute wakes included), so a Core Bluetooth wake with the phone in a pocket was allowed
/// to start the rebuild. The launch starts NOT on screen until the scene says otherwise — the
/// same truth the runtime uses (`AppComposition.noteSceneActive` / `noteSceneBackground` and the
/// restoration relaunch), which call `set(_:)`. The UIKit notifications after launch are
/// truthful and still followed. A real foreground launch is promoted within a second, on the
/// root view's first appearance; nothing is lost by waiting that long.
final class AppForegroundProbe: @unchecked Sendable {
    static let shared = AppForegroundProbe()

    private let lock = NSLock()
    /// Optimistic until `install()` reads the real state: a probe that has never been installed
    /// (previews, tests) must not make every local model "unavailable in the background".
    private var onScreen = true
    private var observers: [NSObjectProtocol] = []

    var isForeground: Bool { lock.withLock { onScreen } }

    /// Set by the scene/restoration signals — see the type comment.
    func set(_ value: Bool) {
        lock.withLock { onScreen = value }
    }

    /// Seeds from whether a scene has ACTUALLY come up in this process, and follows UIKit's
    /// lifecycle notifications from then on. Idempotent; called on the main actor.
    @MainActor
    func install() {
        guard observers.isEmpty else { return }
        lock.withLock { onScreen = AppComposition.sceneHasBeenActive }
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
