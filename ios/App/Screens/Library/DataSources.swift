import Foundation
import AppDB
import StatusUI

// The dependency seams for the Library / Search / Conversation / Notes / Tags / Ask screens.
// View models talk ONLY to these protocols; `AskLibraryDataSources.current` defaults to the
// mock world (exact artboard sample data) and is swapped for the DB/runtime-backed
// implementations when the pipeline wiring lands.

// MARK: - Ask scope (plan 6.6 — always visible, anti-B5)

enum AskScope: Equatable {
    case today
    case yesterday
    case last7Days
    case everything
    /// The artboard default pill ("Last 2 days").
    case lastDays(Int)
    case dateRange(start: Date, end: Date)
    /// Conversation-scoped entry point (Conversation bottom bar).
    case conversation(id: String, title: String)

    var label: String {
        switch self {
        case .today: return Copy.Ask.scopeToday
        case .yesterday: return Copy.Ask.scopeYesterday
        case .last7Days: return Copy.Ask.scopeLast7Days
        case .everything: return Copy.Ask.scopeEverything
        case .lastDays(let days): return Copy.Ask.scopeLastDays(days)
        case .dateRange(let start, let end):
            return TimeFmt.shortDateRange(start, end)
        case .conversation: return "This conversation"
        }
    }

    /// Deep-link key for `Route.ask(scope:query:)`.
    var routeKey: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .last7Days: return "last7"
        case .everything: return "everything"
        case .lastDays(let days): return "last\(days)days"
        case .dateRange: return "everything"
        case .conversation(let id, _): return "conversation:\(id)"
        }
    }

    static func parse(_ key: String?, conversationTitle: (String) -> String?) -> AskScope {
        guard let key else { return .lastDays(2) }
        switch key {
        case "today": return .today
        case "yesterday": return .yesterday
        case "last7": return .last7Days
        case "everything": return .everything
        default:
            if key.hasPrefix("conversation:") {
                let id = String(key.dropFirst("conversation:".count))
                return .conversation(id: id, title: conversationTitle(id) ?? "")
            }
            if key.hasPrefix("last"), key.hasSuffix("days"),
               let days = Int(key.dropFirst(4).dropLast(4)) {
                return .lastDays(days)
            }
            return .lastDays(2)
        }
    }
}

// MARK: - Library display models
// App-layer mirrors of AppDB's ConversationListRow/LibraryDaySection (whose initializers
// are internal to the Kit); the runtime adapter maps between them.

struct LibraryRow: Equatable, Identifiable {
    var id: String
    var title: String?
    var summary: String?
    var startMs: Int64
    var endMs: Int64
    var isLive = false
    var tags: [String] = []
    var lifecycle: ConversationLifecycle = .complete
    var mostlyQuiet = false
    var hasMissingAudio = false
    var followUpCount = 0
    var dateKey: String
    /// Transcribed, but AI has not written a title/summary yet. The row says so instead of
    /// rendering as a bare "Conversation" that reads like something failed.
    var awaitingAnnotation = false

    var durationMs: Int64 { max(0, endMs - startMs) }
}

struct LibraryDayGroup: Equatable {
    var dateKey: String
    var rows: [LibraryRow]
}

// MARK: - Conversation display models

enum SpeakerRole: Equatable {
    case you        // tint
    case other      // teal
    case unresolved // captured marker + dimmed text
}

struct TranscriptTurn: Equatable, Identifiable {
    var id: String
    /// Diarization label within the conversation (stable across renames).
    var speakerLabel: String
    var name: String
    var role: SpeakerRole
    var text: String
    /// Wall-clock start of the turn, shown beside the speaker name. Formatted in the
    /// conversation's recorded zone (Q16), never here. Nil when the timing is unknown.
    var startedAt: Date?
    /// The tail still being transcribed on a live conversation: dimmed text and deliberately
    /// no clock stamp — its words are still being revised, so a final-looking time would be
    /// a lie.
    var isInProgress: Bool = false
    /// The member segment this turn came from. AI citations name segments, so this is what
    /// marks the cited run of the transcript.
    var segmentId: String = ""
    /// Where this turn sits on the player's scrubber: MEDIA time across the whole
    /// conversation (stored audio only, gaps excluded), not wall time. Nil when the segment
    /// has no stored audio to play.
    var mediaOffsetMs: Int64?
}

/// A non-speech row: calm known-quiet, or genuine loss. Never conflated.
struct TranscriptMarker: Equatable, Identifiable {
    var id: String
    /// e.g. "quiet for 40 sec" / "audio interrupted for 12 sec (…)".
    var text: String
    var startedAt: Date?
    /// The member segment the break happened in, so a marker inside a cited stretch stays
    /// inside its highlight instead of cutting the band in two.
    var segmentId: String = ""
}

