import SwiftUI

/// Live Conversation view model: observes the growing transcript and drives the transport.
@Observable
@MainActor
final class LiveViewModel {
    private let dataSource: any LiveDataSource

    private(set) var snapshot: LiveSnapshot

    init(dataSource: (any LiveDataSource)? = nil) {
        let source = dataSource ?? AppDataSources.current.live
        self.dataSource = source
        self.snapshot = source.liveSnapshot()
    }

    func observe() async {
        for await value in dataSource.liveUpdates() {
            snapshot = value
        }
    }

    func pauseTapped() { dataSource.requestPause() }

    func stopTapped() { dataSource.requestStop() }
}
