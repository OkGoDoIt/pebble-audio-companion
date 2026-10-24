import Foundation
import Testing
@testable import AppDB

@Suite struct HistoryMomentDigestTests {
    @Test func markWritesRefreshOnlyTheRelevantHistoryWindow() async throws {
        let db = try AppDatabase.inMemory()
        let store = MomentStore(db: db)
        let scope = HistoryDigestScope(window: 100..<200, segmentIds: [], recapDateKeys: [], includeTags: false)
        let empty = try await HistoryDigest.read(db, scope: scope)
        try await store.add(Moment(id: "outside", wallMs: 200, onAudioClock: true, createdAtMs: 0))
        #expect(try await HistoryDigest.read(db, scope: scope) == empty)
        try await store.add(Moment(id: "inside", wallMs: 100, onAudioClock: true, createdAtMs: 0))
        let added = try await HistoryDigest.read(db, scope: scope)
        #expect(added != empty)
        try await store.saveReview(id: "inside", review: .init(summary: "No action", suggestions: []), state: "reviewed")
        #expect(try await HistoryDigest.read(db, scope: scope) == added)
        try await store.setNote(id: "inside", note: "My note")
        #expect(try await HistoryDigest.read(db, scope: scope) != added)
        try await store.delete(id: "inside")
        #expect(try await HistoryDigest.read(db, scope: scope) == empty)
    }
}
