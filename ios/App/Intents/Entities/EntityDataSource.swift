import AppDB
import CompanionRuntime
import Foundation
import Intelligence
import SearchKit
import Transcription

// The data seam under the App Intents entity model (iOS 27) and the Get* intents.
//
// Everything Siri, Spotlight and Shortcuts can see of the library passes through one protocol
// so it can be faked in `AppTests` (which compiles the App sources without a running app —
// `AppComposition.shared` is nil there) and so there is exactly one place that reads the
// visibility setting before a transcript is handed out. The snapshots are plain values with no
// App Intents types in them: they compile and test on iOS 26, where the entities that consume
// them do not exist.

/// One conversation as the entity layer sees it. `transcript` is nil unless the visibility
/// setting is `.full` — the data source applies that rule, not the caller.
struct ConversationEntitySnapshot: Equatable, Sendable {
    var id: String
    var title: String?
    var summary: String?
    var startMs: Int64
    var endMs: Int64
    var timeZoneID: String
    var dateKey: String
    var tags: [String]
    var isLive: Bool
    var transcript: String?
    /// The names given to its speakers. Not gated: a name is what the person typed to label a
    /// voice, the same tier as a tag.
    var people: [String] = []
}

/// A saved note, body included only when the setting allows text out.
struct NoteEntitySnapshot: Equatable, Sendable {
    var id: String
    var conversationId: String
    var title: String
    var body: String?
    var createdAtMs: Int64
    var editedAtMs: Int64?
}

/// A day recap. `text` is nil under `.off`. It survives `.summaries` because a recap IS a
/// summary — of the day, the way a conversation's AI summary is of the conversation — and
/// that setting promises titles and summaries.
struct RecapEntitySnapshot: Equatable, Sendable {
    var dateKey: String
    var text: String?
    /// The condensed form the Today card shows for a long digest, when one exists.
    var shortText: String?
    var updatedAtMs: Int64
}

/// What the pipeline still has to do, for the "Catch up now" answer.
struct PipelineBacklog: Equatable, Sendable {
    /// Recordings waiting to be transcribed.
    var queued: Int
    /// Conversations transcribed but not yet titled and summarised.
    var awaitingEnrichment: Int

    var isEmpty: Bool { queued == 0 && awaitingEnrichment == 0 }
}

/// A follow-up, in the shape `FollowUp` already has minus the columns Siri has no use for.
struct FollowUpEntitySnapshot: Equatable, Sendable {
    var id: String
    var text: String
    var done: Bool
    var dueAtMs: Int64?
    var priority: FollowUpPriority
    var createdAtMs: Int64
    var completedAtMs: Int64?
    var sourceConversationId: String?
    var why: String?
}

/// The Get Conversations / Get Follow-Ups scope, as the intents' enum maps onto the kit.
enum EntityScope: Equatable, Sendable {
    case today
    case yesterday
    case lastSevenDays
    case everything

    var kitScope: Intelligence.AskScope {
        switch self {
        case .today: return .today
        case .yesterday: return .yesterday
        case .lastSevenDays: return .lastSevenDays
        case .everything: return .everything
        }
    }
}

/// What the entity layer may read. Every method is safe to call from any actor.
protocol EntityDataSource: Sendable {
    /// The current visibility setting; read on every call so a Settings change is immediate.
    func visibility() async -> SystemSearchVisibility

    func conversation(id: String) async -> ConversationEntitySnapshot?
    /// Newest first, live rows excluded (they are still growing), narrowed to the scope's
    /// logical days and, optionally, to one tag.
    func conversations(scope: EntityScope, tag: String?, limit: Int) async
        -> [ConversationEntitySnapshot]
    /// Title/summary/transcript search through the app's own FTS index, conversations only.
    func conversations(matching query: String, limit: Int) async -> [ConversationEntitySnapshot]

    func note(id: String) async -> NoteEntitySnapshot?
    func notes(limit: Int) async -> [NoteEntitySnapshot]
    func notes(matching query: String, limit: Int) async -> [NoteEntitySnapshot]

    func recap(dateKey: String) async -> RecapEntitySnapshot?
    func recaps(limit: Int) async -> [RecapEntitySnapshot]

    func followUp(id: String) async -> FollowUpEntitySnapshot?
    /// Open follow-ups in the list's own order; `includeDone` adds completed ones after them.
    func followUps(scope: EntityScope, includeDone: Bool, limit: Int) async
        -> [FollowUpEntitySnapshot]
    func followUps(matching query: String, limit: Int) async -> [FollowUpEntitySnapshot]

    /// Today's date key in the device zone — what "today's recap" means.
    func todayDateKey() async -> String
    /// The logical days the Library has sections for, newest first.
    func libraryDayKeys(limit: Int) async -> [String]

