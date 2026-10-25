import AppDB
import Foundation
import SearchKit
import SegmentStore
import Transcription

// The conversation as the server holds it: pieces placed on the wall clock, the quiet and
// interrupted rows the Conversation screen shows (from the screen's own rule,
// `SearchKit.pieceTimeline`), and the transcript cut, cleaned and masked exactly as the app's own
// AI layer reads it (`EnrichmentService.pieceTranscriptOf`) — but kept as timed items rather than
// collapsed into prose, so a tool can quote a turn and say when it was said.
//
// Pure: everything here is a function of the pieces (each one's sidecar, transcript and mask),
// so the export is pinned against real sidecars and transcripts in
// `ArchiveTranscriptExportTests` without a database or a store.

public enum ArchiveExport {
    /// Bumped when the export's meaning changes, so every conversation and transcript is sent
    /// again (paced by `ArchiveSyncService`). 2: words Soniox spaced apart no longer run
    /// together, a name reaches only the recording it was given in, and the gaps are the quiet
    /// and interrupted rows the Conversation screen shows — merged, thresholded and worded by
    /// the screen's own rule — instead of one row per gap record. (Never released on a phone
    /// before the gap change, so the two share one re-send.)
    /// 3: range-level human corrections override legacy speaker names, including local ASR
    /// without provider labels. Explicit unnamed/partial corrections block legacy fallback.
    /// 4: acoustic identity uses word alignment; 5: stable source anchors permit names-only
    /// patches without replacing a longer server transcript after phone retention.
    public static let transcriptExportVersion = "transcript-export-5"

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

    /// The conversation's quiet and interrupted rows, exactly as the Conversation screen shows
    /// them: each piece's rows from the screen's own rule (`SearchKit.pieceTimeline` — gap
    /// records collapsed within 5 s of each other, consecutive rows with no speech between them
    /// merged, quiet labelled from 30 s, an interruption given a transcript row from 10 s, the
    /// app's classifier and its words), placed on the wall clock. Nothing else is added: a hole
    /// between two pieces that no record explains is not loss to the app either (History draws
    /// it as not recording), and before 2026-09-30 most such holes were the watch's skipped
    /// silence the old store dropped.
    ///
    /// A piece with no transcript has no rows, as on the screen; the conversation's missing
    /// total (`missingMs`) still counts its loss.
    ///
    /// Only rows that reach into `window` (the conversation's first word to its last) are kept.
    /// A piece runs on to where the next conversation is cut, so its last rows can lie wholly
    /// after the last word; the screen lists them under it, but the server shows a conversation
    /// as its window, and that time belongs to the day's stretch between conversations, which
    /// the coverage sync already describes. A row that straddles an edge is kept whole: its
    /// numbers are the row's, and clipping it would make them disagree with its words.
    ///
    /// `pieces` carry the WHOLE segment's transcript (the rule cuts it). Word timings are not
    /// needed: the screen builds its blocks from them only when the provider labelled no
    /// speakers, which 8 of the 1,643 transcripts in the 2026-10-21 backup are.
    public static func gaps(_ pieces: [Piece], window: Range<Int64>) -> [ArchiveGap] {
        var out: [ArchiveGap] = []
        for piece in pieces {
            guard let transcript = piece.transcript else { continue }
            let clock = piece.clock
            let timeline = pieceTimeline(
                meta: piece.meta, member: piece.member, clock: clock,
                segments: transcript.segments.map {
                    SearchKit.TranscriptSegment(
                        text: $0.text, startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker)
                },
                words: transcript.words.map {
                    SearchKit.TranscriptWord(text: $0.text, startMs: $0.startMs, endMs: $0.endMs)
                },
                timebase: .media)
            for pause in timeline.pauses {
                let gap = ArchiveGap(pause, segmentStartWallMs: clock.startWallMs)
                guard gap.endMs > window.lowerBound, gap.startMs < window.upperBound else { continue }
                out.append(gap)
            }
        }
        return out.sorted { $0.startMs < $1.startMs }
    }

    /// The audio genuinely missing inside `window`, placed where each gap record says it
    /// happened and merged — the quantity History's card for the conversation says is missing
    /// ("4 min missing"), and what a clip of the span is short of. Only `GapClassifier` loss:
    /// quiet and the watch's power-save pause are not missing audio. A segment whose records do
    /// not account for its clocks contributes none: its records cannot be placed, and a guess
    /// would be a lie in the one place the product promises not to tell one.
    public static func lostSpans(_ pieces: [Piece], window: Range<Int64>) -> [ArchiveGap] {
        holes(pieces, window: window).filter { $0.kind == .lost }
    }

