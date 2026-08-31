import Foundation
import AppDB

// Citation granularity. A citation used to name a whole member SEGMENT — minutes of audio and
// dozens of turns — so following one highlighted a wall of transcript and played from the top
// of it. What a note actually draws on is a moment: a stretch of speech a few sentences long.
//
// So the prompt is numbered by STRETCH, not by segment. The model cites `[7]`, and `[7]` is a
// known span of wall-clock time inside a known member — which is exactly what the transcript
// needs to mark, and what the player needs to start from.

/// One timed piece of a member's transcript, as the provider returned it.
public struct TranscriptSpan: Equatable, Sendable {
    public let text: String
    /// Offsets INTO the member segment, the way providers report them.
    public let startMs: Int64
    public let endMs: Int64

    public init(text: String, startMs: Int64, endMs: Int64) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// A stretch of transcript before it has been given its `[n]`.
public struct CitableExcerptDraft: Equatable, Sendable {
    public let segmentId: String
    /// Absolute wall-clock bounds (epoch ms), so a citation survives any later change to how
    /// stretches are cut.
    public let startMs: Int64
    public let endMs: Int64
    public let text: String

    public init(segmentId: String, startMs: Int64, endMs: Int64, text: String) {
        self.segmentId = segmentId
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

/// A stretch as the model sees it: `[number]` is what it writes, and what maps back here.
public struct CitableExcerpt: Equatable, Sendable {
    public let number: Int
    public let segmentId: String
    public let startMs: Int64
    public let endMs: Int64
    public let text: String

    public init(number: Int, segmentId: String, startMs: Int64, endMs: Int64, text: String) {
        self.number = number
        self.segmentId = segmentId
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

public enum CitableExcerpts {
    /// Roughly a paragraph of speech. Long enough that the model is not citing single words,
    /// short enough that following the citation lands you on the sentence it means.
    public static let targetMs: Int64 = 40_000
    public static let maxCharacters = 600
    /// Above this, a long conversation would hand the model hundreds of numbers; the stretches
    /// grow instead so the count stays readable (and the chips stay two digits).
    public static let maxPerConversation = 60

    /// Cut one member's transcript into citable stretches on provider boundaries — never
    /// mid-span, so every stretch starts where someone started speaking.
    ///
    /// A transcript with no timings at all (some providers return only flat text) yields one
    /// stretch covering the member: coarse, but honest about what is known.
    public static func split(
        segmentId: String,
        segmentStartMs: Int64,
        segmentEndMs: Int64,
        spans: [TranscriptSpan],
        wholeText: String,
        targetMs: Int64 = targetMs,
        maxCharacters: Int = maxCharacters
    ) -> [CitableExcerptDraft] {
        let usable = spans.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let fallbackText = wholeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !usable.isEmpty else {
            guard !fallbackText.isEmpty else { return [] }
            return [
                CitableExcerptDraft(
                    segmentId: segmentId, startMs: segmentStartMs,
                    endMs: max(segmentEndMs, segmentStartMs), text: fallbackText)
            ]
        }

        var drafts: [CitableExcerptDraft] = []
        var pieces: [TranscriptSpan] = []

        func flush() {
            guard let first = pieces.first, let last = pieces.last else { return }
            let text = pieces.map { $0.text.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else {
                pieces = []
                return
            }
            drafts.append(
                CitableExcerptDraft(
                    segmentId: segmentId,
                    startMs: segmentStartMs + max(first.startMs, 0),
                    endMs: segmentStartMs + max(last.endMs, last.startMs),
                    text: text))
            pieces = []
        }

        for span in usable {
            pieces.append(span)
            let spanMs = (pieces.last?.endMs ?? 0) - (pieces.first?.startMs ?? 0)
            let characters = pieces.reduce(0) { $0 + $1.text.count }
            if spanMs >= targetMs || characters >= maxCharacters { flush() }
        }
        flush()
        return drafts
    }

    /// Number the stretches in the order they were recorded. The numbers are what the model
    /// writes and what the chips carry, so they are assigned once, here.
    public static func numbered(_ drafts: [CitableExcerptDraft]) -> [CitableExcerpt] {
        drafts.enumerated().map { index, draft in
            CitableExcerpt(
                number: index + 1,
                segmentId: draft.segmentId,
                startMs: draft.startMs,
                endMs: draft.endMs,
                text: draft.text)
        }
    }

    /// Merge neighbouring stretches until there are at most `limit` of them. A day-long
    /// conversation would otherwise hand the model hundreds of numbers to choose between.
    public static func coalesced(
        _ drafts: [CitableExcerptDraft], limit: Int = maxPerConversation
    ) -> [CitableExcerptDraft] {
        guard limit > 0, drafts.count > limit else { return drafts }
        let groupSize = Int((Double(drafts.count) / Double(limit)).rounded(.up))
        var merged: [CitableExcerptDraft] = []
        var index = 0
        while index < drafts.count {
            let group = drafts[index..<min(index + groupSize, drafts.count)]
            // Never merge across members: a stretch has to live inside one recording.
            var run: [CitableExcerptDraft] = []
            for draft in group {
                if let first = run.first, first.segmentId != draft.segmentId {
                    merged.append(join(run))
                    run = []
                }
                run.append(draft)
            }
            if !run.isEmpty { merged.append(join(run)) }
            index += groupSize
        }
        return merged
    }

    private static func join(_ run: [CitableExcerptDraft]) -> CitableExcerptDraft {
        guard let first = run.first, let last = run.last else {
            return CitableExcerptDraft(segmentId: "", startMs: 0, endMs: 0, text: "")
        }
        return CitableExcerptDraft(
            segmentId: first.segmentId,
            startMs: first.startMs,
            endMs: last.endMs,
            text: run.map(\.text).joined(separator: " "))
    }
}
