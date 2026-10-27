import AppDB
import Foundation
import Transcription

public struct SpeakerAttributedTurn: Equatable, Sendable {
    public var text: String
    public var startMs: Int64
    public var endMs: Int64
    public var originalSpeaker: String?
    public var person: Person?
    public var isVoiceMatch: Bool
    public var words: [Transcription.TranscriptWord]
    public var confidence: Double?
}

public enum SpeakerTranscriptAttribution {
    /// Split only when the words demonstrably reproduce the source turn. Missing/mismatched
    /// timings preserve the original text and require exact whole-turn identity coverage.
    public static func attributedTurns(
        transcript: SegmentTranscript, segmentId: String,
        identity: SpeakerIdentitySnapshot, legacyAssignments: [SpeakerAssignment]
    ) -> [SpeakerAttributedTurn] {
        attributedTurns(segments: transcript.segments, words: transcript.words,
            segmentId: segmentId, identity: identity, legacyAssignments: legacyAssignments)
    }

    public static func attributedTurns(
        segments: [Transcription.TranscriptSegment], words: [Transcription.TranscriptWord],
        segmentId: String, identity: SpeakerIdentitySnapshot, legacyAssignments: [SpeakerAssignment]
    ) -> [SpeakerAttributedTurn] {
        func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        let ordered = words.sorted { $0.startMs < $1.startMs }
        return segments.flatMap { turn -> [SpeakerAttributedTurn] in
            var low = 0, high = ordered.count
            while low < high {
                let middle = (low + high) / 2
                if ordered[middle].startMs < turn.startMs { low = middle + 1 } else { high = middle }
            }
            let candidates = ordered[low...].prefix { $0.startMs < turn.endMs }
            var words = Array(candidates.filter {
                $0.endMs <= turn.endMs && $0.endMs >= $0.startMs
            })
            // A provider can put the final subword/punctuation exactly at the turn's end.
            // Include only the tokens needed to reproduce this turn, never the next turn.
            let expected = compact(turn.text)
            var tokenText = compact(words.map(\.text).joined())
            // A zero-length suffix of the preceding turn may share this turn's start.
            // Only skip such boundary tokens if the remaining text can match this turn.
            while let first = words.first, first.startMs == turn.startMs,
                  first.endMs == first.startMs, !expected.hasPrefix(tokenText) {
                words.removeFirst()
                tokenText = compact(words.map(\.text).joined())
            }
            if expected.hasPrefix(tokenText), tokenText.count < expected.count {
                for word in ordered[(low + candidates.count)...].prefix(while: { $0.startMs <= turn.endMs })
                    where word.startMs == turn.endMs && word.endMs == turn.endMs {
                    let next = tokenText + compact(word.text)
                    guard expected.hasPrefix(next) else { break }
                    words.append(word)
                    tokenText = next
                    if tokenText == expected { break }
                }
            }
            guard !words.isEmpty, tokenText == expected else {
                let resolved = identity.resolvedIdentity(segmentId: segmentId, startMediaMs: turn.startMs,
                    endMediaMs: turn.endMs, speaker: turn.speaker, legacyAssignments: legacyAssignments)
                return [SpeakerAttributedTurn(text: turn.text, startMs: turn.startMs, endMs: turn.endMs,
                    originalSpeaker: turn.speaker, person: resolved?.person,
                    isVoiceMatch: resolved?.isVoiceMatch ?? false, words: words, confidence: turn.confidence)]
            }
            // Provider "words" can be subword tokens, including zero-duration syllables.
            // Resolve complete written words, just as the selection UI does. Otherwise a
            // zero-duration suffix or separately timed period can un-name part of a word.
            // Keep every token and original character; punctuation belongs to its word but
            // doesn't expand the acoustic range beyond the letters the person selected.
            var cursor = turn.text.startIndex
            var units: [(text: String, words: [Transcription.TranscriptWord])] = []
            for word in words {
                let begin = cursor
                var remaining = compact(word.text).count
                while cursor < turn.text.endIndex && remaining > 0 {
                    if !turn.text[cursor].isWhitespace { remaining -= 1 }
                    cursor = turn.text.index(after: cursor)
                }
                while cursor < turn.text.endIndex && turn.text[cursor].isWhitespace {
                    cursor = turn.text.index(after: cursor)
                }
                let text = String(turn.text[begin..<cursor])
                if let last = units.last, last.text.last?.isWhitespace == false {
                    units[units.count - 1].text += text
                    units[units.count - 1].words.append(word)
                } else {
                    units.append((text, [word]))
                }
            }
            var out: [SpeakerAttributedTurn] = []
            for unit in units {
                let lexical = unit.words.filter { $0.text.contains { $0.isLetter || $0.isNumber } }
                let timed = lexical.isEmpty ? unit.words : lexical
                let start = timed.map(\.startMs).min()!
                let end = timed.map(\.endMs).max()!
                // A whole word may have a point timestamp. Use half-open point containment
                // for identity, while retaining its true zero-length timing in the output.
                let resolved = identity.resolvedWordIdentity(segmentId: segmentId,
                    startMediaMs: start, endMediaMs: end > start ? end : start + (start < Int64.max ? 1 : 0),
                    speaker: turn.speaker, legacyAssignments: legacyAssignments)
                if let last = out.last, last.person?.id == resolved?.person.id,
                   last.isVoiceMatch == (resolved?.isVoiceMatch ?? false),
                   start - last.endMs < 1_000 {
                    out[out.count - 1].text += unit.text
                    out[out.count - 1].endMs = max(last.endMs, end)
                    out[out.count - 1].words += unit.words
                } else {
                    out.append(SpeakerAttributedTurn(text: unit.text, startMs: start, endMs: end,
                        originalSpeaker: turn.speaker, person: resolved?.person,
                        isVoiceMatch: resolved?.isVoiceMatch ?? false, words: unit.words, confidence: turn.confidence))
                }
            }
            return out
        }
    }

}
