import AppDB
import CompanionRuntime
import Foundation
import Intelligence
import SearchKit
import SegmentStore
import StatusUI
import Transcription

// The real Library / Search / Conversation / Ask / Notes / Tags / People sources.
//
// `MockWorld` renders the artboards; this renders the database. The screens are unchanged —
// they talk to the same protocols, and `AskLibraryDataSources.current` is flipped at launch.

@MainActor
enum LiveLibraryDataSources {
    static func make(composition: AppComposition) -> AskLibraryDataSources {
        let world = LiveWorld(composition: composition)
        return AskLibraryDataSources(
            library: world, search: world, conversations: world, ask: world,
            notes: world, tagEditor: world, people: world
        )
    }
}

@MainActor
final class LiveWorld {
    private let composition: AppComposition
    /// Deletes inside their undo window: nothing is destroyed until the timer commits.
    private var pendingDeletes: [String: (token: PendingConversationDelete, timer: Task<Void, Never>)] =
        [:]

    init(composition: AppComposition) {
        self.composition = composition
    }

    // MARK: - Shared mapping

    fileprivate func row(_ source: ConversationListRow) -> LibraryRow {
        LibraryRow(
            id: source.id,
            title: source.title,
            summary: source.summary,
            startMs: source.startMs,
            endMs: source.endMs,
            isLive: source.isLive,
            tags: source.tags,
            lifecycle: source.lifecycle,
            mostlyQuiet: source.mostlyQuiet,
            hasMissingAudio: source.hasMissingAudio,
            followUpCount: source.openFollowUpCount,
            dateKey: source.dateKey
        )
    }

    /// The segment ids that make up a conversation, in order.
    private func members(of conversationId: String) async -> [String] {
        let detail = try? await composition.runtime.library.conversation(id: conversationId)
        return detail?.members.map(\.segmentId) ?? []
    }

    private func title(of conversationId: String) async -> String? {
        let detail = try? await composition.runtime.library.conversation(id: conversationId)
        return detail?.row.title
    }
}

// MARK: - LibraryDataSource

extension LiveWorld: LibraryDataSource {
    func library(filter: LibraryFilter, tag: String?) async throws -> [LibraryDayGroup] {
        let sections = try await composition.runtime.library.library(filter: filter, tagName: tag)
        return sections.map { section in
            LibraryDayGroup(dateKey: section.dateKey, rows: section.rows.map(row))
        }
    }

    func tags() async throws -> [TagWithCount] {
        try await composition.runtime.library.allTags()
    }

    /// One "something changed" tick per DB write that could affect a list screen.
    func updates() -> AsyncStream<Void> {
        let library = composition.runtime.library
        return AsyncStream { continuation in
            let rows = Task {
                for await _ in library.observeLibrary() { continuation.yield(()) }
            }
            let tags = Task {
                for await _ in library.observeTags() { continuation.yield(()) }
            }
            continuation.onTermination = { _ in
                rows.cancel()
                tags.cancel()
            }
        }
    }
}

// MARK: - SearchDataSource

extension LiveWorld: SearchDataSource {
    func search(query: String, scope: AskScope) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults() }

        let allTags = try await composition.runtime.library.allTags()
        let matchedTags = allTags.filter {
            $0.name.range(of: trimmed, options: .caseInsensitive) != nil
        }

        // The FTS index carries transcript text (this is the D7 fix — the old app indexed only
        // titles), so a hit here is a hit in what was actually said.
        let index = composition.index
        let hits = (try? index.search(trimmed, limit: 40)) ?? []
        let sections = try await composition.runtime.library.library()
        let rows = sections.flatMap(\.rows)
        let conversations = hits
            .filter { $0.kind == .conversation }
            .compactMap { hit -> SearchConversationHit? in
                guard let row = rows.first(where: { $0.id == hit.id }) else { return nil }
                let start = Date(timeIntervalSince1970: Double(row.startMs) / 1000)
                return SearchConversationHit(
                    id: row.id,
                    title: row.title ?? "Conversation",
                    whenLabel: "\(TimeFmt.dayLabel(dateKey: row.dateKey)) · \(TimeFmt.time(start))",
                    snippet: hit.snippet.isEmpty ? (row.summary ?? "") : "“\(hit.snippet)”"
                )
            }

        let followUps = try await composition.followUps.list().filter {
            $0.text.range(of: trimmed, options: .caseInsensitive) != nil
        }
        return SearchResults(
            tags: matchedTags, conversations: conversations, followUps: followUps
        )
    }
}

