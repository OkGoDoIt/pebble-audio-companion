import AppDB
import Foundation
import SearchKit
import SegmentStore
import StatusUI

// One builder for the transcript both detail screens render.
//
// The Conversation screen and the Live screen used to derive their rows separately — the
// finished one from durable transcripts, the live one from the open segment's rolling preview
// — which is how the Live screen ended up showing ONLY the open segment: a conversation that
// spanned a reconnect lost everything before it, on a screen the user was watching at the
// time. They share this now, so a live conversation is the same conversation, still growing.

/// What one member segment contributes to a conversation's transcript.
struct MemberTranscript {
    var items: [TranscriptItem] = []
    /// Id of the last speech row, so a still-open member can mark it as the growing tail.
    var lastTurnId: String?
    /// Stored audio in the member (the player's clock), gaps excluded.
    var mediaMs: Int64 = 0
    /// Media offsets, within this member, of each gap — for the scrubber's amber ticks.
    var missingMediaOffsets: [Int64] = []
}

@MainActor
enum TranscriptItems {
    /// Builds the rows for one member segment from whatever text exists for it — the durable
    /// transcript when it has landed, the live preview while it hasn't.
    static func member(
        segmentId: String,
        meta: SegmentMeta,
        segments: [SearchKit.TranscriptSegment],
        words: [SearchKit.TranscriptWord] = [],
        assignments: [SpeakerAssignment],
        /// Media time consumed by the members already walked, so each turn can carry its
        /// position on the CONVERSATION's scrubber rather than one local to this segment.
        mediaBeforeMemberMs: Int64 = 0
    ) -> MemberTranscript {
        var result = MemberTranscript()
        // Two clocks: wall time (the stamps beside each speaker) and media time (what the
        // scrubber counts — stored audio only, gaps excluded).
        let wallStartMs = Int64(meta.startTimeMs)
        let wallSpanMs = max(segmentDurationMs(meta), 1)
        result.mediaMs = mediaDurationMs(meta)
        func wallDate(_ offsetMs: Int64) -> Date {
            Date(timeIntervalSince1970: Double(wallStartMs + offsetMs) / 1000)
        }
        /// Where a wall offset into this member lands on the scrubber. The same proportional
        /// mapping the missing ticks use: media time is the wall span minus its gaps, so a
        /// point that is 40% through the member is 40% through its stored audio.
        func mediaOffset(_ wallOffsetMs: Int64) -> Int64? {
            guard result.mediaMs > 0 else { return nil }
            let into = min(max(wallOffsetMs, 0), wallSpanMs)
            return mediaBeforeMemberMs + result.mediaMs * into / wallSpanMs
        }

        let timeline = transcriptTimelineItems(meta: meta, segments: segments, words: words)
        for (offset, item) in timeline.enumerated() {
            let itemId = "\(segmentId)-\(offset)"
            switch item {
            case .speech(let speech):
                result.lastTurnId = itemId
                result.items.append(
                    .turn(
                        TranscriptTurn(
                            id: itemId,
                            speakerLabel: speech.speaker ?? "",
                            name: speakerName(speech.speaker, assignments: assignments),
                            role: speakerRole(speech.speaker, assignments: assignments),
                            text: speech.text,
                            startedAt: wallDate(speech.startMs),
                            segmentId: segmentId,
                            mediaOffsetMs: mediaOffset(speech.startMs)
                        )))
            case .silenceBreak:
                break  // an unlabeled visual break; the card's row spacing carries it
            case .pause(let pause):
                let marker = TranscriptMarker(
                    id: itemId, text: pause.label, startedAt: wallDate(pause.startMs),
                    segmentId: segmentId,
                    reasons: pause.hasReasonBreakdown ? markerReasons(pause.reasons) : [])
                if pause.missing {
                    // Where the gap falls on the SCRUBBER: the member's media time scaled by
                    // how far into its wall span the gap happened. Recorded even for the brief
                    // interruptions that earn no transcript row below — the tick and the
                    // recording's missing total are how those stay visible.
                    let intoMember = min(max(pause.startMs, 0), wallSpanMs)
                    result.missingMediaOffsets.append(result.mediaMs * intoMember / wallSpanMs)
                    if pause.isShownInTranscript { result.items.append(.missing(marker)) }
                } else {
                    result.items.append(.quiet(marker))
                }
            }
        }
        return result
    }

    /// The opened form of a mixed interruption: each cause with the time it accounts for, and
    /// how many separate interruptions it covers when that is more than one — twelve brief
    /// dropouts and one long outage are different problems.
    private static func markerReasons(_ reasons: [LossReason]) -> [TranscriptMarkerReason] {
        reasons.map { reason in
            let duration = Formatting.duration(reason.durationMs)
            return TranscriptMarkerReason(
                text: reason.text,
                detail: reason.count > 1 ? "\(duration) · \(reason.count) times" : duration)
        }
    }

    /// A transcript with no timings at all: the live preview before the provider has returned
    /// segment boundaries. One unstamped, still-growing row rather than nothing on screen.
    static func untimedTail(segmentId: String, text: String) -> [TranscriptItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [
            .turn(
                TranscriptTurn(
                    id: "\(segmentId)-tail", speakerLabel: "", name: "Speaker",
                    role: .unresolved, text: trimmed, isInProgress: true,
                    segmentId: segmentId))
        ]
    }

    static func speakerName(_ speaker: String?, assignments: [SpeakerAssignment]) -> String {
        guard let speaker else { return "Speaker" }
        if let match = assignments.first(where: { $0.label == speaker }) {
            return match.personName
        }
        return speakerLabel(speaker)
    }

    static func speakerRole(_ speaker: String?, assignments: [SpeakerAssignment]) -> SpeakerRole {
        guard let speaker else { return .unresolved }
        guard let match = assignments.first(where: { $0.label == speaker }) else {
            return .unresolved
        }
        // The wearer is whoever the user named "You"; everyone else is a counterpart.
        return match.personName.caseInsensitiveCompare("You") == .orderedSame ? .you : .other
    }

    /// The recording's own zone (Q16), so stamps keep the times things happened at.
    static func timeZone(_ meta: SegmentMeta?) -> TimeZone? {
        meta?.recordedTimeZone.flatMap { TimeZone(identifier: $0) }
    }
}

/// Stored audio in a segment, in milliseconds — frames on disk, not the wall span the segment
/// covers. `segmentDurationMs` is the latter, and the two differ by exactly the audio lost.
func mediaDurationMs(_ meta: SegmentMeta) -> Int64 {
    let frames = meta.frameCount * Int64(meta.frameDurationMs)
    return frames > 0 ? frames : segmentDurationMs(meta)
}
