import Foundation
import Testing

@testable import SearchKit

// The rule for what leaves the app's sandbox for the system index, pinned per setting. The
// FTS half is deliberately not here: `SpotlightDonator` upserts the app index before the gate
// runs, and `TranscriptIndexDonatorTests` already prove the full text lands there.

@Suite struct SpotlightVisibilityGateTests {
    private static func donation(
        _ id: String, kind: IndexKind = .conversation, text: String? = "the whole transcript"
    ) -> SpotlightDonation {
        SpotlightDonation(
            entityId: id,
            kind: kind,
            title: "Coffee with Dana",
            contentDescription: "Talked about the roadmap.",
            textContent: text,
            keywords: ["work"],
            deepLinkURL: SpotlightDonator.deepLink(kind: kind, entityId: id),
            contentCreationDateMs: 1_000,
            startDateMs: 900
        )
    }

    /// `.full` is the historical behaviour (plan 4.7 "ported, not regressed"): byte-for-byte
    /// what was donated before the setting existed.
    @Test func fullPassesEveryDonationThroughUntouched() {
        let donations = [Self.donation("conv-1"), Self.donation("day-2026-09-18", kind: .recap)]

        let outcome = SpotlightVisibilityGate.apply(.full, to: donations)

        #expect(outcome.index == donations)
        #expect(outcome.remove.isEmpty)
    }

    /// Summaries keep the title, the summary, the tags and the dates — and drop the text.
    @Test func summariesDropTheTextAndKeepEverythingElse() throws {
        let outcome = SpotlightVisibilityGate.apply(.summaries, to: [Self.donation("conv-1")])

        #expect(outcome.remove.isEmpty)
        let indexed = try #require(outcome.index.first)
        #expect(indexed.textContent == nil)
        #expect(indexed.title == "Coffee with Dana")
        #expect(indexed.contentDescription == "Talked about the roadmap.")
        #expect(indexed.keywords == ["work"])
        #expect(indexed.startDateMs == 900)
        #expect(indexed.contentCreationDateMs == 1_000)
        #expect(indexed.deepLinkURL == "companion://conversation/conv-1")
        #expect(indexed.uniqueIdentifier == "conversation:conv-1")
    }

    /// A note's body is its `textContent`, so under summaries a note is its title only.
    @Test func summariesLeaveANoteAsItsTitle() {
        let note = SpotlightDonation(
            entityId: "note-1", kind: .note, title: "Decisions", textContent: "We agreed to ship.",
            deepLinkURL: "companion://note/note-1", contentCreationDateMs: 5
        )

        let outcome = SpotlightVisibilityGate.apply(.summaries, to: [note])

        #expect(outcome.index.map(\.textContent) == [nil])
        #expect(outcome.index.map(\.title) == ["Decisions"])
    }

    /// Off indexes nothing — and turns every donation into a removal, because an earlier pass
    /// under a more permissive setting may have left that document in the system index. "Off"
    /// means the index holds nothing of ours, not merely that we stopped adding to it.
    @Test func offIndexesNothingAndRemovesWhatWouldHaveBeenIndexed() {
        let donations = [
            Self.donation("conv-1"),
            Self.donation("note-1", kind: .note),
            Self.donation("fu-1", kind: .followUp, text: nil),
        ]

        let outcome = SpotlightVisibilityGate.apply(.off, to: donations)

        #expect(outcome.index.isEmpty)
        #expect(outcome.remove == ["conversation:conv-1", "note:note-1", "followup:fu-1"])
    }

    /// The gate is a function of the setting alone — an empty pass is empty under every value.
    @Test(arguments: SystemSearchVisibility.allCases)
    func anEmptyPassStaysEmpty(visibility: SystemSearchVisibility) {
        let outcome = SpotlightVisibilityGate.apply(visibility, to: [])
        #expect(outcome.index.isEmpty)
        #expect(outcome.remove.isEmpty)
    }

    /// The setting's own two predicates, which the entity layer reads directly
    /// (`hideInSpotlight`, and whether a transcript may be a property of an entity at all).
    @Test func thePredicatesAgreeWithTheGate() {
        #expect(!SystemSearchVisibility.off.donates)
        #expect(SystemSearchVisibility.summaries.donates)
        #expect(SystemSearchVisibility.full.donates)
        #expect(!SystemSearchVisibility.off.includesText)
        #expect(!SystemSearchVisibility.summaries.includesText)
        #expect(SystemSearchVisibility.full.includesText)
        #expect(SystemSearchVisibility.default == .full)
    }
}