// MARK: - ConversationDataSource

extension LiveWorld: ConversationDataSource {
    func display(id: String) async throws -> ConversationDisplay? {
        guard let detail = try await composition.runtime.library.conversation(id: id) else {
            return nil
        }
        let source = detail.row
        let start = Date(timeIntervalSince1970: Double(source.startMs) / 1000)
        let end = Date(timeIntervalSince1970: Double(source.endMs) / 1000)

        let assignments = (try? await composition.people.assignments(forConversation: id)) ?? []
        let tagRows = (try? await composition.tags.tags(forConversation: id)) ?? []
        let followUps = (try? await composition.followUps.list(conversationId: id)) ?? []

        var transcript: [TranscriptItem] = []
        var totalMs: Int64 = 0
        var missingAt: Double?
        var provider: String?
        var transcribedAtMs: Int64?

        for member in detail.members {
            guard let meta = composition.files.readMeta(member.segmentId) else { continue }
            let stored = composition.transcripts.load(member.segmentId)
            if let stored {
                provider = stored.providerId
                transcribedAtMs = max(transcribedAtMs ?? 0, stored.createdAtMs)
            }
            // `TranscriptSegment`/`TranscriptWord` exist in both Transcription (what the
            // provider produced) and SearchKit (what the timeline formatter reads); bridge them.
            let items = transcriptTimelineItems(
                meta: meta,
                segments: (stored?.segments ?? []).map {
                    SearchKit.TranscriptSegment(
                        text: $0.text, startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker)
                },
                words: (stored?.words ?? []).map {
                    SearchKit.TranscriptWord(
                        text: $0.text, startMs: $0.startMs, endMs: $0.endMs)
                }
            )
            for (offset, item) in items.enumerated() {
                let itemId = "\(member.segmentId)-\(offset)"
                switch item {
                case .speech(let speech):
                    transcript.append(
                        .turn(
                            TranscriptTurn(
                                id: itemId,
                                speakerLabel: speech.speaker ?? "",
                                name: Self.speakerName(speech.speaker, assignments: assignments),
                                role: Self.speakerRole(speech.speaker, assignments: assignments),
                                text: speech.text
                            )))
                case .silenceBreak:
                    break  // an unlabeled visual break; the transcript view spaces paragraphs
                case .pause(let pause):
                    if pause.missing {
                        transcript.append(.missing(id: itemId, marker: pause.label))
                        if totalMs > 0, missingAt == nil {
                            missingAt = Double(pause.startMs - source.startMs)
                        }
                    } else {
                        transcript.append(
                            .quiet(id: itemId, duration: pause.label))
                    }
                }
            }
            totalMs += segmentDurationMs(meta)
        }

        let duration = max(totalMs, source.durationMs)
        return ConversationDisplay(
            id: id,
            title: source.title ?? (source.isLive ? "Recording now" : "Conversation"),
            metaLine: TimeFmt.conversationMeta(start: start, end: end),
            summary: source.summary,
            tags: tagRows,
            lifecycle: Self.lifecycle(detail),
            player: duration > 0
                ? PlayerDisplay(
                    durationMs: duration,
                    missingTickFraction: missingAt.map { min(max($0 / Double(duration), 0), 1) }
                ) : nil,
            transcript: transcript,
            provenance: Self.provenance(provider: provider, atMs: transcribedAtMs),
            followUps: followUps
        )
    }

    func rename(id: String, to title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = try await composition.annotations.load(id)
        var annotation =
            existing
            ?? ConversationAnnotation(
                conversationId: id, updatedAtMs: composition.clock.nowMs
            )
        annotation.title = trimmed
        annotation.updatedAtMs = composition.clock.nowMs
        _ = try await composition.annotations.save(annotation)
        try? await composition.donator.donateConversation(
            conversationId: id,
            title: trimmed,
            summary: annotation.summary,
            tags: annotation.tags,
            startDateMs: nil,
            createdAtMs: composition.clock.nowMs
        )
    }

    /// Re-run transcription from scratch for every member segment.
    func retranscribe(id: String) async throws {
        for segmentId in await members(of: id) {
            await composition.runtime.reprocessSegment(segmentId)
        }
    }

    func transcribeNow(id: String) async throws { try await retranscribe(id: id) }

    func retryNow(id: String) async throws { try await retranscribe(id: id) }

    func exportAudio(id: String) async throws {
        for segmentId in await members(of: id) {
            let live = await composition.runtime.environment.live
            _ = try await live.exportSegment(segmentId)
        }
    }

