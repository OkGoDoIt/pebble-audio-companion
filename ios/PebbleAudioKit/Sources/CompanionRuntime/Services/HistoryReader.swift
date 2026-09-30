import AppDB
import Foundation
import Intelligence
import SegmentStore
import Transcription

/// History's read side over the real library (plan 7.10): gathers a day's inputs and builds it
/// with `HistoryDayBuilder`, gathers the facts weeks and months are assembled from
/// (`HistoryPeriodAssembler`), says which rows a page's digest must cover
/// (`HistoryDigestScope`), and answers the recorded range.
///
/// Every read is windowed — the segment index in memory, then indexed queries over the window's
/// ids — and transcripts are only touched through `HistorySpeechRunCache`, so a build costs what
/// its day holds, never the library. An actor: everything here runs off the main actor, and two
/// builds never run at once (the visible page and a prefetched neighbour take turns rather than
/// competing for the CPU).
public actor HistoryReader {
    public struct Sources: Sendable {
        public var database: AppDatabase
        public var recaps: DailyRecapStore
        public var audioContent: any AudioContentSource
        public var speechRuns: HistorySpeechRunCache
        public var transcripts: FileTranscriptStore
        /// The segment index (the spool's in-memory list).
        public var segments: @Sendable () async -> [SegmentMeta]
        /// Conversations inside their undo window (`DeferredDeleteBuffer.hiddenConversationIds`).
        public var hiddenConversationIds: @Sendable () async -> Set<String>
        /// The zone unstamped recordings are dated in: the phone's current one.
        public var currentZoneID: @Sendable () -> String

        public init(
            database: AppDatabase, recaps: DailyRecapStore, audioContent: any AudioContentSource,
            speechRuns: HistorySpeechRunCache, transcripts: FileTranscriptStore,
            segments: @escaping @Sendable () async -> [SegmentMeta],
            hiddenConversationIds: @escaping @Sendable () async -> Set<String> = { [] },
            currentZoneID: @escaping @Sendable () -> String = { TimeZone.current.identifier }
        ) {
            self.database = database
            self.recaps = recaps
            self.audioContent = audioContent
            self.speechRuns = speechRuns
            self.transcripts = transcripts
            self.segments = segments
            self.hiddenConversationIds = hiddenConversationIds
            self.currentZoneID = currentZoneID
        }
    }

    /// The library as one build sees it: the recordings, which zone was in effect when, and
    /// where each recording sits on the wall clock.
    public struct Library: Sendable {
        public var metas: [SegmentMeta]
        public var timeline: ZoneTimeline
        /// Each recording's wall extent (`HistorySegmentState`'s placement; a recording with no
        /// sample yet is a point at its start).
        public var extents: [String: Range<Int64>]
        public var boundsKey: HistoryBoundsKey

        /// Recordings overlapping `window`, plus — when `withNext` — the first to start at or
        /// after its end, which can carry the record of an outage inside it.
        func segments(overlapping window: Range<Int64>, withNext: Bool) -> [SegmentMeta] {
            var result: [SegmentMeta] = []
            var next: SegmentMeta?
            for meta in metas {
                let extent = extents[meta.segmentId] ?? (meta.startWallMs..<meta.startWallMs)
                let touches = extent.isEmpty
                    ? window.contains(extent.lowerBound)
                    : extent.lowerBound < window.upperBound && extent.upperBound > window.lowerBound
                if touches {
                    result.append(meta)
                } else if withNext, meta.startWallMs >= window.upperBound,
                    next.map({ meta.startWallMs < $0.startWallMs }) ?? true
                {
                    next = meta
                }
            }
            if let next { result.append(next) }
            return result
        }

        /// The hull of a day's windows, and the windows.
        func windows(of dateKey: String) -> (hull: Range<Int64>?, windows: [HistoryDayWindow]) {
            let windows = HistoryDayWindow.from(timeline.windows(of: dateKey))
            guard let lower = windows.map(\.range.lowerBound).min(),
                let upper = windows.map(\.range.upperBound).max()
            else { return (nil, windows) }
            return (lower..<upper, windows)
        }
    }

    /// One built day, before the app adds what only it knows (topics, the live line).
    public struct DayBuild: Equatable, Sendable {
        public var day: HistoryDay
        public var brief: HistoryBrief?
        /// Everything placed on the day, open and done.
        public var followUpTotal: Int
        public var followUpOpen: Int

        public init(day: HistoryDay, brief: HistoryBrief?, followUpTotal: Int, followUpOpen: Int) {
            self.day = day
            self.brief = brief
            self.followUpTotal = followUpTotal
            self.followUpOpen = followUpOpen
        }
    }

    private let sources: Sources
    private var cachedTimeline: (key: HistoryBoundsKey, zone: String, timeline: ZoneTimeline)?
    private var cachedBounds: (key: HistoryBoundsKey, zone: String, today: String, bounds: HistoryBounds)?

    public init(sources: Sources) {
        self.sources = sources
    }

    // MARK: - The library

    public func library() async -> Library {
        let metas = await sources.segments()
        let zone = sources.currentZoneID()
        let key = HistoryBoundsKey(startsMs: metas.map(\.startWallMs))
        let timeline: ZoneTimeline
        if let cached = cachedTimeline, cached.key == key, cached.zone == zone {
            timeline = cached.timeline
        } else {
            timeline = ZoneTimeline(segments: metas, currentZoneID: zone)
            cachedTimeline = (key, zone, timeline)
        }
        var extents: [String: Range<Int64>] = [:]
        extents.reserveCapacity(metas.count)
        for meta in metas {
            if let state = HistorySegmentState(meta: meta) {
                extents[meta.segmentId] = state.startMs..<state.endMs
            } else {
                extents[meta.segmentId] = meta.startWallMs..<meta.startWallMs
            }
        }
        return Library(metas: metas, timeline: timeline, extents: extents, boundsKey: key)
    }

    public func todayKey(_ library: Library, nowMs: Int64) -> String {
        library.timeline.dayKey(forMs: nowMs)
    }

    /// The recorded range, recomputed only when the number of recordings, the first or the last
    /// start, the zone or today's key changes (plan 7.10).
    public func bounds(nowMs: Int64) async -> HistoryBounds {
        let library = await library()
        let today = todayKey(library, nowMs: nowMs)
        let zone = sources.currentZoneID()
        if let cached = cachedBounds, cached.key == library.boundsKey, cached.zone == zone, cached.today == today {
            return cached.bounds
        }
        let bounds = bounds(library, nowMs: nowMs)
        cachedBounds = (library.boundsKey, zone, today, bounds)
        return bounds
    }

    public func bounds(_ library: Library, nowMs: Int64) -> HistoryBounds {
        HistoryBounds.of(
            startsMs: library.metas.map(\.startWallMs), timeline: library.timeline,
            todayDateKey: todayKey(library, nowMs: nowMs))
    }

    // MARK: - Digest scopes

    public func dayScope(_ dateKey: String, _ library: Library) -> HistoryDigestScope {
        let (hull, _) = library.windows(of: dateKey)
        guard let hull else {
            return HistoryDigestScope(window: 0..<0, segmentIds: [], recapDateKeys: [dateKey], includeTags: false)
        }
        return HistoryDigestScope(
            window: hull,
            segmentIds: library.segments(overlapping: hull, withNext: false).map(\.segmentId),
            recapDateKeys: [dateKey], includeTags: Self.readsConversationsAsCards,
            includeSummaries: Self.readsConversationsAsCards)
    }

    public func periodScope(days: [String], _ library: Library) -> HistoryDigestScope {
        let hulls = days.compactMap { library.windows(of: $0).hull }
        guard let lower = hulls.map(\.lowerBound).min(), let upper = hulls.map(\.upperBound).max() else {
            return HistoryDigestScope(window: 0..<0, segmentIds: [], recapDateKeys: days, includeTags: true)
        }
        let window = lower..<upper
        return HistoryDigestScope(
            window: window, segmentIds: library.segments(overlapping: window, withNext: false).map(\.segmentId),
            recapDateKeys: days, includeTags: true)
    }

    // MARK: - A day

    /// Builds one day. `nowMs` is set when the day is today; `isLive` when it is recording.
    public func day(
        _ dateKey: String, _ library: Library, nowMs: Int64, isToday: Bool, isLive: Bool
    ) async throws -> DayBuild {
        let inputs = try await dayInput(dateKey, library, nowMs: nowMs, isToday: isToday, isLive: isLive)
        let placed = inputs.followUps
        let day = HistoryDayBuilder.build(inputs.builder)
        let recap = try await sources.recaps.load(dateKey: dateKey)
        return DayBuild(
            day: day, brief: recap.flatMap(Self.brief), followUpTotal: placed.count,
            followUpOpen: placed.filter { !$0.record.done }.count)
    }

    /// What one day is built from.
    public struct DayInputs: Sendable {
        public var builder: HistoryDayBuilder.Input
        /// Every follow-up placed on the day.
        public var followUps: [HistoryPlacedRecord]
        /// The day's transcript turns on the wall clock, in time order — for the builder's
        /// verbatim snippets on untitled cards once it takes them (read in the same memoised
        /// pass as the speech runs).
        public var turns: [HistorySpokenTurn]
    }

    /// The builder's inputs for one day, the follow-ups placed on it, and its turns.
    public func dayInput(
        _ dateKey: String, _ library: Library, nowMs: Int64, isToday: Bool, isLive: Bool
    ) async throws -> DayInputs {
        let (hullOrNil, windows) = library.windows(of: dateKey)
        guard let hull = hullOrNil else {
            return DayInputs(
                builder: HistoryDayBuilder.Input(
                    dateKey: dateKey, windows: windows, segments: [], nowMs: isToday ? nowMs : nil),
                followUps: [], turns: [])
        }
        let metas = library.segments(overlapping: hull, withNext: true)
        let dayIds = library.segments(overlapping: hull, withNext: false).map(\.segmentId)

        let database = sources.database
        let queries = HistoryLibraryQueries(db: database)
        let hidden = await sources.hiddenConversationIds()
        async let tasksRead = queries.tasks(segmentIds: metas.map(\.segmentId))
        async let pausesRead = PauseJournal(db: database).intervals(overlappingMs: hull.lowerBound, hull.upperBound)
        async let rowsRead = ConversationQueries(db: database).rows(overlappingMs: hull)
        async let followUpsRead = FollowUpStore(db: database).history(inWallWindow: hull, segmentIds: dayIds)
        async let contentRead = sources.audioContent.spans(overlappingMs: hull)
        let tasks = try await tasksRead
        let pauses = try await pausesRead
        let rows = try await rowsRead
        let records = try await followUpsRead
        let content = try await contentRead

        // States: the queue and the recording, then whether a transcript file is really there.
        var states: [String: TranscriptionState] = [:]
        for meta in metas {
            states[meta.segmentId] = HistoryTranscriptionStates.resolve(
                segment: meta.transcriptionState, task: tasks[meta.segmentId]?.state, hasTranscriptFile: true)
        }
        let speech = await sources.speechRuns.runs(for: metas, states: states)
        var segmentStates: [HistorySegmentState] = []
        for meta in metas {
            var state = states[meta.segmentId] ?? meta.transcriptionState
            if state == .complete, !speech.withTranscript.contains(meta.segmentId) { state = .pending }
            // The queue's `lastError` is developer prose with the provider's response body in
            // it — which can be the request URL or the key itself — so it never reaches a
            // screen (B20). History carries the classified kind, a machine value; the app's copy
            // turns it into words. An unclassifiable one says nothing.
            let reason = state == .failed ? Self.failureKind(tasks[meta.segmentId]?.lastError) : nil
            if let entry = HistorySegmentState(meta: meta, state: state, failureReason: reason) {
                segmentStates.append(entry)
            }
        }

        // Conversations inside their undo window: their recorded time is drawn as deleted (plan
        // 7.10 rule 1) — left alone, their words would still be cut into cards. The builder takes
        // no other conversation input: its cards are cut from the talk itself
        // (`HistoryTalkCutter`), unless `readsConversationsAsCards` says the conversations are
        // topic-sized and are the cards.
        let members = try await queries.members(ofConversations: rows.map(\.id))
        var deleted: [HistoryDeletedSpanInput] = []
        var hiddenSegments: Set<String> = []
        for row in rows {
            let segmentIds = members[row.id] ?? []
            if hidden.contains(row.id) {
                hiddenSegments.formUnion(segmentIds)
                let extents = segmentIds.compactMap { library.extents[$0] }.filter { !$0.isEmpty }
                if extents.isEmpty {
                    deleted.append(HistoryDeletedSpanInput(startMs: row.startMs, endMs: row.endMs, cause: .user))
                } else {
                    deleted += extents.map { HistoryDeletedSpanInput(startMs: $0.lowerBound, endMs: $0.upperBound, cause: .user) }
                }
                continue
            }
        }
        let chapters = Self.readsConversationsAsCards ? Self.chapters(from: rows, hiding: hidden) : []

        let placed = HistoryPlacedRecord.place(
            records, segmentSpan: { library.extents[$0] }, hiddenSegmentIds: hiddenSegments,
            dayKey: { library.timeline.dayKey(forMs: $0) }
        ).filter { $0.dayKey == dateKey }
        let turns = speech.turns.filter {
            $0.startMs < hull.upperBound && $0.endMs >= hull.lowerBound && !hiddenSegments.contains($0.segmentId)
        }

        let input = HistoryDayBuilder.Input(
            dateKey: dateKey, windows: windows, segments: metas.map { SegmentCoverageInput(meta: $0) },
            pauses: pauses, speechRuns: speech.runs, segmentStates: segmentStates, chapters: chapters,
            turnPreviews: Self.turnPreviews(turns, content: content),
            followUps: placed.map { HistoryFollowUpInput(record: $0.record, placement: $0.placement, nowMs: nowMs) },
            contentSpans: content.map(HistoryContentSpanInput.init(span:)),
            deletedSpans: deleted, nowMs: isToday ? nowMs : nil, isLive: isToday && isLive)
        return DayInputs(builder: input, followUps: placed, turns: turns)
    }

    /// The turns a card's snippet may quote: never a line the loop detector marked (already left
    /// out by `HistorySpeechRunCache` — "the, the, the, the" was being picked), and never one said
    /// inside a stretch the audio classifier marked as no conversation.
    static func turnPreviews(_ turns: [HistorySpokenTurn], content: [AudioContentSpan]) -> [HistoryTurnPreview] {
        let quiet = content.filter { $0.kind == .noConversation }.map { $0.startMs..<$0.endMs }
        return turns.filter { turn in !quiet.contains { $0.contains(turn.startMs) } }
            .map { HistoryTurnPreview(startMs: $0.startMs, text: $0.text) }
    }

    // MARK: - Conversations as cards (the seam for topic-sized conversations)

    /// OFF until the grouper's conversations are topic-sized. The `conversation-units` branch
    /// makes them so and exposes `ConversationUnits.isTopicSized` in AppDB; when it lands this
    /// becomes `ConversationUnits.isTopicSized` (a one-line change). On, each conversation
    /// overlapping the day is a card (`chapters(from:hiding:)`) with its title, summary and tags,
    /// and the day digest carries tags and summaries, so an edit to either rebuilds the page.
    public static let readsConversationsAsCards = false

    /// Each conversation as the builder's chapter input: its extent, title, summary and tags.
    /// Conversations inside their undo window are not cards (they are drawn as deleted).
    public static func chapters(from rows: [ConversationListRow], hiding hidden: Set<String>) -> [HistoryChapterInput] {
        rows.filter { !hidden.contains($0.id) && $0.endMs > $0.startMs }
            .sorted { $0.startMs != $1.startMs ? $0.startMs < $1.startMs : $0.id < $1.id }
            .map { row in
                HistoryChapterInput(
                    id: row.id, startMs: row.startMs, endMs: row.endMs, title: row.title, summary: row.summary,
                    tags: row.tags, people: [], timesApproximate: false)
            }
    }

    /// The stored audio of a recording that falls inside a day: its media time (frames × frame
    /// length) in proportion to how much of its wall extent is inside. "Waiting to transcribe"
    /// is audio to transcribe, not the span a recording covers: on 2026-09-24 of the real backup
    /// eight waiting recordings span 122 minutes and hold 8 minutes of audio.
    static func mediaMs(_ meta: SegmentMeta, inside: Int64, of extent: Range<Int64>) -> Int64 {
        let length = extent.upperBound - extent.lowerBound
        guard length > 0, inside > 0 else { return 0 }
        let media = meta.frameCount * Int64(meta.frameDurationMs > 0 ? meta.frameDurationMs : 20)
        return Int64((Double(media) * Double(min(inside, length)) / Double(length)).rounded())
    }

    /// `TranscriptionFailureKind`'s raw value for a stored error, nil when it cannot be named.
    static func failureKind(_ lastError: String?) -> String? {
        guard let lastError else { return nil }
        let kind = TranscriptionFailureKind.classify(lastError)
        return kind == .unknown ? nil : kind.rawValue
    }

    /// The in-brief card's text: the condensed form while it is current, else the digest.
    static func brief(_ recap: DailyRecap) -> HistoryBrief? {
        let text = (RecapCondenser.condensation(of: recap) ?? recap.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return HistoryBrief(text: text, updatedAtMs: recap.updatedAtMs)
    }

    // MARK: - Tag results

    /// One day of a conversation carrying a tag.
    public struct TagHit: Equatable, Sendable {
        public var conversationId: String
        public var dateKey: String
        /// The first speech of the conversation inside that day.
        public var startMs: Int64
        /// The conversation's end, or the day's, whichever comes first.
        public var endMs: Int64
        public var zoneID: String
        public var title: String?
    }

    /// INTERIM, until conversations are topic-sized (`readsConversationsAsCards`): every
    /// conversation whose tags include `tag`, one hit per day it overlaps that has speech in it,
    /// starting at its first speech that day; newest first. Reads the tag's rows, those
    /// conversations' members, and only their transcripts' timings (memoised).
    public func tagHits(tag: String, _ library: Library) async throws -> [TagHit] {
        let queries = HistoryLibraryQueries(db: sources.database)
        let hidden = await sources.hiddenConversationIds()
        let tagged = try await queries.conversations(taggedWith: tag).filter { !hidden.contains($0.id) }
        guard !tagged.isEmpty else { return [] }
        let members = try await queries.members(ofConversations: tagged.map(\.id))
        let metaById = Dictionary(library.metas.map { ($0.segmentId, $0) }, uniquingKeysWith: { a, _ in a })
        let memberMetas = tagged.flatMap { members[$0.id] ?? [] }.compactMap { metaById[$0] }
        let tasks = try await queries.tasks(segmentIds: memberMetas.map(\.segmentId))
        var states: [String: TranscriptionState] = [:]
        for meta in memberMetas {
            states[meta.segmentId] = HistoryTranscriptionStates.resolve(
                segment: meta.transcriptionState, task: tasks[meta.segmentId]?.state, hasTranscriptFile: true)
        }
        let speech = await sources.speechRuns.runs(for: memberMetas, states: states)
        var runsOf: [String: [HistorySpeechRun]] = [:]
        for run in speech.runs { runsOf[run.segmentId, default: []].append(run) }

        var hits: [TagHit] = []
        for conversation in tagged {
            let runs = (members[conversation.id] ?? []).flatMap { runsOf[$0] ?? [] }
            guard !runs.isEmpty else { continue }
            let firstDay = library.timeline.dayKey(forMs: conversation.startMs)
            let lastDay = library.timeline.dayKey(forMs: max(conversation.startMs, conversation.endMs - 1))
            for day in HistoryCalendar.days(in: firstDay...max(firstDay, lastDay)) {
                for window in library.windows(of: day).windows {
                    let inside = runs.filter { $0.startMs < window.range.upperBound && $0.endMs > window.range.lowerBound }
                    guard let first = inside.map({ max($0.startMs, window.range.lowerBound) }).min() else { continue }
                    hits.append(
                        TagHit(
                            conversationId: conversation.id, dateKey: day, startMs: first,
                            endMs: min(max(conversation.endMs, first), window.range.upperBound),
                            zoneID: window.zoneID, title: conversation.title))
                    break
                }
            }
        }
        return hits.sorted { $0.startMs != $1.startMs ? $0.startMs > $1.startMs : $0.conversationId < $1.conversationId }
    }

    // MARK: - Weeks and months

    public func week(
        firstDateKey: String, lastDateKey: String, _ library: Library, nowMs: Int64, isLive: Bool
    ) async throws -> HistoryPeriod<HistoryWeekRow> {
        let today = todayKey(library, nowMs: nowMs)
        let days = HistoryCalendar.days(in: firstDateKey...lastDateKey).filter { $0 <= today }
        let facts = try await dayFacts(days, library, nowMs: nowMs, todayKey: today, isLive: isLive)
        return HistoryPeriodAssembler.week(
            firstDateKey: firstDateKey, lastDateKey: lastDateKey, days: facts, todayKey: today)
    }

    public func month(
        containing dateKey: String, firstWeekday: Int, _ library: Library, nowMs: Int64, isLive: Bool
    ) async throws -> HistoryPeriod<HistoryMonthRow> {
        let today = todayKey(library, nowMs: nowMs)
        let days = Self.monthDays(containing: dateKey, firstWeekday: firstWeekday).filter { $0 <= today }
        let facts = try await dayFacts(days, library, nowMs: nowMs, todayKey: today, isLive: isLive)
        return HistoryPeriodAssembler.month(
            containing: dateKey, firstWeekday: firstWeekday, days: facts, todayKey: today)
    }

    /// Every day a month page reads: its weeks, whole.
    public static func monthDays(containing dateKey: String, firstWeekday: Int) -> [String] {
        let weeks = HistoryCalendar.weeks(inMonthOf: dateKey, firstWeekday: firstWeekday)
        guard let first = weeks.first?.lowerBound, let last = weeks.last?.upperBound else { return [dateKey] }
        return HistoryCalendar.days(in: first...last)
    }

    /// The facts of these days, from one windowed read of each kind over their hull.
    public func dayFacts(
        _ days: [String], _ library: Library, nowMs: Int64, todayKey: String, isLive: Bool
    ) async throws -> [String: HistoryDayFacts] {
        var windowsOf: [String: [Range<Int64>]] = [:]
        for day in days { windowsOf[day] = library.windows(of: day).windows.map(\.range) }
        let hulls = windowsOf.values.flatMap { $0 }
        guard let lower = hulls.map(\.lowerBound).min(), let upper = hulls.map(\.upperBound).max() else {
            return Dictionary(uniqueKeysWithValues: days.map {
                ($0, HistoryDayFacts(dateKey: $0, isToday: $0 == todayKey, isLive: $0 == todayKey && isLive))
            })
        }
        let hull = lower..<upper
        let metas = library.segments(overlapping: hull, withNext: false)
        let database = sources.database
        let queries = HistoryLibraryQueries(db: database)
        let hidden = await sources.hiddenConversationIds()
        async let tasksRead = queries.tasks(segmentIds: metas.map(\.segmentId))
        async let rowsRead = ConversationQueries(db: database).rows(overlappingMs: hull)
        async let followUpsRead = FollowUpStore(db: database).history(
            inWallWindow: hull, segmentIds: metas.map(\.segmentId))
        let tasks = try await tasksRead
        let rows = try await rowsRead
        let records = try await followUpsRead

        let transcripts = sources.transcripts
        var state: [String: TranscriptionState] = [:]
        for meta in metas {
            let preliminary = HistoryTranscriptionStates.resolve(
                segment: meta.transcriptionState, task: tasks[meta.segmentId]?.state, hasTranscriptFile: true)
            // A `stat` per finished recording, never a read (`FileTranscriptStore.version`).
            let hasFile = preliminary != .complete || transcripts.version(meta.segmentId) != "absent"
            state[meta.segmentId] = HistoryTranscriptionStates.resolve(
                segment: meta.transcriptionState, task: tasks[meta.segmentId]?.state, hasTranscriptFile: hasFile)
        }

        let members = try await queries.members(ofConversations: rows.map(\.id))
        var hiddenSegments: Set<String> = []
        for id in hidden { hiddenSegments.formUnion(members[id] ?? []) }
        let visibleRows = rows.filter { !hidden.contains($0.id) }

        let placed = HistoryPlacedRecord.place(
            records, segmentSpan: { library.extents[$0] }, hiddenSegmentIds: hiddenSegments,
            dayKey: { library.timeline.dayKey(forMs: $0) })
        var followUpsOf: [String: [HistoryPlacedFollowUp]] = [:]
        for record in placed { followUpsOf[record.dayKey, default: []].append(record.placed(nowMs: nowMs)) }

        var result: [String: HistoryDayFacts] = [:]
        for day in days {
            let windows = windowsOf[day] ?? []
            func inside(_ range: Range<Int64>) -> Int64 {
                windows.reduce(0) { total, window in
                    total + max(0, min(range.upperBound, window.upperBound) - max(range.lowerBound, window.lowerBound))
                }
            }
            var facts = HistoryDayFacts(dateKey: day, isToday: day == todayKey, isLive: day == todayKey && isLive)
            for meta in metas {
                guard let extent = library.extents[meta.segmentId], !extent.isEmpty, inside(extent) > 0,
                    !hiddenSegments.contains(meta.segmentId)
                else { continue }
                let segmentState = state[meta.segmentId] ?? meta.transcriptionState
                facts.recordings += 1
                if HistoryTranscriptionStates.isTranscribed(segmentState) { facts.transcribedRecordings += 1 }
                if HistoryTranscriptionStates.isWaiting(segmentState) {
                    facts.waitingMs += Self.mediaMs(meta, inside: inside(extent), of: extent)
                }
            }
            for row in visibleRows {
                let overlap = inside(row.startMs..<max(row.endMs, row.startMs))
                guard overlap > 0 else { continue }
                let transcribed = (members[row.id] ?? []).reduce(Int64(0)) { total, segmentId in
                    guard state[segmentId] == .complete, let extent = library.extents[segmentId] else { return total }
                    return total + inside(extent)
                }
                facts.conversations.append(
                    HistoryConversationFact(
                        id: row.id, title: row.title, tags: row.tags, overlapMs: overlap, transcribedMs: transcribed,
                        durationMs: max(0, row.endMs - row.startMs)))
            }
            if let recap = try await sources.recaps.load(dateKey: day), let brief = Self.brief(recap) {
                facts.recap = HistoryRecapFact(summary: brief.text, updatedAtMs: brief.updatedAtMs)
            }
            facts.followUps = followUpsOf[day] ?? []
            result[day] = facts
        }
        return result
    }
}
