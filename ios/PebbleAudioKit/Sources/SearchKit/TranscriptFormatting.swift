import Foundation
import SegmentStore
import StatusUI
import WireProtocol

// Port of the pure transcript-formatting derivations from `app/.../ui/LibraryScreen.kt`, pinned
// by `TranscriptFormattingTest`. These behaviors are the spec for the rebuilt transcript
// renderer.
//
// Structural adjustments vs KMP (mirrored in SearchKitTests):
// - `SegmentTranscript` (a Transcription-module type) is replaced by the local
//   `TranscriptSegment` / `TranscriptWord` slices — SearchKit deliberately does not depend on
//   the Transcription module.
// - The KMP sealed interface `TranscriptTimelineItem` is a Swift enum with payload structs.
//
// NOT here (plan 4.7): the old hand-rolled fuzzy-search ENGINE. The product's search is the
// persistent FTS5 index in `TranscriptIndex.swift`, which indexes transcript text and ranks
// with bm25; the KMP scorer was ported alongside it, reached no screen, and was deleted rather
// than left looking like a second search engine someone might "fix" search by reaching for.
//
// Gap classification and its plain-language copy come from StatusUI — the one status
// vocabulary. This file used to carry a private copy of both, and the copy had already drifted:
// StatusUI's classifier was rewritten to O(log n) after the O(n²) original froze the main
// thread for ~12 s on a segment with thousands of gap records, and the copy here — the one that
// actually renders transcripts — never got that fix.

// MARK: - Input slices

/// One provider phrase/window with timings (display slice).
public struct TranscriptSegment: Equatable, Sendable {
    public var text: String
    public var startMs: Int64
    public var endMs: Int64
    public var speaker: String?

    public init(text: String, startMs: Int64, endMs: Int64, speaker: String? = nil) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
    }
}

/// One provider word timing (display slice).
public struct TranscriptWord: Equatable, Sendable {
    public var text: String
    public var startMs: Int64
    public var endMs: Int64

    public init(text: String, startMs: Int64, endMs: Int64) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

// MARK: - Speaker presentation

/// Presents a raw provider speaker id ("1", "agent") as a friendly label ("Speaker 1", "Agent").
public func speakerLabel(_ speaker: String) -> String {
    let trimmed = speaker.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return trimmed }
    if trimmed.allSatisfy({ $0.isNumber }) {
        return "Speaker \(trimmed)"
    }
    if let first = trimmed.first, first.isLowercase {
        return first.uppercased() + trimmed.dropFirst()
    }
    return trimmed
}

/// Number of distinct speaker colors the UI cycles through.
public let speakerColorCount = 6

/// Stable palette index for a speaker label: numeric speakers stay stable and distinct; named
/// speakers hash (Kotlin 32-bit `acc * 31 + code` semantics preserved).
public func speakerColorIndex(_ speaker: String) -> Int {
    let normalized = speaker.trimmingCharacters(in: .whitespaces)
    let digits =
        normalized.hasPrefix("Speaker ")
        ? String(normalized.dropFirst("Speaker ".count)) : normalized
    if !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), let number = Int(digits), number > 0 {
        return (number - 1) % speakerColorCount
    }
    var hash: Int32 = 0
    for unit in normalized.lowercased().utf16 {
        hash = hash &* 31 &+ Int32(unit)
    }
    let count = Int32(speakerColorCount)
    return Int(((hash % count) + count) % count)
}

// MARK: - Timeline items

/// One cause of an interruption row, with how much of the row it accounts for.
///
/// An interruption row is usually a run of gap records collapsed together, and those records
/// need not share a cause: a disconnect that outlives the watch's buffer produces both a
/// "connection was interrupted" and a "watch buffer filled while disconnected" record. The
/// collapsed row says how long it was; this says what happened, which is the question a person
/// actually has when they see 47 minutes missing.
public struct LossReason: Equatable, Sendable, Identifiable {
    /// Plain-language cause, from `StatusUI.gapDescription` — the one gap vocabulary.
    public var text: String
    /// Interrupted time attributable to this cause, clipped to the segment like the row is.
    public var durationMs: Int64
    /// Separate interruptions with this cause. Twelve two-second dropouts and one long silence
    /// are different problems, and only the count tells them apart.
    public var count: Int
    /// The cause as a stable code (`StatusUI.gapReasonCode`): what the archive sync sends
    /// beside `text`, so the server and assistants read the cause without parsing the words.
    public var code: String

    public var id: String { text }

    /// Genuine loss, as opposed to the watch's power-save pause (`GapClassifier`): the part a
    /// recording's missing total counts.
    public var isLoss: Bool { code != "powerSave" }

    public init(text: String, durationMs: Int64, count: Int = 1, code: String = "unknown") {
        self.text = text
        self.durationMs = durationMs
        self.count = count
        self.code = code
    }
}

