import Foundation
import AppDB
import CompanionRuntime
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

/// One word of a turn, tied to where it sits both in the rendered text and on the player's
/// scrubber. This is what lets playback highlight the word being spoken instead of the whole
/// paragraph, and what lets a tap on the paragraph seek to the word under the finger.
///
/// Character offsets are into `TranscriptTurn.text` counted in `Character`s, so they survive
/// the `AttributedString` round-trip the transcript renders through. Media offsets are
/// conversation-wide, like `TranscriptTurn.mediaOffsetMs`.
struct TranscriptWordSpan: Equatable {
    var start: Int
    var end: Int
    var mediaStartMs: Int64
    var mediaEndMs: Int64
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
    /// Where the turn ENDS on the scrubber. Without it a turn is a point rather than a span,
    /// and "which turn is playing right now?" can only be answered by looking at the next
    /// turn's start — which is wrong across a gap, where the next turn begins minutes later.
    var mediaEndMs: Int64?
    /// Per-word timings, when the provider gave any and they could be aligned to this turn's
    /// rendered text. Empty is the honest degraded case (older rows, providers with no word
    /// timings): playback then highlights the whole turn rather than pretending to know more.
    var words: [TranscriptWordSpan] = []
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
    /// The causes behind an "audio interrupted for … (3 reasons)" row, biggest first — what
    /// the row shows when it is tapped open. Empty whenever there is nothing more to say than
    /// `text` already does: quiet rows, and interruptions with a single known cause.
    var reasons: [TranscriptMarkerReason] = []
}

/// One line of an opened interruption row: what happened, and how much of the gap it was.
struct TranscriptMarkerReason: Equatable, Identifiable {
    /// Plain-language cause, e.g. "watch buffer filled while disconnected".
    var text: String
    /// e.g. "45 min" — or "45 min · 3 times" when the cause struck more than once.
    var detail: String

    var id: String { text }
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
    /// Where the audio behind `player` is. `.onPhone` plays at once; the other two put the
    /// cold-audio card where the player would be — the audio is real and recorded, it just has
    /// to be fetched (or cannot be, right now), and the card says which.
    var audioAvailability: AudioAvailability = .onPhone
    var transcript: [TranscriptItem]
    /// "Transcribed with Soniox · yesterday 9:54 PM"
    var provenance: String?
    var followUps: [FollowUp]
    /// Q16: transcript stamps read in the zone the audio was RECORDED in, so a conversation
    /// keeps the times it actually happened at after you fly home.
    var timeZone: TimeZone = .current
    /// Wall-clock extent of the recording. The player labels its scrubber with these rather than
    /// with 0:00 and a duration: a recording is a thing that happened at a time of day, and the
    /// transcript beside it is already stamped in clock time.
    var startedAt: Date?
    var endedAt: Date?

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
        // First because it is the one that needs no explaining: the plain long account of what
        // happened, for when the header's two sentences are not enough. Everything below it
        // reshapes the recording into something (notes, a list, an email); this one does not.
        NoteTemplate(id: "extended-summary", title: Copy.Notes.templateExtendedSummary),
        NoteTemplate(id: "meeting-notes", title: Copy.Notes.templateMeetingNotes),
        NoteTemplate(id: "decisions", title: Copy.Notes.templateDecisions),
        NoteTemplate(id: "follow-up-email", title: Copy.Notes.templateFollowUpEmail),
        NoteTemplate(id: "study-notes", title: Copy.Notes.templateStudyNotes),
        NoteTemplate(id: "interview-highlights", title: Copy.Notes.templateInterviewHighlights),
    ]
}

extension AskCitation {
    /// Identifies the MOMENT a citation points at — its segment and where in it — for anything
    /// cached per citation. The segment id alone is not enough: a segment is shared between
    /// conversations, and what a citation is called depends on which one its moment is in.
    var momentKey: String { "\(segmentId)@\(startMs.map(String.init) ?? "start")" }
}

/// Where a citation points. Citations name SEGMENTS, screens navigate by CONVERSATION, and the
/// player counts MEDIA time — resolving one citation is the hop between all three. Without it a
/// chip navigated to `conversation/<segmentId>`, which is not a conversation id, so every tap
/// landed on "Conversation not found".
struct CitationTarget: Equatable {
    var conversationId: String
    var conversationTitle: String
    /// The cited member, and — for citations written against numbered stretches — the
    /// wall-clock bounds of the stretch inside it. The transcript marks exactly those lines;
    /// with no bounds (older citations, imports) it can only mark the whole member.
    var focus: TranscriptFocus
    /// Where the cited stretch starts on the conversation's scrubber. Nil when the member has
    /// no stored audio, which is also when there is nothing to play.
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
    /// Brings audio that is in iCloud back to the phone so `playback` can read it. Returns when
    /// it is readable; throws with a reason the screen can show.
    func fetchAudio(id: String) async throws
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

