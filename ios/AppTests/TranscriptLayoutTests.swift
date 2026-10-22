import CoreGraphics
import Foundation
import Testing

// The transcript card as lazy rows (`TranscriptLayout`). The card used to be one view holding
// every paragraph, which a lazy stack cannot be lazy about; these pin the row model that
// replaced it, and in particular that the rows still add up to exactly the card they replaced.

@Suite("transcript layout: the card as rows")
struct TranscriptLayoutTests {
    typealias Layout = TranscriptLayout
    static let t0: Int64 = 1_727_690_400_000

    static func turn(
        _ id: String, _ speaker: String = "S1", at offsetMs: Int64 = 0, segment: String = "seg-1",
        inProgress: Bool = false
    ) -> TranscriptItem {
        .turn(
            TranscriptTurn(
                id: id, speakerLabel: speaker, name: speaker == "S1" ? "Roger" : "Sam",
                role: speaker == "S1" ? .you : .other, text: id,
                startedAt: Date(timeIntervalSince1970: Double(t0 + offsetMs) / 1000),
                isInProgress: inProgress, segmentId: segment, mediaOffsetMs: offsetMs))
    }

    static func quiet(_ id: String, at offsetMs: Int64 = 0, segment: String = "seg-1")
        -> TranscriptItem
    {
        .quiet(
            TranscriptMarker(
                id: id, text: "quiet for 1 min",
                startedAt: Date(timeIntervalSince1970: Double(t0 + offsetMs) / 1000),
                segmentId: segment))
    }

    static func missing(_ id: String) -> TranscriptItem {
        .missing(TranscriptMarker(id: id, text: "2 sec missing"))
    }

    private func kinds(_ layout: Layout) -> [String] {
        layout.rows.map { row in
            switch row.content {
            case .turn(_, let opensRun): return opensRun ? "turn+name" : "turn"
            case .quiet: return "quiet"
            case .missing: return "missing"
            case .moment: return "moment"
            case .band(let blocks, _): return "band(\(blocks.count))"
            case .provenance: return "provenance"
            case .moment: return "moment"
            }
        }
    }

    // MARK: - Every turn is a row; one speaker's run shares one name

    @Test func aSpeakersConsecutiveTurnsShareOneHeader() {
        let layout = Layout(
            transcript: [
                Self.turn("a"), Self.turn("b"), Self.turn("c", "S2"), Self.turn("d", "S2"),
                Self.turn("e"),
            ],
            provenance: nil, focus: nil)
        #expect(layout.rows.map(\.id) == ["a", "b", "c", "d", "e"])
        #expect(kinds(layout) == ["turn+name", "turn", "turn+name", "turn", "turn+name"])
    }

    /// A marker between two turns of one speaker ends the run: the name is repeated after it,
    /// as it always was.
    @Test func aMarkerBreaksARun() {
        let layout = Layout(
            transcript: [Self.turn("a"), Self.quiet("q"), Self.turn("b"), Self.missing("m"),
                Self.turn("c")],
            provenance: nil, focus: nil)
        #expect(kinds(layout) == ["turn+name", "quiet", "turn+name", "missing", "turn+name"])
    }

    /// The still-growing tail of a live transcript is set apart from the settled words.
    @Test func theInProgressTailStartsItsOwnRun() {
        let layout = Layout(
            transcript: [Self.turn("a"), Self.turn("b", inProgress: true)],
            provenance: nil, focus: nil)
        #expect(kinds(layout) == ["turn+name", "turn+name"])
    }

    // MARK: - The rows add up to the card

