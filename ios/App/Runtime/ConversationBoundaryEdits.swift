import AppDB
import Foundation
import SegmentStore
import Transcription

// The person's own boundary decisions: where a conversation could be split, and the writes
// behind "start a new conversation here", "join with the previous one" and "separate them
// again".
//
// A conversation used to be whole segments, so the only places it could be cut were the joins
// between its member recordings — rotation artefacts every fifteen minutes, nothing to do with
// where anybody stopped talking. It is pieces of segments now (`AppDB/ConversationUnits.swift`)
// and can start between any two turns, so the places offered are the ones a person would
// recognise: where talk picked up again after a pause.
//
// A decision is stored against a POSITION — a segment and an offset into its stored audio
// (`ConversationCut`) — because that is the only thing that survives a regroup; conversation
// ids are derived and move when a split does. Two stores hold them, by where the position is:
//
//  - inside a segment (`mediaMs > 0`): `ConversationCutStore`'s overrides;
//  - a segment's own start (`mediaMs == 0`): `BoundaryOverrideStore`, where decisions about
//    the join between two recordings have always lived. (`ConversationCutStore.fetchInputs`
//    would fold a zero-offset row in there anyway; writing it to the right table keeps one
//    place to look.)
//
// Everything here is either pure or a plain database write, so it is tested without the
// composition root (`AppTests/ConversationPiecesTests.swift`).

enum ConversationSplitPoints {
    /// A pause shorter than this is somebody drawing breath, not a place a conversation ends.
    static let minimumPauseMs: Int64 = 20_000
    /// The sheet is a short list to choose from, not a second transcript: the longest pauses.
    static let limit = 12
    /// A split starts the new conversation this far ahead of its first word, so playback does
    /// not open on a clipped syllable — the same lead the automatic cuts use
    /// (`ConversationRunPlanner.preRollMs`, which the kit keeps internal).
    static let preRollMs: Int64 = 1_500
    /// How much of the turn that follows a pause is quoted, so the place can be recognised.
    static let openingWords = 8

    /// Where a new conversation would start if it began with the turn at `startMs`: a little
    /// ahead of its first word, never before the turn before it (in the same segment) has
    /// ended, and never after the turn itself — turns overlap when two people talk at once.
    /// The rule `ConversationRunPlanner.position(beforeTurn:)` places automatic cuts by, so a
    /// split by hand and a split by the rules at the same turn are the same position.
    static func cut(
        segmentId: String, turnStartMs: Int64, previousTurnEndMs: Int64
    ) -> ConversationCut {
        let lead = max(turnStartMs - preRollMs, previousTurnEndMs, 0)
        return ConversationCut(segmentId: segmentId, mediaMs: min(lead, max(turnStartMs, 0)))
    }

    /// One turn of the conversation, placed on the wall clock.
    private struct PlacedTurn {
        var segmentId: String
        var text: String
        var wallStartMs: Int64
        var wallEndMs: Int64
        var cut: ConversationCut
    }

    /// The conversation's own turns in order — each member's transcript cut to the piece the
    /// conversation owns — with the position a split in front of each would be written at.
    private static func placedTurns(
        pieces: [ConversationMember],
        metas: [String: SegmentMeta],
        turns: [String: [TranscriptSegment]]
    ) -> [PlacedTurn] {
        var placed: [PlacedTurn] = []
        for piece in pieces {
            guard let meta = metas[piece.segmentId], let all = turns[piece.segmentId] else {
                continue
            }
            let wall = wallClock(meta)
            let ordered = all.sorted {
                $0.startMs == $1.startMs ? $0.endMs < $1.endMs : $0.startMs < $1.startMs
            }
            // Over the WHOLE segment, not just the piece: the turn before the piece's first
            // one belongs to the previous conversation and still bounds how early a cut can be.
            var previousEndMs: Int64 = 0
            for turn in ordered {
                let startMs = max(turn.startMs, 0)
                let endMs = max(turn.endMs, startMs)
                defer { previousEndMs = endMs }
                guard piece.contains(mediaMs: startMs) else { continue }
                placed.append(
                    PlacedTurn(
                        segmentId: piece.segmentId,
                        text: turn.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        wallStartMs: wall(startMs),
                        wallEndMs: wall(endMs),
                        cut: cut(
                            segmentId: piece.segmentId, turnStartMs: startMs,
                            previousTurnEndMs: previousEndMs)))
            }
        }
        return placed
    }