    /// Delete with the 5 s undo window. NOTHING is destroyed here — the runtime hides the
    /// conversation and hands back a token; the timer below commits it when the snackbar's
    /// window closes, and `undoDelete` cancels the timer instead.
    func delete(id: String) async throws {
        pendingDeletes[id]?.timer.cancel()
        let token = await composition.runtime.deleteConversation(id: id)
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(DeferredDeleteBuffer.windowMs))
            guard !Task.isCancelled, let self else { return }
            _ = await composition.runtime.commitDelete(token)
            pendingDeletes[id] = nil
        }
        pendingDeletes[id] = (token, timer)
    }

    func undoDelete(id: String) async throws {
        guard let pending = pendingDeletes.removeValue(forKey: id) else { return }
        pending.timer.cancel()
        _ = await composition.runtime.restoreDelete(pending.token)
    }

    func toggleFollowUp(id: String) async throws {
        _ = try await composition.followUps.toggle(id: id)
    }

    // --- mapping helpers -----------------------------------------------------------------

    private static func speakerName(
        _ speaker: String?, assignments: [SpeakerAssignment]
    ) -> String {
        guard let speaker else { return "Speaker" }
        if let match = assignments.first(where: { $0.label == speaker }) {
            return match.personName
        }
        return speakerLabel(speaker)
    }

    private static func speakerRole(
        _ speaker: String?, assignments: [SpeakerAssignment]
    ) -> SpeakerRole {
        guard let speaker else { return .unresolved }
        guard let match = assignments.first(where: { $0.label == speaker }) else {
            return .unresolved
        }
        // The wearer is whoever the user named "You"; everyone else is a counterpart.
        return match.personName.caseInsensitiveCompare("You") == .orderedSame ? .you : .other
    }

    private static func lifecycle(_ detail: ConversationDetail) -> LifecycleDisplay {
        switch detail.row.lifecycle {
        case .complete:
            return .complete
        case .capturedWaiting:
            let waiting = detail.members.filter { $0.state == .pending }.count
            return .capturedWaiting(
                queueLine: waiting <= 1
                    ? "Next in the queue" : "\(waiting) recordings ahead of this one"
            )
        case .transcribing:
            let done = detail.members.filter { $0.state == .complete }.count
            let total = max(detail.members.count, 1)
            return .transcribing(
                progress: Double(done) / Double(total),
                line: "Transcribing \(done + 1) of \(total)"
            )
        case .failed:
            return .failed
        }
    }

    private static func provenance(provider: String?, atMs: Int64?) -> String? {
        guard let provider, let atMs, atMs > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(atMs) / 1000)
        let name = provider == "soniox" ? "Soniox" : (provider == "openai" ? "OpenAI" : provider)
        return "Transcribed with \(name) · \(TimeFmt.dayLabel(for: date)) \(TimeFmt.time(date))"
    }
}

// MARK: - AskDataSource

extension LiveWorld: AskDataSource {
    var hasContent: Bool { !composition.files.listSegments().isEmpty }

    func recent() async throws -> [AskEntry] {
        try await composition.runtime.library.recentAsks()
    }

    func ask(question: String, scope: AskScope) async throws -> AskEntry {
        let kitScope = scope.kitScope
        let nowMs = composition.clock.nowMs
        let metas = segmentsInAskScope(
            composition.files.listSegments(), scope: kitScope, nowMs: nowMs
        )
        // A conversation-scoped question narrows to that conversation's members.
        let scoped: [SegmentMeta]
        if case .conversation(let id, _) = scope {
            let ids = Set(await members(of: id))
            scoped = composition.files.listSegments().filter { ids.contains($0.segmentId) }
        } else {
            scoped = metas
        }

        var excerpts: [TranscriptExcerpt] = []
        var gapSummaries: [String: String?] = [:]
        for meta in scoped {
            guard let transcript = composition.transcripts.load(meta.segmentId),
                !transcript.text.isEmpty
            else { continue }
            excerpts.append(
                TranscriptExcerpt(
                    segmentId: meta.segmentId,
                    text: transcript.text,
                    startTimeMs: Int64(meta.startTimeMs),
                    endTimeMs: Int64(meta.startTimeMs) + segmentDurationMs(meta),
                    timeLabel: TimeFmt.time(
                        Date(timeIntervalSince1970: Double(meta.startTimeMs) / 1000))
                ))
            gapSummaries[meta.segmentId] = askGapSummary(meta)
        }
        guard !excerpts.isEmpty else {
            return try await save(
                question: question,
                answer: "There is nothing recorded in that window to answer from.",
                citedIds: [],
                scope: kitScope,
                nowMs: nowMs
            )
        }

        let sourceOrder = askSourceOrder(excerpts)
        let chunks = await composition.askRetriever.retrieve(
            query: question, excerpts: excerpts, gapSummaries: gapSummaries
        )
        let formatted = composition.askRetriever.formatForPrompt(chunks) {
            askCitationNumber(of: $0, sourceOrder: sourceOrder)
        }
        let result = try await composition.aiRouter.run(
            AiRunRequest(
                requestId: UUID().uuidString.lowercased(),
                prompt: AiPromptTemplates.ask,
                transcripts: [
                    TranscriptExcerpt(segmentId: "ask", text: "\(question)\n\n\(formatted)")
                ]
            )
        )
        let grounded = parseGroundedAnswer(result.text, sourceIds: sourceOrder)
        return try await save(
            question: question,
            answer: result.text,
            citedIds: grounded.citedSegmentIds,
            scope: kitScope,
            nowMs: nowMs
        )
    }