enum TranscriptItem: Equatable, Identifiable {
    case turn(TranscriptTurn)
    case quiet(TranscriptMarker)
    case missing(TranscriptMarker)

    var id: String {
        switch self {
        case .turn(let turn): return turn.id
        case .quiet(let marker): return marker.id
        case .missing(let marker): return marker.id
        }
    }

    var startedAt: Date? {
        switch self {
        case .turn(let turn): return turn.startedAt
        case .quiet(let marker), .missing(let marker): return marker.startedAt
        }
    }
}

enum LifecycleDisplay: Equatable {
    case complete
    /// "Captured · waiting to transcribe" + queue line + [Transcribe Now].
    case capturedWaiting(queueLine: String)
    /// Progress + "Soniox · about a minute left".
    case transcribing(progress: Double, line: String)
    /// "Transcription didn’t finish" + [Retry Now]. `reason` is the classified failure from the
    /// queue (`TranscriptionFailureKind`), never the stored `lastError` string — nil when the
    /// task recorded nothing, in which case the card keeps its generic reassurance.
    case failed(reason: String?)
    /// Transcribed; AI title/summary/tags are still being generated in the background.
    /// No action and no progress bar — this is not something the user is waiting on.
    case summaryComing
    /// Transcribed; AI is off, or it tried and stopped. Says which, and offers nothing.
    case noSummary(gaveUp: Bool)
}

struct PlayerDisplay: Equatable {
    /// MEDIA duration — the audio actually stored, gaps excluded. Never the wall-clock span
    /// of the conversation: a 1 hr 4 min conversation holding 33 min of audio has a 33 min
    /// scrubber, and the gaps are the amber ticks on it.
    var durationMs: Int64
    var initialPositionMs: Int64 = 0
    /// Amber missing-tick positions (0…1) — one per gap, at its position in MEDIA time.
    var missingTickFractions: [Double] = []
}

/// One update from a conversation's playback engine.
struct PlaybackProgress: Equatable, Sendable {
    var playing: Bool
    var positionMs: Int64
    var durationMs: Int64
}

/// Playback of a conversation's stored audio, spanning its member segments as one stream.
/// `MockWorld` has no audio and returns none, which is what puts the player card into its
/// simulated demo mode.
@MainActor
protocol ConversationPlayback: AnyObject {
    /// Media duration of everything stored for the conversation.
    var durationMs: Int64 { get }
    func progress() -> AsyncStream<PlaybackProgress>
    func play(fromMs: Int64)
    func pause()
    func seek(toMs: Int64)
    func setSpeed(_ speed: Double)
    func stop()
}

struct ConversationDisplay: Equatable {
    var id: String
    var title: String
    /// "Yesterday · 9:35 – 9:53 PM · 18 min"
    var metaLine: String
    var summary: String?
    var tags: [ConversationTag]
    var lifecycle: LifecycleDisplay
    var player: PlayerDisplay?
    var transcript: [TranscriptItem]
    /// "Transcribed with Soniox · yesterday 9:54 PM"
    var provenance: String?
    var followUps: [FollowUp]
    /// Q16: transcript stamps read in the zone the audio was RECORDED in, so a conversation
    /// keeps the times it actually happened at after you fly home.
    var timeZone: TimeZone = .current

