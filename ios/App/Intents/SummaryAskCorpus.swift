import AppDB
import Foundation
import Intelligence

// What Siri's Ask may read when "Siri & Spotlight can see" is set to Titles and summaries
// (Roger, 2026-10-21): each conversation's title, summary and tags, and the day recaps — never
// a transcript. The in-app Ask screen is not affected; it always reads everything, because its
// answers never leave the app.
//
// The guarantee is structural: this file is handed the conversation list and the recap store,
// and nothing that can read a transcript. One numbered stretch per conversation goes to the
// same planner Ask uses (`AskCorpusPlanner`), so the budget, the sweep and the coverage are
// Ask's own; the recaps go in as context, uncited, because a recap is not a place a citation
// can open.

struct SummaryAskCorpus: Equatable, Sendable {
    /// One conversation, as far as this corpus is allowed to know it.
    struct Conversation: Equatable, Sendable {
        var id: String
        /// Where a citation of it opens: its first piece.
        var firstSegmentId: String
        var title: String?
        var summary: String?
        var tags: [String]
        var startMs: Int64
        var endMs: Int64
        var timeZoneID: String
    }

    struct Recap: Equatable, Sendable {
        var dateKey: String
        var text: String
    }

    /// One per conversation that has a title or a summary, oldest first. A stretch's
    /// `segmentId` is a key into `sources` (two conversations can start in one recording, and
    /// the planner counts conversations by that id), never a recording id.
    var stretches: [CitableExcerpt]
    /// Stretch key → the conversation and where its citation opens.
    var sources: [String: Conversation]
    var recaps: [Recap]
    /// Stretch key → "Tuesday, 20 October 2026, 4:12 PM – 4:30 PM (yesterday)".
    var whenLabels: [String: String]

    var isEmpty: Bool { stretches.isEmpty && recaps.isEmpty }

    static func key(_ conversationId: String) -> String { "summary:\(conversationId)" }

    static func build(conversations: [Conversation], recaps: [Recap], nowMs: Int64)
        -> SummaryAskCorpus
    {
        var drafts: [CitableExcerptDraft] = []
        var sources: [String: Conversation] = [:]
        var whenLabels: [String: String] = [:]
        for conversation in conversations.sorted(by: { $0.startMs < $1.startMs }) {
            guard let text = Self.text(of: conversation) else { continue }
            let key = Self.key(conversation.id)
            drafts.append(
                CitableExcerptDraft(
                    segmentId: key, startMs: conversation.startMs, endMs: conversation.endMs,
                    text: text))
            sources[key] = conversation
            whenLabels[key] = askWhenLabel(
                startMs: conversation.startMs, endMs: conversation.endMs,
                timeZoneID: conversation.timeZoneID, nowMs: nowMs)
        }
        let days = recaps.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return SummaryAskCorpus(
            stretches: CitableExcerpts.numbered(drafts),
            sources: sources,
            recaps: days.sorted { $0.dateKey < $1.dateKey },
            whenLabels: whenLabels)
    }

    /// Title, summary and tags, the three things this setting lets out. Nil when there is
    /// neither a title nor a summary: an unnamed, unsummarised conversation says nothing here.
    static func text(of conversation: Conversation) -> String? {
        let title = conversation.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = conversation.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty || !summary.isEmpty else { return nil }
        var lines: [String] = []
        if !title.isEmpty { lines.append("Title: \(title)") }
        if !summary.isEmpty { lines.append("Summary: \(summary)") }
        if !conversation.tags.isEmpty {
            lines.append("Tags: \(conversation.tags.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Which conversation a stretch is — what coverage is counted in.
    func conversationOf(_ key: String) -> String? { sources[key]?.id }

    /// A citation the model wrote against a stretch, pointed back at the conversation itself:
    /// its first recording, at its start, which is what `citationTarget` resolves.
    func realCitation(_ citation: AskCitation) -> AskCitation {
        guard let source = sources[citation.segmentId] else { return citation }
        return AskCitation(
            segmentId: source.firstSegmentId, number: citation.number,
            startMs: source.startMs, endMs: source.endMs)
    }

    /// What the model is told about its sources, under the time header. It is not reading what
    /// anyone said, and it has to say so when the question needs the words themselves.
    static let sourcesNote =
        "SOURCES: these are not transcripts. Each numbered item is the title, summary and tags "
        + "the app wrote for one conversation; the day recaps are the app's own summaries of "
        + "each day. Nobody's exact words are included. If the question needs what was said "
        + "word for word, say that only summaries were available to answer from."

    /// The prompt header: the time context, the sources note, and the day recaps.
    func header(nowMs: Int64, scopeDescription: String) -> String {
        var header = askNowContext(nowMs: nowMs, scopeDescription: scopeDescription)
        header += "\n" + Self.sourcesNote
        if !recaps.isEmpty {
            header += "\n\nDAY RECAPS (not numbered; do not cite them):\n"
                + recaps.map { "\($0.dateKey): \($0.text)" }.joined(separator: "\n\n")
        }
        return header
    }

    /// The whole input of a single-pass answer.
    static func content(
        header: String, coverageLine: String, question: String, rendered: String
    ) -> String {
        header + "\n" + coverageLine + "\n\nQUESTION: \(question)\n\nSUMMARIES:\n" + rendered
    }
}

extension SummaryAskCorpus {
    /// Reads the corpus for a scope from the conversation list and the recap store — the only
    /// two things it is given.
    static func load(
        queries: ConversationQueries, recaps: DailyRecapStore, scope: Intelligence.AskScope,
        nowMs: Int64, timeZoneID: String = TimeZone.current.identifier
    ) async -> SummaryAskCorpus {
        let range = askScopeDateKeyRange(scope, nowMs: nowMs, timeZoneID: timeZoneID)
        let rows = ((try? await queries.library()) ?? [])
            .filter { range?.contains($0.dateKey) ?? true }
            .flatMap(\.rows)
            .filter { !$0.isLive }
        var conversations: [Conversation] = []
        for row in rows {
            guard let first = try? await queries.detail(id: row.id)?.pieces.first else {
                continue
            }
            conversations.append(
                Conversation(
                    id: row.id, firstSegmentId: first.segmentId, title: row.title,
                    summary: row.summary, tags: row.tags, startMs: row.startMs, endMs: row.endMs,
                    timeZoneID: row.timeZoneID))
        }
        let days = ((try? await recaps.list()) ?? [])
            .filter { range?.contains($0.dateKey) ?? true }
            .map { Recap(dateKey: $0.dateKey, text: $0.text) }
        return build(conversations: conversations, recaps: days, nowMs: nowMs)
    }
}