    /// Every stretch inside `window` with no stored audio, where each record says it is: the
    /// loss (`lostSpans`), and the silence the watch skipped and its power-save pause as `quiet`
    /// with the loss cut out of them. What a clip of the span leaves out of its audio, so the
    /// player can place what it holds on the clock (`X-Clip-Gaps`).
    public static func holes(_ pieces: [Piece], window: Range<Int64>) -> [ArchiveGap] {
        guard !window.isEmpty else { return [] }
        var lost: [(Range<Int64>, String)] = []
        var quiet: [Range<Int64>] = []
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
                let lower = max(clock.startWallMs + offset, window.lowerBound)
                let upper = min(clock.startWallMs + offset + duration, window.upperBound)
                guard upper > lower else { continue }
                if classifier.classify(gap) == .loss {
                    lost.append((lower..<upper, gap.origin == GapMeta.originSequenceSkip ? "link" : "watch"))
                } else {
                    quiet.append(lower..<upper)
                }
            }
        }
        let lostOut = mergeTagged(lost).map { range, origin in
            ArchiveGap(startMs: range.lowerBound, endMs: range.upperBound, kind: .lost, origin: origin)
        }
        let quietOut = subtract(quiet, lostOut.map { $0.startMs..<$0.endMs }).map {
            ArchiveGap(startMs: $0.lowerBound, endMs: $0.upperBound, kind: .quiet)
        }
        return (lostOut + quietOut).sorted { $0.startMs < $1.startMs }
    }

    /// How much of `window` is genuinely missing (`lostSpans`), in milliseconds.
    public static func missingMs(_ pieces: [Piece], window: Range<Int64>) -> Int64 {
        lostSpans(pieces, window: window).reduce(0) { $0 + $1.durationMs }
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
    /// and interrupted rows (`gaps`) the screen shows between the words go in as their own
    /// items, and everything is in time order.
    ///
    /// `text` is the turns alone, one line each: the speaker's name, or their label when nobody
    /// has named them, a colon, and what they said. A turn with no speaker label is its text.
    public static func transcript(
        conversationId: String, pieces: [Piece], gaps: [ArchiveGap],
        speakerNames: [String: String], sourceHash: String,
        identity: SpeakerIdentitySnapshot = .init(), legacyAssignments: [SpeakerAssignment] = []
    ) -> ArchiveTranscriptPayload {
        var items: [ArchiveTranscriptPayload.Item] = []
        var anchors: [Int: ArchiveSpeakerRange] = [:]
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
            var clean = cut
            clean.segments = turns.enumerated().filter { !looped[$0.offset] }.map(\.element)
            let legacy = legacyAssignments.isEmpty ? speakerNames.map { label, name in
                SpeakerAssignment(conversationId: conversationId, label: label,
                                  personId: "legacy:" + label, personName: name)
            } : legacyAssignments
            let attributed = SpeakerAttribution.attributedTurns(transcript: clean,
                segmentId: piece.member.segmentId, identity: identity, legacyAssignments: legacy)
            var withheldBy = Set<Int>()
            var spoken = 0
            for turn in attributed {
                let middle = turn.startMs + max(turn.endMs - turn.startMs, 0) / 2
                if let mask = piece.masked.firstIndex(where: { $0.range.contains(middle) }) {
                    withheldBy.insert(mask)
                    continue
                }
                let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let wall = clock.wallRange(ofMediaStartMs: turn.startMs, endMs: turn.endMs)
                let label = turn.originalSpeaker?.trimmingCharacters(in: .whitespaces)
                // A provider labels each segment on its own, so a name is the one given to this
                // label IN THIS SEGMENT (`SpeakerKey`); one given before names were scoped, in
                // either form it was stored in, still covers the label wherever no segment name
                // does.
                let name = turn.person?.name
                if turn.endMs > turn.startMs, wall.endMs > wall.startMs {
                    let id = turn.person?.id
                    anchors[items.count] = ArchiveSpeakerRange(itemIndex: nil, segmentId: piece.member.segmentId,
                        startMediaMs: turn.startMs, endMediaMs: turn.endMs, atMs: wall.startMs, endMs: wall.endMs,
                        personId: id?.hasPrefix("legacy:") == true ? nil : id, name: name)
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
        // The rows the screen draws between the words. An interruption too brief for a row of
        // its own there (under 10 s) is not one here either; the conversation's gaps still carry
        // it, and its missing total still counts it.
        for gap in gaps where gap.shown {
            items.append(.gap(gap))
        }
        // Time order; at one instant a marker reads before the words that follow it.
        let sorted = items.enumerated().sorted { a, b in
            if a.element.atMs != b.element.atMs { return a.element.atMs < b.element.atMs }
            let rankA = a.element.kindName == "turn" ? 1 : 0
            let rankB = b.element.kindName == "turn" ? 1 : 0
            if rankA != rankB { return rankA < rankB }
            return a.offset < b.offset
        }
        let ordered = sorted.map(\.element)
        let speakerRanges = sorted.enumerated().compactMap { index, old -> ArchiveSpeakerRange? in
            guard var anchor = anchors[old.offset] else { return nil }
            anchor.itemIndex = index
            return anchor
        }
        var orderedLines: [String] = []
        for item in ordered {
            guard case .turn(_, _, let speaker, let name, let text, _) = item else { continue }
            orderedLines.append(SpeakerAttribution.line(text: text, speaker: speaker, name: name))
        }
        let text = orderedLines.joined(separator: "\n")
        let main = turnsBySource.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }.flatMap { sources[$0.key] }
        return ArchiveTranscriptPayload(
            conversationId: conversationId, sourceHash: sourceHash, provider: main?.provider,
            model: main?.model, language: nil, charCount: text.count, text: text, items: ordered,
            speakerRanges: speakerRanges)
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