    var shareText: String {
        var lines = [title, metaLine]
        if let summary { lines.append(summary) }
        for item in transcript {
            if case .turn(let turn) = item { lines.append("\(turn.name): \(turn.text)") }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Search display models

struct SearchConversationHit: Equatable, Identifiable {
    var id: String
    var title: String
    /// "Today · 9:12 AM"
    var whenLabel: String
    /// Quoted snippet containing the match, e.g. "“…before any long travel we…”".
    var snippet: String
}

struct SearchResults: Equatable {
    var tags: [TagWithCount] = []
    var conversations: [SearchConversationHit] = []
    var followUps: [FollowUp] = []

    var isEmpty: Bool { tags.isEmpty && conversations.isEmpty && followUps.isEmpty }
}

// MARK: - Notes display models

struct NoteDisplay: Equatable, Identifiable {
    var id: String
    var conversationId: String
    var conversationTitle: String
    var title: String
    /// "Generated 9:54 PM · GPT-5.6 Luna · from this conversation"
    var provenance: String
    /// One bullet per line; inline "[n]" markers render as citation chips.
    var body: String
    /// "2 moments · 9:36 PM, 9:51 PM"
    var momentsLabel: String
    var citations: [AskCitation]

    var shareText: String { "\(title)\n\(body.replacingOccurrences(of: " [", with: " ["))" }
}

struct NoteTemplate: Equatable, Identifiable {
    var id: String
    var title: String
    var isCustom: Bool = false
    var prompt: String? = nil

    static let builtIns: [NoteTemplate] = [
        NoteTemplate(id: "meeting-notes", title: Copy.Notes.templateMeetingNotes),
        NoteTemplate(id: "decisions", title: Copy.Notes.templateDecisions),
        NoteTemplate(id: "follow-up-email", title: Copy.Notes.templateFollowUpEmail),
        NoteTemplate(id: "study-notes", title: Copy.Notes.templateStudyNotes),
        NoteTemplate(id: "interview-highlights", title: Copy.Notes.templateInterviewHighlights),
    ]
}

/// Where a citation points. Citations name SEGMENTS, screens navigate by CONVERSATION, and the
/// player counts MEDIA time — resolving one citation is the hop between all three. Without it a
/// chip navigated to `conversation/<segmentId>`, which is not a conversation id, so every tap
/// landed on "Conversation not found".
struct CitationTarget: Equatable {
    var conversationId: String
    var conversationTitle: String
    /// The cited member: the transcript marks its turns and scrolls to the first of them.
    var segmentId: String
    /// Where that member starts on the conversation's scrubber. Nil when it has no stored
    /// audio, which is also when there is nothing to play.
    var mediaOffsetMs: Int64?
    /// Wall-clock start of the cited moment ("9:36 PM").
    var startedAt: Date?
}

// MARK: - Data-source protocols

@MainActor
protocol LibraryDataSource: AnyObject {
    func library(filter: LibraryFilter, tag: String?) async throws -> [LibraryDayGroup]
    func tags() async throws -> [TagWithCount]
    /// Emits after any mutation so list screens can reload (DB impl: ValueObservation).
    func updates() -> AsyncStream<Void>
}

@MainActor
protocol SearchDataSource: AnyObject {
    func search(query: String, scope: AskScope) async throws -> SearchResults
}

@MainActor
protocol ConversationDataSource: AnyObject {
    func display(id: String) async throws -> ConversationDisplay?
    /// One tick per database write that changes THIS conversation. The screen used to load once
    /// and reload only after the user's own actions, so a conversation opened while it was
    /// still being transcribed never updated in place: the transcript, the AI title and summary
    /// and the follow-ups all landed invisibly, and you had to leave and come back to see them.
    func updates(conversationId: String) -> AsyncStream<Void>
    /// The playback engine for this conversation's stored audio; nil when there is none.
    func playback(id: String) async throws -> (any ConversationPlayback)?
    func rename(id: String, to title: String) async throws
    func retranscribe(id: String) async throws
    func transcribeNow(id: String) async throws
    func retryNow(id: String) async throws
    /// Writes WAV copies of the conversation's audio. Returns how many files were written — a
    /// conversation that survived reconnects is several segments, so it is several files, and
    /// the screen has to say the real number or the user goes to Files looking for one.
    func exportAudio(id: String) async throws -> Int
    func delete(id: String) async throws
    func undoDelete(id: String) async throws
    func toggleFollowUp(id: String) async throws
}

@MainActor
protocol AskDataSource: AnyObject {
    /// False until the first recording exists ("Nothing to ask about yet…").
    var hasContent: Bool { get }
    /// Recent Ask conversations, newest first, each with all of its turns.
    func recentThreads() async throws -> [AskThread]
    /// Answers `question` as the next turn of `thread` (nil starts a new conversation): the
    /// earlier turns go to the model as context and the answer joins the same thread.
    func ask(question: String, thread: AskThread?, scope: AskScope) async throws -> AskEntry
    func clearHistory() async throws
    /// Conversation title for a citation's source id (footer + tap-through).
    func conversationTitle(citedId: String) -> String?
    /// The conversation, moment and scrubber position a citation names. Nil once the cited
    /// segment is gone (retention), which is when a chip must not navigate at all.
    func citationTarget(citedId: String) async -> CitationTarget?
}

@MainActor
protocol NotesDataSource: AnyObject {
    func notes(conversationId: String) async throws -> [NoteDisplay]
    func note(id: String) async throws -> NoteDisplay?
    func templates() async throws -> [NoteTemplate]
    func generate(
        conversationId: String, template: NoteTemplate, customPrompt: String?
    ) async throws -> NoteDisplay
    func regenerate(noteId: String) async throws -> NoteDisplay
    func saveEdit(noteId: String, title: String, body: String) async throws
    func saveTemplate(title: String, prompt: String) async throws
    func deleteTemplate(id: String) async throws
    func deleteNote(id: String) async throws
}

@MainActor
protocol TagEditorDataSource: AnyObject {
    func tags(forConversation id: String) async throws -> [ConversationTag]
    func suggestions(forConversation id: String) async throws -> [String]
    func addTag(conversationId: String, name: String) async throws
    func removeTag(conversationId: String, tagId: String) async throws
    /// Global rename (Q10) — applies everywhere.
    func renameTag(tagId: String, to newName: String) async throws
}

@MainActor
protocol PeopleDataSource: AnyObject {
    func people() async throws -> [Person]
    /// Assign a diarization label to a person by name (find-or-create), per plan 6.3.
    func assign(conversationId: String, label: String, personName: String) async throws
    /// Who this label is currently assigned to in this conversation, if anyone. Distinguishes
    /// "named" from "the diarizer's own Speaker 2", which the displayed name cannot.
    func assignedPerson(conversationId: String, label: String) async throws -> Person?
    /// Global rename (Q17) — every conversation assigned to this person follows, and renaming
    /// onto an existing name merges the two, so a typo can be corrected rather than duplicated.
    func renamePerson(id: String, to newName: String) async throws
    /// Clears this label's assignment. The person stays in the registry; the turns go back to
    /// the unresolved "Speaker N" they came from.
    func unassign(conversationId: String, label: String) async throws
    /// Removes the person everywhere, along with every speaker assignment that named them.
    func deletePerson(id: String) async throws
}

// MARK: - The holder

@MainActor
struct AskLibraryDataSources {
    var library: any LibraryDataSource
    var search: any SearchDataSource
    var conversations: any ConversationDataSource
    var ask: any AskDataSource
    var notes: any NotesDataSource
    var tagEditor: any TagEditorDataSource
    var people: any PeopleDataSource

    /// Defaults to the mock world; the runtime swaps DB-backed sources in at launch.
    static var current: AskLibraryDataSources = .mocks()
}

// MARK: - Undo center (delete w/ 5 s undo snackbar, shown on Library)

@MainActor
@Observable
final class UndoCenter {
    static let shared = UndoCenter()
    var snackbar: SnackbarItem?
}

// MARK: - Time formatting (display-layer; Q16 zones handled by the data layer)

enum TimeFmt {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let intervalFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        return formatter
    }()

    private static let shortMonthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// "9:12 AM"
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// "9:35 – 9:53 PM"
    static func timeRange(_ start: Date, _ end: Date) -> String {
        intervalFormatter.string(from: start, to: end)
    }

    /// "Aug 25 – Aug 28"
    static func shortDateRange(_ start: Date, _ end: Date) -> String {
        "\(shortMonthDayFormatter.string(from: start)) – \(shortMonthDayFormatter.string(from: end))"
    }

    /// "2h ago"
    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// "4:01" / "18:12" / "1:03:09" — player timecodes.
    static func timecode(_ ms: Int64) -> String {
        let totalSeconds = max(ms, 0) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Logical-day label for a section key: "Today" / "Yesterday" / "August 27".
    static func dayLabel(dateKey: String) -> String {
        let zone = TimeZone.current.identifier
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if dateKey == LogicalDay.dateKey(forMs: nowMs, timeZoneID: zone) { return "Today" }
        if dateKey == LogicalDay.dateKey(forMs: nowMs - 86_400_000, timeZoneID: zone) {
            return "Yesterday"
        }
        guard let bounds = LogicalDay.bounds(ofDateKey: dateKey, timeZoneID: zone) else {
            return dateKey
        }
        return monthDayFormatter.string(
            from: Date(timeIntervalSince1970: Double(bounds.startMs) / 1000))
    }

    static func dayLabel(for date: Date) -> String {
        let zone = TimeZone.current.identifier
        let key = LogicalDay.dateKey(
            forMs: Int64(date.timeIntervalSince1970 * 1000), timeZoneID: zone)
        return dayLabel(dateKey: key)
    }

    /// Library row meta: "7:02 PM · 1 hr 40 min · mostly quiet" / "12:04 PM · 48 min so far".
    static func rowMeta(_ row: LibraryRow) -> String {
        let start = Date(timeIntervalSince1970: Double(row.startMs) / 1000)
        var meta = "\(time(start)) · \(Formatting.duration(row.durationMs))"
        if row.isLive { meta += " so far" }
        if row.mostlyQuiet { meta += " · \(Copy.Library.mostlyQuiet)" }
        // An untitled row is either still being written or genuinely bare; say which.
        if !row.isLive, row.title == nil, row.awaitingAnnotation {
            meta += " · \(Copy.Conversation.rowSummaryComing)"
        }
        return meta
    }

    /// Conversation header meta: "Yesterday · 9:35 – 9:53 PM · 18 min".
    static func conversationMeta(start: Date, end: Date) -> String {
        let durationMs = Int64(end.timeIntervalSince(start) * 1000)
        return "\(dayLabel(for: start)) · \(timeRange(start, end)) · \(Formatting.duration(durationMs))"
    }
}