    /// Re-donates the named items (the system asked for them by id).
    func reindex(conversationIds: [String]) async
    func reindex(noteIds: [String]) async
    func reindex(followUpIds: [String]) async
    func reindex(recapDateKeys: [String]) async
    /// Rebuilds the whole index from the database — the same recovery Diagnostics offers.
    func reindexEverything() async
    /// Wakes the pipeline so a backlog is worked on now; answers what that backlog is. Nil
    /// when no runtime is up to wake.
    func nudgePipeline() async -> PipelineBacklog?
}

/// The holder the entities and intents read. Defaults to the live graph; tests install a fake.
@MainActor
enum EntityDataSources {
    static var current: any EntityDataSource = LiveEntityDataSource()
}

// MARK: - Live

/// Reads the live composition. Every method tolerates the composition being absent (a Siri
/// launch that raced `bootstrap`, a preview) by answering "nothing" rather than throwing —
/// an intent that fails is a Siri error alert, an empty answer is an honest one.
struct LiveEntityDataSource: EntityDataSource {
    private static let nowMs: @Sendable () -> Int64 = {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// The Sendable pieces of the graph, gathered on the main actor in one hop. The
    /// composition itself is main-actor-bound and must not cross; its stores and the runtime
    /// actor are all `Sendable` and can.
    private struct Graph: Sendable {
        var library: LibraryStore
        var transcripts: FileTranscriptStore
        var index: TranscriptIndex
        var notes: NotesStore
        var followUps: FollowUpStore
        var recaps: DailyRecapStore
        var people: PeopleStore
        var runtime: CompanionRuntime
        var donator: SpotlightDonator
        var visibility: SystemSearchVisibility
    }

    @MainActor private static func graph() -> Graph? {
        guard let composition = AppComposition.shared else { return nil }
        return Graph(
            library: composition.runtime.library,
            transcripts: composition.transcripts,
            index: composition.index,
            notes: composition.notes,
            followUps: composition.followUps,
            recaps: composition.recapStore,
            people: composition.people,
            runtime: composition.runtime,
            donator: composition.donator,
            visibility: EntityVisibility.current()
        )
    }

    func visibility() async -> SystemSearchVisibility { EntityVisibility.current() }

    // MARK: Conversations

    func conversation(id: String) async -> ConversationEntitySnapshot? {
        guard let graph = await Self.graph() else { return nil }
        return await Self.conversation(id: id, in: graph)
    }

    private static func conversation(id: String, in graph: Graph) async
        -> ConversationEntitySnapshot?
    {
        guard let detail = try? await graph.library.conversation(id: id) else { return nil }
        return snapshot(
            row: detail.row,
            transcript: graph.visibility.includesText
                ? transcript(of: detail, transcripts: graph.transcripts) : nil,
            people: await people(of: id, in: graph)
        )
    }

    private static func people(of conversationId: String, in graph: Graph) async -> [String] {
        let assignments = (try? await graph.people.assignments(forConversation: conversationId)) ?? []
        return EntityMapping.people(assignments.map(\.personName))
    }

    func conversations(scope: EntityScope, tag: String?, limit: Int) async
        -> [ConversationEntitySnapshot]
    {
        guard let graph = await Self.graph() else { return [] }
        guard let sections = try? await graph.library.library(tagName: tag) else { return [] }
        let range = askScopeDateKeyRange(
            scope.kitScope, nowMs: Self.nowMs(), timeZoneID: TimeZone.current.identifier)
        let rows = sections
            .filter { range?.contains($0.dateKey) ?? true }
            .flatMap(\.rows)
            .filter { !$0.isLive }
            .prefix(max(0, limit))
        var out: [ConversationEntitySnapshot] = []
        for row in rows {
            var transcript: String?
            if graph.visibility.includesText,
                let detail = try? await graph.library.conversation(id: row.id)
            {
                transcript = Self.transcript(of: detail, transcripts: graph.transcripts)
            }
            out.append(
                Self.snapshot(
                    row: row, transcript: transcript,
                    people: await Self.people(of: row.id, in: graph)))
        }
        return out
    }

    func conversations(matching query: String, limit: Int) async
        -> [ConversationEntitySnapshot]
    {
        guard let graph = await Self.graph() else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let hits =
            (try? await graph.index.searchOffMain(
                trimmed, limit: limit, kinds: [.conversation], mode: .any)) ?? []
        var out: [ConversationEntitySnapshot] = []
        for hit in hits {
            if let snapshot = await Self.conversation(id: hit.id, in: graph) {
                out.append(snapshot)
            }
        }
        return out
    }

    private static func snapshot(row: ConversationListRow, transcript: String?, people: [String])
        -> ConversationEntitySnapshot
    {
        ConversationEntitySnapshot(
            id: row.id,
            title: row.title,
            summary: row.summary,
            startMs: row.startMs,
            endMs: row.endMs,
            timeZoneID: row.timeZoneID,
            dateKey: row.dateKey,
            tags: row.tags,
            isLive: row.isLive,
            transcript: transcript,
            people: people
        )
    }

    /// The same text the Spotlight pass indexes (`AppComposition.install`): the conversation's
    /// own pieces of its segments — never a member's whole transcript, which also holds the
    /// conversations either side — with loops collapsed, because a looped recording must not
    /// hand Siri 1 649 copies of one sentence.
    private static func transcript(of detail: ConversationDetail, transcripts: FileTranscriptStore)
        -> String?
    {
        ConversationText.joined(detail.pieces) { transcripts.load($0) }
    }

    // MARK: Notes

    func note(id: String) async -> NoteEntitySnapshot? {
        guard let graph = await Self.graph() else { return nil }
        return await Self.note(id: id, in: graph)
    }

    private static func note(id: String, in graph: Graph) async -> NoteEntitySnapshot? {
        guard let note = try? await graph.notes.get(id: id) else { return nil }
        return snapshot(note: note, includeBody: graph.visibility.includesText)
    }

    func notes(limit: Int) async -> [NoteEntitySnapshot] {
        guard let graph = await Self.graph() else { return [] }
        // Notes hang off conversations; the newest conversations' notes are the suggestions.
        guard let sections = try? await graph.library.library() else { return [] }
        var out: [NoteEntitySnapshot] = []
        for row in sections.flatMap(\.rows) where out.count < limit {
            let notes = (try? await graph.notes.list(conversationId: row.id)) ?? []
            out.append(
                contentsOf: notes.map {
                    Self.snapshot(note: $0, includeBody: graph.visibility.includesText)
                })
        }
        return Array(out.prefix(max(0, limit)))
    }

    func notes(matching query: String, limit: Int) async -> [NoteEntitySnapshot] {
        guard let graph = await Self.graph() else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let hits =
            (try? await graph.index.searchOffMain(
                trimmed, limit: limit, kinds: [.note], mode: .any)) ?? []
        var out: [NoteEntitySnapshot] = []
        for hit in hits {
            if let snapshot = await Self.note(id: hit.id, in: graph) { out.append(snapshot) }
        }
        return out
    }

    private static func snapshot(note: Note, includeBody: Bool) -> NoteEntitySnapshot {
        NoteEntitySnapshot(
            id: note.id,
            conversationId: note.conversationId,
            title: note.title,
            body: includeBody ? note.body : nil,
            createdAtMs: note.createdAtMs,
            editedAtMs: note.editedAtMs
        )
    }

    // MARK: Recaps

    func recap(dateKey: String) async -> RecapEntitySnapshot? {
        guard let graph = await Self.graph() else { return nil }
        guard let recap = try? await graph.recaps.load(dateKey: dateKey) else { return nil }
        return Self.snapshot(recap: recap, includeText: graph.visibility.donates)
    }

    func recaps(limit: Int) async -> [RecapEntitySnapshot] {
        guard let graph = await Self.graph() else { return [] }
        let recaps = (try? await graph.recaps.list()) ?? []
        return
            recaps
            .sorted { $0.dateKey > $1.dateKey }
            .prefix(max(0, limit))
            .map { Self.snapshot(recap: $0, includeText: graph.visibility.donates) }
    }

    private static func snapshot(recap: DailyRecap, includeText: Bool) -> RecapEntitySnapshot {
        RecapEntitySnapshot(
            dateKey: recap.dateKey,
            text: includeText ? recap.text : nil,
            shortText: includeText ? recap.shortText : nil,
            updatedAtMs: recap.updatedAtMs
        )
    }

    // MARK: Follow-ups

    func followUp(id: String) async -> FollowUpEntitySnapshot? {
        guard let graph = await Self.graph() else { return nil }
        return await Self.followUp(id: id, in: graph)
    }

    private static func followUp(id: String, in graph: Graph) async -> FollowUpEntitySnapshot? {
        guard let item = try? await graph.followUps.load(id: id) else { return nil }
        return snapshot(followUp: item)
    }

    func followUps(scope: EntityScope, includeDone: Bool, limit: Int) async
        -> [FollowUpEntitySnapshot]
    {
        guard let graph = await Self.graph() else { return [] }
        let nowMs = Self.nowMs()
        var items = (try? await graph.followUps.list(scope: .open, nowMs: nowMs)) ?? []
        if includeDone {
            items += (try? await graph.followUps.list(scope: .completed, nowMs: nowMs)) ?? []
        }
        let range = askScopeDateKeyRange(
            scope.kitScope, nowMs: nowMs, timeZoneID: TimeZone.current.identifier)
        let zone = TimeZone.current.identifier
        let scoped = items.filter { item in
            guard let range else { return true }
            // A follow-up belongs to the day it was made — the day of the conversation it
            // came from, in practice, since the pipeline extracts it as that conversation
            // finishes.
            return range.contains(LogicalDay.dateKey(forMs: item.createdAtMs, timeZoneID: zone))
        }
        return scoped.prefix(max(0, limit)).map(Self.snapshot(followUp:))
    }

    func followUps(matching query: String, limit: Int) async -> [FollowUpEntitySnapshot] {
        guard let graph = await Self.graph() else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let hits =
            (try? await graph.index.searchOffMain(
                trimmed, limit: limit, kinds: [.followUp], mode: .any)) ?? []
        var out: [FollowUpEntitySnapshot] = []
        for hit in hits {
            if let snapshot = await Self.followUp(id: hit.id, in: graph) { out.append(snapshot) }
        }
        return out
    }

    private static func snapshot(followUp item: FollowUp) -> FollowUpEntitySnapshot {
        FollowUpEntitySnapshot(
            id: item.id,
            text: item.text,
            done: item.done,
            dueAtMs: item.dueAtMs,
            priority: item.priority,
            createdAtMs: item.createdAtMs,
            completedAtMs: item.completedAtMs,
            sourceConversationId: item.sourceConversationId,
            why: item.why
        )
    }

    // MARK: Days, reindexing, the pipeline

    func todayDateKey() async -> String {
        LogicalDay.dateKey(forMs: Self.nowMs(), timeZoneID: TimeZone.current.identifier)
    }

    func libraryDayKeys(limit: Int) async -> [String] {
        guard let graph = await Self.graph() else { return [] }
        let sections = (try? await graph.library.library()) ?? []
        return Array(sections.map(\.dateKey).prefix(max(0, limit)))
    }

    func reindex(conversationIds: [String]) async {
        guard let graph = await Self.graph() else { return }
        await graph.runtime.enrichment.donate(conversationIds: conversationIds)
        AppRuntimeLog.shared.record("entities  reindex conversations=\(conversationIds.count)")
    }

    func reindex(noteIds: [String]) async {
        guard let graph = await Self.graph() else { return }
        for id in noteIds {
            guard let note = try? await graph.notes.get(id: id) else { continue }
            try? await graph.donator.donateNote(
                id: note.id, title: note.title, body: note.body, createdAtMs: note.createdAtMs)
        }
        AppRuntimeLog.shared.record("entities  reindex notes=\(noteIds.count)")
    }

    func reindex(followUpIds: [String]) async {
        guard let graph = await Self.graph() else { return }
        for id in followUpIds {
            guard let item = try? await graph.followUps.load(id: id) else { continue }
            try? await graph.donator.donateFollowUp(item)
        }
        AppRuntimeLog.shared.record("entities  reindex followups=\(followUpIds.count)")
    }

    func reindex(recapDateKeys: [String]) async {
        guard let graph = await Self.graph() else { return }
        for dateKey in recapDateKeys {
            guard let recap = try? await graph.recaps.load(dateKey: dateKey) else { continue }
            try? await graph.donator.donateRecap(
                dateKey: recap.dateKey, text: recap.text, createdAtMs: recap.updatedAtMs)
        }
        AppRuntimeLog.shared.record("entities  reindex recaps=\(recapDateKeys.count)")
    }

    func reindexEverything() async {
        guard let count = await Self.rebuildIndex() else { return }
        AppRuntimeLog.shared.record("entities  reindex all · conversations=\(count)")
    }

    /// Main-actor because `SearchIndexRebuilder` is; the count is all that comes back.
    @MainActor private static func rebuildIndex() async -> Int? {
        guard let composition = AppComposition.shared else { return nil }
        return (try? await SearchIndexRebuilder(composition: composition).run()) ?? -1
    }

    func nudgePipeline() async -> PipelineBacklog? {
        guard let graph = await Self.graph() else { return nil }
        // The wake is what the pipeline loop pacing listens for; the burst is the background
        // shape of the same work (it is a no-op in the foreground, where the loop is already
        // running at foreground pace). Detached so the intent answers now rather than after
        // ten segments of local transcription. The burst deliberately does not consult the
        // "while charging" policy: the person just asked.
        graph.runtime.notifyConfigChanged(reviveFailures: true)
        let runtime = graph.runtime
        Task.detached(priority: .utility) { await runtime.runCatchUpBurst() }
        let diagnostics = runtime.diagnostics.value
        AppRuntimeLog.shared.record(
            "entities  catch up now · queued=\(diagnostics.queuedTranscriptionTasks) "
                + "enrich=\(diagnostics.conversationsAwaitingEnrichment)"
        )
        return PipelineBacklog(
            queued: diagnostics.queuedTranscriptionTasks,
            awaitingEnrichment: diagnostics.conversationsAwaitingEnrichment
        )
    }
}
