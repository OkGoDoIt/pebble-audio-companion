import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// A "don't suspend me while I am writing this down" assertion, renewed while audio is arriving.
///
/// This is the SECOND line of defence, not the first. `BackgroundResidency` is what normally keeps
/// this process running; when it holds, the app is never suspended and this assertion is redundant.
/// It exists for the windows where residency is not available — a phone call has interrupted the
/// audio session, the audio stack refused to start, or the user has capture on while something
/// else owns the hardware. In those windows iOS is back to waking a suspended app for each Core
/// Bluetooth callback and re-suspending it the moment the callback returns, and the callback
/// returns immediately: the delegate hands the frame to a channel and the actual decode, file
/// append and checkpoint happen afterwards on the cooperative pool. Being suspended in that gap
/// loses the frame AND skips the checkpoint, which is what the watch's liveness watchdog is
/// counting.
///
/// Apple's own example for `beginBackgroundTask` is exactly this: "call this method before writing
/// data to a file to prevent the system from suspending your app while the operation is in
/// progress."
///
/// Honest about what it buys: roughly thirty seconds of runtime, drawn from a single background
/// budget, not an extension that can be renewed forever. It covers the tail of each wake, not the
/// gaps between them — that is residency's job. Leaking one gets the app killed with 0x8badf00d,
/// so the release timer is not optional.
public final class BackgroundActivityAssertion: @unchecked Sendable {
    private let log: RuntimeLog
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "audio-companion.background-activity")
    private var releaseGeneration = 0

    #if canImport(UIKit)
        private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// How long after the last renewal the assertion is dropped. Comfortably longer than the gap
    /// between two data notifications on a live stream (~150 ms), short enough that a stream that
    /// really has stopped does not hold the budget open.
    private static let idleReleaseMs = 5_000

    public init(log: RuntimeLog = .silent) {
        self.log = log
    }

    /// Called on the Core Bluetooth delegate queue when a frame arrives. Cheap in the common case:
    /// once the assertion is held, renewing is a lock and an integer.
    public func renew() {
        #if canImport(UIKit)
            let needsStart: Bool = lock.withLock {
                releaseGeneration += 1
                return identifier == .invalid
            }
            if needsStart { begin() }
            scheduleRelease()
        #endif
    }

    /// Drops the assertion now — the app came to the foreground, or capture was turned off.
    public func release() {
        #if canImport(UIKit)
            end()
        #endif
    }

    #if canImport(UIKit)
        private func begin() {
            // `beginBackgroundTask` must be called on the main thread.
            DispatchQueue.main.async { [self] in
                let started = UIApplication.shared.beginBackgroundTask(
                    withName: "audio-companion.receive"
                ) { [weak self] in
                    // Expiry is a genuine diagnostic: it means the app was backgrounded WITHOUT
                    // residency for long enough to exhaust the budget, which is the state the
                    // whole reliability effort exists to avoid.
                    self?.log.write("background activity assertion expired")
                    self?.end()
                }
                let stale: UIBackgroundTaskIdentifier? = lock.withLock {
                    guard identifier == .invalid else { return started }
                    identifier = started
                    return nil
                }
                // Lost a race with another begin(): end the one we just took, not the live one.
                if let stale, stale != .invalid { UIApplication.shared.endBackgroundTask(stale) }
            }
        }

        private func end() {
            let held: UIBackgroundTaskIdentifier = lock.withLock {
                let value = identifier
                identifier = .invalid
                return value
            }
            guard held != .invalid else { return }
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(held) }
        }

        private func scheduleRelease() {
            let generation = lock.withLock { releaseGeneration }
            queue.asyncAfter(deadline: .now() + .milliseconds(Self.idleReleaseMs)) { [weak self] in
                guard let self else { return }
                guard self.lock.withLock({ self.releaseGeneration == generation }) else { return }
                self.end()
            }
        }
    #endif
}
