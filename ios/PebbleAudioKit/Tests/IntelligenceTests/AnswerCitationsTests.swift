import Testing

@testable import Intelligence

// Port of `app/src/commonTest/.../ui/AnswerCitationsTest.kt` — all 8 pinned behaviors.

@Suite struct AnswerCitationsTests {
    private let sources = [
        "seg-1782360302159-000000fc-1",
        "seg-1782365702732-0000004a-2",
        "seg-1781897412175-00000085-1",
    ]

    private func spans(_ line: AnswerLine) -> String {
        line.tokens.compactMap { token -> String? in
            if case .span(let text) = token { return text }
            return nil
        }.joined()
    }

    private func cites(_ line: AnswerLine) -> [(number: Int, segmentId: String)] {
        line.tokens.compactMap { token in
            if case .citation(let number, let segmentId) = token {
                return (number, segmentId)
            }
            return nil
        }
    }

    private func allCites(_ parsed: GroundedAnswer) -> [(number: Int, segmentId: String)] {
        parsed.lines.flatMap { cites($0) }
    }

    @Test func resolvesTruncatedMarkdownLinkByPrefixAndStripsWrappingPunctuation() {
        let parsed = parseGroundedAnswer(
            "You're considering Brazil ([seg-1782360302159...](#)).",
            sourceIds: sources)
        #expect(parsed.lines.count == 1)
        let line = parsed.lines[0]
        // The wrapping "( ... )." collapses to just the trailing period; the chip hugs the word.
        #expect(spans(line) == "You're considering Brazil .")
        let cite = cites(line)
        #expect(cite.count == 1)
        #expect(cite[0].segmentId == "seg-1782360302159-000000fc-1")
        #expect(cite[0].number == 1)
    }

    @Test func groupsAdjacentCitationsAndDropsSeparators() {
        let parsed = parseGroundedAnswer(
            "Stepping back ([seg-1782360302159...](#), [seg-1782365702732...](#))",
            sourceIds: sources)
        #expect(parsed.lines.count == 1)
        let line = parsed.lines[0]
        #expect(cites(line).map(\.number) == [1, 2])
        #expect(cites(line).map(\.segmentId) == [
            "seg-1782360302159-000000fc-1", "seg-1782365702732-0000004a-2",
        ])
        // No stray "(", ")" or "," survives between/around the two chips.
        let prose = spans(line).trimmingCharacters(in: .whitespaces)
        #expect("Stepping back".contains(prose) || prose == "Stepping back")
    }

    @Test func footnoteNumbersMapToSourceOrder() {
        let parsed = parseGroundedAnswer(
            "Atlanta for July 4 [2]. Back to SF [3].", sourceIds: sources)
        let cites = allCites(parsed)
        #expect(cites[0].segmentId == "seg-1782365702732-0000004a-2")
        #expect(cites[1].segmentId == "seg-1781897412175-00000085-1")
    }

    @Test func displayNumbersFollowFirstAppearanceNotSourceIndex() {
        // First cited source is sources[1] -> should display as 1, not 2.
        let parsed = parseGroundedAnswer(
            "Boston Tuesday [2]. Then Atlanta [1].", sourceIds: sources)
        #expect(parsed.citedSegmentIds == [
            "seg-1782365702732-0000004a-2", "seg-1782360302159-000000fc-1",
        ])
        let first = allCites(parsed)[0]
        #expect(first.number == 1)
        #expect(first.segmentId == "seg-1782365702732-0000004a-2")
    }

    @Test func sameSegmentCitedTwiceKeepsOneNumber() {
        let parsed = parseGroundedAnswer(
            "Brazil [1]. Also Brazil again [1].", sourceIds: sources)
        #expect(parsed.citedSegmentIds == ["seg-1782360302159-000000fc-1"])
        #expect(allCites(parsed).allSatisfy { $0.number == 1 })
    }

    @Test func unresolvableCitationsAreDroppedFromProseInsteadOfShownRaw() {
        let parsed = parseGroundedAnswer(
            "Mystery [seg-9999999999999...](#) claim.", sourceIds: sources)
        #expect(parsed.lines.count == 1)
        let line = parsed.lines[0]
        #expect(cites(line).isEmpty)
        // The opaque dangling id is removed; the surrounding sentence stays readable.
        #expect(spans(line) == "Mystery  claim.")
    }

    @Test func realHyperlinksKeepTheirLabelAndDoNotBecomeChips() {
        let parsed = parseGroundedAnswer(
            "See [the docs](https://example.com) for details.", sourceIds: sources)
        #expect(parsed.lines.count == 1)
        let line = parsed.lines[0]
        #expect(cites(line).isEmpty)
        #expect(spans(line) == "See the docs for details.")
    }

    @Test func bulletAndNumberMarkersArePreserved() {
        let parsed = parseGroundedAnswer(
            "- First point [1]\n2. Second point", sourceIds: sources)
        #expect(parsed.lines[0].marker == "•")
        #expect(parsed.lines[1].marker == "2.")
        let firstLineCites = cites(parsed.lines[0])
        #expect(firstLineCites.count == 1)
        #expect(firstLineCites[0].number == 1)
    }
}
