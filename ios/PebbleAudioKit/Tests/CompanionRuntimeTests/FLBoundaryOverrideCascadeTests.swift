import AppDB
import CompanionRuntime
import Foundation
import SegmentStore
import Testing

// A manual "this is one conversation" / "this is two" decision is keyed by the segment that
// FOLLOWS the join. Delete that segment and the row is about a join that no longer exists: it can
// never apply again, and nothing else in the app ever removes it.
//
// `BoundaryOverrideStore.forget(segmentIds:)` was written for exactly this and had no caller. The
// leak is inert while segment ids are unique — nothing will ever match the stale row — but it is a
// decision the person made about a recording they have since deleted, sitting in the one table
// this cascade exists to keep honest.

@Suite("boundary override cascade") struct FLBoundaryOverrideCascadeTests {

    @Test func deletingASegmentForgetsTheManualBoundaryDecisionAboutIt() async throws {
        let fixture = try RuntimeFixture()
        let segmentId = try await Fixture.writeSegment(into: fixture.store)
        let overrides = BoundaryOverrideStore(db: fixture.database)
        try await overrides.set(segmentId: segmentId, decision: .split, atMs: 0)
        try await overrides.set(segmentId: "a-segment-that-survives", decision: .join, atMs: 0)

        #expect(await fixture.cascade.deleteSegment(segmentId))

        #expect(try await overrides.decision(forSegment: segmentId) == nil)
        // Only the deleted segment's decision goes: everyone else's standing answer is untouched.
        #expect(try await overrides.decision(forSegment: "a-segment-that-survives") == .join)
    }

    /// The open segment is never deleted, so nothing about it is forgotten either.
    @Test func refusingToDeleteTheOpenSegmentLeavesItsDecisionAlone() async throws {
        let fixture = try RuntimeFixture()
        _ = try await Fixture.writeSegment(into: fixture.store, close: false)
        let openId = try #require(await fixture.store.openSegmentId)
        let overrides = BoundaryOverrideStore(db: fixture.database)
        try await overrides.set(segmentId: openId, decision: .split, atMs: 0)

        #expect(await fixture.cascade.deleteSegment(openId) == false)

        #expect(try await overrides.decision(forSegment: openId) == .split)
    }
}