    /// Everything the "Split or join" sheet draws itself from. Grouping is automatic and
    /// derived, so this is the one place a person can overrule it — which is the answer to
    /// "a Stop is a strong signal but not an absolute one": rather than a heuristic guessing
    /// whether someone ended a meeting or just blanked out a moment, the split is predictable
    /// and putting it back is one tap.
    func boundaries(id: String) async throws -> ConversationBoundariesDisplay
    /// Start a new conversation at `cut`. Keyed by the position alone — a recording and an
    /// offset into it are the only things stable across a regroup, and the conversation this
    /// is being done FROM is about to stop existing in its current shape anyway. Taken back by
    /// joining the conversation it creates to the one before it.
    func split(at cut: ConversationCut) async throws
    /// Join this conversation onto the one before it, or clear that decision.
    func setJoinWithPrevious(conversationId: String, on: Bool) async throws
    /// "Separate them again": take back the person's join at a place INSIDE a conversation
    /// (`ConversationBoundariesDisplay.joins`), handing that place back to the automatic rules.
    func separate(at cut: ConversationCut) async throws

    /// The conversation a wall-clock moment falls in, and where on its scrubber (History plan
    /// 7.9): `focus` is a `.moment` at exactly `atWallMs`, so the transcript lands on the row
    /// being said then and marks nothing. A moment between recordings opens the nearest one
    /// (see `MomentResolver.segment`). Nil only when nothing was recorded near the time.
    ///
    /// `conversationId` pins the answer to that conversation: a History card knows which
    /// conversation it is, and its start can sit a few seconds inside the one before it (the
    /// day's tidying folds quiet into the card). The moment is then placed on the pinned
    /// conversation's pieces, clamped to the nearest of them.
    func momentTarget(atWallMs wallMs: Int64, inConversation conversationId: String?) async
        -> CitationTarget?
}

extension ConversationDataSource {
    /// A moment in whichever conversation owns it.
    func momentTarget(atWallMs wallMs: Int64) async -> CitationTarget? {
        await momentTarget(atWallMs: wallMs, inConversation: nil)
    }
}

/// The state of one conversation's boundaries: why it starts where it does, whether it can be
/// joined backwards, the places inside it where a new one could start, and the places where
/// the person joined two.
struct ConversationBoundariesDisplay: Equatable {
    var startReason: ConversationStartReason?
    /// False for the oldest conversation there is — nothing to join to.
    var canJoinWithPrevious: Bool
    var isJoinedWithPrevious: Bool
    /// Where talk resumed after a pause, in the order it happened.
    var points: [ConversationBoundaryPoint]
    /// The person's joins inside this conversation, each of which can be taken back.
    var joins: [ConversationBoundaryPoint] = []

    static let none = ConversationBoundariesDisplay(
        startReason: nil, canJoinWithPrevious: false, isJoinedWithPrevious: false, points: [])
}

@MainActor
protocol AskDataSource: AnyObject {
    /// False until the first recording exists ("Nothing to ask about yet…"). Async so the live
    /// implementation can look at the spool off the main thread; callers cache the answer —
    /// this must never be read per render.
    func hasContent() async -> Bool
    /// Recent Ask conversations, newest first, each with all of its turns.
    func recentThreads() async throws -> [AskThread]
    /// Answers `question` as the next turn of `thread` (nil starts a new conversation): the
    /// earlier turns go to the model as context and the answer joins the same thread.
    func ask(question: String, thread: AskThread?, scope: AskScope) async throws -> AskEntry
    /// The same question answered from conversation titles, summaries and tags and the day
    /// recaps only — never a transcript. Siri's Ask under "Siri & Spotlight can see: Titles and
    /// summaries"; the Ask screen itself always uses `ask`.
    func askFromSummaries(question: String, scope: AskScope) async throws -> AskEntry
    func clearHistory() async throws
    /// Conversation title for a citation's source id (footer + tap-through).
    func conversationTitle(citedId: String) -> String?
    /// Titles for many citations at once, keyed by `AskCitation.momentKey` and resolved off
    /// the main thread. The thread screen caches the result — the sync variant decodes a
    /// transcript per call, which must never happen per render.
    ///
    /// Per citation, not per cited segment: one recording usually holds the end of one
    /// conversation and the start of the next, so two citations into the same segment can
    /// belong to two conversations with two titles.
    func citationTitles(for citations: [AskCitation]) async -> [String: String]
    /// The conversation, moment and scrubber position a citation names. Nil once the cited
    /// segment is gone (retention), which is when a chip must not navigate at all.
    func citationTarget(for citation: AskCitation) async -> CitationTarget?
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

// MARK: - Follow-ups

/// Which slice of the list a screen is asking for. The names are the ones on screen: what is
/// still open, what has been ticked off, and what the app filed away because nobody touched it.
enum FollowUpListScope: String, CaseIterable, Equatable, Identifiable {
    case open
    case completed
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return Copy.FollowUps.scopeOpen
        case .completed: return Copy.FollowUps.scopeCompleted
        case .archived: return Copy.FollowUps.scopeArchived
        }
    }
}

