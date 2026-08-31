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
        assignments: [SpeakerAssignment]
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
                            startedAt: wallDate(speech.startMs)
                        )))
            case .silenceBreak:
                break  // an unlabeled visual break; the card's row spacing carries it
            case .pause(let pause):
                let marker = TranscriptMarker(
                    id: itemId, text: pause.label, startedAt: wallDate(pause.startMs))
                if pause.missing {
                    result.items.append(.missing(marker))
                    // Where the gap falls on the SCRUBBER: the member's media time scaled by
                    // how far into its wall span the gap happened.
                    let intoMember = min(max(pause.startMs, 0), wallSpanMs)
                    result.missingMediaOffsets.append(result.mediaMs * intoMember / wallSpanMs)
                } else {
                    result.items.append(.quiet(marker))
                }
            }
        }
        return result
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
                    role: .unresolved, text: trimmed, isInProgress: true))
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
