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
            let words = ordered[low...].prefix { $0.startMs < turn.endMs }.filter {
                $0.endMs <= turn.endMs && $0.endMs > $0.startMs
            }
            guard !words.isEmpty, compact(words.map(\.text).joined()) == compact(turn.text) else {
                let resolved = identity.resolvedIdentity(segmentId: segmentId, startMediaMs: turn.startMs,
                    endMediaMs: turn.endMs, speaker: turn.speaker, legacyAssignments: legacyAssignments)
                return [SpeakerAttributedTurn(text: turn.text, startMs: turn.startMs, endMs: turn.endMs,
                    originalSpeaker: turn.speaker, person: resolved?.person,
                    isVoiceMatch: resolved?.isVoiceMatch ?? false, words: words, confidence: turn.confidence)]
            }
            // Consume the original string, assigning each token all following whitespace.
            // Joining these pieces recovers exactly the source, including punctuation.
            var cursor = turn.text.startIndex
            var out: [SpeakerAttributedTurn] = []
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
                let resolved = identity.resolvedWordIdentity(segmentId: segmentId,
                    startMediaMs: word.startMs, endMediaMs: word.endMs,
                    speaker: turn.speaker, legacyAssignments: legacyAssignments)
                let text = String(turn.text[begin..<cursor])
                if let last = out.last, last.person?.id == resolved?.person.id,
                   last.isVoiceMatch == (resolved?.isVoiceMatch ?? false),
                   word.startMs - last.endMs < 1_000 {
                    out[out.count - 1].text += text
                    out[out.count - 1].endMs = word.endMs
                    out[out.count - 1].words.append(word)
                } else {
                    out.append(SpeakerAttributedTurn(text: text, startMs: word.startMs, endMs: word.endMs,
                        originalSpeaker: turn.speaker, person: resolved?.person,
                        isVoiceMatch: resolved?.isVoiceMatch ?? false, words: [word], confidence: turn.confidence))
                }
            }
            return out
        }
    }

}