/// One follow-up as the screens render it.
///
/// Everything here beyond `text` and `done` exists because the previous model had neither: a
/// row was an id, a string and a flag, so nothing on screen could say where an item came from,
/// when it mattered, or why it had been suggested at all — and the only honest answer to "what
/// is this?" was to go and read the transcript yourself.
struct FollowUpItem: Equatable, Identifiable {
    let id: String
    var text: String
    var done: Bool
    var dueAtMs: Int64?
    var priority: FollowUpPriority
    /// The words in the recording that created it. Nil for one the person wrote themselves.
    var quote: String?
    /// What goes wrong if it never happens, from the pass that proposed it.
    var why: String?
    var origin: FollowUpOrigin
    var createdAtMs: Int64
    var completedAtMs: Int64?
    var archivedAtMs: Int64?
    var snoozedUntilMs: Int64?
    var sourceConversationId: String?
    /// The conversation's own title, so a row can say where it came from without a second load.
    var sourceConversationTitle: String?
    /// The member recording the quote was spoken in, and where inside it. Carried on the
    /// display model so an undone delete can put the row back exactly as it was, provenance
    /// and all — re-adding it as a new hand-written item would quietly lose the recording it
    /// came from.
    var sourceSegmentId: String?
    var sourceStartMs: Int64?
    var sourceEndMs: Int64?
    /// The model that found it, as recorded (`FollowUp.model`) — carried so an undone delete
    /// puts it back — and its display name for the provenance card. Nil for an item a person
    /// wrote and for rows from before it was recorded.
    var model: String? = nil
    var modelName: String? = nil

    var isArchived: Bool { archivedAtMs != nil }

    func isSnoozed(at now: Date) -> Bool {
        guard let snoozedUntilMs else { return false }
        return Double(snoozedUntilMs) / 1000 > now.timeIntervalSince1970
    }

    var dueDate: Date? {
        dueAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    var snoozedUntil: Date? {
        snoozedUntilMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    var created: Date { Date(timeIntervalSince1970: Double(createdAtMs) / 1000) }
}

@MainActor
protocol FollowUpsDataSource: AnyObject {
    func items(scope: FollowUpListScope) async throws -> [FollowUpItem]
    func item(id: String) async throws -> FollowUpItem?
    /// Emits after any change to the table, so every screen showing follow-ups reloads.
    /// Named apart from `LibraryDataSource.updates()` because one type answers both, and the
    /// two watch different things: that one tracks conversations, this one the follow-up rows.
    func followUpUpdates() -> AsyncStream<Void>

    /// A follow-up the person typed. Returns its id so the caller can open it.
    @discardableResult
    func add(text: String, dueAtMs: Int64?) async throws -> String
    func setDone(id: String, done: Bool) async throws
    func setText(id: String, text: String) async throws
    func setDue(id: String, dueAtMs: Int64?) async throws
    func setPriority(id: String, priority: FollowUpPriority) async throws
    func snooze(id: String, untilMs: Int64?) async throws
    func setArchived(id: String, archived: Bool) async throws
    func delete(id: String) async throws
    /// Puts a deleted item back exactly as it was — same id, same quote, same recording. What
    /// the undo snackbar calls.
    func restore(_ item: FollowUpItem) async throws

    /// Where "play the moment this came from" goes: the conversation, cued to the words.
    func source(of id: String) async -> CitationTarget?

    /// True when the app is set up to propose follow-ups at all. The empty state says which
    /// kind of empty it is looking at rather than implying nothing was worth remembering.
    var automaticProposalsEnabled: Bool { get }

    /// True when those proposals come from the on-device reader rather than the cloud one.
    /// The on-device path finds about half as much and is right about roughly three quarters
    /// of what it shows, so the screen has to say so — see `Copy.LocalFollowUps`.
    var proposalsAreOnDevice: Bool { get }
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
    var followUps: any FollowUpsDataSource

    /// Defaults to the mock world; the runtime swaps DB-backed sources in at launch.
    static var current: AskLibraryDataSources = .mocks()
}

// MARK: - Undo center (the app's one snackbar: delete w/ 5 s undo, and short notices)

/// Hosted once, by `RootView`, over whichever tab is showing. A conversation deleted from a
/// screen that is being popped has nowhere else to put its Undo — it used to be hosted by the
/// Library alone, so a delete made from Today offered no Undo at all.
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

    /// A format style (a `Sendable` value), not a `RelativeDateTimeFormatter` held in a static.
    /// `.numeric` is what the formatter's default `dateTimeStyle` produced: "2 hr. ago".
    private static let relativeStyle = Date.RelativeFormatStyle(
        presentation: .numeric, unitsStyle: .abbreviated)

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
        relativeStyle.format(date)
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
        var meta =
            "\(time(start)) · "
            + ConversationDuration.label(durationMs: row.durationMs, isLive: row.isLive)
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
        return "\(dayLabel(for: start)) · \(timeRange(start, end)) · "
            + ConversationDuration.label(durationMs: durationMs)
    }
}
