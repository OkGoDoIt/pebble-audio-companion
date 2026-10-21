import AppDB
import Foundation
import SearchKit
import SegmentStore
import Transcription

// The conversation as the server holds it: pieces placed on the wall clock, the stretches inside
// it with no stored audio, and the transcript cut, cleaned and masked exactly as the app's own AI
// layer reads it (`EnrichmentService.pieceTranscriptOf`) — but kept as timed items rather than
// collapsed into prose, so a tool can quote a turn and say when it was said.
//
// Pure: everything here is a function of the pieces (each one's sidecar, transcript and mask),
// so the export is pinned against real sidecars and transcripts in
// `ArchiveTranscriptExportTests` without a database or a store.

public enum ArchiveExport {
    /// Bumped when the export's meaning changes, so every transcript is sent again (paced by
    /// `ArchiveSyncService`). 2: words Soniox spaced apart no longer run together, and a name
    /// reaches only the recording it was given in.
    public static let transcriptExportVersion = "transcript-export-2"

    /// A stretch of a segment's stored audio withheld from the models (the music/TV mask), on
    /// the segment's media clock, and what it was judged to hold when that is known.
    public struct MaskedRange: Equatable, Sendable {
        public var range: Range<Int64>
        public var descriptor: String?

        public init(range: Range<Int64>, descriptor: String? = nil) {
            self.range = range
            self.descriptor = descriptor
        }
    }

    /// One piece of a conversation with what the export reads about it.
    public struct Piece: Sendable {
        public var member: ConversationMember
        public var meta: SegmentMeta
        /// The WHOLE segment's transcript (it is cut to the piece here); nil while there is none.
        public var transcript: SegmentTranscript?
        public var masked: [MaskedRange]

        public init(
            member: ConversationMember, meta: SegmentMeta, transcript: SegmentTranscript? = nil,
            masked: [MaskedRange] = []
        ) {
            self.member = member
            self.meta = meta
            self.transcript = transcript
            self.masked = masked
        }

        var clock: SegmentMediaClock { SegmentMediaClock(meta) }

        func mediaRange(_ clock: SegmentMediaClock) -> Range<Int64> {
            member.mediaRange(mediaSpanMs: clock.mediaSpanMs)
        }
    }

    // MARK: - Placement

    /// Where a piece sits on the wall clock (epoch ms): from its first stored instant to its
    /// last, the gaps inside it included. A gap that starts exactly at a cut belongs to the
    /// conversation before it, the same way `SegmentMediaClock.wall(fromMedia:)` places it.
    public static func wallExtent(_ piece: Piece) -> Range<Int64> {
        let clock = piece.clock
        let media = piece.mediaRange(clock)
        let start = clock.startWallMs + clock.wallOffset(ofMedia: media.lowerBound)
        let end = clock.startWallMs + clock.wallOffset(ofMedia: media.upperBound)
        return start..<max(end, start)
    }

    /// Stored audio inside `window`, in milliseconds.
    public static func recordedMs(_ pieces: [Piece], window: Range<Int64>) -> Int64 {
        var total: Int64 = 0
        for piece in pieces {
            let clock = piece.clock
            let media = piece.mediaRange(clock)
            guard clock.isExact else {
                // No reliable placement of the gaps: the piece's stored audio, if it is in the
                // window at all.
                let extent = wallExtent(piece)
                if extent.lowerBound < window.upperBound, extent.upperBound > window.lowerBound {
                    total += Int64(media.count)
                }
                continue
            }
            for stretch in clock.wallRanges(fromMedia: media) {
                let lower = max(clock.startWallMs + stretch.lowerBound, window.lowerBound)
                let upper = min(clock.startWallMs + stretch.upperBound, window.upperBound)
                if upper > lower { total += upper - lower }
            }
        }
        return total
    }

    // MARK: - Gaps