/// Merges reason lists (across the gaps of one cluster, or the clusters of one coalesced row),
/// summing per cause and ordering biggest-first with first-seen breaking ties.
func mergedLossReasons(_ lists: [[LossReason]]) -> [LossReason] {
    var order: [String] = []
    var totals: [String: LossReason] = [:]
    for reason in lists.joined() {
        if var existing = totals[reason.text] {
            existing.durationMs += reason.durationMs
            existing.count += reason.count
            totals[reason.text] = existing
        } else {
            order.append(reason.text)
            totals[reason.text] = reason
        }
    }
    var ranked: [(rank: Int, reason: LossReason)] = []
    for (rank, text) in order.enumerated() {
        guard let reason = totals[text] else { continue }
        ranked.append((rank, reason))
    }
    ranked.sort { left, right in
        if left.reason.durationMs != right.reason.durationMs {
            return left.reason.durationMs > right.reason.durationMs
        }
        return left.rank < right.rank
    }
    return ranked.map(\.reason)
}

public enum TranscriptTimelineItem: Equatable, Sendable {
    public struct Speech: Equatable, Sendable {
        public var startMs: Int64
        public var endMs: Int64
        public var text: String
        public var speaker: String?

        public init(startMs: Int64, endMs: Int64, text: String, speaker: String? = nil) {
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
            self.speaker = speaker
        }
    }

    /// A short unlabeled visual break between paragraphs (5–30 s of nothing).
    public struct Break: Equatable, Sendable {
        public var startMs: Int64
        public var durationMs: Int64

        public init(startMs: Int64, durationMs: Int64) {
            self.startMs = startMs
            self.durationMs = durationMs
        }
    }

    /// A labeled pause row: genuine loss (`missing == true`, "audio interrupted…") or calm
    /// known-quiet time (`missing == false`, "quiet for…"). Never conflated.
    public struct Pause: Equatable, Sendable {
        public var startMs: Int64
        public var durationMs: Int64
        public var missing: Bool
        /// What caused this interruption, largest cause first. One entry per distinct plain-
        /// language reason, carrying how much of the row it accounts for and how many separate
        /// interruptions it covers — that breakdown is the whole content of the expanded row.
        public var reasons: [LossReason]
        /// Looped transcriber output that stood in this stretch and is not shown as rows (see
        /// `TranscriptLoopSuppression.swift`). Only ever set on a QUIET row: the audio was
        /// received and it was silent, so this is not loss and must never be labelled as loss.
        /// Zero for every row the caller did not ask to have suppressed.
        public var suppressedRepeats: Int
        /// How far past `startMs` the stretch this row covers reaches. An interruption row is a
        /// run of gap records collapsed together (records within `gapCollapseWindowMs` of each
        /// other), and when the watch drops a fraction of a second every couple of seconds the
        /// run covers many minutes while losing one of them. `durationMs` there is the run's
        /// length, which is what decides whether it earns a transcript row; this is where it
        /// ends, which is what places it. The two only differ once rows with no speech between
        /// them are merged. Equal to `durationMs` for a quiet row.
        public var extentMs: Int64
        /// The audio NOT HEARD inside an interruption row: the union of its records, genuine
        /// loss and the watch's power-save pause alike. This, not the run's length, is what the
        /// row says it was interrupted for. Zero on a quiet row.
        public var interruptedMs: Int64
        /// The part of `interruptedMs` that is genuine loss (`GapClassifier` `.loss`) — the
        /// quantity a recording's missing total counts. The power-save pause is not loss. Zero
        /// on a quiet row.
        public var missingMs: Int64

        public init(
            startMs: Int64, durationMs: Int64, missing: Bool, reasons: [LossReason] = [],
            suppressedRepeats: Int = 0, extentMs: Int64? = nil, interruptedMs: Int64? = nil,
            missingMs: Int64? = nil
        ) {
            self.startMs = startMs
            self.durationMs = durationMs
            self.missing = missing
            self.reasons = reasons
            self.suppressedRepeats = suppressedRepeats
            self.extentMs = max(extentMs ?? durationMs, 0)
            let heard = missing ? max(interruptedMs ?? durationMs, 0) : 0
            self.interruptedMs = heard
            self.missingMs = missing ? min(max(missingMs ?? heard, 0), heard) : 0
        }

        /// Where the stretch this row covers ends, on the caller's clock.
        public var endMs: Int64 { startMs + extentMs }

        /// The interruption is spread thin over its stretch — brief drops scattered through
        /// minutes of audio that was heard — rather than one hole. Saying only "interrupted for
        /// 1 min" there reads as a minute-long hole at this point in the words; saying only the
        /// stretch ("for 14 min") claims thirteen minutes of loss that did not happen. So a
        /// spread row says both.
        public var isSpread: Bool {
            missing && interruptedMs >= 1_000 && extentMs >= interruptedMs * spreadLossFactor
                && Formatting.duration(extentMs) != Formatting.duration(interruptedMs)
        }

