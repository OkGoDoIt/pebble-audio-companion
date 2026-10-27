import Foundation
import Testing

@testable import AppDB

@Suite struct MomentStoreTests {
    @Test func paginatedMarksKeepStableIDsAndEditsDoNotResurrectDeletes() async throws {
        let store = MomentStore(db: try AppDatabase.inMemory())
        for index in 0..<65 {
            try await store.add(Moment(id: "m-\(index)", wallMs: Int64(index), onAudioClock: false, createdAtMs: Int64(index)))
        }
        let first = try await store.page(offset: 0, limit: 40)
        let second = try await store.page(offset: 40, limit: 40)
        #expect(first.count == 40 && second.count == 25)
        #expect(Set((first + second).map(\.id)).count == 65)
        try await store.setNote(id: "m-64", note: "edited")
        #expect(try await store.load(id: "m-64")?.note == "edited")
        try await store.delete(id: "m-64")
        try await store.setNote(id: "m-64", note: "late edit")
        #expect(try await store.load(id: "m-64") == nil)
    }

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

    @Test func aResendPreservesThePersonsNoteAndFinishedReview() async throws {
        let store = MomentStore(db: try AppDatabase.inMemory())
        let moment = Moment(id: "watch-1", wallMs: 50_000, onAudioClock: true, createdAtMs: 51_000)
        try await store.add(moment)
        try await store.setNote(id: moment.id, note: "  keep this  ")
        let review = MomentReview(summary: "A useful idea", suggestions: [])
        try await store.saveReview(id: moment.id, review: review, state: "reviewed")
        try await store.add(moment)
        let read = try await store.moments(fromWallMs: 0, to: 100_000)
        #expect(read.first?.note == "keep this")
        #expect(read.first?.review == review)
        #expect(try await store.pendingReviews(nowMs: 100_000).isEmpty)
    }

    @Test func deletingContextClearsAIAndRejectsALateResultButKeepsTheNote() async throws {
        let store = MomentStore(db: try AppDatabase.inMemory())
        try await store.add(Moment(id: "mark", wallMs: 60_000, onAudioClock: true,
                                   createdAtMs: 61_000, note: "Mine"))
        let review = MomentReview(summary: "Private words", suggestions: [])
        try await store.saveReview(id: "mark", review: review, state: "reviewed")
        try await store.forgetRecordingContext(from: 20_000, to: 40_000)
        try await store.saveReview(id: "mark", review: review, state: "reviewed")
        let read = try await store.moments(fromWallMs: 0, to: 100_000)
        #expect(read.first?.review == nil)
        #expect(read.first?.reviewState == "unavailable")
        #expect(read.first?.note == "Mine")
        try await store.delete(id: "mark")
        try await store.saveReview(id: "mark", review: review, state: "reviewed")
        #expect(try await store.moments(fromWallMs: 0, to: 100_000).isEmpty)
    }

    @Test func aWatchRetryCannotResurrectADeletedMark() async throws {
        let store = MomentStore(db: try AppDatabase.inMemory())
        let moment = Moment(id: "watch-1", wallMs: 50_000, onAudioClock: true, createdAtMs: 51_000)
        try await store.add(moment)
        try await store.delete(id: moment.id)
        #expect(!(try await store.add(moment)))
        #expect(try await store.moments(fromWallMs: 0, to: 100_000).isEmpty)
    }

    @Test func failedReviewsRespectBackoff() async throws {
        let store = MomentStore(db: try AppDatabase.inMemory())
        try await store.add(Moment(id: "mark", wallMs: 60_000, onAudioClock: true, createdAtMs: 61_000))
        #expect(try await store.pendingReviews(nowMs: 70_000).isEmpty)
        #expect(try await store.pendingReviews(nowMs: 100_000).count == 1)
        try await store.saveReview(id: "mark", review: nil, state: "retry", nextMs: 500_000)
        #expect(try await store.pendingReviews(nowMs: 400_000).isEmpty)
        #expect(try await store.pendingReviews(nowMs: 500_000).count == 1)
    }
}