    /// Every stretch inside `window` (the conversation's first word to its last) with no stored
    /// audio: the segments' own gap records, classified by the app's one classifier
    /// (`GapClassifier` — quiet is never loss), and any hole between two pieces no record
    /// accounts for, which is loss of unknown origin. Loss wins where the two overlap, as it does
    /// on the coverage strip.
    ///
    /// A segment whose records do not account for its clocks (`SegmentMediaClock.isExact`
    /// false) contributes none: its records cannot be placed, and a guess would be a lie in the
    /// one place the product promises not to tell one.
    public static func gaps(_ pieces: [Piece], window: Range<Int64>) -> [ArchiveGap] {
        guard !window.isEmpty else { return [] }
        let extents = pieces.map(wallExtent).sorted { $0.lowerBound < $1.lowerBound }
        guard let hullLower = extents.first?.lowerBound,
            let hullUpper = extents.map(\.upperBound).max()
        else { return [] }
        let lowerBound = max(hullLower, window.lowerBound)
        let bounds = lowerBound..<max(min(hullUpper, window.upperBound), lowerBound)
        guard !bounds.isEmpty else { return [] }

        var lost: [(range: Range<Int64>, origin: String)] = []
        var quiet: [(range: Range<Int64>, reason: String?)] = []
        var seen = Set<String>()
        for piece in pieces {
            let meta = piece.meta
            // One segment's records once, whichever of its pieces is here.
            guard seen.insert(meta.segmentId).inserted else { continue }
            let clock = piece.clock
            guard clock.isExact, !meta.gaps.isEmpty else { continue }
            let classifier = GapClassifier(meta.gaps)
            let rate = Int64(max(meta.sampleRateHz, 1))
            for gap in meta.gaps {
                let anchor = meta.firstSampleIndex ?? gap.firstMissingSampleIndex
                let offset: Int64 =
                    gap.firstMissingSampleIndex >= anchor
                    ? Int64(gap.firstMissingSampleIndex - anchor) * 1_000 / rate
                    : -(Int64(anchor - gap.firstMissingSampleIndex) * 1_000 / rate)
                let duration = max(Int64(gap.missingFrameCount) * Int64(meta.frameDurationMs), 0)
                let lower = max(clock.startWallMs + offset, bounds.lowerBound)
                let upper = min(clock.startWallMs + offset + duration, bounds.upperBound)
                guard upper > lower else { continue }
                switch classifier.classify(gap) {
                case .loss:
                    lost.append((lower..<upper, gap.origin == GapMeta.originSequenceSkip ? "link" : "watch"))
                case .quiet:
                    quiet.append((lower..<upper, nil))
                case .watchPause:
                    quiet.append((lower..<upper, "watchPause"))
                }
            }
        }

        // Holes between pieces that no record explains.
        var covered = mergeRanges(lost.map(\.range) + quiet.map(\.range))
        for (previous, next) in zip(extents, extents.dropFirst()) {
            let lower = max(previous.upperBound, bounds.lowerBound)
            let upper = min(next.lowerBound, bounds.upperBound)
            guard upper - lower >= 1_000 else { continue }
            for hole in subtract([lower..<upper], covered) where hole.count >= 1_000 {
                lost.append((hole, "unknown"))
            }
        }
        covered = mergeRanges(lost.map(\.range))

        var out: [ArchiveGap] = []
        // Loss: merged per origin run, in order.
        for (range, origin) in mergeTagged(lost.map { ($0.range, $0.origin) }) {
            out.append(ArchiveGap(startMs: range.lowerBound, endMs: range.upperBound, kind: .lost, origin: origin))
        }
        // Quiet, with the loss cut out of it.
        for (range, reason) in mergeTagged(quiet.map { ($0.range, $0.reason ?? "") }) {
            for piece in subtract([range], covered) where !piece.isEmpty {
                out.append(
                    ArchiveGap(
                        startMs: piece.lowerBound, endMs: piece.upperBound, kind: .quiet,
                        reason: reason.isEmpty ? nil : reason))
            }
        }
        return out.sorted { ($0.startMs, $0.kind == .lost ? 0 : 1) < ($1.startMs, $1.kind == .lost ? 0 : 1) }
    }

    // MARK: - Transcript

