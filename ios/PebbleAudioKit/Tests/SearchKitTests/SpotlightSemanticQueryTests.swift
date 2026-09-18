import Foundation
import Testing

@testable import SearchKit

// The pure half of Ask's semantic recall: how a Spotlight result becomes a candidate
// conversation, and how a rank becomes a score. The OS query itself needs an index a test
// process does not have; what can be pinned here is everything that decides what Ask is handed
// once the OS has answered — and that a call never stalls.

@Suite("Spotlight semantic query")
struct SpotlightSemanticQueryTests {

    // MARK: - Id parsing

    /// The index keys on CONVERSATION ids (`conv-<firstMemberSegmentId>`), donated under the
    /// `"<kind>:<entityId>"` unique identifier. The conversation id has to come back out
    /// exactly, or the hit can never be matched to a segment.
    @Test func aConversationUniqueIdentifierYieldsItsConversationId() {
        #expect(
            SpotlightSemanticQuery.conversationId(
                fromUniqueIdentifier: "conversation:conv-9f2a") == "conv-9f2a")
        // Round-trips what the donator writes.
        let donated = SpotlightDonation.uniqueIdentifier(kind: .conversation, entityId: "conv-1")
        #expect(SpotlightSemanticQuery.conversationId(fromUniqueIdentifier: donated) == "conv-1")
    }

    /// A conversation id can itself contain the separator character in principle; only the
    /// first one splits kind from id.
    @Test func onlyTheFirstColonSeparatesKindFromId() {
        #expect(
            SpotlightSemanticQuery.conversationId(
                fromUniqueIdentifier: "conversation:conv-a:b") == "conv-a:b")
    }

    /// A note, recap or follow-up hit can never resolve to a recording, so it is not a
    /// candidate — silently, rather than as a hit that later matches nothing.
    @Test func otherKindsAndMalformedIdsAreNotCandidates() {
        for uniqueIdentifier in [
            "note:n-1", "recap:day-2026-09-18", "followup:f-1",
            "conversation:", ":conv-1", "conv-1", "", "meeting:conv-1",
        ] {
            #expect(
                SpotlightSemanticQuery.conversationId(fromUniqueIdentifier: uniqueIdentifier)
                    == nil,
                "\(uniqueIdentifier) must not be a candidate")
        }
    }

    // MARK: - Rank to score

    /// Spotlight returns an order, not a number. The score is linear in rank so that the batch
    /// scorer (sum + best) treats a top hit as worth more than several tail hits without
    /// letting one hit dwarf everything — and it depends on the LIMIT, not on how many others
    /// happened to come back, so the same rank means the same thing on every question.
    @Test func hitsScoreLinearlyByRankAgainstTheLimit() {
        let hits = SpotlightSemanticQuery.hits(
            rankedUniqueIdentifiers: [
                "conversation:conv-a", "conversation:conv-b", "conversation:conv-c",
            ],
            limit: 4)
        #expect(hits.map(\.id) == ["conv-a", "conv-b", "conv-c"])
        #expect(hits.map(\.score) == [1.0, 0.75, 0.5])
        // Order is preserved and scores strictly descend.
        #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score > $1.score })
    }

    @Test func nonConversationsAndDuplicatesDropOutWithoutConsumingARank() {
        let hits = SpotlightSemanticQuery.hits(
            rankedUniqueIdentifiers: [
                "note:n-1", "conversation:conv-a", "conversation:conv-a", "recap:day-1",
                "conversation:conv-b",
            ],
            limit: 10)
        #expect(hits.map(\.id) == ["conv-a", "conv-b"])
        #expect(hits.map(\.score) == [1.0, 0.9])
    }

    @Test func theLimitCapsTheHitsAndAZeroLimitYieldsNothing() {
        let ids = (0..<20).map { "conversation:conv-\($0)" }
        #expect(SpotlightSemanticQuery.hits(rankedUniqueIdentifiers: ids, limit: 5).count == 5)
        #expect(SpotlightSemanticQuery.hits(rankedUniqueIdentifiers: ids, limit: 0).isEmpty)
    }

    @Test func theDomainFilterNamesOurDomain() {
        #expect(
            SpotlightSemanticQuery.filterQuery(domainIdentifier: "dev.audiocompanion.app.search")
                == "domainIdentifier == \"dev.audiocompanion.app.search\"")
    }

    // MARK: - The deadline

    /// The producer finishing first releases the waiter with everything it appended.
    @Test func theCollectorReleasesOnFinishWithWhatArrived() async {
        let collector = SemanticRecallCollector()
        #expect(collector.append("conversation:conv-1") == 1)
        #expect(collector.append("conversation:conv-2") == 2)
        collector.finish(timedOut: false)
        let outcome = await collector.wait()
        #expect(outcome == SemanticRecallOutcome(
            uniqueIdentifiers: ["conversation:conv-1", "conversation:conv-2"], timedOut: false))
    }

    /// The deadline firing first releases the waiter with the PARTIAL list, and nothing the
    /// producer does afterwards changes the answer — a late result must not resume a
    /// continuation twice, and must not be mistaken for a complete one.
    @Test func theDeadlineReleasesThePartialListAndLateResultsAreIgnored() async {
        let collector = SemanticRecallCollector()
        collector.append("conversation:conv-1")
        let waiter = Task { await collector.wait() }
        collector.finish(timedOut: true)
        let outcome = await waiter.value
        #expect(outcome.uniqueIdentifiers == ["conversation:conv-1"])
        #expect(outcome.timedOut)
        // Late: ignored.
        #expect(collector.append("conversation:conv-2") == 1)
        collector.finish(timedOut: false)
        let again = await collector.wait()
        #expect(again == outcome)
    }

    #if canImport(CoreSpotlight)
        /// On a machine with no index for this process the call returns at once; on one with an
        /// index it returns by the deadline. Either way it returns, which is the property Ask
        /// depends on — a semantic pass that could hang would hang every large question.
        @Test func aRealQueryAlwaysComesBack() async {
            let recall = CoreSpotlightSemanticRecall(timeout: .milliseconds(300))
            let started = ContinuousClock.now
            let hits = await recall.rank(query: "what did the plumber quote", limit: 5)
            let elapsed = ContinuousClock.now - started
            #expect(hits.count <= 5)
            #expect(elapsed < .seconds(10))
            // Blank and zero-limit queries short-circuit without touching the OS at all.
            #expect(await recall.rank(query: "   ", limit: 5).isEmpty)
            #expect(await recall.rank(query: "plumber", limit: 0).isEmpty)
        }
    #endif
}
