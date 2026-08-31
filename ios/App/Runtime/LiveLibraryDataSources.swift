import AppDB
import CompanionRuntime
import LiveAudio
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
            dateKey: source.dateKey,
            awaitingAnnotation: source.awaitingAnnotation
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
    /// `scope` is the pill above the results, and it is load-bearing: narrowing to "Today"
    /// filters everything below to today's logical day (5 AM boundary, in each conversation's
    /// own recorded zone — Q16). This used to accept `scope` and ignore it, so the pill changed,
    /// the search visibly re-ran, and the results were byte-identical to "Everything".
    func search(query: String, scope: AskScope) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults() }

        // nil for `.everything` — no window, so nothing is filtered out below.
        let window = askScopeDateKeyRange(
            scope.kitScope,
            nowMs: composition.clock.nowMs,
            timeZoneID: TimeZone.current.identifier
        )

        let sections = try await composition.runtime.library.library()
        let rows = sections.flatMap(\.rows).filter { window?.contains($0.dateKey) ?? true }

        // The FTS index carries transcript text (this is the D7 fix — the old app indexed only
        // titles), so a hit here is a hit in what was actually said.
        //
        // The window and the kind go INTO the query. Taking the global top 40 and filtering
        // afterwards spent the whole limit on rows this function then discarded: under "Today",
        // a conversation from today that ranked 41st across the library simply did not appear,
        // and that gets steadily worse as the library grows. Scoped, the 40 are 40 conversations
        // from inside the window, so the pill reports what is actually there.
        let index = composition.index
        let hits =
            (try? index.search(
                trimmed,
                limit: 40,
                kinds: [.conversation],
                within: window == nil ? nil : Set(rows.map(\.id))
            )) ?? []
        let conversations = hits
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

        let dayOfConversation = Dictionary(
            rows.map { ($0.id, $0.dateKey) }, uniquingKeysWith: { first, _ in first })
        let followUps = try await composition.followUps.list().filter { followUp in
            guard followUp.text.range(of: trimmed, options: .caseInsensitive) != nil else {
                return false
            }
            guard let window else { return true }
            // A follow-up belongs to the day of the conversation it came from; a hand-written
            // one has no conversation, so it falls back to when it was written.
            if let conversationId = followUp.sourceConversationId {
                guard let day = dayOfConversation[conversationId] else { return false }
                return window.contains(day)
            }
            return window.contains(
                LogicalDay.dateKey(
                    forMs: followUp.createdAtMs, timeZoneID: TimeZone.current.identifier))
        }

        return SearchResults(
            tags: try await matchingTags(trimmed, scopedTo: window, rows: rows),
            conversations: conversations,
            followUps: followUps
        )
    }

    /// Tags whose name matches, counted within the scope. Outside `.everything` the global
    /// count would be a second, quieter lie: "travel (34)" under a "Today" pill, on a day with
    /// one travel conversation. A tag with nothing inside the window is dropped entirely.
    private func matchingTags(
        _ query: String, scopedTo window: ClosedRange<String>?, rows: [ConversationListRow]
    ) async throws -> [TagWithCount] {
        let all = try await composition.runtime.library.allTags()
        let matched = all.filter { $0.name.range(of: query, options: .caseInsensitive) != nil }
        guard window != nil else { return matched }
        var counts: [String: Int] = [:]
        for row in rows {
            for name in row.tags { counts[name.lowercased(), default: 0] += 1 }
        }
        return matched.compactMap { tag in
            guard let count = counts[tag.name.lowercased()], count > 0 else { return nil }
            return TagWithCount(id: tag.id, name: tag.name, count: count)
        }
    }
}

/// Bridges the kit's `SegmentPlaybackController` (which plays one keyed stream) to the
/// screen's `ConversationPlayback`, keyed on the CONVERSATION: its frame source concatenates
/// every member segment, so a conversation that survived three reconnects still plays as one.
@MainActor
private final class ConversationPlaybackEngine: ConversationPlayback {
    let durationMs: Int64
    private let key: String
    private let controller: SegmentPlaybackController

    init(key: String, durationMs: Int64, controller: SegmentPlaybackController) {
        self.key = key
        self.durationMs = durationMs
        self.controller = controller
    }

    deinit { controller.stop() }

