import Foundation
import Testing

@testable import AppDB

@Suite struct MomentStoreTests {
    @Test func aMarkSentTwiceIsKeptOnceAndARangeReadsInOrder() async throws {
        let store = MomentStore(db: try AppDatabase.inMemory())
        let first = Moment(id: "watch-100-1", wallMs: 5_000, onAudioClock: true, createdAtMs: 6_000)
        #expect(try await store.add(first))
        #expect(!(try await store.add(first)))
        try await store.add(
            Moment(id: "watch-50-2", wallMs: 2_000, onAudioClock: false, createdAtMs: 6_100))
        try await store.add(
            Moment(id: "watch-900-3", wallMs: 9_000, onAudioClock: true, createdAtMs: 9_100))

        let inside = try await store.moments(fromWallMs: 2_000, to: 9_000)
        #expect(inside.map(\.id) == ["watch-50-2", "watch-100-1"])
        #expect(inside.last?.onAudioClock == true)
        #expect(inside.last?.origin == .watch)
    }
}