        /// What the row says, without its cause: "audio interrupted for 1 min over 14 min",
        /// "quiet for 3 min". `label` is this plus `cause` in parentheses; the archive sync sends
        /// the two apart so the server can set the cause in its own type.
        public var summaryText: String {
            if missing {
                guard interruptedMs >= 1_000 else { return "audio briefly interrupted" }
                let base = "audio interrupted for \(Formatting.duration(interruptedMs))"
                return isSpread ? "\(base) over \(Formatting.duration(extentMs))" : base
            }
            return label
        }

        /// What caused an interruption, as its row names it: the one reason, or "2 reasons"
        /// when the row has a breakdown. Nil on a quiet row and on an interruption nothing
        /// explains.
        public var cause: String? { missing ? reasonSummary : nil }

        public var label: String {
            if missing {
                let base = summaryText
                if let summary = reasonSummary { return "\(base) (\(summary))" }
                return base
            }
            let quiet = "quiet for \(Formatting.duration(durationMs))"
            // Say what was taken out, in the plainest terms available: the model wrote text
            // over a silent room, and the person reading this is owed the fact rather than an
            // unexplained hole where a wall of repeated lines used to be.
            guard suppressedRepeats >= minimumReportedSuppressedLines else { return quiet }
            let hidden =
                suppressedRepeats == 1
                ? "1 repeated line hidden" : "\(suppressedRepeats) repeated lines hidden"
            // A loop can emit a hundred lines in ten seconds. Leading with "quiet for 10 sec"
            // there would bury the thing that actually happened under a duration nobody cares
            // about, so the short ones report only the lines.
            return durationMs < silenceBreakThresholdMs ? hidden : "\(quiet) · \(hidden)"
        }

        /// True when the row has a breakdown worth opening. One reason is already spelled out
        /// in `label`, so only a genuinely mixed interruption expands.
        public var hasReasonBreakdown: Bool { missing && reasons.count > 1 }

        /// A row this short is noise between two halves of one sentence, so the transcript
        /// doesn't give it a line of its own. The loss itself is never dropped: it still marks
        /// the scrubber and still counts in the recording's missing total.
        public var isShownInTranscript: Bool {
            !missing || durationMs >= minimumShownLossMs
        }

        /// Says how many causes there were rather than "several", so the count itself tells you
        /// how much is behind the tap.
        private var reasonSummary: String? {
            switch reasons.count {
            case 0: return nil
            case 1: return reasons[0].text
            default: return "\(reasons.count) reasons"
            }
        }
    }

    case speech(Speech)
    case silenceBreak(Break)
    case pause(Pause)

    public var startMs: Int64 {
        switch self {
        case .speech(let item): return item.startMs
        case .silenceBreak(let item): return item.startMs
        case .pause(let item): return item.startMs
        }
    }

    public var asSpeech: Speech? {
        if case .speech(let item) = self { return item }
        return nil
    }

    public var asBreak: Break? {
        if case .silenceBreak(let item) = self { return item }
        return nil
    }

    public var asPause: Pause? {
        if case .pause(let item) = self { return item }
        return nil
    }
}

/// Interruptions shorter than this get no row in the transcript (see
/// `Pause.isShownInTranscript`). Ten seconds is about where a marker stops explaining a jump in
/// the words and starts interrupting the reading of them.
public let minimumShownLossMs: Int64 = 10_000

/// An interruption row whose stretch is at least this many times the audio it lost reads as
/// spread thin over that stretch (`Pause.isSpread`) and says both numbers. Roger's
/// conversation of 2026-10-20 is the case it was set on: 432 drops of 0.1-1.3 s every ~2 s,
/// 1 min 31 sec lost across a 15-minute recording, which the row used to call "audio
/// interrupted for 14 min".
public let spreadLossFactor: Int64 = 2

/// Hidden looped lines below this many are collapsed without saying so. The line itself is
/// still on screen — suppression never touches a first occurrence — so six echoes of "Yeah."
/// cost the reader nothing, while a row per burst would cost them the transcript. Ten is where
/// the hidden material stops being a stutter and starts being a stretch of the recording:
/// across the measured library it labels the 70 substantial loops and stays quiet for the 221
/// small ones (median 1.6 s long).
public let minimumReportedSuppressedLines = 10

let silenceBreakThresholdMs: Int64 = 5_000
let quietPauseThresholdMs: Int64 = 30_000
let gapCollapseWindowMs: Int64 = 5_000