    /// The transcript the server holds for one conversation.
    ///
    /// For each piece, in order: the segment's transcript cut to the piece (the one cut rule,
    /// `SegmentTranscript.piece`), then the transcriber's loops collapsed (the first line of
    /// each repeat survives; `TranscriptArtefacts` decides, as it does for every model input),
    /// then the turns inside the music/TV mask withheld — one `masked` item per masked stretch
    /// that withheld anything, saying what it held when that is known. Turns go on the wall
    /// clock through the segment's own gap records (`SegmentMediaClock.wallRange`). The quiet
    /// and lost stretches (`gaps`) go in as their own items, and everything is in time order.
    ///
    /// `text` is the turns alone, one line each: the speaker's name, or their label when nobody
    /// has named them, a colon, and what they said. A turn with no speaker label is its text.
    public static func transcript(
        conversationId: String, pieces: [Piece], gaps: [ArchiveGap],
        speakerNames: [String: String], sourceHash: String
    ) -> ArchiveTranscriptPayload {
        var items: [ArchiveTranscriptPayload.Item] = []
        var turnsBySource: [String: Int] = [:]
        var sources: [String: (provider: String, model: String?)] = [:]

        for piece in pieces {
            guard let transcript = piece.transcript else { continue }
            let clock = piece.clock
            let pieceMedia = piece.mediaRange(clock)
            let cut = transcript.piece(piece.member)
            let turns = cut.segments
            guard !turns.isEmpty else { continue }
            let looped =
                turns.count > 1
                ? TranscriptArtefacts.loopedArtefacts(
                    in: turns.map { ArtefactTurn(text: $0.text, startMs: $0.startMs) })
                : Array(repeating: false, count: turns.count)
            var withheldBy = Set<Int>()
            var spoken = 0
            for (index, turn) in turns.enumerated() where !looped[index] {
                let middle = turn.startMs + max(turn.endMs - turn.startMs, 0) / 2
                if let mask = piece.masked.firstIndex(where: { $0.range.contains(middle) }) {
                    withheldBy.insert(mask)
                    continue
                }
                let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let wall = clock.wallRange(ofMediaStartMs: turn.startMs, endMs: turn.endMs)
                let label = turn.speaker?.trimmingCharacters(in: .whitespaces)
                // A provider labels each segment on its own, so a name is the one given to this
                // label IN THIS SEGMENT (`SpeakerKey`); one given before names were scoped, in
                // either form it was stored in, still covers the label wherever no segment name
                // does.
                let name = label.flatMap {
                    SpeakerKey(segmentId: piece.member.segmentId, label: $0).name(in: speakerNames)
                }
                items.append(
                    .turn(
                        atMs: wall.startMs, endMs: wall.endMs,
                        speaker: (label?.isEmpty ?? true) ? nil : label, name: name, text: text,
                        confidence: turn.confidence))
                spoken += 1
            }
            for index in withheldBy.sorted() {
                let mask = piece.masked[index]
                let lower = max(mask.range.lowerBound, pieceMedia.lowerBound)
                let upper = min(mask.range.upperBound, pieceMedia.upperBound)
                guard upper > lower else { continue }
                items.append(
                    .masked(
                        atMs: clock.startWallMs + clock.wallOffset(ofMedia: lower),
                        endMs: clock.startWallMs + clock.wallOffset(ofMedia: upper),
                        descriptor: mask.descriptor))
            }
            let sourceKey = "\(transcript.providerId)|\(transcript.modelUsed ?? "")"
            turnsBySource[sourceKey, default: 0] += spoken
            sources[sourceKey] = (transcript.providerId, transcript.modelUsed)
        }
        for gap in gaps {
            switch gap.kind {
            case .quiet: items.append(.quiet(atMs: gap.startMs, endMs: gap.endMs))
            case .lost: items.append(.lost(atMs: gap.startMs, endMs: gap.endMs, origin: gap.origin ?? "unknown"))
            }
        }
        // Time order; at one instant a marker reads before the words that follow it.
        let ordered = items.enumerated().sorted { a, b in
            if a.element.atMs != b.element.atMs { return a.element.atMs < b.element.atMs }
            let rankA = a.element.kindName == "turn" ? 1 : 0
            let rankB = b.element.kindName == "turn" ? 1 : 0
            if rankA != rankB { return rankA < rankB }
            return a.offset < b.offset
        }.map(\.element)
        var orderedLines: [String] = []
        for item in ordered {
            guard case .turn(_, _, let speaker, let name, let text, _) = item else { continue }
            if let speaker { orderedLines.append("\(name ?? speakerLabel(speaker)): \(text)") }
            else { orderedLines.append(text) }
        }
        let text = orderedLines.joined(separator: "\n")
        let main = turnsBySource.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }.flatMap { sources[$0.key] }
        return ArchiveTranscriptPayload(
            conversationId: conversationId, sourceHash: sourceHash, provider: main?.provider,
            model: main?.model, language: nil, charCount: text.count, text: text, items: ordered)
    }

    // MARK: - Range helpers

    static func mergeRanges(_ ranges: [Range<Int64>]) -> [Range<Int64>] {
        var out: [Range<Int64>] = []
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }

    /// Overlapping or touching ranges merged; the merged range keeps the first one's tag.
    static func mergeTagged(_ ranges: [(Range<Int64>, String)]) -> [(Range<Int64>, String)] {
        var out: [(Range<Int64>, String)] = []
        for (range, tag) in ranges.filter({ !$0.0.isEmpty }).sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.0.upperBound {
                out[out.count - 1] = (last.0.lowerBound..<max(last.0.upperBound, range.upperBound), last.1)
            } else {
                out.append((range, tag))
            }
        }
        return out
    }

    static func subtract(_ base: [Range<Int64>], _ holes: [Range<Int64>]) -> [Range<Int64>] {
        let cuts = mergeRanges(holes)
        var out: [Range<Int64>] = []
        for range in mergeRanges(base) {
            var cursor = range.lowerBound
            for hole in cuts where hole.upperBound > cursor && hole.lowerBound < range.upperBound {
                if hole.lowerBound > cursor { out.append(cursor..<hole.lowerBound) }
                cursor = max(cursor, hole.upperBound)
                if cursor >= range.upperBound { break }
            }
            if cursor < range.upperBound { out.append(cursor..<range.upperBound) }
        }
        return out
    }
}

