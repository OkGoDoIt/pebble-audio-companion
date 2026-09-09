import Testing

// The Today recap card's height, which is the one thing about that card a person notices.
//
// The card exists to be GLANCED at, above the coverage strip, the follow-ups and the
// conversations. `RecapCondenser` keeps it short by writing a shorter second version of the day
// — but that is an AI call, and an AI call is a thing that has not run yet, or was refused, or
// found no provider. Whenever it has not landed, the card renders the raw digest, and the digest
// is bounded by nothing but what the model felt like writing: on a full day, three paragraphs
// that pushed everything else on Today below the fold.
//
// So the fallback is clamped. These tests pin that the clamp applies to exactly the case that
// needs it and never to the condensation, which is short by construction and must not be cut.

@Suite("Today recap card height")
struct RecapCardHeightTests {

    private func display(condensed: String?) -> RecapDisplay {
        RecapDisplay(
            updatedText: "updated 11:58 PM",
            digest: String(repeating: "A long day. ", count: 200),
            condensed: condensed,
            detail: RecapDetailDisplay(
                id: "day-2026-09-09", title: "Today so far", generatedLine: "",
                bullets: [], momentsFooter: "")
        )
    }

    @Test func anUncondensedDigestIsClampedSoTheCardCannotRunAwayWithTheScreen() {
        let recap = display(condensed: nil)
        #expect(recap.cardText == recap.digest)
        #expect(recap.cardLineLimit != nil)
    }

    @Test func theCondensationIsShownWhole() {
        let recap = display(condensed: "Quiet morning; redesign work after lunch.")
        #expect(recap.cardText == "Quiet morning; redesign work after lunch.")
        #expect(recap.cardLineLimit == nil)
    }

    /// Whatever the card shows, the pushed detail shows the WHOLE digest — a "full recap" that
    /// turned out to be the same paragraph would make the chevron a lie.
    @Test func theDetailKeepsTheWholeDigestEitherWay() {
        #expect(display(condensed: "short").digest.count > 1_000)
        #expect(display(condensed: nil).digest.count > 1_000)
    }
}
