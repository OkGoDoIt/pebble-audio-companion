import Testing

@testable import Intelligence

// Citation granularity: a citation has to name a MOMENT (a few sentences of one recording),
// not a whole member segment - that is what the transcript marks and the player starts from.

@Suite struct CitableExcerptsTests {
    private let segmentStartMs: Int64 = 1_782_360_000_000

    private func spans(_ pairs: [(String, Int64, Int64)]) -> [TranscriptSpan] {
        pairs.map { TranscriptSpan(text: $0.0, startMs: $0.1, endMs: $0.2) }
    }

    @Test func cutsOnProviderBoundariesAndCarriesAbsoluteBounds() {
        let drafts = CitableExcerpts.split(
            segmentId: "seg-a",
            segmentStartMs: segmentStartMs,
            segmentEndMs: segmentStartMs + 120_000,
            spans: spans([
                ("One.", 0, 20_000),
                ("Two.", 20_000, 45_000),
                ("Three.", 45_000, 60_000),
                ("Four.", 60_000, 95_000),
            ]),
            wholeText: "One. Two. Three. Four.",
            targetMs: 40_000,
            maxCharacters: 10_000)

        #expect(drafts.count == 2)
        #expect(drafts[0].text == "One. Two.")
        #expect(drafts[0].startMs == segmentStartMs)
        #expect(drafts[0].endMs == segmentStartMs + 45_000)
        #expect(drafts[1].text == "Three. Four.")
        #expect(drafts[1].startMs == segmentStartMs + 45_000)
        #expect(drafts[1].endMs == segmentStartMs + 95_000)
    }

    @Test func longSpeechSplitsOnLengthEvenWhenItIsShort() {
        let drafts = CitableExcerpts.split(
            segmentId: "seg-a",
            segmentStartMs: segmentStartMs,
            segmentEndMs: segmentStartMs + 10_000,
            spans: spans([("aaaa", 0, 1_000), ("bbbb", 1_000, 2_000), ("cccc", 2_000, 3_000)]),
            wholeText: "aaaa bbbb cccc",
            targetMs: 60_000,
            maxCharacters: 8)
        #expect(drafts.map(\.text) == ["aaaa bbbb", "cccc"])
    }

    /// Some providers return flat text with no timings at all. One stretch covering the member
    /// is coarse, but it is what is actually known - better than inventing boundaries.
    @Test func untimedTranscriptYieldsOneStretchForTheWholeMember() {
        let drafts = CitableExcerpts.split(
            segmentId: "seg-a",
            segmentStartMs: segmentStartMs,
            segmentEndMs: segmentStartMs + 300_000,
            spans: [],
            wholeText: "  A whole transcript with no timings.  ")
        #expect(drafts.count == 1)
        #expect(drafts[0].text == "A whole transcript with no timings.")
        #expect(drafts[0].startMs == segmentStartMs)
        #expect(drafts[0].endMs == segmentStartMs + 300_000)
    }

    @Test func emptyTranscriptYieldsNothingToCite() {
        #expect(
            CitableExcerpts.split(
                segmentId: "seg-a", segmentStartMs: segmentStartMs,
                segmentEndMs: segmentStartMs + 1_000, spans: [], wholeText: "   "
            ).isEmpty)
    }

    @Test func coalescingNeverMergesAcrossMembers() {
        let drafts = (0..<8).map { index in
            CitableExcerptDraft(
                segmentId: index < 4 ? "seg-a" : "seg-b",
                startMs: segmentStartMs + Int64(index) * 10_000,
                endMs: segmentStartMs + Int64(index + 1) * 10_000,
                text: "piece \(index)")
        }
        let merged = CitableExcerpts.coalesced(drafts, limit: 2)
        #expect(merged.count >= 2)
        #expect(Set(merged.map(\.segmentId)) == ["seg-a", "seg-b"])
        for piece in merged {
            // A stretch that spanned two recordings could not be highlighted or played.
            #expect(piece.startMs < piece.endMs)
        }
    }

    @Test func citationsCarryTheStretchTheModelNamed() {
        let sources = CitableExcerpts.numbered([
            CitableExcerptDraft(
                segmentId: "seg-a", startMs: segmentStartMs,
                endMs: segmentStartMs + 40_000, text: "first"),
            CitableExcerptDraft(
                segmentId: "seg-a", startMs: segmentStartMs + 40_000,
                endMs: segmentStartMs + 80_000, text: "second"),
        ])
        #expect(sources.map(\.number) == [1, 2])

        let citations = renderedAnswerCitations(
            "They settled it [2]. Nothing else [9].", sources: sources)
        #expect(citations.count == 1)
        // Two citations of one segment are two different moments: the bounds are what
        // distinguishes them, and what the highlight and the play offset are built from.
        #expect(citations[0].number == 2)
        #expect(citations[0].segmentId == "seg-a")
        #expect(citations[0].startMs == segmentStartMs + 40_000)
        #expect(citations[0].endMs == segmentStartMs + 80_000)
    }
}
