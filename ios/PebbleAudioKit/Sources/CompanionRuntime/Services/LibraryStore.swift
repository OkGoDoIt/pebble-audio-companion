import AppDB
import Foundation
import Intelligence

/// The UI's read model. **DB-observed, never disk-reloaded** — the B17 fix.
///
/// Every list the app renders comes from a database observation, so a new transcript, a renamed
/// tag or a finished recap pushes a new value on its own. The runtime never tells the UI to
/// "reload"; diagnostics is a separate published struct, not a reload key.
public struct LibraryStore: Sendable {
    public let database: AppDatabase
    private let queries: ConversationQueries
    private let tags: TagStore
    private let followUps: FollowUpStore
    private let notes: NotesStore
    private let askHistory: AskHistoryStore
    private let deferredDeletes: DeferredDeleteBuffer?

    public init(database: AppDatabase, deferredDeletes: DeferredDeleteBuffer? = nil) {
        self.database = database
        self.queries = ConversationQueries(db: database)
        self.tags = TagStore(db: database)
        self.followUps = FollowUpStore(db: database)
        self.notes = NotesStore(db: database)
        self.askHistory = AskHistoryStore(db: database)
        self.deferredDeletes = deferredDeletes
    }

    // --- one-shot reads ------------------------------------------------------------------------

    /// Library sections, with conversations inside an open undo window filtered out.
    public func library(
        filter: LibraryFilter = .all, tagName: String? = nil
    ) async throws -> [LibraryDaySection] {
        let sections = try await queries.library(filter: filter, tagName: tagName)
        return await applyPendingDeletes(to: sections)
    }

    public func conversation(id: String) async throws -> ConversationDetail? {
        try await queries.detail(id: id)
    }

    public func allTags() async throws -> [TagWithCount] { try await tags.listTags() }

    public func openFollowUps() async throws -> [FollowUp] { try await followUps.list(done: false) }

    public func notes(conversationId: String) async throws -> [Note] {
        try await notes.list(conversationId: conversationId)
    }

    public func recentAsks() async throws -> [AskEntry] { try await askHistory.recent() }

    /// Recent Ask conversations, each with all of its turns.
    public func recentAskThreads() async throws -> [AskThread] {
        try await askHistory.recentThreads()
    }

    // --- observations --------------------------------------------------------------------------

    /// Streams library sections. Terminates when the consuming task is cancelled.
    public func observeLibrary(
        filter: LibraryFilter = .all, tagName: String? = nil
    ) -> AsyncStream<[LibraryDaySection]> {
        let observation = queries.observeLibrary(filter: filter, tagName: tagName)
        let deferredDeletes = self.deferredDeletes
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await sections in observation {
                        let hidden = await deferredDeletes?.hiddenConversationIds ?? []
                        continuation.yield(Self.filter(sections, hiding: hidden))
                    }
                } catch {
                    // An observation error means the DB went away; the UI keeps its last value.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func observeConversation(id: String) -> AsyncStream<ConversationDetail?> {
        let observation = queries.observeDetail(id: id)
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await detail in observation { continuation.yield(detail) }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func observeTags() -> AsyncStream<[TagWithCount]> {
        let observation = tags.observeTags()
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation { continuation.yield(value) }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func observeOpenFollowUps(limit: Int = 50) -> AsyncStream<[FollowUp]> {
        let observation = followUps.observeOpen(limit: limit)
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation { continuation.yield(value) }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // --- undo-window filtering -------------------------------------------------------------------

    private func applyPendingDeletes(
        to sections: [LibraryDaySection]
    ) async -> [LibraryDaySection] {
        guard let deferredDeletes else { return sections }
        return Self.filter(sections, hiding: await deferredDeletes.hiddenConversationIds)
    }

    private static func filter(
        _ sections: [LibraryDaySection], hiding hidden: Set<String>
    ) -> [LibraryDaySection] {
        guard !hidden.isEmpty else { return sections }
        return sections.compactMap { section in
            let rows = section.rows.filter { !hidden.contains($0.id) }
            if rows.isEmpty { return nil }
            var trimmed = section
            trimmed.rows = rows
            return trimmed
        }
    }
}