/// Derives the transcript timeline for one segment: readable speech blocks interleaved with
/// unlabeled breaks, calm quiet rows, and explicit loss rows (loss is never hidden and quiet is
/// never framed as loss).
///
/// **`segments` and `words` must be WALL offsets into the segment** — milliseconds since its
/// first sample, the same clock `meta.gaps` are on. That is not a formality: this function
/// orders the gap records against the speech, and the two producers of transcript timings do
/// not agree on a clock. A durable transcript is timed against STORED audio (the processor
/// decodes the frame log and hands only that to the provider), so its offsets have to come back
/// through `SegmentMediaClock` first; the live preview is already on the wall clock. Feeding
/// media offsets in here does not make the rows wrong one at a time — it puts every quiet and
/// interrupted marker in the wrong PLACE in the list, and computes the pause between two turns
/// as a media-time difference, which is zero across exactly the silence the pause describes.
/// `App/Runtime/TranscriptItems.swift` does the conversion; see its `TranscriptTimebase` note.
///
/// `suppressedLoops` describes stretches the caller has already removed from `segments` with
/// `filteringLoopedArtefacts`; they are folded into the quiet rows so a hidden loop reads as
/// the quiet it actually was, and says how many lines it stands for. Callers that pass nothing
/// get exactly the behavior they had before suppression existed.
///
/// `window` is for a caller rendering a PIECE of the segment — a conversation owns a range of a
/// segment's audio, not always all of it — and is that piece as wall offsets into the segment.
/// The caller has already cut `segments` and `words` to the piece; what it cannot cut is the
/// gap records, which this function reads straight off `meta`. Without the window a piece would
/// open on every quiet and interrupted row of the conversation before it, and close on the
/// next one's. A gap record belongs to the piece its START falls in, so the pieces of a segment
/// show each record exactly once between them. Nil is the whole segment, as it always was.
public func transcriptTimelineItems(
    meta: SegmentMeta,
    segments: [TranscriptSegment],
    words: [TranscriptWord] = [],
    suppressedLoops: [SuppressedLoop] = [],
    window: Range<Int64>? = nil
) -> [TranscriptTimelineItem] {
    let speech = coalescedSpeechBlocks(segments: segments, words: words)
        .flatMap { splitSpeechBlock($0) }
    if speech.isEmpty {
        // A recording whose text was ENTIRELY looped artefact still has a story: it was quiet,
        // and the transcriber filled the silence. Saying nothing here would leave the reader
        // with a blank screen and no idea why.
        return coalesceTimelineQuiet(quietRowsForUncoveredLoops([], suppressedLoops))
    }

    let gaps = collapsedTranscriptGaps(meta, window: window)
    var items: [TranscriptTimelineItem] = []
    var gapIndex = 0
    var previousSpeechEnd: Int64?
    for block in speech {
        // Everything the segment recorded between the previous turn and this one.
        var pending: [TranscriptTimelineItem.Pause] = []
        while gapIndex < gaps.count, gaps[gapIndex].startMs <= block.startMs {
            pending.append(gaps[gapIndex])
            gapIndex += 1
        }
        // A stretch whose only records are SILENCE-SUPPRESSED is quiet the whole way through,
        // and its length is the stretch — not the sum of the records inside it.
        //
        // The watch withholds only the part of a silence its detector is confident about: it
        // arms after 5-20 s of near-continuous quiet (mode-dependent) and resumes on the first
        // frame above the resume threshold, so a room with a fridge, a car outside and a TV two
        // rooms away produces many short records scattered through one long silence rather than
        // one record covering it. Over this library, with suppression synthesised at the
        // firmware's own measured rates (PebbleOS a47acac74: 4.1-13.8% of airtime across 60-200
        // episodes an hour), that is 15-50 records per segment averaging ~2.5 s each. Reporting
        // their sum would have told a reader who watched eight minutes of transcript go by that
        // it had been "quiet for 38 sec".
        //
        // Loss is deliberately NOT treated this way. An interruption row says how much audio is
        // MISSING, which is the sum of the records and nothing else; stretching it over the
        // quiet around it would claim loss that did not happen. So a stretch holding any loss
        // keeps exactly the behaviour it has always had.
        if let previousEnd = previousSpeechEnd, !pending.contains(where: \.missing) {
            let pauseMs = block.startMs - previousEnd
            if pauseMs >= quietPauseThresholdMs {
                items.append(
                    .pause(
                        TranscriptTimelineItem.Pause(
                            startMs: previousEnd, durationMs: pauseMs, missing: false
                        )
                    )
                )
            } else if pauseMs >= silenceBreakThresholdMs {
                items.append(
                    .silenceBreak(
                        TranscriptTimelineItem.Break(startMs: previousEnd, durationMs: pauseMs)
                    )
                )
            }
        }
        items.append(contentsOf: pending.map { .pause($0) })
        items.append(.speech(block))
        previousSpeechEnd = max(previousSpeechEnd ?? block.endMs, block.endMs)
    }
    while gapIndex < gaps.count {
        items.append(.pause(gaps[gapIndex]))
        gapIndex += 1
    }

    var seen = Set<String>()
    let deduped = items.filter { item in
        let key: String
        switch item {
        case .speech(let s): key = "speech:\(s.startMs):\(s.endMs):\(s.text)"
        case .silenceBreak(let b): key = "break:\(b.startMs):\(b.durationMs)"
        case .pause(let p):
            key = "pause:\(p.startMs):\(p.durationMs):\(p.missing):"
                + p.reasons.map(\.text).joined(separator: "|")
        }
        return seen.insert(key).inserted
    }
    return coalesceTimelineQuiet(attributingSuppressedLoops(deduped, suppressedLoops))
}

