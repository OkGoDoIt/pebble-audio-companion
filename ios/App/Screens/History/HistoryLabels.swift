import AppDB
import Foundation

// What each timeline item says, visibly and to VoiceOver (plan 5.3 "Gap kinds", 5.9). Pure
// builders over the model types, so the rules — which gaps carry a label, when a quiet stretch
// shows its time range, what a card's time line reads — are decided once and tested, and the
// views only draw them.

enum HistoryLabels {

    /// A quiet or undescribed no-conversation gap is labelled only at this length.
    static let quietLabelMinimumMinutes: Double = 30
    /// ...and shows its time range only past this length.
    static let quietRangeMinimumMinutes: Double = 90

    // MARK: Chapter cards

    /// A card's time line, split so the missing part can be drawn in its own colour:
    /// ("9:05 – 10:15 AM · 1 hr 10 min", "4 min missing").
    static func chapterTimeLine(_ block: HistoryChapterBlock, locale: Locale = .current)
        -> (main: String, missing: String?)
    {
        let duration = HistoryFormat.duration(ms: block.endMs - block.startMs)
        // The same on every card, titled or not: the text leads, the time is the quiet line.
        let main = timeRange(block, locale: locale) + " · " + duration
        let missing = block.missingMs > 0
            ? Copy.History.missing(HistoryFormat.duration(ms: block.missingMs)) : nil
        return (main, missing)
    }

    /// A card with no title: a conversation not titled yet, or talk no conversation covers.
    static func isUntitled(_ block: HistoryChapterBlock) -> Bool {
        block.title?.isEmpty ?? true
    }

    /// What stands in a card's title position. Every card leads with text and keeps its time on
    /// the quiet gray line (Roger, 2026-10: "focus on the text, the time in light grey"): the
    /// title; for an untitled card the first words said in it; and with neither, a quiet
    /// placeholder. Never the time.
    enum Heading: Equatable {
        case title(String)
        /// Verbatim first words, drawn quoted.
        case quote(String)
        /// "Not summarised yet".
        case placeholder
    }

