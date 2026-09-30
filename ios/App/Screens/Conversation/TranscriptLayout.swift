import CoreGraphics
import Foundation

/// The transcript card cut into rows a lazy stack can render one at a time.
///
/// The card used to be ONE view: a `Card` around a `VStack` of every paragraph, sitting as a
/// single child of the conversation screen's `LazyVStack`. A lazy stack cannot be lazy about
/// the inside of one child, so opening a conversation laid out every paragraph it had before
/// drawing anything. Measured in the simulator on a synthetic 6,000-row day, that blocked the
/// main thread for 5-7 s and held ~2 GB; with a speaker change on every row it never drew at
/// all. History opens 15- and 24-hour conversations routinely, so the card is now rows.
///
/// Each row carries its share of the space around it and whether it opens or closes the card,
/// so the rows can sit at zero spacing and still reproduce the card exactly: 14 pt card padding
/// at the ends, 12 pt between blocks, 7 pt between one speaker's paragraphs, 3 pt under a
/// speaker's name, and the provenance line's extra 4. A gap is split evenly between the rows on
/// either side of it rather than given to one of them, so a row's frame is centred on its
/// content — which is what makes "scroll the cited band to the centre" centre the band, and not
/// the band plus the gap above it.
///
/// What is a row:
/// - every turn, so one speaker talking for an hour is hundreds of rows, not one tall block —
///   the first turn of a same-speaker run carries the name header, the rest are paragraphs;
/// - every quiet or missing marker;
/// - a cited stretch, as ONE row: the band is a single shape with a single leading rule and it
///   is a few lines long, so drawing it whole keeps it pixel-identical to what it was;
/// - the provenance line.
///
/// Pure data, built once per transcript (see `TranscriptView`), so the screen can also ask it
/// which row holds an item when it needs somewhere to scroll.
struct TranscriptLayout: Equatable {
    struct Row: Identifiable, Equatable {
        enum Content: Equatable {
            /// One paragraph. `opensRun` rows carry the speaker header for the run they start.
            case turn(TranscriptTurn, opensRun: Bool)
            case quiet(TranscriptMarker)
            case missing(TranscriptMarker)
            /// A cited stretch, drawn whole. `playFromMs` is where its first speech sits on the
            /// scrubber, for the band's "Play from here".
            case band([TranscriptBlock], playFromMs: Int64?)
            case provenance(String)
        }

        var id: String
        var content: Content
        /// Space above and below this row's content, inside the card: half of each gap it
        /// shares with a neighbour, or the card's own padding at the card's ends.
        var topInset: CGFloat = 0
        var bottomInset: CGFloat = 0
        var isFirst = false
        var isLast = false
    }

    /// The card's own padding at its top and bottom edges.
    static let cardInset: CGFloat = 14
    /// Between blocks — speakers, markers, the band.
    static let blockGap: CGFloat = 12
    /// Between the paragraphs of one speaker's run.
    static let paragraphGap: CGFloat = 7
    /// The provenance line sits a little further off the last block than blocks do.
    static let provenanceExtra: CGFloat = 4
    /// The first cited band's row id, and the anchor a citation scrolls to. Later bands, if a
    /// focus ever produced more than one, are numbered after it.
    static let citedAnchor = "transcript-cited-moment"
    static let provenanceId = "transcript-provenance"

    private(set) var rows: [Row] = []
    /// Items that are not rows of their own — the members of a band — mapped to the row that
    /// holds them.
    private var bandRowByItem: [String: String] = [:]

