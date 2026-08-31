import Foundation
import SegmentStore

// Port of the pure Today-timeline derivations from `app/.../ui/TodayScreen.kt` (the Compose UI
// around them is NOT ported — SwiftUI rebuilds those screens from the mockups).
//
// Structural adjustments vs KMP (mirrored in StatusUITests):
// - Transcripts arrive as plain text (`transcriptText: String?`) instead of the
//   `SegmentTranscript` type: that type belongs to the Transcription module, which StatusUI
//   deliberately does not depend on. Only `.text` was ever read here.
// - `SegmentAnnotation` / `ActionItem` / `DailyDigest` / `AiOutput` are lightweight local
//   value types carrying exactly the fields this layer reads; the Intelligence module owns
//   the full store-backed models (module namespacing keeps both importable side by side).
// - KMP's one-case `sealed interface TimelineItem` is the flat `TimelineSegmentItem` struct.

/// AI-produced title/summary/tags for one segment (display slice).
public struct SegmentAnnotation: Equatable, Sendable {
    public let segmentId: String
    public var title: String?
    public var summary: String?
    public var tags: [String]
    public var createdAtMs: Int64

    public init(
        segmentId: String,
        title: String? = nil,
        summary: String? = nil,
        tags: [String] = [],
        createdAtMs: Int64
    ) {
        self.segmentId = segmentId
        self.title = title
        self.summary = summary
        self.tags = tags
        self.createdAtMs = createdAtMs
    }
}

/// One follow-up item extracted from a conversation (display slice).
public struct ActionItem: Equatable, Sendable {
    public let id: String
    public var text: String
    public var done: Bool
    public var sourceSegmentId: String
    public var createdAtMs: Int64

    public init(
        id: String,
        text: String,
        done: Bool = false,
        sourceSegmentId: String,
        createdAtMs: Int64
    ) {
        self.id = id
        self.text = text
        self.done = done
        self.sourceSegmentId = sourceSegmentId
        self.createdAtMs = createdAtMs
    }
}

/// One stored AI answer/notes output (display slice).
public struct AiOutput: Equatable, Sendable {
    public let outputId: String
    public var promptTitle: String
    public var segmentIds: [String]
    public var text: String
    public var createdAtMs: Int64

    public init(
        outputId: String,
        promptTitle: String,
        segmentIds: [String],
        text: String,
        createdAtMs: Int64
    ) {
        self.outputId = outputId
        self.promptTitle = promptTitle
        self.segmentIds = segmentIds
        self.text = text
        self.createdAtMs = createdAtMs
    }
}

/// One day's AI recap (display slice).
public struct DailyDigest: Equatable, Sendable {
    public let dateKey: String
    public var text: String
    public var createdAtMs: Int64

    public init(dateKey: String, text: String, createdAtMs: Int64) {
        self.dateKey = dateKey
        self.text = text
        self.createdAtMs = createdAtMs
    }
}

/// One row in the Today timeline: a captured segment (gaps render inside the row, quietly).
public struct TimelineSegmentItem: Equatable, Sendable {
    public let meta: SegmentMeta
    public let title: String
    public let summary: String?
    public let stateLabel: String
    /// Calm one-line summary of missing audio, or nil.
    public let gapSummary: String?

    public var key: String { "seg-\(meta.segmentId)" }
}

/// Rolling Today window.
public let todayTimelineWindowMs: Int64 = 24 * 60 * 60 * 1000
private let todayMajorGapMinMs: Int64 = 30_000
private let todayMajorGapRatioFloorMs: Int64 = 5_000
private let todayMajorGapRatioDenominator: Int64 = 5

/// Derives the Today timeline: rolling 24-hour segments newest-first, plus any open segment.
public func buildTimeline(
    segments: [SegmentMeta],
    transcriptOf: (String) -> String?,
    nowMs: Int64,
    windowMs: Int64 = todayTimelineWindowMs,
    annotationOf: (String) -> SegmentAnnotation? = { _ in nil },
    /// Rolling live transcript of a still-recording segment (preview, not durable).
    liveTextOf: (String) -> String? = { _ in nil }
) -> [TimelineSegmentItem] {
    let oldestVisibleMs = nowMs - windowMs
    let relevant = segments
        .filter { $0.isOpen || $0.receivedAtMs >= oldestVisibleMs }
        .sorted { $0.receivedAtMs > $1.receivedAtMs }
    return relevant.map { meta in
        let transcriptText = transcriptOf(meta.segmentId)
        let liveText = liveTextOf(meta.segmentId)
        let annotation = annotationOf(meta.segmentId)
        return TimelineSegmentItem(
            meta: meta,
            title: segmentTitle(
                meta,
                transcriptText: transcriptText,
                annotation: annotation,
                liveText: liveText
            ),
            summary: nil,
            stateLabel: meta.isOpen ? "Recording" : transcriptionStateLabel(meta.transcriptionState),
            gapSummary: todayGapSummary(meta, transcriptText: transcriptText, liveText: liveText)
        )
    }
}

