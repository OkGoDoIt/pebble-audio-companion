import AppDB
import Foundation
import SegmentStore

// Method 1 of the audio-content classification: conversation or not, per minute, from the
// transcript alone. Measurements and the reasoning behind every constant are in
// `docs/audio-content-classification.md`; the short version:
//
// - 320 one-minute windows of real recordings were labelled by reading their transcripts with
//   two minutes of context either side, plus their loudness shape. 40% were held back.
// - Under two words a minute is "no conversation" at 96% precision (weighted to the library's
//   real mix; 83% raw, every miss a pause inside a conversation). It can never hide more than
//   two words a minute, which is what makes it safe to act on.
// - Two or more words a minute is conversation 90-92% of the time. The rest is TV, lyrics,
//   announcements and transcriber loops, which nothing this cheap can tell from talk; the loops
//   are caught here, the others need a reading of the words (method 2) and are left as
//   conversation until something can say so accurately.
// - Smoothing (absorbing short no-conversation runs into their neighbours) was measured and
//   rejected: it lost far more real no-conversation minutes than lulls it saved, because the
//   "conversation" neighbours are often lyrics or TV themselves.
//
// Pure: no I/O, no clock. The caller supplies the segment's metadata and its turns.

public enum AudioContentMethod {
    /// Bump when the verdicts this method gives for the same input change. Every stored
    /// segment's input key embeds it, so a bump reclassifies the library (cheaply: this is a
    /// pass over turn timings, no model).
    public static let version = 1

    /// The unit of judgement. A minute is short enough that half an hour of music after a
    /// conversation is not folded into it, long enough that one pause between sentences is
    /// not a verdict.
    public static let windowMs: Int64 = 60_000

    /// A trailing piece shorter than this joins the window before it: 20 seconds with one word
    /// in it is not evidence of anything.
    public static let minimumWindowMs: Int64 = 30_000

    /// Fewer words a minute than this is no conversation.
    public static let minimumWordsPerMinute = 2.0

    /// Faster than anyone talks for a whole minute. Across the library's 18,651 minutes, 51 are
    /// over this and every one of them repeats at least 77% of its word trigrams — loops the
    /// display-side artefact rule leaves alone ("Yeah. Yeah. Yeah." for four minutes, a lyric
    /// line forty times). The fastest real conversations measured sit near 240.
    public static let implausibleWordsPerMinute = 320.0
    /// ...and made of the same few phrases. Both conditions, so a fast real conversation whose
    /// transcript duplicated a stretch at a seam is never read as a loop.
    public static let implausibleRepetition = 0.6

    /// At any speed, a minute that is this repetitive IS a loop. 26 of the library's minutes
    /// with 20+ words reach it and every one read is the transcriber stuck ("안녕하세요." forty
    /// times, "Good morning." thirty, "the, the, the"); the most repetitive real conversation
    /// found sits at 0.80.
    public static let loopRepetition = 0.85
    public static let loopMinimumWords = 20.0

    /// Measured precisions (held-back labels, weighted to the library's mix), stored as the
    /// span's confidence. See the design doc's table.
    public static let noConversationConfidence = 0.96
    public static let conversationConfidence = 0.90
    /// The transcriber's own verdict for a whole segment. Wrong verdicts have hidden real
    /// conversations before (53 of 575, all from failing engines, since fixed and re-queued),
    /// so this is not treated as certain either.
    public static let noSpeechConfidence = 0.95
    public static let loopConfidence = 0.95

    /// What a stored classification was computed from. When it differs from the current one
    /// the segment is classified again.
    public static func inputKey(state: TranscriptionState, transcriptVersion: String?) -> String {
        "v\(version)|\(state.rawValue)|\(transcriptVersion ?? "-")"
    }
}