    init(transcript: [TranscriptItem], provenance: String?, focus: TranscriptFocus?) {
        // Only a citation marks lines; a moment is a place to land, not a quote.
        let citation = focus?.style == .citation ? focus : nil
        func isCited(_ segmentId: String, _ startedAt: Date?) -> Bool {
            citation?.contains(segmentId: segmentId, at: startedAt) ?? false
        }

        var rows: [Row] = []
        /// The gap above each row, in step with `rows`; split between neighbours at the end.
        var gaps: [CGFloat] = []
        var bandBlocks: [TranscriptBlock] = []
        var bandItems: [String] = []
        var bands = 0
        /// The turn row directly above, when a same-speaker turn can continue its run.
        var runTurn: TranscriptTurn?

        func closeBand() {
            guard !bandBlocks.isEmpty else { return }
            let id = bands == 0 ? Self.citedAnchor : "\(Self.citedAnchor)-\(bands)"
            let playFrom = bandBlocks.lazy.compactMap(\.mediaOffsetMs).first
            rows.append(Row(id: id, content: .band(bandBlocks, playFromMs: playFrom)))
            gaps.append(Self.blockGap)
            for item in bandItems { bandRowByItem[item] = id }
            bands += 1
            bandBlocks = []
            bandItems = []
        }

        for item in transcript {
            switch item {
            case .turn(let turn) where isCited(turn.segmentId, turn.startedAt):
                runTurn = nil
                bandItems.append(turn.id)
                // Inside a band, one speaker's consecutive turns are one block, as they always
                // were: a name header and a paragraph each.
                if case .speech(let id, var turns) = bandBlocks.last,
                    let previous = turns.last, Self.continuesRun(previous, with: turn)
                {
                    turns.append(turn)
                    bandBlocks[bandBlocks.count - 1] = .speech(id: id, turns: turns)
                } else {
                    bandBlocks.append(.speech(id: turn.id, turns: [turn]))
                }
            case .quiet(let marker) where isCited(marker.segmentId, marker.startedAt):
                runTurn = nil
                bandItems.append(marker.id)
                bandBlocks.append(.quiet(marker))
            case .missing(let marker) where isCited(marker.segmentId, marker.startedAt):
                runTurn = nil
                bandItems.append(marker.id)
                bandBlocks.append(.missing(marker))
            case .turn(let turn):
                closeBand()
                let continues = runTurn.map { Self.continuesRun($0, with: turn) } ?? false
                rows.append(Row(id: turn.id, content: .turn(turn, opensRun: !continues)))
                gaps.append(continues ? Self.paragraphGap : Self.blockGap)
                runTurn = turn
            case .quiet(let marker):
                closeBand()
                runTurn = nil
                rows.append(Row(id: marker.id, content: .quiet(marker)))
                gaps.append(Self.blockGap)
            case .missing(let marker):
                closeBand()
                runTurn = nil
                rows.append(Row(id: marker.id, content: .missing(marker)))
                gaps.append(Self.blockGap)
            }
        }
        closeBand()
        if let provenance {
            rows.append(Row(id: Self.provenanceId, content: .provenance(provenance)))
            gaps.append(Self.blockGap + Self.provenanceExtra)
        }
        for index in rows.indices {
            rows[index].topInset = index == 0 ? 0 : gaps[index] / 2
            rows[index].bottomInset =
                index == rows.count - 1 ? Self.cardInset : gaps[index + 1] / 2
        }
        if !rows.isEmpty {
            // The card's own top padding stands where a gap would be above the first row; the
            // provenance line keeps its extra 4 even when it is alone.
            let extra: CGFloat =
                if case .provenance = rows[0].content { Self.provenanceExtra } else { 0 }
            rows[0].topInset = Self.cardInset + extra
            rows[0].isFirst = true
            rows[rows.count - 1].isLast = true
        }
        self.rows = rows
    }

    /// Consecutive turns by the same speaker read as one person still talking, so they share
    /// ONE name header. Real transcripts arrive split at provider segment boundaries — often
    /// mid-sentence — and repeating "Speaker 1" over every fragment turned the card into a wall
    /// of labels.
    static func continuesRun(_ previous: TranscriptTurn, with turn: TranscriptTurn) -> Bool {
        previous.speakerLabel == turn.speakerLabel && previous.name == turn.name
            && previous.role == turn.role && previous.isInProgress == turn.isInProgress
    }

    /// The row to scroll to for a transcript item: its own row, or the band that holds it.
    func rowId(forItemId itemId: String) -> String {
        bandRowByItem[itemId] ?? itemId
    }

    /// The first cited band's row, when the focus produced one.
    var citedRowId: String? {
        rows.first { if case .band = $0.content { true } else { false } }?.id
    }
}

/// One block of a cited band: a run of consecutive same-speaker turns, or a marker.
enum TranscriptBlock: Identifiable, Equatable {
    case speech(id: String, turns: [TranscriptTurn])
    case quiet(TranscriptMarker)
    case missing(TranscriptMarker)

    var id: String {
        switch self {
        case .speech(let id, _): return id
        case .quiet(let marker), .missing(let marker): return marker.id
        }
    }

    /// Where this block starts on the conversation's scrubber; markers carry no position.
    var mediaOffsetMs: Int64? {
        if case .speech(_, let turns) = self { return turns.first?.mediaOffsetMs }
        return nil
    }
}
