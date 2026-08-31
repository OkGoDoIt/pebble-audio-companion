import Foundation
import Network

/// Is this phone on an unmetered link right now?
///
/// The Settings promise "Downloads run on Wi-Fi only" has to be enforced somewhere, and the
/// kit's `LocalModelManager` takes a synchronous, `Sendable` gate for exactly that. `NWPathMonitor`
/// pushes updates on its own queue, so the last path is cached behind a lock and read without
/// awaiting. Before the first path arrives the answer is `true` — an unknown link must not block
/// a download the user asked for; it only stops one we know is metered.
final class NetworkReachability: @unchecked Sendable {
    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var cachedUnmetered = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.store(path.status == .satisfied && !path.isExpensive)
        }
        monitor.start(queue: DispatchQueue(label: "dev.audiocompanion.reachability"))
    }

    /// Wi-Fi or wired — i.e. not cellular and not a personal hotspot.
    var isUnmetered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedUnmetered
    }

    private func store(_ value: Bool) {
        lock.lock()
        cachedUnmetered = value
        lock.unlock()
    }
}