// MARK: - Clips

/// Where a requested wall-clock span lies in the stored audio of a conversation's pieces
/// (`sync-protocol.md` §4 `clip`). A clip is a remux of those frames, so it is cut on the media
/// clock: the gaps inside the span hold no frames and are collapsed in the audio, and the span
/// actually covered is reported back from the frames found.
public enum ArchiveClipPlan {
    public struct Range: Equatable, Sendable {
        public var segmentId: String
        /// Stored audio in the segment, half open, milliseconds.
        public var mediaRange: Swift.Range<Int64>
        /// The same stretch on the wall clock (epoch ms), gaps inside it included.
        public var wallRange: Swift.Range<Int64>

        public init(segmentId: String, mediaRange: Swift.Range<Int64>, wallRange: Swift.Range<Int64>) {
            self.segmentId = segmentId
            self.mediaRange = mediaRange
            self.wallRange = wallRange
        }
    }

    /// The media ranges, in order, that the span `[startMs, endMs)` covers across `pieces`,
    /// holding at most `maxMs` of audio (the end is trimmed). A piece the span misses, or whose
    /// overlap falls wholly inside one of its gaps, contributes nothing.
    public static func resolve(
        pieces: [ArchiveExport.Piece], startMs: Int64, endMs: Int64, maxMs: Int64? = nil
    ) -> [Range] {
        guard endMs > startMs else { return [] }
        var out: [Range] = []
        var remaining = maxMs.map { max($0, 0) } ?? Int64.max
        for piece in pieces {
            guard remaining > 0 else { break }
            let extent = ArchiveExport.wallExtent(piece)
            let lower = max(startMs, extent.lowerBound)
            let upper = min(endMs, extent.upperBound)
            guard upper > lower else { continue }
            let clock = piece.clock
            let pieceMedia = piece.mediaRange(clock)
            func media(_ wall: Int64) -> Int64 {
                let offset = wall - clock.startWallMs
                // An inexact clock left the transcript on the media clock; the clip does too.
                let value = clock.isExact ? clock.media(fromWall: offset) : offset
                return min(max(value, pieceMedia.lowerBound), pieceMedia.upperBound)
            }
            var mediaLower = media(lower)
            var mediaUpper = media(upper)
            // Wholly inside a gap: the span holds no stored audio here.
            guard mediaUpper > mediaLower else { continue }
            if mediaUpper - mediaLower > remaining { mediaUpper = mediaLower + remaining }
            // Frame-aligned outward: a clip never starts or ends inside a frame.
            let frame = Int64(max(piece.meta.frameDurationMs, 1))
            mediaLower = max((mediaLower / frame) * frame, pieceMedia.lowerBound)
            mediaUpper = min(((mediaUpper + frame - 1) / frame) * frame, pieceMedia.upperBound)
            guard mediaUpper > mediaLower else { continue }
            remaining -= mediaUpper - mediaLower
            out.append(
                Range(
                    segmentId: piece.meta.segmentId, mediaRange: mediaLower..<mediaUpper,
                    wallRange: (clock.startWallMs + clock.wallOffset(ofMedia: mediaLower))
                        ..< (clock.startWallMs + clock.wallOffset(ofMedia: mediaUpper))))
        }
        return out
    }

    /// The frames of one range: frame `i` in stream order holds media `[i, i + 1) × frame`.
    public static func frames(
        _ range: Range, from records: [FrameRecord], frameDurationMs: Int
    ) -> [Data] {
        let frame = Int64(max(frameDurationMs, 1))
        let first = Int(range.mediaRange.lowerBound / frame)
        let last = Int((range.mediaRange.upperBound + frame - 1) / frame)
        guard first < records.count, last > first else { return [] }
        return records[first..<min(last, records.count)].map { Data($0.payload) }
    }
}
