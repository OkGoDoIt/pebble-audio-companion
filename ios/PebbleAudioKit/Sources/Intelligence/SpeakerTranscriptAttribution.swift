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
        // Looked up per word below: only this recording's rows, however long the conversation.
        let identity = identity.narrowed(to: segmentId)
        // The last of the app's own speakers heard, carried over words it heard nobody say.
        var carried: (label: String, endMs: Int64)?
        return segments.flatMap { turn -> [SpeakerAttributedTurn] in
            // A transcript with no speaker labels takes the speakers the app told apart itself.
            let provided = turn.speaker.flatMap { $0.isEmpty ? nil : $0 }
            func own(_ start: Int64, _ end: Int64) -> String? {
                identity.ownSpeaker(segmentId: segmentId, startMediaMs: start, endMediaMs: end)
            }
            /// A short pause doesn't change who's talking.
            func carriedLabel(at start: Int64) -> String? {
                guard let carried, start - carried.endMs < Self.carryMs else { return nil }
                return carried.label
            }
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
                var label = provided
                if provided == nil, resolved == nil {
                    label = own(turn.startMs, turn.endMs) ?? carriedLabel(at: turn.startMs)
                    if let label { carried = (label, turn.endMs) }
                }
                return [SpeakerAttributedTurn(text: turn.text, startMs: turn.startMs, endMs: turn.endMs,
                    originalSpeaker: label, person: resolved?.person,
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
            var entries: [WordRun] = units.map { unit in
                let lexical = unit.words.filter { $0.text.contains { $0.isLetter || $0.isNumber } }
                let timed = lexical.isEmpty ? unit.words : lexical
                let start = timed.map(\.startMs).min()!
                let end = timed.map(\.endMs).max()!
                // A whole word may have a point timestamp. Use half-open point containment
                // for identity, while retaining its true zero-length timing in the output.
                let resolved = identity.resolvedWordIdentity(segmentId: segmentId,
                    startMediaMs: start, endMediaMs: end > start ? end : start + (start < Int64.max ? 1 : 0),
                    speaker: turn.speaker, legacyAssignments: legacyAssignments)
                return WordRun(text: unit.text, words: unit.words, start: start, end: end, resolved: resolved, label: provided)
            }
            if provided == nil { Self.labelOwnSpeakers(&entries, own: own, carried: &carried) }
            var out: [SpeakerAttributedTurn] = []
            for entry in entries {
                if let last = out.last, last.person?.id == entry.resolved?.person.id,
                   last.isVoiceMatch == (entry.resolved?.isVoiceMatch ?? false),
                   last.originalSpeaker == entry.label,
                   entry.start - last.endMs < 1_000 {
                    out[out.count - 1].text += entry.text
                    out[out.count - 1].endMs = max(last.endMs, entry.end)
                    out[out.count - 1].words += entry.words
                } else {
                    out.append(SpeakerAttributedTurn(text: entry.text, startMs: entry.start, endMs: entry.end,
                        originalSpeaker: entry.label, person: entry.resolved?.person,
                        isVoiceMatch: entry.resolved?.isVoiceMatch ?? false, words: entry.words, confidence: turn.confidence))
                }
            }
            return out
        }
    }

    /// How long a pause can run with the same person still talking.
    static let carryMs: Int64 = 2_000
    /// A label held for this few words, between others, is a stray and not a new speaker.
    static let strayWords = 2
    /// A pause this short either side means the words ran on without a break.
    static let strayPauseMs: Int64 = 500

    /// Unnamed words take the app's own speakers. Named words keep their name, and don't split
    /// on a speaker number nobody sees. Words the app heard nobody say carry the speaker around
    /// them, and a stray word or two takes its neighbour's: a speaker for one word is noise.
    fileprivate static func labelOwnSpeakers(_ entries: inout [WordRun], own: (Int64, Int64) -> String?,
                                             carried: inout (label: String, endMs: Int64)?) {
        let unnamed = entries.indices.filter { entries[$0].resolved == nil }
        for index in unnamed {
            let entry = entries[index]
            entries[index].label = own(entry.start, entry.end > entry.start ? entry.end : entry.start + 1)
        }
        // Heard by nobody: the speaker just before, across a short pause, else the next one heard.
        var previous = carried
        for index in unnamed {
            if let label = entries[index].label {
                previous = (label, entries[index].end)
            } else if let previous, entries[index].start - previous.endMs < carryMs {
                entries[index].label = previous.label
            }
        }
        var next: String?
        for index in unnamed.reversed() {
            if let label = entries[index].label { next = label } else { entries[index].label = next }
        }
        // Strays: a word or two mid-flow, with the same person either side and no pause around
        // it, is theirs. A short reply after a pause ("Yes, twice.") is a turn of its own.
        var runStart = 0
        while runStart < unnamed.count {
            var runEnd = runStart
            while runEnd + 1 < unnamed.count, unnamed[runEnd + 1] == unnamed[runEnd] + 1,
                  entries[unnamed[runEnd + 1]].label == entries[unnamed[runStart]].label { runEnd += 1 }
            let first = unnamed[runStart], last = unnamed[runEnd]
            let words = (runStart...runEnd).reduce(0) { $0 + entries[unnamed[$1]].wordCount }
            if words <= strayWords, runStart > 0, runEnd + 1 < unnamed.count,
               unnamed[runStart - 1] == first - 1, unnamed[runEnd + 1] == last + 1,
               let neighbour = entries[first - 1].label, neighbour == entries[last + 1].label,
               neighbour != entries[first].label,
               entries[first].start - entries[first - 1].end < strayPauseMs,
               entries[last + 1].start - entries[last].end < strayPauseMs {
                for index in first...last { entries[index].label = neighbour }
            }
            runStart = runEnd + 1
        }
        if let last = unnamed.last, let label = entries[last].label { carried = (label, entries[last].end) }
    }
}

/// A word, or a few run together, on its way to becoming part of a turn.
fileprivate struct WordRun {
    var text: String
    var words: [Transcription.TranscriptWord]
    var start: Int64
    var end: Int64
    var resolved: ResolvedSpeakerIdentity?
    var label: String?
    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}