public enum AudioContentClassifier {
    /// The spans for one segment, or nil when it cannot be classified yet: still open, or not
    /// in a terminal transcription state, or `Complete` with no transcript on disk (a
    /// bookkeeping fault, never read as silence — the same rule `SegmentSpeechEvidence` keeps).
    ///
    /// `turns` are the transcript's segments (`SegmentTranscript.segments`), on the segment's
    /// stored-audio clock.
    public static func classify(
        meta: SegmentMeta, turns: [TranscriptSegment]?
    ) -> [SegmentAudioContentSpan]? {
        guard meta.closeReason != nil else { return nil }
        let clock = SegmentMediaClock(meta)
        let mediaSpan = clock.mediaSpanMs
        guard mediaSpan > 0 else { return [] }

        switch meta.transcriptionState {
        case .noSpeech:
            return place(
                [
                    Verdict(
                        mediaStart: 0, mediaEnd: mediaSpan, kind: .noConversation,
                        descriptor: nil, decidedBy: AudioContentDecider.noSpeech,
                        confidence: AudioContentMethod.noSpeechConfidence, words: 0)
                ], meta: meta, clock: clock)
        case .complete:
            guard let turns else { return nil }
            return place(verdicts(turns: turns, mediaSpan: mediaSpan), meta: meta, clock: clock)
        case .pending, .running, .uploading, .failed, .disabled:
            return nil
        }
    }

    struct Verdict: Equatable {
        var mediaStart: Int64
        var mediaEnd: Int64
        var kind: AudioContentKind
        var descriptor: String?
        var decidedBy: String
        var confidence: Double
        var words: Double
    }

    /// Per-minute verdicts over the stored audio, adjacent equal ones merged.
    static func verdicts(turns: [TranscriptSegment], mediaSpan: Int64) -> [Verdict] {
        let windows = windowEdges(mediaSpan: mediaSpan)
        let loops = TranscriptArtefacts.loopedArtefacts(
            in: turns.map { ArtefactTurn(text: $0.text, startMs: $0.startMs) })

        // Each turn's words spread evenly over its own time, so a turn straddling a window
        // edge counts in proportion on either side; loop echoes counted apart.
        var words = Array(repeating: 0.0, count: windows.count)
        var loopWords = Array(repeating: 0.0, count: windows.count)
        var windowTokens = Array(repeating: [String](), count: windows.count)
        for (index, turn) in turns.enumerated() {
            let tokens = TranscriptArtefacts.tokenize(turn.text)
            let count = Double(tokens.count)
            guard count > 0 else { continue }
            let start = min(max(turn.startMs, 0), mediaSpan)
            let end = min(max(turn.endMs, start + 1), mediaSpan)
            let length = Double(max(end - start, 1))
            for (w, edge) in windows.enumerated() {
                let overlap = min(end, edge.upperBound) - max(start, edge.lowerBound)
                guard overlap > 0 else { continue }
                let share = count * Double(overlap) / length
                if loops[index] { loopWords[w] += share } else { words[w] += share }
                windowTokens[w].append(contentsOf: tokens)
            }
        }

        var out: [Verdict] = []
        for (w, edge) in windows.enumerated() {
            let minutes = Double(edge.count) / 60_000
            let rate = words[w] / minutes
            let verdict: Verdict
            // Loop first: the artefact rule keeps the FIRST occurrence of every repeated line
            // (`TranscriptArtefacts`), so a minute of "¿Qué pasó?" forty times still holds a few
            // "real" words. When most of a minute's words are echoes, the minute is the loop.
            //
            // The artefact rule is tuned for DISPLAY, where hiding a real line is the worst
            // outcome, so it passes some loops through. A minute faster than anyone speaks and
            // made of the same few phrases is one of them (see `implausibleWordsPerMinute`).
            let echoes =
                loopWords[w] / minutes >= AudioContentMethod.minimumWordsPerMinute
                && loopWords[w] > words[w]
            let repeated = repetition(windowTokens[w])
            let implausible =
                (words[w] + loopWords[w]) / minutes > AudioContentMethod.implausibleWordsPerMinute
                && repeated >= AudioContentMethod.implausibleRepetition
            let monotonous =
                words[w] + loopWords[w] >= AudioContentMethod.loopMinimumWords
                && repeated >= AudioContentMethod.loopRepetition
            if echoes || implausible || monotonous {
                // The words that are there are the transcriber repeating itself: not speech.
                verdict = Verdict(
                    mediaStart: edge.lowerBound, mediaEnd: edge.upperBound, kind: .noConversation,
                    descriptor: nil, decidedBy: AudioContentDecider.loop,
                    confidence: AudioContentMethod.loopConfidence, words: words[w])
            } else if rate >= AudioContentMethod.minimumWordsPerMinute {
                verdict = Verdict(
                    mediaStart: edge.lowerBound, mediaEnd: edge.upperBound, kind: .conversation,
                    descriptor: nil, decidedBy: AudioContentDecider.wordRate,
                    confidence: AudioContentMethod.conversationConfidence, words: words[w])
            } else if loopWords[w] / minutes >= AudioContentMethod.minimumWordsPerMinute {
                verdict = Verdict(
                    mediaStart: edge.lowerBound, mediaEnd: edge.upperBound, kind: .noConversation,
                    descriptor: nil, decidedBy: AudioContentDecider.loop,
                    confidence: AudioContentMethod.loopConfidence, words: words[w])
            } else {
                verdict = Verdict(
                    mediaStart: edge.lowerBound, mediaEnd: edge.upperBound, kind: .noConversation,
                    descriptor: words[w] >= 0.5 ? AudioContentDescriptor.fewWords : nil,
                    decidedBy: AudioContentDecider.wordRate,
                    confidence: AudioContentMethod.noConversationConfidence, words: words[w])
            }
            if var last = out.last, last.kind == verdict.kind,
                last.decidedBy == verdict.decidedBy, last.mediaEnd == verdict.mediaStart
            {
                // A no-conversation run with a stray word somewhere in it is one run with a
                // few words in it, not alternating "few words" and "nothing" minutes.
                last.mediaEnd = verdict.mediaEnd
                last.words += verdict.words
                if last.decidedBy == AudioContentDecider.wordRate, last.kind == .noConversation {
                    last.descriptor = last.words >= 0.5 ? AudioContentDescriptor.fewWords : nil
                }
                out[out.count - 1] = last
            } else {
                out.append(verdict)
            }
        }
        return out
    }

