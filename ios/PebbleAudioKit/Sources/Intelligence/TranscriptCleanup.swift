import AppDB
import Foundation
import Transcription

// The AI's half of looped-artefact handling. `AppDB/TranscriptArtefacts.swift` carries the
// rationale, the measured numbers, and the thresholds.
//
// This is the higher-value half and the lower-risk one. What reaches a model today is
// `SegmentTranscript.text` verbatim, so one 15-minute recording in Roger's library hands the
// summariser 12 439 words of which 12 278 are the same sentence over and over. Everything
// downstream then inherits it: the conversation's title and summary, its library tags, the
// follow-ups extracted from it, the day's recap, the Spotlight document, and every Ask that
// retrieves the stretch. The model is being asked to find meaning in a transcriber's stutter,
// and it obliges — that is where "Unclear Conversation About Plans" comes from.
//
// Nothing is deleted. `withLoopedArtefactsCollapsed()` returns an in-memory copy; the file the
// provider wrote is untouched and is what the transcript screen still reads. When nothing is
// suppressed it returns `self`, byte for byte, so a clean transcript is never reformatted.

extension SegmentTranscript {
    /// This transcript with looped ASR artefacts collapsed: the first occurrence of every
    /// repeated line survives, the echoes after it are replaced by one short note saying how
    /// many there were.
    ///
    /// The note matters as much as the removal. A model handed 104 surviving words from a
    /// fifteen-minute recording, with no explanation, will reach for significance it cannot
    /// have; told that the recording was quiet and the transcriber looped, it can say so.
    public func withLoopedArtefactsCollapsed() -> SegmentTranscript {
        // Word timings are dropped from the analysis copy rather than filtered: nothing on the
        // AI path reads them, and filtering them correctly needs the render path's positional
        // character walk. Callers that need aligned words use SearchKit's version.
        guard segments.count > 1 else { return self }
        let turns = segments.map { ArtefactTurn(text: $0.text, startMs: $0.startMs) }
        let verdicts = TranscriptArtefacts.loopedArtefacts(in: turns)
        guard verdicts.contains(true) else { return self }

        var kept: [TranscriptSegment] = []
        var pieces: [String] = []
        var index = 0
        while index < segments.count {
            if !verdicts[index] {
                kept.append(segments[index])
                let trimmed = segments[index].text.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append(trimmed) }
                index += 1
                continue
            }
            var end = index
            while end + 1 < segments.count, verdicts[end + 1] { end += 1 }
            pieces.append(Self.loopNote(repeats: end - index + 1))
            index = end + 1
        }
        var copy = self
        copy.segments = kept
        copy.words = []
        copy.text = pieces.joined(separator: " ")
        return copy
    }

    /// Words the artefact rules account for, without building the collapsed copy — for callers
    /// that want to know how much of a transcript is loop before deciding what to do with it.
    public var loopedArtefactWordCount: Int {
        guard segments.count > 1 else { return 0 }
        let turns = segments.map { ArtefactTurn(text: $0.text, startMs: $0.startMs) }
        let verdicts = TranscriptArtefacts.loopedArtefacts(in: turns)
        var total = 0
        for (index, suppressed) in verdicts.enumerated() where suppressed {
            total += TranscriptArtefacts.tokenize(segments[index].text).count
        }
        return total
    }

    /// Plain English, present tense, no jargon — this lands in a prompt, and a model reads it
    /// as a statement about the recording rather than as transcript content.
    static func loopNote(repeats: Int) -> String {
        repeats == 1
            ? "[the transcriber repeated the previous line once more over quiet audio; omitted]"
            : "[the transcriber repeated the previous line \(repeats) more times over quiet audio; omitted]"
    }
}