    func progress() -> AsyncStream<PlaybackProgress> {
        let updates = controller.stateUpdates()
        return AsyncStream { continuation in
            let task = Task {
                for await state in updates {
                    continuation.yield(
                        PlaybackProgress(
                            playing: state.playing,
                            positionMs: state.positionMs,
                            durationMs: state.durationMs))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func play(fromMs: Int64) {
        let key = key
        let controller = controller
        // `play` reads the frame logs synchronously before it starts decoding; off the main
        // actor, so a long conversation cannot stall the first frame of the UI.
        Task.detached(priority: .userInitiated) {
            controller.seekTo(key, positionMs: fromMs)
            controller.play(key)
        }
    }

    func pause() { controller.pause() }

    func seek(toMs: Int64) { controller.seekTo(key, positionMs: toMs) }

    /// The controller only cycles 1 → 1.5 → 2, so reaching a speed means stepping to it —
    /// bounded by the length of that cycle so an unexpected value can never spin here.
    func setSpeed(_ speed: Double) {
        for _ in 0..<3 {
            if controller.state.speed == Float(speed) { return }
            controller.cycleSpeed()
        }
    }

    func stop() { controller.stop() }
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
        /// Media time consumed by the members already walked — the player's clock.
        var mediaBeforeMemberMs: Int64 = 0
        var missingTicks: [Double] = []
        var provider: String?
        var transcribedAtMs: Int64?
        var zone: TimeZone?

        for member in detail.members {
            guard let meta = composition.files.readMeta(member.segmentId) else { continue }
            let stored = composition.transcripts.load(member.segmentId)
            if let stored {
                provider = stored.providerId
                transcribedAtMs = max(transcribedAtMs ?? 0, stored.createdAtMs)
            }
            if zone == nil { zone = TranscriptItems.timeZone(meta) }
            // `TranscriptSegment`/`TranscriptWord` exist in both Transcription (what the
            // provider produced) and SearchKit (what the timeline formatter reads); bridge them.
            let built = TranscriptItems.member(
                segmentId: member.segmentId,
                meta: meta,
                segments: (stored?.segments ?? []).map {
                    SearchKit.TranscriptSegment(
                        text: $0.text, startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker)
                },
                words: (stored?.words ?? []).map {
                    SearchKit.TranscriptWord(
                        text: $0.text, startMs: $0.startMs, endMs: $0.endMs)
                },
                assignments: assignments,
                mediaBeforeMemberMs: mediaBeforeMemberMs
            )
            transcript.append(contentsOf: built.items)
            missingTicks.append(
                contentsOf: built.missingMediaOffsets.map { Double(mediaBeforeMemberMs + $0) })
            mediaBeforeMemberMs += built.mediaMs
        }

        // The scrubber measures STORED AUDIO. Using the wall span instead (a 1 hr 4 min
        // conversation holding 33 min of audio) made the player claim time that does not
        // exist, and every position on it was wrong by however much was missing.
        let duration = mediaBeforeMemberMs
        let hasWords = transcript.contains { if case .turn = $0 { return true } else { return false } }
        let aiAvailable = await composition.aiRouter.isAvailable()
        return ConversationDisplay(
            id: id,
            title: source.title ?? (source.isLive ? "Recording now" : "Conversation"),
            metaLine: TimeFmt.conversationMeta(start: start, end: end),
            summary: source.summary,
            tags: tagRows,
            lifecycle: Self.lifecycle(detail, hasWords: hasWords, aiAvailable: aiAvailable),
            player: duration > 0
                ? PlayerDisplay(
                    durationMs: duration,
                    missingTickFractions: missingTicks.map {
                        min(max($0 / Double(duration), 0), 1)
                    }
                ) : nil,
            transcript: transcript,
            provenance: Self.provenance(provider: provider, atMs: transcribedAtMs),
            followUps: followUps,
            timeZone: zone ?? .current
        )
    }

    /// Ticks whenever this conversation's own row, members, transcript state, annotation or
    /// follow-ups change — the DB observation that existed all along and nothing subscribed to.
    func updates(conversationId: String) -> AsyncStream<Void> {
        let library = composition.runtime.library
        return AsyncStream { continuation in
            let task = Task {
                for await _ in library.observeConversation(id: conversationId) {
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Playback over every member segment of the conversation, as one continuous stream.
    func playback(id: String) async throws -> (any ConversationPlayback)? {
        let segments = await members(of: id)
        guard !segments.isEmpty else { return nil }
        let files = composition.files
        let durationMs = segments.compactMap { files.readMeta($0) }
            .reduce(Int64(0)) { $0 + mediaDurationMs($1) }
        guard durationMs > 0 else { return nil }
        return ConversationPlaybackEngine(
            key: id,
            durationMs: durationMs,
            controller: SegmentPlaybackController(
                playerFactory: { AVFoundationPcmPlayer() },
                decoder: SpeexLiveFrameDecoder(),
                // Called on the playback executor, never the main actor: the frame logs of a
                // long conversation are tens of megabytes to walk.
                frameSource: { _ in segments.flatMap { files.readFrames($0).map(\.payload) } }
            ))
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

    /// One WAV per member segment. The count is returned rather than assumed: a conversation
    /// that survived three reconnects is four files, and the screen used to report "1 file
    /// exported" for all of them.
    func exportAudio(id: String) async throws -> Int {
        let live = await composition.runtime.environment.live
        var written = 0
        for segmentId in await members(of: id) {
            written += try await live.exportSegment(segmentId).files.count
        }
        return written
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

    /// The one state card the conversation shows. Transcription first (it gates everything
    /// else), then the AI pass — so a conversation always says which kind of work, if any, is
    /// still owed to it, and never claims to be waiting for work that is already done.
    ///
    /// `aiAvailable` separates "AI is working through the backlog" from "AI is off, so there
    /// is genuinely nothing coming" — the distinction Roger could not make from the UI.
    private static func lifecycle(
        _ detail: ConversationDetail, hasWords: Bool, aiAvailable: Bool
    ) -> LifecycleDisplay {
        switch detail.row.lifecycle {
        case .complete:
            guard !detail.row.hasAnnotation else { return .complete }
            // Enrichment writes nothing for a conversation with no words in it; a silent
            // stretch is finished, not pending.
            guard hasWords else { return .complete }
            if detail.row.annotationFinalAttempts >= EnrichmentWorker.maxAttempts {
                return .noSummary(gaveUp: true)
            }
            return aiAvailable ? .summaryComing : .noSummary(gaveUp: false)
        case .capturedWaiting:
            // Members already holding a transcript are not "ahead of" anything.
            let waiting = detail.members.filter {
                !($0.segmentState == .complete || $0.segmentState == .noSpeech)
            }.count
            return .capturedWaiting(
                queueLine: waiting <= 1
                    ? "Next in the queue" : "\(waiting) recordings ahead of this one"
            )
        case .transcribing:
            let done = detail.members.filter {
                $0.segmentState == .complete || $0.segmentState == .noSpeech
            }.count
            let total = max(detail.members.count, 1)
            return .transcribing(
                progress: Double(done) / Double(total),
                line: "Transcribing \(min(done + 1, total)) of \(total)"
            )
        case .failed:
            // WHY it failed is already on the member's task row; it was simply never read.
            // The newest failure wins — a conversation that failed twice is telling you about
            // the attempt that just happened, not the one from yesterday. `.unknown` members
            // are skipped so one uninformative row cannot hide an informative one.
            let failures = detail.members.filter { $0.state == .failed }
            let named = failures.last {
                TranscriptionFailureKind.classify($0.lastError) != .unknown
            }
            guard let named, let message = named.lastError else { return .failed(reason: nil) }
            // The card has one line, so the retry status rides along with the reason; the
            // Diagnostics rows carry it in their own column instead.
            return .failed(
                reason: Copy.TranscriptionFailure.line(
                    TranscriptionFailureKind.classify(message).reason,
                    retrying: named.attempts < TranscriptionQueue.maxAttempts
                )
            )
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

    func recentThreads() async throws -> [AskThread] {
        try await composition.runtime.library.recentAskThreads()
    }

    func ask(question: String, thread: AskThread?, scope: AskScope) async throws -> AskEntry {
        let kitScope = scope.kitScope
        let nowMs = composition.clock.nowMs
        let priorTurns = thread?.turns ?? []
        let threadId = thread?.id
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
            let startMs = Int64(meta.startTimeMs)
            let endMs = startMs + segmentDurationMs(meta)
            excerpts.append(
                TranscriptExcerpt(
                    segmentId: meta.segmentId,
                    text: transcript.text,
                    startTimeMs: startMs,
                    endTimeMs: endMs,
                    // The full recorded date, not just a clock time: these transcripts span
                    // many days, and a bare "9:35 PM" reads as tonight.
                    timeLabel: askWhenLabel(
                        startMs: startMs, endMs: endMs,
                        timeZoneID: meta.recordedTimeZone ?? TimeZone.current.identifier,
                        nowMs: nowMs)
                ))
            gapSummaries[meta.segmentId] = askGapSummary(meta)
        }
        guard !excerpts.isEmpty else {
            return try await save(
                question: question,
                answer: "There is nothing recorded in that window to answer from.",
                citations: [],
                scope: kitScope,
                threadId: threadId,
                nowMs: nowMs
            )
        }

        let sourceOrder = askSourceOrder(excerpts)
        let chunks = await composition.askRetriever.retrieve(
            query: askRetrievalQuery(question: question, priorTurns: priorTurns),
            excerpts: excerpts, gapSummaries: gapSummaries
        )
        let formatted = composition.askRetriever.formatForPrompt(chunks) {
            askCitationNumber(of: $0, sourceOrder: sourceOrder)
        }
        var content = askNowContext(nowMs: nowMs, scopeDescription: kitScope.displayName)
        if let thread = askThreadContext(priorTurns) { content += "\n\n\(thread)" }
        content += "\n\nQUESTION: \(question)\n\nTRANSCRIPTS:\n\(formatted)"
        let result = try await composition.aiRouter.run(
            AiRunRequest(
                requestId: UUID().uuidString.lowercased(),
                prompt: AiPromptTemplates.ask,
                transcripts: [TranscriptExcerpt(segmentId: "ask", text: content)]
            )
        )
        // The answer card shows the model's text verbatim, so a chip reading "2" has to be
        // the segment the prompt called [2]. Renumbering by first appearance (what
        // `parseGroundedAnswer` does, for its own re-rendered lines) sent chips to the wrong
        // moment whenever an answer's first citation was not [1].
        return try await save(
            question: question,
            answer: result.text,
            citations: renderedAnswerCitations(result.text, sourceIds: sourceOrder),
            scope: kitScope,
            threadId: threadId,
            nowMs: nowMs
        )
    }

    private func save(
        question: String, answer: String, citations: [AskCitation],
        scope: Intelligence.AskScope, threadId: String?, nowMs: Int64
    ) async throws -> AskEntry {
        try await saveAskAnswer(
            question: question,
            answerText: answer,
            citations: citations,
            scope: scope,
            history: composition.askHistory,
            threadId: threadId,
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

    /// Resolve a citation all the way to something the UI can act on: which conversation holds
    /// the cited segment, where that segment starts on the player's scrubber (media time, gaps
    /// excluded — the same accumulation `display(id:)` walks), and when it was recorded.
    func citationTarget(citedId: String) async -> CitationTarget? {
        guard
            let conversationId = try? await composition.runtime.library.conversationId(
                ofSegment: citedId),
            let detail = try? await composition.runtime.library.conversation(id: conversationId)
        else { return nil }

        var mediaBeforeMemberMs: Int64 = 0
        var mediaOffsetMs: Int64?
        for member in detail.members {
            guard let meta = composition.files.readMeta(member.segmentId) else { continue }
            if member.segmentId == citedId {
                mediaOffsetMs = mediaDurationMs(meta) > 0 ? mediaBeforeMemberMs : nil
                break
            }
            mediaBeforeMemberMs += mediaDurationMs(meta)
        }
        let meta = composition.files.readMeta(citedId)
        return CitationTarget(
            conversationId: conversationId,
            conversationTitle: detail.row.title ?? "Conversation",
            segmentId: citedId,
            mediaOffsetMs: mediaOffsetMs,
            startedAt: meta.map {
                Date(timeIntervalSince1970: Double($0.startTimeMs) / 1000)
            }
        )
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
        let produced = try await produce(
            conversationId: conversationId, template: template, customPrompt: customPrompt)
        let stored = try await composition.notes.create(
            conversationId: conversationId,
            templateId: template.id,
            title: template.title,
            body: produced.body,
            citationsJson: produced.citationsJson,
            provider: produced.provider,
            model: produced.model,
            nowMs: composition.clock.nowMs
        )
        try? await composition.donator.donateNote(
            id: stored.id, title: stored.title, body: stored.body,
            createdAtMs: stored.createdAtMs
        )
        let title = await self.title(of: conversationId) ?? "Conversation"
        return Self.display(stored, conversationTitle: title)
    }

    /// One model run over a conversation's transcripts. Split out from `generate` so
    /// `regenerate` can write the result back onto the EXISTING note instead of creating a
    /// second one and deleting the first.
    private struct ProducedNote {
        var body: String
        var citationsJson: String
        var provider: String?
        var model: String?
    }

    private func produce(
        conversationId: String, template: NoteTemplate, customPrompt: String?
    ) async throws -> ProducedNote {
        let segmentIds = await members(of: conversationId)
        let prompt = Self.prompt(for: template, customPrompt: customPrompt)
        // A citing template labels each member "[1]", "[2]" … in the order they were recorded,
        // and the model cites those numbers. That labelling is the whole reason a saved note
        // can point back at a moment: without it the notes carried no citations at all, so
        // every chip, the moments footer and the tap-through were dead weight on screen.
        var citationNumber = 0
        let excerpts = segmentIds.compactMap { segmentId -> TranscriptExcerpt? in
            guard let transcript = composition.transcripts.load(segmentId),
                !transcript.text.isEmpty
            else { return nil }
            citationNumber += 1
            let meta = composition.files.readMeta(segmentId)
            return TranscriptExcerpt(
                segmentId: segmentId,
                text: transcript.text,
                startTimeMs: meta.map { Int64($0.startTimeMs) },
                timeLabel: meta.map {
                    TimeFmt.time(Date(timeIntervalSince1970: Double($0.startTimeMs) / 1000))
                },
                citationNumber: prompt.citesSources ? citationNumber : nil
            )
        }
        let result = try await composition.aiRouter.run(
            AiRunRequest(
                requestId: UUID().uuidString.lowercased(),
                prompt: prompt,
                transcripts: excerpts
            )
        )
        // The note is rendered verbatim, so the chips carry the model's OWN numbers.
        let citations = prompt.citesSources
            ? renderedAnswerCitations(result.text, sourceIds: excerpts.map(\.segmentId))
            : []
        return ProducedNote(
            body: result.text,
            citationsJson: Self.citationsJson(citations),
            provider: result.providerId,
            model: result.modelUsed
        )
    }

    /// Rewrites the note IN PLACE. The screen that asked for this is addressing the note by its
    /// route id, so a regeneration that minted a new id (and deleted the old row) left that
    /// screen pointing at nothing: Edit → Save silently discarded the user's text and the note
    /// appeared to vanish, and Delete Note deleted an already-dead row while the regenerated
    /// note stayed in the library.
    func regenerate(noteId: String) async throws -> NoteDisplay {
        guard let existing = try await composition.notes.get(id: noteId) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let templates = try await templates()
        let template =
            templates.first { $0.id == existing.templateId }
            ?? NoteTemplate(id: existing.templateId, title: existing.title)
        let produced = try await produce(
            conversationId: existing.conversationId, template: template,
            customPrompt: template.prompt
        )
        let nowMs = composition.clock.nowMs
        try await composition.notes.replaceContent(
            id: noteId,
            title: existing.title,
            body: produced.body,
            citationsJson: produced.citationsJson,
            provider: produced.provider,
            model: produced.model,
            nowMs: nowMs
        )
        guard let stored = try await composition.notes.get(id: noteId) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try? await composition.donator.donateNote(
            id: stored.id, title: stored.title, body: stored.body,
            createdAtMs: stored.createdAtMs
        )
        let title = await self.title(of: existing.conversationId) ?? "Conversation"
        return Self.display(stored, conversationTitle: title)
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

    static func citationsJson(_ citations: [AskCitation]) -> String {
        guard let data = try? JSONEncoder().encode(citations) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
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

    func assignedPerson(conversationId: String, label: String) async throws -> Person? {
        try await composition.people.assignments(forConversation: conversationId)
            .first { $0.label == label }
            .map { Person(id: $0.personId, name: $0.personName) }
    }

    /// Q17: one row update in `people`, and every conversation assigned to them follows,
    /// because assignments reference the person by id and never copy the name.
    func renamePerson(id: String, to newName: String) async throws {
        try await composition.people.renamePerson(id: id, to: newName)
    }

    func unassign(conversationId: String, label: String) async throws {
        try await composition.people.unassign(conversationId: conversationId, label: label)
    }

    func deletePerson(id: String) async throws {
        try await composition.people.deletePerson(id: id)
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
