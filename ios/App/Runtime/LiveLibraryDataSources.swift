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
            notes: world, tagEditor: world, people: world,
            followUps: LiveFollowUps(composition: composition, world: world)
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

    /// Batch-decodes transcripts off the main actor. Every screen-facing path in this file runs
    /// on the main actor, and `FileTranscriptStore.load` is a synchronous read + JSON decode of
    /// word-level timing arrays — per-member, that is exactly the work that made scrolling and
    /// typing stutter whenever anything walked a conversation.
    static func loadTranscripts(
        _ segmentIds: [String], store: FileTranscriptStore
    ) async -> [String: SegmentTranscript] {
        await Task.detached(priority: .userInitiated) {
            var loaded: [String: SegmentTranscript] = [:]
            for id in segmentIds {
                if let transcript = store.load(id) { loaded[id] = transcript }
            }
            return loaded
        }.value
    }

    /// What one walk over a conversation's members produced.
    struct WalkedMembers: Sendable {
        var transcript: [TranscriptItem] = []
        var missingTicks: [Double] = []
        /// Total STORED audio across the members — the player's clock, not the wall span.
        var mediaMs: Int64 = 0
        var provider: String?
        var transcribedAtMs: Int64?
        var zone: TimeZone?
    }

    /// Turns the loaded metas and transcripts into the screen's rows — OFF the main actor.
    ///
    /// Decoding was moved off main a while ago; this loop was not, and it is the expensive half.
    /// Measured against the largest real transcript in the 2026-09-09 backup (24,854 words),
    /// `TranscriptItems.member` alone is 136 ms for ONE member on a Mac — a phone is slower, a
    /// long conversation has several members, and the screen re-runs the whole thing on every
    /// database tick it observes. That is a main thread blocked for a second at a time while
    /// somebody is reading, which is exactly what "the app gets unresponsive in a longer
    /// conversation" is.
    static func walkMembers(
        _ memberIds: [String],
        metas: [String: SegmentMeta],
        transcripts: [String: SegmentTranscript],
        assignments: [SpeakerAssignment]
    ) async -> WalkedMembers {
        await Task.detached(priority: .userInitiated) {
            var result = WalkedMembers()
            for segmentId in memberIds {
                guard let meta = metas[segmentId] else { continue }
                let stored = transcripts[segmentId]
                if let stored {
                    result.provider = stored.providerId
                    result.transcribedAtMs = max(result.transcribedAtMs ?? 0, stored.createdAtMs)
                }
                if result.zone == nil { result.zone = TranscriptItems.timeZone(meta) }
                // `TranscriptSegment`/`TranscriptWord` exist in both Transcription (what the
                // provider produced) and SearchKit (what the timeline formatter reads); bridge
                // them.
                let built = TranscriptItems.member(
                    segmentId: segmentId,
                    meta: meta,
                    segments: (stored?.segments ?? []).map {
                        SearchKit.TranscriptSegment(
                            text: $0.text, startMs: $0.startMs, endMs: $0.endMs,
                            speaker: $0.speaker)
                    },
                    words: (stored?.words ?? []).map {
                        SearchKit.TranscriptWord(
                            text: $0.text, startMs: $0.startMs, endMs: $0.endMs)
                    },
                    assignments: assignments,
                    mediaBeforeMemberMs: result.mediaMs,
                    // Durable transcripts are timed against the STORED audio: the processor
                    // decodes the frame log and hands that to the provider, so gaps are simply
                    // absent from what it heard. Reading those offsets as wall time (which is
                    // what this did before the two clocks were told apart) compressed every
                    // transcript position by the gap ratio — on a silence-suppressed recording,
                    // by half or more.
                    timebase: .media
                )
                let before = result.mediaMs
                result.transcript.append(contentsOf: built.items)
                result.missingTicks.append(
                    contentsOf: built.missingMediaOffsets.map { Double(before + $0) })
                result.mediaMs += built.mediaMs
            }
            return result
        }.value
    }

    /// Same hop for the sidecar metas of a conversation's members.
    static func loadMetas(
        _ segmentIds: [String], files: SegmentFileReader
    ) async -> [String: SegmentMeta] {
        await Task.detached(priority: .userInitiated) {
            var loaded: [String: SegmentMeta] = [:]
            for id in segmentIds {
                if let meta = files.readMeta(id) { loaded[id] = meta }
            }
            return loaded
        }.value
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
        // Off-main: the synchronous variant runs the whole FTS query on the caller's thread,
        // and this is called from the main actor on (debounced) keystrokes.
        let index = composition.index
        let hits =
            (try? await index.searchOffMain(
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
        // Everything, not just what is open: search is where you go for something you
        // half-remember, and "did I already tick that off?" is exactly that question. A
        // completed or filed-away follow-up that cannot be found is a follow-up that looks
        // deleted.
        let followUps = try await composition.followUps.list(scope: .all).filter { followUp in
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

        // One off-main pass for every member's sidecar and transcript: an hour-long conversation
        // is megabytes of word-timing JSON, and this used to decode all of it on the main actor
        // on every DB tick the open conversation observed.
        let memberIds = detail.members.map(\.segmentId)
        let metas = await Self.loadMetas(memberIds, files: composition.files)
        let storedTranscripts = await Self.loadTranscripts(memberIds, store: composition.transcripts)

        let walked = await Self.walkMembers(
            memberIds, metas: metas, transcripts: storedTranscripts, assignments: assignments)
        let transcript = walked.transcript
        let missingTicks = walked.missingTicks
        let provider = walked.provider
        let transcribedAtMs = walked.transcribedAtMs
        let zone = walked.zone

        // The scrubber measures STORED AUDIO. Using the wall span instead (a 1 hr 4 min
        // conversation holding 33 min of audio) made the player claim time that does not
        // exist, and every position on it was wrong by however much was missing.
        let duration = walked.mediaMs
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
            timeZone: zone ?? .current,
            startedAt: start,
            // A live conversation has no end yet; the scrubber says "now" rather than naming the
            // last moment audio happened to arrive.
            endedAt: source.isLive ? nil : end
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

    // --- boundaries (split / join) ---------------------------------------------------------

    /// Every member except the first is a place this conversation could be cut, because a member
    /// is exactly a stretch the receiver already treats as one piece — a cut anywhere else would
    /// land inside a segment, which grouping cannot express.
    func boundaries(id: String) async throws -> ConversationBoundariesDisplay {
        guard let detail = try? await composition.runtime.library.conversation(id: id) else {
            return .none
        }
        let memberIds = detail.members.map(\.segmentId)
        guard let firstMemberId = memberIds.first else { return .none }
        let metas = await Self.loadMetas(memberIds, files: composition.files)
        let overrides = BoundaryOverrideStore(db: composition.database)
        let decisions = (try? await overrides.all()) ?? [:]
        let queries = ConversationQueries(db: composition.database)
        let startReason = try? await queries.startReason(ofConversation: id)

        let conversationStartMs = detail.row.startMs
        let points: [ConversationBoundaryPoint] = memberIds.dropFirst().compactMap { memberId in
            guard let meta = metas[memberId] else { return nil }
            let startMs = ConversationGrouper.segmentStartMs(meta)
            return ConversationBoundaryPoint(
                id: memberId,
                startedAt: Date(timeIntervalSince1970: Double(startMs) / 1000),
                offsetMs: max(0, startMs - conversationStartMs),
                isSplit: decisions[memberId] == .split
            )
        }
        // Something to join BACK to: an earlier conversation has to exist. Asked of the listing
        // rather than inferred from `startReason` being nil, which is also nil for everything
        // grouped before that column existed and would offer the join on conversations that
        // have nothing behind them.
        let sections = (try? await composition.runtime.library.library()) ?? []
        let hasPrevious = sections.contains { section in
            section.rows.contains { $0.startMs < conversationStartMs }
        }
        return ConversationBoundariesDisplay(
            startReason: startReason,
            canJoinWithPrevious: hasPrevious,
            isJoinedWithPrevious: decisions[firstMemberId] == .join,
            points: points
        )
    }

    func setSplit(atSegmentId segmentId: String, on: Bool) async throws {
        let overrides = BoundaryOverrideStore(db: composition.database)
        try await overrides.set(segmentId: segmentId, decision: on ? .split : nil)
        try await regroupAfterBoundaryChange()
    }

    func setJoinWithPrevious(conversationId: String, on: Bool) async throws {
        guard
            let detail = try? await composition.runtime.library.conversation(id: conversationId),
            let firstMemberId = detail.members.first?.segmentId
        else { return }
        let overrides = BoundaryOverrideStore(db: composition.database)
        try await overrides.set(segmentId: firstMemberId, decision: on ? .join : nil)
        try await regroupAfterBoundaryChange()
    }

    /// Grouping is derived, so a decision only becomes visible once it is recomputed. Doing it
    /// here rather than waiting for the next pipeline pass is the difference between a switch
    /// that works and one that appears to do nothing for a few minutes.
    private func regroupAfterBoundaryChange() async throws {
        try await composition.runtime.enrichment.regroupPass()
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
    /// Off the main actor: `listSegments()` decodes every sidecar in the spool, and this used to
    /// run as a computed property on every render of the Ask screen — every keystroke in the
    /// composer paid a full directory scan on the main thread.
    func hasContent() async -> Bool {
        let files = composition.files
        return await Task.detached(priority: .userInitiated) { files.hasAnySegment() }.value
    }

    func recentThreads() async throws -> [AskThread] {
        try await composition.runtime.library.recentAskThreads()
    }

    func ask(question: String, thread: AskThread?, scope: AskScope) async throws -> AskEntry {
        let kitScope = scope.kitScope
        let nowMs = composition.clock.nowMs
        let priorTurns = thread?.turns ?? []
        let threadId = thread?.id
        // The spool scan and every transcript decode stay off the main actor: an Everything-scoped
        // question reads the whole archive, and doing that inline froze the UI for the entire
        // load right as the question was sent.
        let files = composition.files
        let allMetas = await Task.detached(priority: .userInitiated) { files.listSegments() }.value
        let metas = segmentsInAskScope(allMetas, scope: kitScope, nowMs: nowMs)
        // A conversation-scoped question narrows to that conversation's members.
        let scoped: [SegmentMeta]
        if case .conversation(let id, _) = scope {
            let ids = Set(await members(of: id))
            scoped = allMetas.filter { ids.contains($0.segmentId) }
        } else {
            scoped = metas
        }

        // Kept so the stretch cutter below does not decode every one of these a second time.
        let loaded = await Self.loadTranscripts(
            scoped.map(\.segmentId), store: composition.transcripts)
        var excerpts: [TranscriptExcerpt] = []
        var gapSummaries: [String: String?] = [:]
        for meta in scoped {
            guard let transcript = loaded[meta.segmentId], !transcript.text.isEmpty
            else { continue }
            // `segmentStartMs`, not `startTimeMs`: the latter is the STREAM's birth, so every
            // mid-stream segment is filed early by `firstSampleIndex` samples — across this
            // library a median of 30 min, p90 6 h 24 m, worst 19 h 33 m, with 502 of 767
            // segments off by over a minute. This is the date Ask puts in front of the model
            // and prints beside the answer, so it was answering "what did I say last night"
            // with material from the wrong evening.
            let startMs = ConversationGrouper.segmentStartMs(meta)
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
                coverage: nil,
                threadId: threadId,
                nowMs: nowMs
            )
        }

        // Read the whole scope, in the order it happened. Retrieval used to choose twelve
        // segments here; it now only decides what to SACRIFICE if the scope will not fit even
        // as a sweep (`AskCorpusPlanner`), so an answer of "nothing was recorded about that"
        // is backed by having actually read the range.
        let ordered = excerpts.sorted { ($0.startTimeMs ?? 0) < ($1.startTimeMs ?? 0) }
        let budget = await askBudget(
            mode: composition.settings.aiMode, modelId: composition.settings.aiModel)
        let stretches = citableStretches(
            of: ordered.compactMap { excerpt in
                loaded[excerpt.segmentId].map { (excerpt.segmentId, $0) }
            },
            metas: Dictionary(scoped.map { ($0.segmentId, $0) }, uniquingKeysWith: { first, _ in first }))
        // Two signals, one rule: keyword evidence ranks exactly as it always has, and the
        // semantic pass may only rescue a batch keyword could not tell apart from its
        // neighbours (`AskRecallPolicy.keywordFirst`). Nil when the scope will be read whole
        // or swept in full — then there is nothing to rank and nothing is asked of either index.
        let recall = await recallSignals(
            question: question, priorTurns: priorTurns, excerpts: ordered, budget: budget)
        let policy = AskRecallPolicy.keywordFirst
        let plan = AskCorpusPlanner.plan(
            stretches: stretches,
            budget: budget,
            relevance: recall?.signals.relevance ?? { _ in .none },
            policy: policy)
        if let recall {
            recordRecallExperiment(
                question: question, recall: recall, plan: plan, policy: policy, nowMs: nowMs)
        }

        let whenLabels = Dictionary(
            ordered.map { ($0.segmentId, $0.timeLabel) }, uniquingKeysWith: { first, _ in first })
        // A frozen copy: the map above filled `gapSummaries` as a `var`, and a `@Sendable`
        // function may only capture values that no longer change.
        let frozenGapSummaries = gapSummaries
        @Sendable func render(_ batch: [CitableExcerpt]) -> String {
            composition.askRetriever.formatForPrompt(
                stretches: batch,
                whenLabel: { whenLabels[$0.segmentId] ?? nil },
                gapSummary: { frozenGapSummaries[$0] ?? nil })
        }

        let header = askNowContext(nowMs: nowMs, scopeDescription: kitScope.displayName)
        let threadContext = askThreadContext(priorTurns)
        let answer: String
        if plan.isSinglePass {
            var content = header + "\n" + plan.coverage.promptLine
            if let threadContext { content += "\n\n\(threadContext)" }
            content += "\n\nQUESTION: \(question)\n\nTRANSCRIPTS:\n"
                + render(plan.batches.first ?? [])
            answer = try await run(prompt: AiPromptTemplates.ask, content: content)
        } else {
            answer = try await sweep(
                plan: plan, question: question, header: header,
                threadContext: threadContext, render: render)
        }

        // The answer card shows the model's text verbatim, so a chip reading "2" has to be
        // the segment the prompt called [2]. Renumbering by first appearance (what
        // `parseGroundedAnswer` does, for its own re-rendered lines) sent chips to the wrong
        // moment whenever an answer's first citation was not [1].
        return try await save(
            question: question,
            answer: answer,
            citations: renderedAnswerCitations(answer, sources: plan.stretches),
            scope: kitScope,
            coverage: plan.coverage,
            threadId: threadId,
            nowMs: nowMs
        )
    }

    private func run(prompt: AiPromptTemplate, content: String) async throws -> String {
        try await composition.aiRouter.run(
            AiRunRequest(
                requestId: UUID().uuidString.lowercased(),
                prompt: prompt,
                transcripts: [TranscriptExcerpt(segmentId: "ask", text: content)]
            )
        ).text
    }

    /// Map-reduce for a range too large to hand a model in one call: read every batch for facts
    /// bearing on the question, then answer from the gathered notes. Slower and dearer than one
    /// call, and the only way an archive-wide question stays *complete* once the archive
    /// outgrows the context window.
    private func sweep(
        plan: AskCorpusPlan,
        question: String,
        header: String,
        threadContext: String?,
        render: @escaping @Sendable ([CitableExcerpt]) -> String
    ) async throws -> String {
        let total = plan.batches.count
        // Bounded concurrency: the batches are independent, but firing a dozen large uploads at
        // once is how a phone on a train gets them all timed out at the same moment.
        var notes = [String?](repeating: nil, count: total)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func addTask(_ index: Int) {
                let batch = plan.batches[index]
                group.addTask {
                    var content = header
                    content += "\n\nQUESTION: \(question)"
                    content += "\n\nThis is part \(index + 1) of \(total) of the range."
                    content += "\n\nTRANSCRIPTS:\n" + render(batch)
                    let text = try await self.run(
                        prompt: AiPromptTemplates.askSweepFindings, content: content)
                    return (index, text)
                }
            }
            while next < min(Self.sweepConcurrency, total) {
                addTask(next)
                next += 1
            }
            while let (index, text) = try await group.next() {
                notes[index] = text
                if next < total {
                    addTask(next)
                    next += 1
                }
            }
        }

        let gathered = notes.enumerated().compactMap { index, text -> String? in
            guard let text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A part with nothing to say contributes nothing but its absence of findings —
            // which is information the synthesis pass does not need spelled out.
            guard !trimmed.isEmpty, !trimmed.uppercased().hasPrefix("NOTHING RELEVANT") else {
                return nil
            }
            return "PART \(index + 1) OF \(total):\n\(trimmed)"
        }
        guard !gathered.isEmpty else {
            return plan.coverage.isComplete
                ? "I read every conversation in that range and found nothing about that."
                : "I could not find anything about that in the part of the range I was able to "
                    + "read."
        }

        var content = header + "\n" + plan.coverage.promptLine
        if let threadContext { content += "\n\n\(threadContext)" }
        content += "\n\nQUESTION: \(question)\n\nGATHERED NOTES:\n"
            + gathered.joined(separator: "\n\n")
        return try await run(prompt: AiPromptTemplates.askSweepAnswer, content: content)
    }

    /// Model calls a sweep keeps in flight at once.
    private static let sweepConcurrency = 3

    /// The budget Ask plans against, sized by the provider that will actually answer.
    ///
    /// The ceiling belongs to the provider (its context window), not to this file: the local
    /// slot reports its own input ceiling (8,000 characters on a 4,096-token model, twice that
    /// on the iOS 27 model), and a remote slot that knows its window in tokens (Apple Private
    /// Cloud Compute) reports it too; OpenAI's window still comes from `AiModels` by model id.
    /// Each falls back to what Ask always assumed when the router cannot say.
    private func askBudget(mode: AiProcessingMode, modelId: String?) async -> AskBudget {
        switch mode {
        case .localOnly, .localFirst:
            let local =
                await composition.aiRouter.localInputChars()
                ?? OnDeviceAiProvider.defaultMaxInputChars
            return AskBudget.forMode(mode, modelId: modelId, onDeviceMaxInputChars: local)
        case .remoteOnly, .remoteFirst:
            if let tokens = await composition.aiRouter.remoteContextTokens() {
                return AskBudget.forContext(tokens: tokens)
            }
            return AskBudget.forMode(mode, modelId: modelId)
        }
    }

    /// Both index passes' findings for one question, plus what the experiment needs after
    /// the plan is made.
    private struct RecallSignals {
        let signals: AskRecallSignals
        /// Conversation id → its in-scope segment ids.
        let members: [String: [String]]
        let semanticRan: Bool
        let ms: Int
    }

    /// Relevance per segment, used ONLY to choose which batches survive when a range is too
    /// large even to sweep. Both indexes key on conversation ids (`conv-<firstMember>`), so
    /// hits are expanded to their member segments before they can match an excerpt —
    /// comparing the two namespaces directly is what silently disabled retrieval entirely.
    ///
    /// The keyword pass is the FTS index, exactly as before; the semantic pass is Core
    /// Spotlight's ranking of the same transcripts, run concurrently when the setting allows
    /// it. Nil when the scope does not overflow the ceiling.
    private func recallSignals(
        question: String,
        priorTurns: [AskEntry],
        excerpts: [TranscriptExcerpt],
        budget: AskBudget
    ) async -> RecallSignals? {
        // The scoring only matters when the scope overflows the sweep ceiling; skip both the
        // membership walk and the index round-trips entirely when it plainly does not — which
        // is every ordinary library.
        let totalChars = excerpts.reduce(0) { $0 + $1.text.count }
        guard totalChars > budget.transcriptChars * budget.maxBatches else { return nil }

        var members: [String: [String]] = [:]
        for excerpt in excerpts {
            guard let conversationId = try? await composition.runtime.library
                .conversationId(ofSegment: excerpt.segmentId)
            else { continue }
            members[conversationId, default: []].append(excerpt.segmentId)
        }

        let started = ContinuousClock.now
        // Ask for more hits than segments: one index document is a CONVERSATION, which
        // expands to however many member segments it has, and hits outside the scope drop
        // out on resolution rather than shrinking the result.
        let hits = await composition.askRetriever.recall(
            query: askRetrievalQuery(question: question, priorTurns: priorTurns),
            limit: excerpts.count * 2,
            includeSemantic: composition.settings.askSemanticRecallEnabled)
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        return RecallSignals(
            signals: AskRecallSignals.resolve(
                keyword: hits.keyword, semantic: hits.semantic,
                members: members, scope: Set(excerpts.map(\.segmentId))),
            members: members,
            semanticRan: hits.semanticRan,
            ms: ms)
    }

    /// Writes the experiment down: one log line, and the record the Diagnostics screen shows.
    /// Counts only in the log; the record carries the clipped question and no transcript text.
    private func recordRecallExperiment(
        question: String, recall: RecallSignals, plan: AskCorpusPlan,
        policy: AskRecallPolicy, nowMs: Int64
    ) {
        let record = AskRecallExperiment.measure(
            atMs: nowMs,
            question: question,
            signals: recall.signals,
            members: recall.members,
            keptSegmentIds: Set(plan.stretches.map(\.segmentId)),
            plan: plan,
            policy: policy,
            ms: recall.ms,
            semanticRan: recall.semanticRan)
        AppRuntimeLog.shared.record(record.logLine)
        AskRecallLedgerHolder.shared.append(record)
    }

    private func save(
        question: String, answer: String, citations: [AskCitation],
        scope: Intelligence.AskScope, coverage: AskCoverage?, threadId: String?, nowMs: Int64
    ) async throws -> AskEntry {
        try await saveAskAnswer(
            question: question,
            answerText: answer,
            citations: citations,
            scope: scope,
            coverage: coverage,
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

    /// The batch form, with every meta read and transcript decode off the main actor.
    func citationTitles(for citedIds: [String]) async -> [String: String] {
        let ids = Array(Set(citedIds))
        let files = composition.files
        let store = composition.transcripts
        return await Task.detached(priority: .userInitiated) {
            var titles: [String: String] = [:]
            for id in ids {
                guard let meta = files.readMeta(id) else { continue }
                titles[id] = segmentTitle(meta, transcriptText: store.load(id)?.text)
            }
            return titles
        }.value
    }

    /// A conversation's transcripts cut into citable stretches, in recording order and
    /// numbered once. Provider spans give the boundaries, so every stretch starts where
    /// someone started speaking.
    func citableStretches(of segmentIds: [String]) async -> [CitableExcerpt] {
        let transcripts = await Self.loadTranscripts(segmentIds, store: composition.transcripts)
        let metas = await Self.loadMetas(segmentIds, files: composition.files)
        return citableStretches(
            of: segmentIds.compactMap { id in transcripts[id].map { (id, $0) } }, metas: metas)
    }

    /// The same, for a caller that has already read these transcripts and metas. Ask reads every
    /// transcript in scope to build its excerpts and would otherwise decode all of them a
    /// second time here — which, on an "Everything" question over a few hundred recordings, is
    /// tens of megabytes of JSON parsed twice for one question.
    func citableStretches(
        of transcripts: [(segmentId: String, transcript: SegmentTranscript)],
        metas: [String: SegmentMeta]
    ) -> [CitableExcerpt] {
        CitableExcerpts.numbered(
            CitableExcerpts.coalesced(
                transcripts.flatMap {
                    drafts(of: $0.segmentId, transcript: $0.transcript, meta: metas[$0.segmentId])
                }))
    }

    private func drafts(of segmentId: String, transcript: SegmentTranscript, meta: SegmentMeta?)
        -> [CitableExcerptDraft]
    {
        guard !transcript.text.isEmpty, let meta else { return [] }
        // Ask's citable excerpts were the last model input still reading raw transcript text,
        // so a conversation whose transcriber looped could be cited hundreds of times on the
        // same fabricated sentence. Same collapse every other AI surface gets, via one seam in
        // `EnrichmentService`; this path builds its own excerpts and needed it explicitly.
        let transcript = transcript.withLoopedArtefactsCollapsed()
        guard !transcript.text.isEmpty else { return [] }
        // An excerpt's stamp is `segmentStartMs + span.startMs`, so BOTH halves have to be the
        // wall clock or the sum is meaningless. Neither was.
        //
        //  - `startTimeMs` is the STREAM's birth, not this segment's; `startWallMs` (which
        //    `segmentStartMs` returns) adds `firstSampleIndex` and clamps to `receivedAtMs`.
        //    Across this library the two differ by a median of 1 h.
        //  - the provider's span offsets count STORED audio, so they have to come back through
        //    the segment's gap records before they can be added to a wall anchor. Watch-side
        //    silence suppression (PebbleOS a47acac74) withholds 4.1-13.8% of airtime, and on
        //    the real library reading those offsets as wall time puts the last excerpt of a
        //    segment a median of 7.5 s early in the default mode, p90 1 m 07 s, worst 21.8 min.
        //
        // These stamps are what Ask shows beside a citation and what `citationTarget` turns
        // back into a scrubber position, so the error was visible twice: the wrong time printed
        // and the wrong moment played.
        //
        // ONLY WHERE THE RECORDS SUPPORT IT. When a segment's gaps do not account for the
        // difference between its stored audio and its elapsed wall time, `SegmentMediaClock`
        // falls back to a proportional guess, and converting on a guess re-inflates exactly the
        // phantom durations the honest-extent work removed. Measured on the 2026-09-08 backup:
        // 169 of the transcribed segments are inexact, and stretching their 14,272 turns
        // proportionally moves 4,813 of them by over a minute — the worst from 14 m 43 s to
        // 14 h 59 m. `TranscriptItems` and `ConversationBoundaryDetector.spokenRuns` both
        // decline the same way, and all three must agree or the transcript screen, the split
        // and the citation describe different recordings.
        let clock = SegmentMediaClock(meta)
        let toWall: (Int64) -> Int64 = clock.isExact ? { clock.wall(fromMedia: $0) } : { $0 }
        let startMs = ConversationGrouper.segmentStartMs(meta)
        return CitableExcerpts.split(
            segmentId: segmentId,
            segmentStartMs: startMs,
            segmentEndMs: startMs + clock.wallSpanMs,
            spans: transcript.segments.map {
                TranscriptSpan(
                    text: $0.text,
                    startMs: toWall($0.startMs),
                    endMs: toWall(max($0.endMs, $0.startMs)))
            },
            wholeText: transcript.text)
    }

    /// Resolve a citation all the way to something the UI can act on: which conversation holds
    /// the cited segment, where that segment starts on the player's scrubber (media time, gaps
    /// excluded — the same accumulation `display(id:)` walks), and when it was recorded.
    func citationTarget(for citation: AskCitation) async -> CitationTarget? {
        let citedId = citation.segmentId
        guard
            let conversationId = try? await composition.runtime.library.conversationId(
                ofSegment: citedId),
            let detail = try? await composition.runtime.library.conversation(id: conversationId)
        else { return nil }

        var mediaBeforeMemberMs: Int64 = 0
        var mediaOffsetMs: Int64?
        let metas = await Self.loadMetas(detail.members.map(\.segmentId), files: composition.files)
        for member in detail.members {
            guard let meta = metas[member.segmentId] else { continue }
            let mediaMs = mediaDurationMs(meta)
            if member.segmentId == citedId {
                // Where the cited STRETCH starts on the scrubber, not where its recording
                // does — the same wall→media conversion the transcript rows and the missing
                // ticks use, through the member's own gap records.
                //
                // This used to interpolate proportionally (a point 40% through the wall span
                // is 40% through the stored audio), which is only true when the gaps are
                // spread evenly. `SegmentMediaClock` replaced that guess for the transcript
                // screen; leaving the copy here meant tapping a citation and tapping the turn
                // it cites landed in different places on the same scrubber. Watch-side silence
                // suppression (PebbleOS a47acac74) makes the disagreement routine rather than
                // occasional: the withheld quiet is 4.1-13.8% of airtime, concentrated in the
                // stretches where nobody is talking, which is exactly where "evenly spread"
                // stops being true.
                //
                // The anchor is `ConversationGrouper.segmentStartMs`, not `startTimeMs`, for
                // the reason `SegmentMeta.startWallMs` documents: `startTimeMs` is the STREAM's
                // birth, so for every mid-stream segment it is early by `firstSampleIndex`
                // samples — a median of 1 h across this library. Subtracting it from a wall
                // citation put `into` past the end of the span and pinned the target at the
                // segment's last sample.
                guard mediaMs > 0 else { break }
                let memberStartMs = ConversationGrouper.segmentStartMs(meta)
                let clock = SegmentMediaClock(meta)
                let into = min(
                    max((citation.startMs ?? memberStartMs) - memberStartMs, 0), clock.wallSpanMs)
                // Untouched on the way in, untouched on the way out. `drafts` above (and
                // `TranscriptItems`) leave an inexact segment's offsets on the media clock
                // rather than acting on the proportional guess, so converting back here would
                // apply an inverse that was never applied — on the 2026-09-08 backup that is
                // 169 segments and 4,813 turns that move by over a minute, worst 14 h 44 m.
                mediaOffsetMs =
                    mediaBeforeMemberMs
                    + (clock.isExact ? clock.media(fromWall: into) : min(into, clock.mediaSpanMs))
                break
            }
            mediaBeforeMemberMs += mediaMs
        }
        let meta = metas[citedId]
        // Same anchor as everything else that says when a recording happened (see
        // `SegmentMeta.startWallMs`): `startTimeMs` is the stream's birth and files a
        // mid-stream segment a median of 1 h early.
        let startedAtMs = citation.startMs ?? meta.map { ConversationGrouper.segmentStartMs($0) }
        return CitationTarget(
            conversationId: conversationId,
            conversationTitle: detail.row.title ?? "Conversation",
            focus: TranscriptFocus(
                segmentId: citedId, startMs: citation.startMs, endMs: citation.endMs),
            mediaOffsetMs: mediaOffsetMs,
            startedAt: startedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        )
    }
}

// MARK: - NotesDataSource

extension LiveWorld: NotesDataSource {
    func notes(conversationId: String) async throws -> [NoteDisplay] {
        let stored = try await composition.notes.list(conversationId: conversationId)
        let title = await self.title(of: conversationId) ?? "Conversation"
        return stored.map { display($0, conversationTitle: title) }
    }

    func note(id: String) async throws -> NoteDisplay? {
        guard let stored = try await composition.notes.get(id: id) else { return nil }
        let title = await self.title(of: stored.conversationId) ?? "Conversation"
        return display(stored, conversationTitle: title)
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
        return display(stored, conversationTitle: title)
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
        // A citing template numbers STRETCHES — a paragraph of speech each, not whole
        // recordings. That is what makes a chip land on the lines the point came from and the
        // player start there; numbering by member sent every citation to the top of a
        // twenty-minute segment.
        let stretches = prompt.citesSources ? await citableStretches(of: segmentIds) : []
        // Off-main for the same reason as `ask()`: a fallback over a long conversation decodes
        // every member transcript, and "Generate note" should not freeze the screen doing it.
        let fallbackTranscripts = stretches.isEmpty
            ? await Self.loadTranscripts(segmentIds, store: composition.transcripts) : [:]
        let fallbackMetas = stretches.isEmpty
            ? await Self.loadMetas(segmentIds, files: composition.files) : [:]
        let excerpts =
            stretches.isEmpty
            ? segmentIds.compactMap { segmentId -> TranscriptExcerpt? in
                guard let transcript = fallbackTranscripts[segmentId],
                    !transcript.text.isEmpty
                else { return nil }
                let meta = fallbackMetas[segmentId]
                // `segmentStartMs` (= `startWallMs`), not the raw field: `startTimeMs` anchors
                // sample index 0 of the STREAM, so a rotation successor or a reattach carries
                // the stream's birth clock. Over the 2026-09-08 backup that is a different
                // instant for 602 of 774 segments, 594 of them by more than a minute (median
                // 1 h 59 m, worst 24 h 21 m). This is the clock time printed into the note
                // prompt, so the model was told a morning conversation happened the night
                // before — the citing branch below has used the right anchor since
                // `citableStretches`; only this no-stretches fallback was left behind.
                let startMs = meta.map { ConversationGrouper.segmentStartMs($0) }
                return TranscriptExcerpt(
                    segmentId: segmentId,
                    text: transcript.text,
                    startTimeMs: startMs,
                    timeLabel: startMs.map {
                        TimeFmt.time(Date(timeIntervalSince1970: Double($0) / 1000))
                    }
                )
            }
            : stretches.map { stretch in
                TranscriptExcerpt(
                    segmentId: stretch.segmentId,
                    text: stretch.text,
                    startTimeMs: stretch.startMs,
                    endTimeMs: stretch.endMs,
                    timeLabel: TimeFmt.time(
                        Date(timeIntervalSince1970: Double(stretch.startMs) / 1000)),
                    citationNumber: stretch.number
                )
            }
        // A conversation with nothing transcribed yet is a CRASH without this. `AiRunRequest.init`
        // asserts `!transcripts.isEmpty` — a `precondition`, so it traps in release too — and
        // "Notes" is reachable from any conversation, including one recorded a minute ago whose
        // transcription is still queued or has failed. The dock already has a sentence for this
        // exact situation ("There is no transcript for this conversation yet"), keyed off
        // `fileNoSuchFile`; it just had no way to be thrown.
        guard !excerpts.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let result = try await composition.aiRouter.run(
            AiRunRequest(
                requestId: UUID().uuidString.lowercased(),
                prompt: prompt,
                transcripts: excerpts
            )
        )
        // The note is rendered verbatim, so the chips carry the model's OWN numbers.
        let citations = renderedAnswerCitations(result.text, sources: stretches)
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
        return display(stored, conversationTitle: title)
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

    private func display(_ note: Note, conversationTitle: String) -> NoteDisplay {
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
            momentsLabel: Self.momentsLabel(
                citations,
                startedAt: { [files = composition.files] segmentId in
                    // The footer under a saved note names the clock times its citations point
                    // at, so it has to use the SAME anchor `citationTarget` opens the player
                    // with (`segmentStartMs`/`startWallMs`). On the raw `startTimeMs` the
                    // footer and the player disagreed for 602 of the backup's 774 segments —
                    // "2 moments · 9:36 PM, 9:51 PM" under a note whose taps land hours away.
                    files.readMeta(segmentId).map {
                        Date(
                            timeIntervalSince1970:
                                Double(ConversationGrouper.segmentStartMs($0)) / 1000)
                    }
                }),
            citations: citations
        )
    }

    /// "2 moments · 9:36 PM, 9:51 PM" — the cited segments, in time order.
    ///
    /// This was `momentsLabel: ""` at the one live construction while `MockWorld` built the real
    /// line, so the footer under every saved note was blank on a real phone and populated in
    /// every artboard. Empty when nothing is cited, or when retention has taken the segments the
    /// citations name — a moment we can no longer place is not one to invent a time for.
    static func momentsLabel(
        _ citations: [AskCitation], startedAt: (String) -> Date?
    ) -> String {
        let times = Set(citations.map(\.segmentId))
            .compactMap(startedAt)
            .sorted()
        guard !times.isEmpty else { return "" }
        return Copy.Ask.moments(times.map(TimeFmt.time), naming: 3)
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


// MARK: - FollowUpsDataSource

/// Its own type rather than another face of `LiveWorld`: follow-ups need `delete(id:)`,
/// `add(...)` and `updates()`, and every one of those already means something else on the
/// conversation seam. One object answering to both would have to spell each of them oddly.
@MainActor
final class LiveFollowUps {
    private let composition: AppComposition
    /// The one `LiveWorld` the rest of the app uses — resolving a citation is its job, and
    /// building a second one per tap would be a second copy of its pending-delete state.
    private let world: LiveWorld

    init(composition: AppComposition, world: LiveWorld) {
        self.composition = composition
        self.world = world
    }

    private func title(of conversationId: String) async -> String? {
        let detail = try? await composition.runtime.library.conversation(id: conversationId)
        return detail?.row.title
    }
}

extension LiveFollowUps: FollowUpsDataSource {
    func items(scope: FollowUpListScope) async throws -> [FollowUpItem] {
        let rows = try await composition.followUps.list(
            scope: scope.storeScope, nowMs: composition.clock.nowMs)
        return await withTitles(rows)
    }

    func item(id: String) async throws -> FollowUpItem? {
        guard let row = try await composition.followUps.load(id: id) else { return nil }
        return await withTitles([row]).first
    }

    /// One conversation lookup per distinct source, not per row: a list of twelve follow-ups
    /// from three conversations is three reads, and a row without a title would otherwise have
    /// to say "Conversation" — which tells the reader nothing about where it came from.
    private func withTitles(_ rows: [FollowUp]) async -> [FollowUpItem] {
        var titles: [String: String] = [:]
        for conversationId in Set(rows.compactMap(\.sourceConversationId)) {
            if let title = await title(of: conversationId) { titles[conversationId] = title }
        }
        return rows.map { row in
            FollowUpItem(
                id: row.id,
                text: row.text,
                done: row.done,
                dueAtMs: row.dueAtMs,
                priority: row.priority,
                quote: row.quote,
                why: row.why,
                origin: row.origin,
                createdAtMs: row.createdAtMs,
                completedAtMs: row.completedAtMs,
                archivedAtMs: row.archivedAtMs,
                snoozedUntilMs: row.snoozedUntilMs,
                sourceConversationId: row.sourceConversationId,
                sourceConversationTitle: row.sourceConversationId.flatMap { titles[$0] },
                sourceSegmentId: row.sourceSegmentId,
                sourceStartMs: row.sourceStartMs,
                sourceEndMs: row.sourceEndMs)
        }
    }

    func followUpUpdates() -> AsyncStream<Void> {
        let stream = composition.runtime.library.observeOpenFollowUps()
        return AsyncStream { continuation in
            let task = Task {
                for await _ in stream { continuation.yield(()) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    func add(text: String, dueAtMs: Int64?) async throws -> String {
        let item = try await composition.followUps.add(
            text: text, dueAtMs: dueAtMs, nowMs: composition.clock.nowMs)
        // Findable from the moment it exists. Extraction donates what it writes; a follow-up
        // somebody typed themselves is at least as worth finding.
        try? await composition.donator.donateFollowUp(
            id: item.id, text: item.text, createdAtMs: item.createdAtMs)
        return item.id
    }

    func setDone(id: String, done: Bool) async throws {
        try await composition.followUps.setDone(id: id, done, nowMs: composition.clock.nowMs)
    }

    func setText(id: String, text: String) async throws {
        try await composition.followUps.setText(id: id, text, nowMs: composition.clock.nowMs)
        // Otherwise the old wording is what search keeps finding.
        guard let row = try await composition.followUps.load(id: id) else { return }
        try? await composition.donator.donateFollowUp(
            id: row.id, text: row.text, sourceConversationId: row.sourceConversationId,
            createdAtMs: row.createdAtMs)
    }

    func setDue(id: String, dueAtMs: Int64?) async throws {
        try await composition.followUps.setDue(id: id, dueAtMs)
    }

    func setPriority(id: String, priority: FollowUpPriority) async throws {
        try await composition.followUps.setPriority(id: id, priority)
    }

    func snooze(id: String, untilMs: Int64?) async throws {
        try await composition.followUps.snooze(id: id, until: untilMs)
    }

    func setArchived(id: String, archived: Bool) async throws {
        try await composition.followUps.setArchived(
            id: id, archived, nowMs: composition.clock.nowMs)
    }

    func delete(id: String) async throws {
        try await composition.followUps.delete(id: id)
        // Through the donator, not the raw index: `composition.index` is FTS only, so removing
        // there left the Core Spotlight document behind and the deleted item kept turning up
        // in system search.
        try? await composition.donator.remove(id: id, kind: .followUp)
    }

    func restore(_ item: FollowUpItem) async throws {
        try await composition.followUps.upsertExtracted(
            FollowUp(
                id: item.id, text: item.text, done: item.done,
                sourceConversationId: item.sourceConversationId,
                sourceSegmentId: item.sourceSegmentId, createdAtMs: item.createdAtMs,
                quote: item.quote, why: item.why, dueAtMs: item.dueAtMs,
                priority: item.priority, sourceStartMs: item.sourceStartMs,
                sourceEndMs: item.sourceEndMs, completedAtMs: item.completedAtMs,
                archivedAtMs: item.archivedAtMs, snoozedUntilMs: item.snoozedUntilMs,
                origin: item.origin))
    }

    /// The recording, cued to the words that created the item.
    ///
    /// The stored offsets are relative to the SEGMENT (that is what the transcriber reports),
    /// while a citation is wall-clock — so the segment's own start is added here. Getting that
    /// wrong opens the recording at the top and quietly looks like the timestamp is broken.
    ///
    /// Both halves of that sum were wrong, in the same direction, and the errors compounded.
    /// The transcriber's offsets count STORED audio, so they have to come back through the
    /// segment's gap records before they mean anything on a wall clock; and `startTimeMs` is
    /// the stream's birth rather than this segment's (median 30 min early over this library).
    /// Watch-side silence suppression (PebbleOS a47acac74) makes the first of those grow from
    /// occasional to routine: 4.1-13.8% of airtime is now withheld, concentrated in the pauses.
    func source(of id: String) async -> CitationTarget? {
        guard let row = try? await composition.followUps.load(id: id),
            let segmentId = row.sourceSegmentId
        else { return nil }
        let meta = composition.files.readMeta(segmentId)
        let clock = meta.map { SegmentMediaClock($0) }
        func wallMs(_ mediaOffsetMs: Int64) -> Int64? {
            guard let meta, let clock else { return nil }
            // And only where the gap records explain the recording. On an inexact segment the
            // clock's fallback is a proportional guess; acting on it here sends the player to a
            // moment nothing was said at (169 segments on the 2026-09-08 backup, 4,813 turns
            // moved by over a minute, worst 14 h 44 m). Left alone, the offset at least sits
            // where the audio does — the same choice `TranscriptItems` and `spokenRuns` make.
            let offset = clock.isExact ? clock.wall(fromMedia: mediaOffsetMs) : mediaOffsetMs
            return ConversationGrouper.segmentStartMs(meta) + offset
        }
        let citation = AskCitation(
            segmentId: segmentId,
            number: 1,
            startMs: row.sourceStartMs.flatMap(wallMs),
            endMs: row.sourceEndMs.flatMap(wallMs))
        return await world.citationTarget(for: citation)
    }

    /// Whether anything is set up to propose follow-ups at all — a local-only mode with no
    /// on-device model available, or remote AI without consent, means the list will stay as
    /// empty as the person left it, and the empty state should say so rather than implying
    /// nothing in their week was worth remembering.
    var automaticProposalsEnabled: Bool {
        switch composition.settings.aiMode {
        case .localOnly:
            // A capability question about THIS device, not a constant. It used to return false
            // everywhere, and that was correct at the time: `OnDeviceAiProvider.run` refused
            // anything tagged `requiresStructuredOutput` before it looked at the model at all.
            // The refusal is now conditional on the model actually lacking guided generation
            // (`OnDeviceStructuredOutput.swift`), so on a device with Apple Intelligence on,
            // local proposals are real — fewer and rougher than the cloud's, which is what
            // `proposalsAreOnDevice` below exists to say out loud, but real. On a device
            // without it, or with it still downloading, the answer is still false and the empty
            // state still says the app is not looking.
            return OnDeviceAiCapability.canProposeFollowUps
        case .remoteOnly, .remoteFirst, .localFirst:
            return composition.settings.hasApiKey(for: .openAi)
        }
    }

    /// True when the proposals on this list were found by the on-device reader rather than the
    /// cloud one. The two are not the same product and the screen must not imply they are:
    /// measured over twenty hand-labelled conversations from this user's own recordings, the
    /// on-device path returned four items where a careful reader finds eight — it misses most
    /// of them, and it never proposes a due date. That is worth having and it is not worth
    /// pretending about; `Copy.LocalFollowUps` is what says so.
    var proposalsAreOnDevice: Bool {
        composition.settings.aiMode == .localOnly && OnDeviceAiCapability.canProposeFollowUps
    }

    private func removeFollowUpFromIndex(id: String) {
        try? composition.index.remove(id: id, kind: .followUp)
    }
}

extension FollowUpListScope {
    /// The screen's vocabulary mapped onto the store's.
    var storeScope: FollowUpScope {
        switch self {
        case .open: return .open
        case .completed: return .completed
        case .archived: return .archived
        }
    }
}