    static func heading(_ block: HistoryChapterBlock) -> Heading {
        if let title = block.title, !title.isEmpty { return .title(title) }
        if let snippet = block.snippet?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
            return .quote(snippet)
        }
        return .placeholder
    }

    /// The heading as plain text, where a card is named outside the timeline (topic results,
    /// menus): the title, the quoted first words, or the placeholder.
    static func chapterTitle(_ block: HistoryChapterBlock, locale: Locale = .current) -> String {
        switch heading(block) {
        case .title(let title): return title
        case .quote(let quote): return Copy.History.quote(quote)
        case .placeholder: return Copy.History.notSummarisedYet
        }
    }

    private static func timeRange(_ block: HistoryChapterBlock, locale: Locale) -> String {
        let zone = TimeZone(identifier: block.zoneID) ?? .current
        let range = HistoryFormat.timeRange(block.startMs, block.endMs, zone: zone, locale: locale)
        return block.timesApproximate ? Copy.History.approximately(range) : range
    }

    /// A compact card's trailing meta: its start and length, "9:05 AM · 6 min".
    static func compactTimeLine(_ block: HistoryChapterBlock, locale: Locale = .current)
        -> (main: String, missing: String?)
    {
        let zone = TimeZone(identifier: block.zoneID) ?? .current
        var start = HistoryFormat.time(block.startMs, zone: zone, locale: locale)
        if block.timesApproximate { start = Copy.History.approximately(start) }
        let missing = block.missingMs > 0
            ? Copy.History.missing(HistoryFormat.duration(ms: block.missingMs)) : nil
        return (start + " · " + HistoryFormat.duration(ms: block.endMs - block.startMs), missing)
    }

    /// The live card's time line: "11:20 AM · 21 min so far".
    static func liveTimeLine(_ live: HistoryLiveBlock, locale: Locale = .current) -> String {
        let zone = TimeZone(identifier: live.zoneID) ?? .current
        return Copy.History.liveTime(
            start: HistoryFormat.time(live.startMs, zone: zone, locale: locale),
            soFar: HistoryFormat.duration(ms: live.endMs - live.startMs))
    }

    // MARK: Gaps

    /// The two lines a gap on the axis carries. `title` nil means the gap is drawn bare.
    struct GapText: Equatable {
        var title: String?
        /// The gray second line.
        var detail: String?
        /// Loss carried inside the gap ("under 1 min missing"), drawn after `detail` in amber
        /// exactly as on a card — never folded into the gray line.
        var missing: String?

        /// The second line as plain text, for places that do not colour it.
        var fullDetail: String? {
            let parts = [detail, missing].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// The label of a gap drawn on the axis. `openEnded` is a gap at the end of today that is
    /// still going ("Paused since 2:30 PM").
    static func gapText(_ gap: HistoryGap, openEnded: Bool = false, locale: Locale = .current)
        -> GapText
    {
        let zone = TimeZone(identifier: gap.zoneID) ?? .current
        let minutes = Double(gap.endMs - gap.startMs) / 60_000
        let name = Copy.History.gapName(gap)
        let range = HistoryFormat.timeRange(gap.startMs, gap.endMs, zone: zone, locale: locale)
        let title = openEnded
            ? Copy.History.since(name, time: HistoryFormat.time(gap.startMs, zone: zone, locale: locale))
            : Copy.History.gapLabel(name, duration: HistoryFormat.duration(ms: gap.endMs - gap.startMs))

        // Loss carried inside a gap (`HistoryGap.missingMs`, "· 4 s missing") is said exactly as
        // on a card. It used to be dropped here: 09-24 of the real backup drew a 20-hour "Not
        // transcribed yet" whose 5 minutes of lost audio appeared nowhere.
        let missing = gap.kind != .audioMissing && gap.missingMs > 0
            ? Copy.History.missing(HistoryFormat.duration(ms: gap.missingMs)) : nil

        switch gap.kind {
        case .quiet:
            // A gap carrying loss is always labelled: the loss must be said somewhere.
            guard minutes >= quietLabelMinimumMinutes || missing != nil else { return GapText() }
            return GapText(
                title: title, detail: minutes > quietRangeMinimumMinutes || missing != nil ? range : nil,
                missing: missing)
        case .noConversation where gap.descriptor == nil:
            // Styled exactly like quiet: it says less rather than guess what the sound was.
            guard minutes >= quietLabelMinimumMinutes || missing != nil else { return GapText() }
            return GapText(
                title: title, detail: minutes > quietRangeMinimumMinutes || missing != nil ? range : nil,
                missing: missing)
        case .paused, .audioMissing, .notRecording, .noConversation, .deleted:
            let detail = Copy.History.gapDetail(gap).map { range + " · " + $0 } ?? range
            return GapText(
                title: title, detail: openEnded ? Copy.History.gapDetail(gap) : detail, missing: missing)
        case .notTranscribedYet, .transcriptionFailed:
            // Drawn as a dashed card (`PendingChapterCard`), whose own lines these are.
            let detail = Copy.History.gapDetail(gap).map { range + " · " + $0 }
                ?? range + " · " + HistoryFormat.duration(ms: gap.endMs - gap.startMs)
            return GapText(title: name, detail: detail, missing: missing)
        }
    }

    /// Whether a gap is drawn as a dashed card rather than a label on the axis.
    static func isPendingCard(_ gap: HistoryGap) -> Bool {
        gap.kind == .notTranscribedYet || gap.kind == .transcriptionFailed
    }

    /// Whether the gap is at least the labelled floor (44 pt) tall.
    static func isLabelled(_ gap: HistoryGap) -> Bool {
        gapText(gap).title != nil
    }

    // MARK: Accessibility (5.9)

    /// A chapter as one element: title, time range, duration, missing audio, summary, tags,
    /// people, "2 follow-ups, 1 open".
    static func chapterAccessibilityLabel(_ block: HistoryChapterBlock, locale: Locale = .current)
        -> String
    {
        let zone = TimeZone(identifier: block.zoneID) ?? .current
        var range = HistoryFormat.spokenTimeRange(block.startMs, block.endMs, zone: zone, locale: locale)
        if block.timesApproximate { range = Copy.History.A11y.approximately(range) }
        if isUntitled(block) {
            // "First words: …. 3:20 to 4:05 PM, 45 minutes" — the words lead, as on screen.
            var head = range + ", " + HistoryFormat.spokenDuration(ms: block.endMs - block.startMs)
            if block.missingMs > 0 {
                head += ", " + Copy.History.A11y.missing(HistoryFormat.spokenDuration(ms: block.missingMs))
            }
            var sentences: [String] = []
            if case .quote(let quote) = heading(block) {
                sentences.append(Copy.History.A11y.firstWords(quote))
            } else {
                sentences.append(Copy.History.notSummarisedYet)
            }
            sentences.append(head)
            var rest: [String] = []
            if !block.tags.isEmpty { rest.append(Copy.History.A11y.topics(block.tags)) }
            if !block.people.isEmpty { rest.append(Copy.History.A11y.people(block.people)) }
            let open = block.followUps.filter { !$0.done }.count
            let followUps = Copy.History.A11y.followUps(total: block.followUps.count, open: open)
            if !followUps.isEmpty { rest.append(followUps) }
            if !rest.isEmpty { sentences.append(rest.joined(separator: ", ")) }
            // Verbatim words often end in their own punctuation; do not add a second stop.
            return sentences.dropFirst().reduce(sentences[0]) { text, next in
                let ends = text.last.map { ".?!…".contains($0) } ?? false
                return text + (ends ? " " : ". ") + next
            }
        }
        var parts = [chapterTitle(block), range, HistoryFormat.spokenDuration(ms: block.endMs - block.startMs)]
        if block.missingMs > 0 {
            parts.append(Copy.History.A11y.missing(HistoryFormat.spokenDuration(ms: block.missingMs)))
        }
        if let summary = block.summary, !summary.isEmpty,
            ChapterCardFit.showsSummary(durationMs: block.endMs - block.startMs, hasSummary: true)
        {
            parts.append(summary)
        }
        if !block.tags.isEmpty { parts.append(Copy.History.A11y.topics(block.tags)) }
        if !block.people.isEmpty { parts.append(Copy.History.A11y.people(block.people)) }
        let open = block.followUps.filter { !$0.done }.count
        let followUps = Copy.History.A11y.followUps(total: block.followUps.count, open: open)
        if !followUps.isEmpty { parts.append(followUps) }
        return parts.joined(separator: ", ")
    }

    /// A gap as one element: "Quiet, 1 hour 5 minutes, 10:15 to 11:20 AM", then the recorded
    /// detail when there is one. Every gap is read, labelled on screen or not: the axis is
    /// hidden from VoiceOver, so this is the only place its time is said.
    static func gapAccessibilityLabel(_ gap: HistoryGap, openEnded: Bool = false, locale: Locale = .current)
        -> String
    {
        let zone = TimeZone(identifier: gap.zoneID) ?? .current
        let name = Copy.History.gapName(gap)
        var parts: [String]
        if openEnded {
            parts = [Copy.History.since(name, time: HistoryFormat.time(gap.startMs, zone: zone, locale: locale))]
        } else {
            parts = [
                name, HistoryFormat.spokenDuration(ms: gap.endMs - gap.startMs),
                HistoryFormat.spokenTimeRange(gap.startMs, gap.endMs, zone: zone, locale: locale),
            ]
        }
        if gap.kind != .audioMissing, gap.missingMs > 0 {
            parts.append(Copy.History.A11y.missing(HistoryFormat.spokenDuration(ms: gap.missingMs)))
        }
        if gap.kind == .audioMissing, gap.lossCauses.count > 1 {
            parts.append(gap.lossCauses.map(Copy.History.lossCause).joined(separator: ", "))
        } else if let detail = Copy.History.gapDetail(gap) {
            parts.append(detail)
        }
        return parts.joined(separator: ", ")
    }
}