    /// Wall clock of an offset into a segment's stored audio — through the gap records where
    /// they add up, and as a plain offset where they do not, exactly as the transcript's own
    /// stamps are placed (`TranscriptItems`), so a row here and the turn it names agree.
    private static func wallClock(_ meta: SegmentMeta) -> (Int64) -> Int64 {
        let clock = SegmentMediaClock(meta)
        let startMs = ConversationGrouper.segmentStartMs(meta)
        return { mediaMs in
            let offset = clock.isExact ? clock.wall(fromMedia: mediaMs) : mediaMs
            return startMs + min(max(offset, 0), clock.wallSpanMs)
        }
    }

    /// The places inside a conversation where talk resumed after a pause: the longest
    /// `limit` pauses of at least `minimumPauseMs` between one turn and the next, in the
    /// order they happened.
    ///
    /// `turns` is each member segment's WHOLE transcript (turn timings and text); it is cut to
    /// the conversation's pieces here. The conversation's own first turn is never offered —
    /// it already starts there.
    static func points(
        pieces: [ConversationMember],
        metas: [String: SegmentMeta],
        turns: [String: [TranscriptSegment]],
        conversationStartMs: Int64
    ) -> [ConversationBoundaryPoint] {
        let placed = placedTurns(pieces: pieces, metas: metas, turns: turns)
        guard let first = pieces.first, placed.count > 1 else { return [] }
        let ownStart = ConversationCut(
            segmentId: first.segmentId, mediaMs: first.startMediaMs ?? 0)

        var candidates: [(order: Int, point: ConversationBoundaryPoint)] = []
        // The latest END so far, not the previous turn's: with two people talking over each
        // other the turn that started last is not always the one that stopped last.
        var lastWordMs = placed[0].wallEndMs
        for (order, turn) in placed.enumerated().dropFirst() {
            defer { lastWordMs = max(lastWordMs, turn.wallEndMs) }
            let pauseMs = turn.wallStartMs - lastWordMs
            // A turn with no words in it is not a place anyone would recognise, and a cut at
            // the conversation's own start would split nothing.
            guard pauseMs >= minimumPauseMs, !turn.text.isEmpty, turn.cut != ownStart else {
                continue
            }
            candidates.append(
                (
                    order,
                    ConversationBoundaryPoint(
                        cut: turn.cut,
                        startedAt: Date(timeIntervalSince1970: Double(turn.wallStartMs) / 1000),
                        offsetMs: max(0, turn.wallStartMs - conversationStartMs),
                        pauseMs: pauseMs,
                        opening: opening(of: turn.text))
                ))
        }
        return candidates
            .sorted { $0.point.pauseMs == $1.point.pauseMs
                ? $0.order < $1.order : $0.point.pauseMs > $1.point.pauseMs }
            .prefix(limit)
            .sorted { $0.order < $1.order }
            .map(\.point)
    }