    private func save(
        question: String, answer: String, citedIds: [String],
        scope: Intelligence.AskScope, nowMs: Int64
    ) async throws -> AskEntry {
        try await saveAskAnswer(
            question: question,
            answerText: answer,
            citedSegmentIds: citedIds,
            scope: scope,
            history: composition.askHistory,
            nowMs: nowMs
        )
    }

    func clearHistory() async throws {
        try await composition.askHistory.clear()
    }

    /// Citations name SEGMENTS; the footer wants the conversation they belong to.
    func conversationTitle(citedId: String) -> String? {
        guard let meta = composition.files.readMeta(citedId) else { return nil }
        return segmentTitle(meta, transcriptText: composition.transcripts.load(citedId)?.text)
    }
}

// MARK: - NotesDataSource

extension LiveWorld: NotesDataSource {
    func notes(conversationId: String) async throws -> [NoteDisplay] {
        let stored = try await composition.notes.list(conversationId: conversationId)
        let title = await self.title(of: conversationId) ?? "Conversation"
        return stored.map { Self.display($0, conversationTitle: title) }
    }

    func note(id: String) async throws -> NoteDisplay? {
        guard let stored = try await composition.notes.get(id: id) else { return nil }
        let title = await self.title(of: stored.conversationId) ?? "Conversation"
        return Self.display(stored, conversationTitle: title)
    }

    func templates() async throws -> [NoteTemplate] {
        let custom = try await composition.customTemplates.list()
        return NoteTemplate.builtIns
            + custom.map {
                NoteTemplate(id: $0.id, title: $0.title, isCustom: true, prompt: $0.prompt)
            }
    }

    func generate(
        conversationId: String, template: NoteTemplate, customPrompt: String?
    ) async throws -> NoteDisplay {
        let segmentIds = await members(of: conversationId)
        let excerpts = segmentIds.compactMap { segmentId -> TranscriptExcerpt? in
            guard let transcript = composition.transcripts.load(segmentId),
                !transcript.text.isEmpty
            else { return nil }
            return TranscriptExcerpt(segmentId: segmentId, text: transcript.text)
        }
        let prompt = Self.prompt(for: template, customPrompt: customPrompt)
        let result = try await composition.aiRouter.run(
            AiRunRequest(
                requestId: UUID().uuidString.lowercased(),
                prompt: prompt,
                transcripts: excerpts
            )
        )
        let stored = try await composition.notes.create(
            conversationId: conversationId,
            templateId: template.id,
            title: template.title,
            body: result.text,
            provider: result.providerId,
            model: result.modelUsed,
            nowMs: composition.clock.nowMs
        )
        try? await composition.donator.donateNote(
            id: stored.id, title: stored.title, body: stored.body,
            createdAtMs: stored.createdAtMs
        )
        let title = await self.title(of: conversationId) ?? "Conversation"
        return Self.display(stored, conversationTitle: title)
    }

    func regenerate(noteId: String) async throws -> NoteDisplay {
        guard let existing = try await composition.notes.get(id: noteId) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let templates = try await templates()
        let template =
            templates.first { $0.id == existing.templateId }
            ?? NoteTemplate(id: existing.templateId, title: existing.title)
        let regenerated = try await generate(
            conversationId: existing.conversationId, template: template, customPrompt: template.prompt
        )
        try await composition.notes.delete(id: noteId)
        return regenerated
    }