/// Today is the at-a-glance surface: small recoverable interruptions should not crowd out
/// useful transcript snippets. Keep the full gap details in Library/detail, but show Today
/// attention copy when the segment has no transcript text or the missing audio is likely
/// consequential (Q9-adjacent thresholds: >= 30 s absolute, or >= 5 s and >= 1/5 of the
/// segment).
public func todayGapSummary(
    _ meta: SegmentMeta,
    transcriptText: String?,
    liveText: String? = nil
) -> String? {
    guard let summary = gapSummary(meta) else { return nil }
    let hasTranscriptText = !(transcriptText ?? "").isBlank || !(liveText ?? "").isBlank
    if !hasTranscriptText { return summary }

    let gapMs = displayGapMs(meta)
    let durationMs = segmentDurationMs(meta)
    let isMajorByRatio = durationMs > 0
        && gapMs >= todayMajorGapRatioFloorMs
        && gapMs * todayMajorGapRatioDenominator >= durationMs
    return (gapMs >= todayMajorGapMinMs || isMajorByRatio) ? summary : nil
}

/// Title preference (ux plan Sections 8/9): AI-generated title, else transcript snippet (the
/// live preview while still recording), else a neutral label. Never raw file names/ids.
public func segmentTitle(
    _ meta: SegmentMeta,
    transcriptText: String?,
    annotation: SegmentAnnotation? = nil,
    liveText: String? = nil
) -> String {
    if let cleaned = AiPlainText.clean(annotation?.title) { return cleaned }
    if let snippet = transcriptSnippet(transcriptText) { return snippet }
    // While recording, the freshest words are the interesting ones: show the tail.
    if let snippet = transcriptSnippet(liveText, tail: meta.isOpen) { return snippet }
    return meta.isOpen ? "Recording now" : "Conversation"
}

/// A ~64-char single-line transcript snippet (head or tail), or nil when blank.
public func transcriptSnippet(_ text: String?, tail: Bool = false) -> String? {
    guard let text else { return nil }
    let snippet = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
    if snippet.isBlank { return nil }
    if snippet.count <= 64 { return snippet }
    if tail {
        let tailText = String(snippet.suffix(64))
        return "…" + tailText.drop(while: { $0.isWhitespace })
    }
    let head = String(snippet.prefix(64))
    return head.trimmedTrailingWhitespace + "…"
}

/// Compact recap text for the Today feed. Full digest text lives in the AI/Library surfaces.
public func dailyDigestPreviewText(_ digest: DailyDigest) -> String? {
    let lines = digest.text
        .components(separatedBy: .newlines)
        .compactMap { AiPlainText.cleanLine($0) }
        .filter { line in
            !(line.caseInsensitiveCompare("Daily recap") == .orderedSame
                || line.lowercased().hasPrefix("here's a chronological summary")
                || line.lowercased().hasPrefix("here is a chronological summary"))
        }
    return AiPlainText.clean(lines.joined(separator: " "), maxChars: 220)
}

/// The open (undone) follow-ups belonging to segments visible on Today, newest first.
public func todayOpenActionItems(
    _ actionItems: [ActionItem],
    timeline: [TimelineSegmentItem]
) -> [ActionItem] {
    let visibleSegmentIds = Set(timeline.map { $0.meta.segmentId })
    return actionItems
        .filter { !$0.done && visibleSegmentIds.contains($0.sourceSegmentId) }
        .sorted { $0.createdAtMs > $1.createdAtMs }
}

// MARK: - AiPlainText (port of core/ai/.../AiPlainText.kt)

/// Utilities for displaying model output in compact app surfaces.
public enum AiPlainText {
    public static func clean(_ text: String?, maxChars: Int? = nil) -> String? {
        guard let text else { return nil }
        let cleaned = text
            .components(separatedBy: .newlines)
            .compactMap { cleanLine($0) }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return nil }
        guard let maxChars else { return cleaned }
        return String(cleaned.prefix(maxChars)).trimmedTrailingWhitespace
    }

    public static func cleanLine(_ line: String) -> String? {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return nil }
        value = value
            .replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^[-*•]\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
            .replacingOccurrences(
                of: "(^|\\s)[*_]([^*_]+)[*_](\\s|$)", with: "$1$2$3", options: .regularExpression
            )
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(
                of: "^(?i:TITLE|SUMMARY|TAGS)\\s*:\\s*", with: "", options: .regularExpression
            )
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var trimmedTrailingWhitespace: String {
        var value = self
        while let last = value.last, last.isWhitespace { value.removeLast() }
        return value
    }
}