    /// 14 at the card's edges; 12 between blocks and 7 between one speaker's paragraphs, each
    /// split evenly between the rows either side; the provenance line 4 further off.
    @Test func theInsetsReproduceTheCardsSpacing() {
        let layout = Layout(
            transcript: [Self.turn("a"), Self.turn("b"), Self.quiet("q"), Self.turn("c")],
            provenance: "Transcribed with Soniox", focus: nil)
        let insets = layout.rows.map { [$0.topInset, $0.bottomInset] }
        #expect(
            insets == [
                [14, 3.5],  // a: card top | half the paragraph gap to b
                [3.5, 6],  // b | half a block gap to the marker
                [6, 6],  // q
                [6, 8],  // c | half of 12 + 4 to the provenance line
                [8, 14],  // provenance | card bottom
            ])
        // Every gap between two rows is the gap the card had there.
        let gaps = zip(layout.rows, layout.rows.dropFirst()).map { $0.bottomInset + $1.topInset }
        #expect(gaps == [7, 12, 12, 16])
        #expect(layout.rows.first?.isFirst == true && layout.rows.last?.isLast == true)
        #expect(layout.rows.dropFirst().allSatisfy { !$0.isFirst })
        #expect(layout.rows.dropLast().allSatisfy { !$0.isLast })
    }

    @Test func aSingleRowIsBothEndsOfTheCard() throws {
        let layout = Layout(transcript: [Self.turn("a")], provenance: nil, focus: nil)
        let row = try #require(layout.rows.first)
        #expect(layout.rows.count == 1)
        #expect(row.isFirst && row.isLast)
        #expect(row.topInset == 14 && row.bottomInset == 14)
    }

    /// The provenance line alone keeps its extra 4 below the card's top padding.
    @Test func aLoneProvenanceLine() {
        let layout = Layout(transcript: [], provenance: "Transcribed", focus: nil)
        #expect(layout.rows.map(\.id) == [Layout.provenanceId])
        #expect(layout.rows.first?.topInset == 18)
        #expect(Layout(transcript: [], provenance: nil, focus: nil).rows.isEmpty)
    }

    // MARK: - A citation: one band, one row

    /// The cited stretch is ONE row — one tinted shape, one leading rule, one header — holding
    /// its blocks grouped by speaker as before, and every item inside it resolves to that row.
    @Test func aCitedStretchIsOneBandRow() throws {
        let focus = TranscriptFocus(segmentId: "seg-1", startMs: Self.t0 + 60_000,
            endMs: Self.t0 + 180_000)
        let layout = Layout(
            transcript: [
                Self.turn("a", at: 0), Self.turn("b", at: 60_000), Self.turn("c", at: 90_000),
                Self.quiet("q", at: 120_000), Self.turn("d", "S2", at: 180_000),
                Self.turn("e", "S2", at: 240_000),
            ],
            provenance: nil, focus: focus)
        #expect(kinds(layout) == ["turn+name", "band(3)", "turn+name"])
        let band = layout.rows[1]
        #expect(band.id == Layout.citedAnchor)
        #expect(layout.citedRowId == Layout.citedAnchor)
        guard case .band(let blocks, let playFromMs) = band.content else {
            Issue.record("not a band")
            return
        }
        #expect(blocks.map(\.id) == ["b", "q", "d"])
        guard case .speech(_, let turns) = blocks[0] else {
            Issue.record("first block is not speech")
            return
        }
        #expect(turns.map(\.id) == ["b", "c"])
        #expect(playFromMs == 60_000)
        for member in ["b", "c", "q", "d"] {
            #expect(layout.rowId(forItemId: member) == Layout.citedAnchor)
        }
        // "e" continues d's speaker but not d's band: it opens a run of its own.
        #expect(layout.rowId(forItemId: "e") == "e")
        #expect(layout.rowId(forItemId: "a") == "a")
    }

    /// Older citations with no stretch mark their whole member.
    @Test func aCitationWithoutTimesBandsItsWholeMember() {
        let layout = Layout(
            transcript: [
                Self.turn("a", segment: "seg-1"), Self.turn("b", segment: "seg-2"),
                Self.turn("c", segment: "seg-2"),
            ],
            provenance: nil, focus: TranscriptFocus(segmentId: "seg-2"))
        #expect(kinds(layout) == ["turn+name", "band(1)"])
        #expect(layout.rows.last?.isLast == true)
    }

    /// A moment marks nothing: the same transcript and window, drawn as plain rows.
    @Test func aMomentDrawsNoBand() {
        let transcript = [Self.turn("a", at: 0), Self.turn("b", at: 60_000)]
        let layout = Layout(
            transcript: transcript, provenance: nil,
            focus: .moment(segmentId: "seg-1", atWallMs: Self.t0 + 60_000))
        #expect(kinds(layout) == ["turn+name", "turn"])
        #expect(layout.citedRowId == nil)
        #expect(layout.rowId(forItemId: "b") == "b")
    }

    @Test func noCitedRowWhenTheStretchHoldsNothing() {
        let layout = Layout(
            transcript: [Self.turn("a", at: 0)], provenance: nil,
            focus: TranscriptFocus(segmentId: "seg-1", startMs: Self.t0 + 1, endMs: Self.t0 + 2))
        #expect(layout.citedRowId == nil)
    }

    /// Thousands of rows are a plain pass over the items.
    @Test func aDayLongTranscriptBuildsOneRowPerItem() {
        var transcript: [TranscriptItem] = []
        for index in 0..<6_000 {
            let at = Int64(index) * 14_400
            if index % 50 == 25 {
                transcript.append(Self.quiet("r\(index)", at: at))
            } else {
                let speaker = (index / 3) % 2 == 0 ? "S1" : "S2"
                transcript.append(Self.turn("r\(index)", speaker, at: at))
            }
        }
        let layout = Layout(transcript: transcript, provenance: "p", focus: nil)
        #expect(layout.rows.count == 6_001)
        #expect(layout.rowId(forItemId: "r4321") == "r4321")
    }
}

@Suite("transcript layout memo") @MainActor
struct TranscriptLayoutMemoTests {
    @Test func rebuildsOnlyWhenItsInputsChange() {
        let memo = TranscriptLayoutMemo()
        let transcript = [TranscriptLayoutTests.turn("a"), TranscriptLayoutTests.turn("b")]
        let first = memo.layout(transcript: transcript, provenance: nil, focus: nil)
        #expect(memo.layout(transcript: transcript, provenance: nil, focus: nil) == first)
        let withProvenance = memo.layout(transcript: transcript, provenance: "p", focus: nil)
        #expect(withProvenance.rows.count == 3)
        let cited = memo.layout(
            transcript: transcript, provenance: "p", focus: TranscriptFocus(segmentId: "seg-1"))
        #expect(cited.citedRowId == TranscriptLayout.citedAnchor)
    }
}
