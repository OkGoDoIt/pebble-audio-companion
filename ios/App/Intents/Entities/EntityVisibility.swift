import Foundation
import os
import SearchKit

/// The visibility setting as the entity layer reads it: synchronously, from any actor.
///
/// `IndexedEntity.hideInSpotlight` is a plain getter the system calls off the main actor, and
/// `AppSettings` is main-actor state, so the composition installs a provider here that reads
/// the runtime settings box (a lock-guarded mirror the pipeline already reads the same way).
/// Until something is installed — previews, a test that never asked — the answer is the
/// default, which is what a fresh install has.
enum EntityVisibility {
    // A bare closure in a generic inout lock accumulates reabstraction wrappers on reads
    // (swiftlang/swift#91348). On a long-running phone that exhausted the thread's stack.
    // Store an aggregate so reading the provider never writes back a wrapped function.
    private struct Provider: Sendable {
        var read: @Sendable () -> SystemSearchVisibility = { .default }
    }
    private static let provider = OSAllocatedUnfairLock(initialState: Provider())

    static func install(_ read: @escaping @Sendable () -> SystemSearchVisibility) {
        provider.withLock { $0.read = read }
    }

    static func current() -> SystemSearchVisibility {
        provider.withLock { $0.read }()
    }
}
