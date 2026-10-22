import Foundation
import Transcription

// The person asked, out loud, for something to be remembered.
//
// The extraction prompt is built to distrust: it rejects instructions given to an assistant and
// dictation nobody answered, because those once filled the list with product feedback said to
// a coding agent. A run of "please help me remember to follow up on this … create a follow-up"
// with nobody answering is shaped exactly like that, and on 2026-10-22 three such requests in
// one conversation were all rejected. But it is the opposite case: the person is asking this
// recording to hold the thing for them, and nothing else will. A missed ordinary follow-up
// costs little, since Ask can still find it; a missed request breaks the one promise the
// person relied on.
//
// So these sentences are found here, by their words, and the model is told where they are
// rather than left to notice them; and a candidate drawn from beside one is marked, so curation
// cannot drop it as vague or as someone else's job.

/// A sentence in which the person asks for something to be remembered or followed up.
public struct FollowUpRequest: Equatable, Sendable {
    public let segmentId: String
    /// The sentence, as transcribed.
    public let sentence: String
    /// The turn it is in, on the segment's media clock.
    public let startMs: Int64
    public let endMs: Int64
}

public enum FollowUpRequestDetector {
    /// How far from a request a candidate's quote may sit and still be what was asked for: the
    /// thing is usually described in the sentences just before or after the request, inside a
    /// minute or so of it.
    public static let nearbyMs: Int64 = 90_000
    /// Most request sentences listed for the model per piece.
    static let maxLines = 8

    /// Asking for a reminder or a follow-up. Deliberately narrow: each phrase is a request to
    /// remember, not a request for information ("remind me what her name was") or a likeness
    /// ("you remind me of").
    private static let cue = try! NSRegularExpression(
        pattern: [
            #"\bremind\s+me\b(?!\s+(?:of|what|who|whom|whose|how|where|when|why|which)\b)"#,
            // With an article, so talk about the feature ("create follow-ups from calls") is
            // not a request.
            #"\b(?:create|make|add|write\s+down|log|save|set)\s+(?:a|an|another)\s+"#
                + #"(?:follow[\s-]?up|reminder)\b"#,
            #"\bfollow[\s-]?up\s+reminders?\b"#,
            #"\bhelp\s+me\s+remember\b"#,
            #"\b(?:need|have|want)\s+to\s+remember\s+(?:to|this|that)\b"#,
            #"\bdon'?t\s+let\s+me\s+forget\b"#,
            #"\bnote\s+to\s+self\b"#,
            #"\badd\s+(?:this|that|it)\s+to\s+(?:my\s+)?"#
                + #"(?:follow[\s-]?ups|reminders|to[\s-]?do(?:\s+list)?)\b"#,
        ].joined(separator: "|"),
        options: [.caseInsensitive])

    /// Whether `text` holds a request anywhere.
    public static func mentionsRequest(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return cue.firstMatch(in: text, range: range) != nil
    }

    /// Every request sentence in the conversation, in order.
    public static func requests(in parts: [FollowUpSourcePart]) -> [FollowUpRequest] {
        var found: [FollowUpRequest] = []
        for part in parts {
            guard mentionsRequest(part.text) else { continue }
            if part.turns.isEmpty {
                for sentence in sentences(part.text) where mentionsRequest(sentence) {
                    found.append(
                        FollowUpRequest(
                            segmentId: part.segmentId, sentence: sentence, startMs: 0, endMs: 0))
                }
                continue
            }
            for turn in part.turns where mentionsRequest(turn.text) {
                for sentence in sentences(turn.text) where mentionsRequest(sentence) {
                    found.append(
                        FollowUpRequest(
                            segmentId: part.segmentId, sentence: sentence,
                            startMs: turn.startMs, endMs: turn.endMs))
                }
            }
        }
        return found
    }

    /// Whether a quote found at `location` is what one of `requests` asked for: in the same
    /// recording, within `nearbyMs` of the request's turn.
    public static func isAskedFor(_ location: QuoteLocation, requests: [FollowUpRequest]) -> Bool {
        requests.contains { request in
            guard request.segmentId == location.segmentId else { return false }
            guard let start = location.startMs else { return true }
            let end = location.endMs ?? start
            return start <= request.endMs + nearbyMs && end >= request.startMs - nearbyMs
        }
    }

    /// The lines that tell the model where the requests are, or nil when there are none in
    /// `body` (one piece of a long conversation holds only its own).
    static func promptBlock(_ requests: [FollowUpRequest], in body: String) -> String? {
        let flat = FollowUpQuoteLocator.normalize(body)
        var seen = Set<String>()
        let lines = requests.compactMap { request -> String? in
            let normalized = FollowUpQuoteLocator.normalize(request.sentence)
            guard flat.contains(normalized), seen.insert(normalized).inserted else { return nil }
            return "- \"\(request.sentence)\""
        }
        guard !lines.isEmpty else { return nil }
        // A recording that says "remind me" every minute is dictation, not a dozen requests;
        // the block stays small whatever the transcript does.
        let shown = lines.prefix(maxLines)
        return "Asked out loud to be remembered. The person said these, asking for a reminder "
            + "or a follow-up:\n" + shown.joined(separator: "\n")
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, _ in
            let sentence = (sub ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { out.append(sentence) }
        }
        return out.isEmpty ? [text] : out
    }
}