/// Folds suppressed loops into the rows that already cover their time, and gives a quiet row of
/// its own to any loop nothing covers — a loop at the very start of a recording has no
/// preceding speech to open a pause against, and that is exactly the 99%-artefact case.
private func attributingSuppressedLoops(
    _ items: [TranscriptTimelineItem], _ loops: [SuppressedLoop]
) -> [TranscriptTimelineItem] {
    guard !loops.isEmpty else { return items }
    var out = items
    var uncovered: [SuppressedLoop] = []
    for loop in loops {
        // A quiet row over the same stretch is the right home, so look for one before settling
        // for anything else — the rows are in time order and a merged speech block can spill
        // into the loop's span, so first-overlap-wins would hand the count to the wrong row.
        if let index = out.firstIndex(where: { item in
            guard let pause = item.asPause, !pause.missing else { return false }
            return overlaps(pause.startMs, pause.startMs + pause.durationMs, loop)
        }), var pause = out[index].asPause {
            pause.suppressedRepeats += loop.turnCount
            out[index] = .pause(pause)
            continue
        }
        // A break is the SAME quiet, just short enough that it normally goes unlabelled.
        // Promote it in place rather than inserting a second row: the coalescing pass
        // re-derives the form from the merged duration and count, so a hundred lines emitted in
        // ten seconds still get said out loud, and a handful still do not.
        if let index = out.firstIndex(where: { item in
            guard let gap = item.asBreak else { return false }
            return overlaps(gap.startMs, gap.startMs + gap.durationMs, loop)
        }), let gap = out[index].asBreak {
            out[index] = .pause(
                TranscriptTimelineItem.Pause(
                    startMs: gap.startMs, durationMs: gap.durationMs, missing: false,
                    suppressedRepeats: loop.turnCount))
            continue
        }
        // Surviving speech already accounts for this time: there is no hole to explain, and a
        // quiet row laid over it would invent one.
        let inSpeech = out.contains { item in
            guard let speech = item.asSpeech else { return false }
            return overlaps(speech.startMs, speech.endMs, loop)
        }
        if !inSpeech { uncovered.append(loop) }
    }
    return quietRowsForUncoveredLoops(out, uncovered)
}

private func quietRowsForUncoveredLoops(
    _ items: [TranscriptTimelineItem], _ loops: [SuppressedLoop]
) -> [TranscriptTimelineItem] {
    guard !loops.isEmpty else { return items }
    var out = items
    for loop in loops {
        let row = TranscriptTimelineItem.Pause(
            startMs: loop.startMs,
            durationMs: max(loop.endMs - loop.startMs, 0),
            missing: false,
            suppressedRepeats: loop.turnCount)
        let insertion = out.firstIndex { $0.startMs > loop.startMs } ?? out.count
        out.insert(.pause(row), at: insertion)
    }
    return out
}

private func overlaps(_ startMs: Int64, _ endMs: Int64, _ loop: SuppressedLoop) -> Bool {
    loop.startMs < endMs && startMs <= loop.endMs
}