    /// Share of a token list's word trigrams that are repeats: 0 for varied speech, near 1 for
    /// the same phrase over and over. Too few words to say is 0.
    static func repetition(_ tokens: [String]) -> Double {
        guard tokens.count >= 12 else { return 0 }
        var seen = Set<String>()
        let total = tokens.count - 2
        for index in 0..<total {
            seen.insert(tokens[index] + " " + tokens[index + 1] + " " + tokens[index + 2])
        }
        return 1 - Double(seen.count) / Double(total)
    }

    /// Minute windows over `[0, mediaSpan)`, the last short piece folded into its predecessor.
    static func windowEdges(mediaSpan: Int64) -> [Range<Int64>] {
        let size = AudioContentMethod.windowMs
        var edges: [Range<Int64>] = []
        var start: Int64 = 0
        while start < mediaSpan {
            let end = min(start + size, mediaSpan)
            if end - start < AudioContentMethod.minimumWindowMs, let last = edges.last {
                edges[edges.count - 1] = last.lowerBound..<end
            } else {
                edges.append(start..<end)
            }
            start = end
        }
        return edges
    }

    /// Media verdicts onto the wall clock. With exact gap records a verdict that straddles a
    /// quiet or lost gap becomes two stored spans with the gap left out. Without them, the
    /// verdicts sit at their stored-audio offsets from the segment's start and are not
    /// stretched across wall time the records cannot account for (the same refusal
    /// `ConversationBoundaryDetector.spokenRuns` makes); the rest of such a segment stays
    /// unclassified rather than labelled on a guess.
    static func place(
        _ verdicts: [Verdict], meta: SegmentMeta, clock: SegmentMediaClock
    ) -> [SegmentAudioContentSpan] {
        let start = ConversationGrouper.segmentStartMs(meta)
        let end = ConversationGrouper.segmentEndMs(meta)
        var out: [SegmentAudioContentSpan] = []
        for verdict in verdicts {
            let media = verdict.mediaStart..<verdict.mediaEnd
            let pieces: [Range<Int64>] =
                clock.isExact
                ? clock.wallRanges(fromMedia: media)
                : [media]
            let total = pieces.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
            for piece in pieces {
                let low = min(start + piece.lowerBound, end)
                let high = min(start + piece.upperBound, end)
                guard high > low else { continue }
                let share = total > 0 ? Double(piece.count) / Double(total) : 1
                out.append(
                    SegmentAudioContentSpan(
                        segmentId: meta.segmentId, index: out.count, startMs: low, endMs: high,
                        mediaStartMs: verdict.mediaStart, mediaEndMs: verdict.mediaEnd,
                        kind: verdict.kind, descriptor: verdict.descriptor,
                        confidence: verdict.confidence, decidedBy: verdict.decidedBy,
                        version: AudioContentMethod.version,
                        wordCount: Int((verdict.words * share).rounded())))
            }
        }
        return out
    }
}