    /// The person's own "these are one conversation" decisions that lie INSIDE this
    /// conversation — the joins that made it the size it is. They are listed so each can be
    /// taken back: once two conversations are joined the later one no longer exists to open,
    /// and the place they met is rarely one of the pauses offered above.
    ///
    /// A join at the conversation's own start is not one of these (it is "joined with the
    /// previous conversation", and has its own row).
    static func joins(
        pieces: [ConversationMember],
        metas: [String: SegmentMeta],
        turns: [String: [TranscriptSegment]],
        insideSegments: [ConversationCut: BoundaryDecision],
        atSegmentStarts: [String: BoundaryDecision],
        conversationStartMs: Int64
    ) -> [ConversationBoundaryPoint] {
        var points: [ConversationBoundaryPoint] = []
        for (index, piece) in pieces.enumerated() {
            guard let meta = metas[piece.segmentId] else { continue }
            var offsets =
                insideSegments
                .filter { $0.value == .join && $0.key.segmentId == piece.segmentId }
                .map(\.key.mediaMs)
                .filter { $0 > 0 && piece.contains(mediaMs: $0) }
            if piece.startMediaMs == nil, atSegmentStarts[piece.segmentId] == .join {
                offsets.append(0)
            }
            // The conversation's own start is the join with the PREVIOUS conversation.
            if index == 0 { offsets.removeAll { $0 == (piece.startMediaMs ?? 0) } }
            let wall = wallClock(meta)
            let ordered = (turns[piece.segmentId] ?? []).sorted { $0.startMs < $1.startMs }
            for mediaMs in offsets.sorted() {
                let wallMs = wall(mediaMs)
                let next = ordered.first {
                    $0.startMs >= mediaMs && piece.contains(mediaMs: max($0.startMs, 0))
                }
                points.append(
                    ConversationBoundaryPoint(
                        cut: ConversationCut(segmentId: piece.segmentId, mediaMs: mediaMs),
                        startedAt: Date(timeIntervalSince1970: Double(wallMs) / 1000),
                        offsetMs: max(0, wallMs - conversationStartMs),
                        pauseMs: 0,
                        opening: next.map { opening(of: $0.text) } ?? ""))
            }
        }
        return points
    }

    /// The first few words of a turn, with an ellipsis when there were more.
    static func opening(of text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > openingWords else { return words.joined(separator: " ") }
        return words.prefix(openingWords).joined(separator: " ") + "…"
    }
}

/// The writes behind the "Split or join" sheet. Each is one row in one of the two override
/// tables; the grouping itself is derived and is recomputed by the caller afterwards.
struct ConversationBoundaryEdits: Sendable {
    let database: AppDatabase

    private var insideSegments: ConversationCutStore { ConversationCutStore(db: database) }
    private var atSegmentStarts: BoundaryOverrideStore { BoundaryOverrideStore(db: database) }

    /// The person's decision at a position, from whichever table holds that kind of position.
    func decision(at cut: ConversationCut) async throws -> BoundaryDecision? {
        cut.mediaMs > 0
            ? try await insideSegments.overrides()[cut]
            : try await atSegmentStarts.decision(forSegment: cut.segmentId)
    }

    private func write(_ decision: BoundaryDecision?, at cut: ConversationCut) async throws {
        if cut.mediaMs > 0 {
            try await insideSegments.setOverride(at: cut, decision: decision)
        } else {
            try await atSegmentStarts.set(segmentId: cut.segmentId, decision: decision)
        }
    }

    /// "Start a new conversation here." Replaces a join the person made at the same place:
    /// it is the newer decision about it.
    func split(at cut: ConversationCut) async throws {
        try await write(.split, at: cut)
    }

    /// What joining a conversation to the one before it had to write.
    enum JoinWrite: Equatable {
        /// The conversation started here only because the person split here. Taking the split
        /// away is the whole undo: the place goes back to the rules, with no standing "keep
        /// these together" left behind to explain later.
        case clearedSplit
        /// The rules start a conversation here; the person's join now overrules them.
        case joined
    }

    /// "Join with the previous conversation", for the conversation that starts at `start`.
    ///
    /// After `.clearedSplit` the caller regroups and looks again: if the rules start a
    /// conversation at the same place on their own account, it calls this a second time —
    /// there is then no split left to clear, and the join is written.
    @discardableResult
    func joinWithPrevious(conversationStartingAt start: ConversationCut) async throws -> JoinWrite {
        if try await decision(at: start) == .split {
            try await write(nil, at: start)
            return .clearedSplit
        }
        try await write(.join, at: start)
        return .joined
    }

    /// "Separate them again": takes back the person's join at a position and hands the place
    /// to the rules. Leaves anything else stored there alone — clearing a SPLIT from here
    /// would join two conversations under a button that says it separates them.
    func clearJoin(at cut: ConversationCut) async throws {
        guard try await decision(at: cut) == .join else { return }
        try await write(nil, at: cut)
    }
}