/// Collapses consecutive non-speech rows of the same kind so the transcript reads cleanly: a
/// run of quiet spans becomes one quiet period, and a run of interruptions becomes one. The
/// merged quiet total is then labelled by length — 30 s+ gets a "quiet for…" label, 5–30 s a
/// bare break, shorter is dropped.
///
/// The two kinds measure differently, and the difference is the product rule rather than an
/// inconsistency:
///
/// - **Quiet** is a STRETCH of the recording, so the merged row spans from the start of the
///   first row to the end of the last. Nothing was said anywhere in between — that is what put
///   these rows next to each other with no speech separating them — so the reader's question is
///   "how long was I looking at nothing", and the answer is the span. Summing the parts instead
///   answered a question nobody asked and, once the watch began withholding scattered seconds
///   of a long silence, answered it with a number an order of magnitude too small.
/// - **Loss** is a QUANTITY of missing audio, so the merged row is the sum. Its reason
///   breakdown adds up to it, and stretching it across the intact audio between two dropouts
///   would claim loss that did not happen.
private func coalesceTimelineQuiet(
    _ items: [TranscriptTimelineItem]
) -> [TranscriptTimelineItem] {
    var out: [TranscriptTimelineItem] = []
    var i = 0
    while i < items.count {
        guard let kind = timelineQuietKind(items[i]) else {
            out.append(items[i])
            i += 1
            continue
        }
        var startMs = items[i].startMs
        var endMs = startMs
        var totalMs: Int64 = 0
        var suppressed = 0
        var interruptedMs: Int64 = 0
        var missingMs: Int64 = 0
        var j = i
        while j < items.count, timelineQuietKind(items[j]) == kind {
            let duration = timelineItemDurationMs(items[j])
            totalMs += duration
            startMs = min(startMs, items[j].startMs)
            if case .pause(let pause) = items[j] {
                suppressed += pause.suppressedRepeats
                // The rows of one run never overlap (each is a collapsed cluster, and clusters
                // are more than the collapse window apart), so their unions simply add.
                interruptedMs += pause.interruptedMs
                missingMs += pause.missingMs
                endMs = max(endMs, pause.endMs)
            } else {
                endMs = max(endMs, items[j].startMs + duration)
            }
            j += 1
        }
        if kind == .quiet { totalMs = max(endMs - startMs, 0) }
        if kind == .loss {
            let reasons = mergedLossReasons(
                items[i..<j].compactMap { item in
                    if case .pause(let pause) = item { return pause.reasons }
                    return nil
                })
            out.append(
                .pause(
                    TranscriptTimelineItem.Pause(
                        startMs: startMs, durationMs: totalMs, missing: true, reasons: reasons,
                        extentMs: max(endMs - startMs, totalMs), interruptedMs: interruptedMs,
                        missingMs: missingMs
                    )
                )
            )
        } else if totalMs >= quietPauseThresholdMs
            || suppressed >= minimumReportedSuppressedLines
        {
            // Normally quiet needs 30 s to earn a labelled row. A stretch that hid a
            // substantial number of lines earns one at any length, because a loop can emit a
            // hundred of them in ten seconds and the reader would otherwise see the transcript
            // skip with nothing said about it.
            out.append(
                .pause(
                    TranscriptTimelineItem.Pause(
                        startMs: startMs, durationMs: totalMs, missing: false,
                        suppressedRepeats: suppressed
                    )
                )
            )
        } else if totalMs >= silenceBreakThresholdMs {
            out.append(
                .silenceBreak(TranscriptTimelineItem.Break(startMs: startMs, durationMs: totalMs))
            )
        }
        // Shorter than a break: nothing to show.
        i = j
    }
    return out
}

private enum TimelineQuietKind {
    case quiet
    case loss
}

/// Quiet (skipped silence / too-quiet pause / break) vs interruption; nil for speech.
private func timelineQuietKind(_ item: TranscriptTimelineItem) -> TimelineQuietKind? {
    switch item {
    case .speech: return nil
    case .silenceBreak: return .quiet
    case .pause(let pause): return pause.missing ? .loss : .quiet
    }
}

private func timelineItemDurationMs(_ item: TranscriptTimelineItem) -> Int64 {
    switch item {
    case .speech: return 0
    case .silenceBreak(let b): return b.durationMs
    case .pause(let p): return p.durationMs
    }
}

private func coalescedSpeechBlocks(
    segments: [TranscriptSegment],
    words: [TranscriptWord]
) -> [TranscriptTimelineItem.Speech] {
    // Prefer word-level timings for the finest timeline, EXCEPT when diarization labeled the
    // segments with speakers (words carry no speaker) — then segment-level keeps the labels.
    let hasSpeakers = segments.contains { !($0.speaker ?? "").isEmptyOrBlank }
    let raw: [TranscriptTimelineItem.Speech]
    if !words.isEmpty && !hasSpeakers {
        raw = words.map {
            TranscriptTimelineItem.Speech(
                startMs: max($0.startMs, 0),
                endMs: max($0.endMs, $0.startMs),
                text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                speaker: nil
            )
        }
    } else {
        raw = segments.map {
            TranscriptTimelineItem.Speech(
                startMs: max($0.startMs, 0),
                endMs: max($0.endMs, $0.startMs),
                text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                speaker: $0.speaker.map(speakerLabel)
            )
        }
    }
    let sorted = raw.filter { !$0.text.isEmptyOrBlank }.sorted { $0.startMs < $1.startMs }

    var blocks: [TranscriptTimelineItem.Speech] = []
    var current: TranscriptTimelineItem.Speech?
    for next in sorted {
        if let existing = current,
            next.startMs - existing.endMs < silenceBreakThresholdMs,
            next.speaker == existing.speaker
        {
            current = TranscriptTimelineItem.Speech(
                startMs: existing.startMs,
                endMs: max(existing.endMs, next.endMs),
                text: joinTranscriptText(existing.text, next.text),
                speaker: existing.speaker
            )
        } else {
            if let existing = current { blocks.append(existing) }
            current = next
        }
    }
    if let existing = current { blocks.append(existing) }
    return blocks
}