    func saveEdit(noteId: String, title: String, body: String) async throws {
        try await composition.notes.update(
            id: noteId, title: title, body: body, nowMs: composition.clock.nowMs
        )
    }

    func saveTemplate(title: String, prompt: String) async throws {
        _ = try await composition.customTemplates.add(title: title, prompt: prompt)
    }

    func deleteTemplate(id: String) async throws {
        try await composition.customTemplates.delete(id: id)
    }

    func deleteNote(id: String) async throws {
        try await composition.notes.delete(id: id)
        try? await composition.donator.remove(id: id, kind: .note)
    }

    private static func prompt(
        for template: NoteTemplate, customPrompt: String?
    ) -> AiPromptTemplate {
        if let customPrompt, !customPrompt.isEmpty { return AiPromptTemplates.custom(customPrompt) }
        if let stored = template.prompt, !stored.isEmpty {
            return AiPromptTemplates.custom(stored)
        }
        return AiPromptTemplates.builtIn.first { $0.id == template.id }
            ?? AiPromptTemplates.meetingNotes
    }

    private static func display(_ note: Note, conversationTitle: String) -> NoteDisplay {
        let created = Date(timeIntervalSince1970: Double(note.createdAtMs) / 1000)
        let citations =
            (try? JSONDecoder().decode([AskCitation].self, from: Data(note.citationsJson.utf8)))
            ?? []
        return NoteDisplay(
            id: note.id,
            conversationId: note.conversationId,
            conversationTitle: conversationTitle,
            title: note.title,
            provenance: "Generated \(TimeFmt.time(created)) · "
                + "\(AiModels.byId(note.model).displayName) · from this conversation",
            body: note.body,
            momentsLabel: "",
            citations: citations
        )
    }
}

// MARK: - TagEditorDataSource

extension LiveWorld: TagEditorDataSource {
    func tags(forConversation id: String) async throws -> [ConversationTag] {
        try await composition.tags.tags(forConversation: id)
    }

    func suggestions(forConversation id: String) async throws -> [String] {
        try await composition.tags.suggestions(forConversation: id).map(\.name)
    }

    func addTag(conversationId: String, name: String) async throws {
        _ = try await composition.tags.addTag(
            conversationId: conversationId, name: name, source: "user"
        )
    }

    func removeTag(conversationId: String, tagId: String) async throws {
        try await composition.tags.removeTag(conversationId: conversationId, tagId: tagId)
    }

    /// Q10: renaming a tag renames it EVERYWHERE (and merges into an existing name).
    func renameTag(tagId: String, to newName: String) async throws {
        try await composition.tags.renameTag(tagId: tagId, to: newName)
    }
}

// MARK: - PeopleDataSource

extension LiveWorld: PeopleDataSource {
    func people() async throws -> [Person] {
        try await composition.people.listPeople().map(\.person)
    }

    func assign(conversationId: String, label: String, personName: String) async throws {
        let trimmed = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = try await composition.people.listPeople().map(\.person)
        let person: Person
        if let match = existing.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            person = match
        } else {
            person = try await composition.people.createPerson(name: trimmed)
        }
        try await composition.people.assign(
            conversationId: conversationId, label: label, personId: person.id
        )
    }
}

// MARK: - Scope bridging

extension AskScope {
    /// The app's scope vocabulary (which includes conversation scope and arbitrary day counts)
    /// mapped onto the kit's, which only knows logical-day ranges.
    var kitScope: Intelligence.AskScope {
        let zone = TimeZone.current.identifier
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        switch self {
        case .today: return .today
        case .yesterday: return .yesterday
        case .last7Days: return .lastSevenDays
        case .everything, .conversation: return .everything
        case .lastDays(let days):
            let end = LogicalDay.dateKey(forMs: nowMs, timeZoneID: zone)
            let start = LogicalDay.dateKey(
                forMs: nowMs - Int64(max(0, days - 1)) * 86_400_000, timeZoneID: zone)
            return .dateRange(startKey: start, endKey: end)
        case .dateRange(let start, let end):
            return .dateRange(
                startKey: LogicalDay.dateKey(
                    forMs: Int64(start.timeIntervalSince1970 * 1000), timeZoneID: zone),
                endKey: LogicalDay.dateKey(
                    forMs: Int64(end.timeIntervalSince1970 * 1000), timeZoneID: zone)
            )
        }
    }
}
