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
            recapDateKeys: [dateKey], includeTags: false)
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
        let (input, placed) = try await dayInput(dateKey, library, nowMs: nowMs, isToday: isToday, isLive: isLive)
        let day = HistoryDayBuilder.build(input)
        let recap = try await sources.recaps.load(dateKey: dateKey)
        return DayBuild(
            day: day, brief: recap.flatMap(Self.brief), followUpTotal: placed.count,
            followUpOpen: placed.filter { !$0.record.done }.count)
    }

    /// The builder's inputs for one day, and the follow-ups placed on it.
    public func dayInput(
        _ dateKey: String, _ library: Library, nowMs: Int64, isToday: Bool, isLive: Bool
    ) async throws -> (HistoryDayBuilder.Input, [HistoryPlacedRecord]) {
        let (hullOrNil, windows) = library.windows(of: dateKey)
        guard let hull = hullOrNil else {
            return (HistoryDayBuilder.Input(dateKey: dateKey, windows: windows, segments: [],
                nowMs: isToday ? nowMs : nil), [])
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
            let reason = state == .failed ? tasks[meta.segmentId]?.lastError : nil
            if let entry = HistorySegmentState(meta: meta, state: state, failureReason: reason) {
                segmentStates.append(entry)
            }
        }

        // Conversations, minus those inside their undo window. Their recorded time is drawn as
        // deleted (plan 7.10 rule 1): dropping them alone would leave their words behind as an
        // untitled card, which is the one thing a person who just deleted them must not see.
        let members = try await queries.members(ofConversations: rows.map(\.id))
        var conversations: [HistoryConversationInput] = []
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
            conversations.append(
                HistoryConversationInput(
                    id: row.id, startMs: row.startMs, endMs: row.endMs, title: row.title, segmentIds: segmentIds))
        }

        let placed = HistoryPlacedRecord.place(
            records, segmentSpan: { library.extents[$0] }, hiddenSegmentIds: hiddenSegments,
            dayKey: { library.timeline.dayKey(forMs: $0) }
        ).filter { $0.dayKey == dateKey }

        let input = HistoryDayBuilder.Input(
            dateKey: dateKey, windows: windows, segments: metas.map { SegmentCoverageInput(meta: $0) },
            pauses: pauses, speechRuns: speech.runs, segmentStates: segmentStates,
            conversations: conversations,
            followUps: placed.map { HistoryFollowUpInput(record: $0.record, placement: $0.placement, nowMs: nowMs) },
            contentSpans: content.map(HistoryContentSpanInput.init(span:)),
            deletedSpans: deleted, nowMs: isToday ? nowMs : nil, isLive: isToday && isLive)
        return (input, placed)
    }

    /// The in-brief card's text: the condensed form while it is current, else the digest.
    static func brief(_ recap: DailyRecap) -> HistoryBrief? {
        let text = (RecapCondenser.condensation(of: recap) ?? recap.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return HistoryBrief(text: text, updatedAtMs: recap.updatedAtMs)
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
                if HistoryTranscriptionStates.isWaiting(segmentState) { facts.waitingMs += inside(extent) }
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
                        id: row.id, title: row.title, tags: row.tags, overlapMs: overlap, transcribedMs: transcribed))
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