private func splitSpeechBlock(
    _ block: TranscriptTimelineItem.Speech,
    maxChars: Int = 260,
    maxWords: Int = 34
) -> [TranscriptTimelineItem.Speech] {
    let chunks = readableChunks(block.text, maxChars: maxChars, maxWords: maxWords)
    if chunks.count <= 1 { return [block] }
    let totalWords = Int64(max(wordCount(block.text), 1))
    let durationMs = max(block.endMs - block.startMs, 0)
    var consumedWords: Int64 = 0
    return chunks.map { chunk in
        let chunkWords = Int64(max(wordCount(chunk), 1))
        let startOffset = durationMs * consumedWords / totalWords
        consumedWords += chunkWords
        let endOffset = durationMs * consumedWords / totalWords
        return TranscriptTimelineItem.Speech(
            startMs: block.startMs + startOffset,
            endMs: max(block.startMs + endOffset, block.startMs + startOffset),
            text: chunk,
            speaker: block.speaker
        )
    }
}

private func collapsedTranscriptGaps(
    _ meta: SegmentMeta, window: Range<Int64>? = nil
) -> [TranscriptTimelineItem.Pause] {
    if meta.gaps.isEmpty { return [] }
    let segmentDuration = max(segmentDurationMs(meta), 0)
    // Built once over ALL of the segment's records (see the note below on the window).
    let classifier = GapClassifier(meta.gaps)

    func rangeOf(_ gap: GapMeta) -> (Int64, Int64) {
        let rawStart = sampleOffsetMs(meta, sampleIndex: gap.firstMissingSampleIndex)
        let start =
            segmentDuration > 0
            ? min(max(rawStart, 0), segmentDuration) : max(rawStart, 0)
        let rawDuration = max(Int64(gap.missingFrameCount) * Int64(meta.frameDurationMs), 0)
        let end = segmentDuration > 0 ? min(start + rawDuration, segmentDuration) : start + rawDuration
        return (start, max(end, start))
    }

    struct GapCluster {
        var startMs: Int64
        var endMs: Int64
        var gaps: [GapMeta]
    }

    func collapse(_ gaps: [GapMeta]) -> [GapCluster] {
        let ranges = gaps.map { gap -> GapCluster in
            let (start, end) = rangeOf(gap)
            return GapCluster(startMs: start, endMs: end, gaps: [gap])
        }.sorted { $0.startMs < $1.startMs }
        var merged: [GapCluster] = []
        for range in ranges {
            if let last = merged.last, range.startMs <= last.endMs + gapCollapseWindowMs {
                merged[merged.count - 1].endMs = max(last.endMs, range.endMs)
                merged[merged.count - 1].gaps.append(contentsOf: range.gaps)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Milliseconds covered by the union of these ranges.
    func unionMs(_ ranges: [(Int64, Int64)]) -> Int64 {
        var total: Int64 = 0
        var cursor = Int64.min
        for (start, end) in ranges.sorted(by: { $0.0 < $1.0 }) where end > start {
            let from = max(start, cursor)
            if end > from { total += end - from }
            cursor = max(cursor, end)
        }
        return total
    }

    func pauses(_ gaps: [GapMeta], missing: Bool) -> [TranscriptTimelineItem.Pause] {
        collapse(gaps).map { cluster in
            // Each gap contributes its own clipped length to its cause, so the expanded row
            // adds up to roughly what the row lost (overlapping records can exceed it — the
            // row's own numbers are the union, which is the honest one).
            let reasons =
                missing
                ? mergedLossReasons(
                    cluster.gaps.map { gap in
                        let (start, end) = rangeOf(gap)
                        return [
                            LossReason(
                                // The DISPLAYED length, not the raw record: a gap clipped to this
                                // segment can run ten hours raw and show as seconds, and the
                                // wording has to match what the person is looking at. Without it
                                // a 10 h 30 m hole read "the phone briefly missed audio".
                                text: gapDescription(gap, displayedDurationMs: max(end - start, 0)),
                                durationMs: max(end - start, 0),
                                code: gapReasonCode(gap))
                        ]
                    })
                : []
            // The cluster's length is the run from its first record to its last, intact audio
            // between them included; what it actually did not hear is the union of the records.
            // On a stretch of brief drops the two differ by an order of magnitude, and only the
            // second may be called an interruption (`Pause.isSpread`).
            let placed = cluster.gaps.map(rangeOf)
            let interrupted = missing ? unionMs(placed) : 0
            let lost =
                missing
                ? unionMs(
                    zip(cluster.gaps, placed).filter { classifier.classify($0.0) == .loss }
                        .map(\.1))
                : 0
            return TranscriptTimelineItem.Pause(
                startMs: cluster.startMs,
                durationMs: max(cluster.endMs - cluster.startMs, 0),
                missing: missing,
                reasons: reasons,
                interruptedMs: interrupted,
                missingMs: lost
            )
        }
    }

    // Silence-suppressed spans are known-quiet audio (missing=false, "quiet"); genuine loss is
    // missing=true ("audio interrupted"). They collapse separately so a quiet stretch never
    // inherits an interruption's framing; length-based labelling happens later in
    // coalesceTimelineQuiet on the combined totals.
    //
    // The watch's power-save pause is not loss (`GapClassifier`), but it is not quiet either:
    // nothing was heard. The transcript has only these two row kinds, so it keeps the
    // interruption row it has always had, which names its cause ("watch was saving power").
    // Filing it under quiet would tell the reader a room was silent that nobody listened to.
    //
    // Each record is classified against ALL of the segment's records (a sequence skip is hidden
    // by the watch record that covers it, wherever a piece happens to be cut); only then are the
    // records outside the window dropped — before collapsing, so a cluster never reaches across
    // the edge of the piece and drags a neighbour's quiet in with it.
    let inWindow = meta.gaps.filter { gap in
        guard let window else { return true }
        return window.contains(rangeOf(gap).0)
    }
    let lost = pauses(inWindow.filter { classifier.classify($0) != .quiet }, missing: true)
    let quiet = pauses(inWindow.filter { classifier.classify($0) == .quiet }, missing: false)
    return (lost + quiet).sorted { $0.startMs < $1.startMs }
}

private func joinTranscriptText(_ a: String, _ b: String) -> String {
    if a.isEmptyOrBlank { return b }
    if b.isEmptyOrBlank { return a }
    if let first = b.first, ".,!?;:".contains(first) { return a + b }
    return "\(a) \(b)"
}

private func sampleOffsetMs(_ meta: SegmentMeta, sampleIndex: UInt64) -> Int64 {
    let base = meta.firstSampleIndex ?? sampleIndex
    let samples = sampleIndex >= base ? sampleIndex - base : 0
    return Int64(samples) * 1_000 / Int64(meta.sampleRateHz)
}

// MARK: - Paragraphs

/// Splits durable transcript text into readable paragraphs: explicit blank lines are kept,
/// sentences pack up to the char/word budgets, and punctuation-free live text splits by words.
public func transcriptParagraphs(
    _ text: String,
    maxChars: Int = 280,
    maxWords: Int = 34
) -> [String] {
    let normalized = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\r", with: "\n")
    if normalized.isEmptyOrBlank { return [] }
    var paragraphs: [String] = []
    var current = ""
    var currentWords = 0
    func flush() {
        if !current.isEmpty {
            paragraphs.append(current)
            current = ""
            currentWords = 0
        }
    }
    // Kotlin `split(Regex("\\n{2,}"))`.
    let blocks = normalized
        .replacingOccurrences(of: "\n{2,}", with: "\u{0}", options: .regularExpression)
        .components(separatedBy: "\u{0}")
    for (blockIndex, block) in blocks.enumerated() {
        if blockIndex > 0 { flush() }
        for sentence in sentencesIn(block)
            .flatMap({ readableChunks($0, maxChars: maxChars, maxWords: maxWords) })
        {
            let words = wordCount(sentence)
            if !current.isEmpty
                && (current.count + 1 + sentence.count > maxChars
                    || currentWords + words > maxWords)
            {
                flush()
            }
            if !current.isEmpty { current.append(" ") }
            current.append(sentence)
            currentWords += words
        }
    }
    flush()
    return paragraphs
}

private func readableChunks(_ text: String, maxChars: Int, maxWords: Int) -> [String] {
    let words = text
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
        .split(separator: " ")
        .map(String.init)
        .filter { !$0.isEmptyOrBlank }
    if words.isEmpty { return [] }
    if text.count <= maxChars && words.count <= maxWords {
        return [text.trimmingCharacters(in: .whitespaces)]
    }
    var chunks: [String] = []
    var current: [String] = []
    var currentChars = 0
    func flush() {
        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
            current = []
            currentChars = 0
        }
    }
    for word in words {
        let nextChars = currentChars + word.count + (current.isEmpty ? 0 : 1)
        if !current.isEmpty && (nextChars > maxChars || current.count >= maxWords) {
            flush()
        }
        current.append(word)
        currentChars += word.count + (current.count == 1 ? 0 : 1)
    }
    flush()
    return chunks
}

private func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).count
}

private func sentencesIn(_ block: String) -> [String] {
    let chars = Array(block)
    var sentences: [String] = []
    var current = ""
    for index in chars.indices {
        let char = chars[index]
        current.append(char == "\n" || char == "\t" ? " " : char)
        let next = index + 1 < chars.count ? chars[index + 1] : nil
        let nextAfterSpace = chars[(index + 1)...].first { !$0.isWhitespace }
        if (char == "." || char == "!" || char == "?"),
            next?.isWhitespace == true,
            nextAfterSpace == nil || nextAfterSpace!.isUppercase || nextAfterSpace!.isNumber
        {
            sentences.append(collapseSpaces(current))
            current = ""
        }
    }
    let tail = collapseSpaces(current)
    if !tail.isEmptyOrBlank { sentences.append(tail) }
    return sentences
}

private func collapseSpaces(_ text: String) -> String {
    text
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

extension String {
    fileprivate var isEmptyOrBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
