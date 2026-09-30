import AppDB
import CompanionRuntime
import Foundation
import os

// The History tab's live data source (plan 7.10 "The data source", 7.13).
//
// The two battery rules (CLAUDE.md) are the shape of this file, not a layer on top of it:
//
// - AN OBSERVER NEVER RE-PUBLISHES WHAT IT OBSERVES; A REFRESH THAT CHANGES NOTHING PUBLISHES
//   NOTHING. A visible page keeps exactly one database observation, over a small digest of its
//   window (`HistoryDigest`), never over the page. An unchanged digest is dropped without a
//   build — that is what the pipeline's regroup produces for a past day, every pass. A changed
//   digest rebuilds the page OFF the main actor, and the result is published only when it
//   differs from what that subscriber last received. History only reads; nothing here writes.
// - A SCREEN'S DATA SOURCE DOES NOTHING WHILE ITS SCREEN IS OFF SCREEN. `setVisible(false)`
//   CANCELS every observation, timer and prefetch (it does not merely ignore their output), so
//   a write while hidden costs no query and no build. `setVisible(true)` resubscribes; each
//   observation's first value is one digest read, compared with the cache — a rebuild, and a
//   publish, happen only if something changed while the screen was away.
//
// Today is the one page whose digest moves on every pipeline pass while recording (the live
// conversation's end advances). Its rebuilds are coalesced to one per `todayCoalesceMs`
// (10 s). Its live line comes from Today's live snapshot, never from a second walk of the
// transcript, and a new line re-publishes the cached page without rebuilding it. Because
// today's timeline runs to "now", a visible today is also rebuilt once per `todayTickMs`.
//
// Neighbours are built once by `prefetch` into a small LRU (about a week of days) and are not
// observed. The recorded range (`bounds`) is cached by the reader and recomputed only when the
// number of recordings, the first start or the last start changes.

/// A page History can show.
enum HistoryWindow: Hashable, Sendable {
    case day(String)
    case week(first: String, last: String)
    /// Keyed by the month's first day.
    case month(first: String, firstWeekday: Int)

    var isDay: Bool {
        if case .day = self { return true }
        return false
    }
}

/// What a window builds to.
enum HistoryBuilt: Equatable, Sendable {
    case day(HistoryReader.DayBuild)
    case week(HistoryPeriod<HistoryWeekRow>)
    case month(HistoryPeriod<HistoryMonthRow>)

    /// Whether the built page includes today (and so depends on the clock and the live state).
    var includesToday: Bool {
        switch self {
        case .day(let build): return build.day.isToday
        case .week(let period): return period.rows.contains { if case .today = $0.state { return true } else { return false } }
        case .month(let period): return period.rows.contains(where: \.isCurrentWeek)
        }
    }
}

/// Today's live state as History uses it: whether a conversation is being recorded, and its
/// newest line.
struct HistoryLiveState: Equatable, Sendable {
    var isLive = false
    var line: String?
}

/// Everything `LiveHistory` reads. The live conformer is `ReaderHistoryBackend`; the gate tests
/// substitute one over a scratch database whose builds are counted.
protocol HistoryLiveBackend: Sendable {
    func bounds(nowMs: Int64) async -> HistoryBounds
    /// The rows a window's digest covers.
    func scope(of window: HistoryWindow) async -> HistoryDigestScope
    /// One read of the digest (prefetch).
    func digest(_ scope: HistoryDigestScope) async -> HistoryDigest?
    /// The digest now and after every change (the one observation a visible window keeps).
    func digests(_ scope: HistoryDigestScope) -> AsyncStream<HistoryDigest>
    /// Builds a window. Nil when the read failed; the page keeps what it showed.
    func build(_ window: HistoryWindow, nowMs: Int64, isLive: Bool) async -> HistoryBuilt?
    /// The days and stretches carrying a tag, newest first (one read; no observation).
    func tagHits(tag: String) async -> [HistoryReader.TagHit]
}

@MainActor
final class LiveHistory: HistoryDataSource {
    struct Tuning {
        /// Today, while recording: at most one rebuild per this.
        var todayCoalesceMs: Int64 = 10_000
        /// Any other page: at most one rebuild per this, so a burst of writes (a catch-up pass
        /// classifying a day's recordings one by one) is one build, not one per write.
        var minimumRebuildIntervalMs: Int64 = 2_000
        /// Today, while visible: rebuilt this often, because its timeline runs to "now".
        var todayTickMs: Int64 = 60_000
        /// Days kept built (the visible one, its neighbours, recently seen ones).
        var dayCacheSize = 7
        /// Weeks and months kept built, each.
        var periodCacheSize = 3
    }

    private let backend: any HistoryLiveBackend
    private let now: @MainActor () -> Int64
    private let liveState: @MainActor () -> HistoryLiveState
    private let liveStates: @MainActor () -> AsyncStream<HistoryLiveState>
    private let firstWeekday: Int
    private let tuning: Tuning
    private let log = Logger(subsystem: "dev.audiocompanion.app", category: "History")

    /// Whether the History screen is on screen (the screen calls `setVisible`).
    private(set) var isVisible = true
    /// Pages published to subscribers, for tests and the debug log.
    private(set) var publishCount = 0

    private final class Subscriber {
        let window: HistoryWindow
        /// Maps the built value to the stream's element and yields it when it differs from the
        /// last one this subscriber received. True when it yielded.
        let offer: @MainActor (HistoryBuilt) -> Bool
        let finish: () -> Void

        init(window: HistoryWindow, offer: @escaping @MainActor (HistoryBuilt) -> Bool, finish: @escaping () -> Void) {
            self.window = window
            self.offer = offer
            self.finish = finish
        }
    }

    private struct Entry {
        /// The digest the built value was made from.
        var digest: HistoryDigest?
        var built: HistoryBuilt?
        var builtAtMs: Int64 = 0
        /// A pending delete touched a conversation in this window: rebuild even on an
        /// unchanged digest (the undo buffer lives in memory, not in the database).
        var stale = false
        /// Hidden since the last check: the next digest decides whether anything changed.
        var unverified = false
        var lastUse = 0
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private var cache: [HistoryWindow: Entry] = [:]
    private var useCounter = 0
    /// The one observation per visible window.
    private var observations: [HistoryWindow: Task<Void, Never>] = [:]
    private var builds: [HistoryWindow: Task<Void, Never>] = [:]
    /// The newest digest seen while a build was already running for the window.
    private var rebuildAgain: [HistoryWindow: HistoryDigest?] = [:]
    /// Rebuilds waiting for their slot (`minimumRebuildIntervalMs`, today's `todayCoalesceMs`).
    private var deferred: [HistoryWindow: Task<Void, Never>] = [:]
    /// The newest digest each observed window delivered, for a deferred rebuild.
    private var latestDigest: [HistoryWindow: HistoryDigest] = [:]
    private var todayTick: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchQueue: [String] = []
    private var live: HistoryLiveState

    init(
        backend: any HistoryLiveBackend,
        now: @escaping @MainActor () -> Int64,
        liveState: @escaping @MainActor () -> HistoryLiveState = { HistoryLiveState() },
        liveStates: @escaping @MainActor () -> AsyncStream<HistoryLiveState> = { AsyncStream { $0.finish() } },
        firstWeekday: Int = Calendar.current.firstWeekday,
        tuning: Tuning = Tuning()
    ) {
        self.backend = backend
        self.now = now
        self.liveState = liveState
        self.liveStates = liveStates
        self.firstWeekday = firstWeekday
        self.tuning = tuning
        self.live = liveState()
    }

    deinit {
        for task in observations.values { task.cancel() }
        for task in builds.values { task.cancel() }
        for task in deferred.values { task.cancel() }
        todayTick?.cancel()
        liveTask?.cancel()
        prefetchTask?.cancel()
    }

    // MARK: - HistoryDataSource

    func bounds() async -> HistoryBounds {
        await backend.bounds(nowMs: now())
    }

    func day(_ dateKey: String) -> AsyncStream<HistoryDayPage> {
        subscribe(.day(dateKey)) { [weak self] built in
            guard case .day(let build) = built else { return nil }
            return self?.page(build)
        }
    }

    func week(firstDateKey: String, lastDateKey: String) -> AsyncStream<HistoryPeriod<HistoryWeekRow>> {
        subscribe(.week(first: firstDateKey, last: lastDateKey)) { built in
            guard case .week(let period) = built else { return nil }
            return period
        }
    }

    func month(containing dateKey: String) -> AsyncStream<HistoryPeriod<HistoryMonthRow>> {
        let first = HistoryCalendar.month(containing: dateKey).lowerBound
        return subscribe(.month(first: first, firstWeekday: firstWeekday)) { built in
            guard case .month(let period) = built else { return nil }
            return period
        }
    }

    /// Builds these days once into the cache, without observing them. Nothing while hidden.
    func prefetch(days: [String]) {
        guard isVisible else { return }
        for key in days where !prefetchQueue.contains(key) {
            let window = HistoryWindow.day(key)
            if let entry = cache[window], entry.built != nil, !entry.stale {
                touch(window)
                continue
            }
            prefetchQueue.append(key)
        }
        guard prefetchTask == nil, !prefetchQueue.isEmpty else { return }
        prefetchTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.prefetchQueue.isEmpty {
                let window = HistoryWindow.day(self.prefetchQueue.removeFirst())
                // Already built, being built, or observed by a subscriber: nothing to do.
                let current = self.cache[window]
                if (current?.built != nil && current?.stale == false) || self.builds[window] != nil
                    || self.observations[window] != nil
                {
                    continue
                }
                await self.prefetchOne(window)
            }
            self?.prefetchTask = nil
        }
    }

    /// Each conversation whose tags include `tag`, once, with its own start, title and summary
    /// (conversations are topic-sized, so a result is the conversation itself). One read when
    /// the results screen opens; nothing is observed.
    func tagResults(tag: String) async -> [HistoryTagResult] {
        await backend.tagHits(tag: tag).map { hit in
            HistoryTagResult(
                dateKey: hit.dateKey, startMs: hit.startMs, endMs: hit.endMs, zoneID: hit.zoneID,
                title: hit.title.flatMap { $0.isEmpty ? nil : $0 } ?? Copy.History.untitledTagResult,
                summary: hit.summary.flatMap { $0.isEmpty ? nil : $0 },
                conversationId: hit.conversationId)
        }
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            for window in Set(subscribers.values.map(\.window)) { activate(window) }
            updateTimeObservers()
        } else {
            // Cancelled, not ignored: a write while hidden must cost nothing.
            for task in observations.values { task.cancel() }
            observations.removeAll()
            for task in deferred.values { task.cancel() }
            deferred.removeAll()
            prefetchTask?.cancel()
            prefetchTask = nil
            prefetchQueue.removeAll()
            for window in cache.keys { cache[window]?.unverified = true }
            updateTimeObservers()
        }
    }

    // MARK: - Pending deletes

    /// A conversation was hidden by a delete, or restored by its undo (`LiveWorld`). The undo
    /// buffer lives in memory, so no digest sees it: pages whose window holds that conversation
    /// are marked stale, and the visible ones rebuild now.
    func pendingDeletesChanged(conversationId: String) {
        for (window, entry) in cache where entry.digest?.conversationIds.contains(conversationId) ?? false {
            cache[window]?.stale = true
            if observations[window] != nil { requestBuild(window, digest: entry.digest) }
        }
    }

    // MARK: - Subscriptions

    private func subscribe<Element: Equatable & Sendable>(
        _ window: HistoryWindow, map: @escaping @MainActor (HistoryBuilt) -> Element?
    ) -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            var last: Element?
            let subscriber = Subscriber(
                window: window,
                offer: { [weak self] built in
                    guard let value = map(built), value != last else { return false }
                    last = value
                    self?.publishCount += 1
                    continuation.yield(value)
                    return true
                },
                finish: { continuation.finish() })
            subscribers[id] = subscriber
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.unsubscribe(id) }
            }
            // What was last built for this window shows at once (plan 5.8: the previous content
            // stays until new data is ready); the observation then says whether it still holds.
            if let built = cache[window]?.built {
                touch(window)
                _ = subscriber.offer(built)
            }
            activate(window)
        }
    }

    private func unsubscribe(_ id: UUID) {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        let window = subscriber.window
        guard !subscribers.values.contains(where: { $0.window == window }) else { return }
        observations.removeValue(forKey: window)?.cancel()
        deferred.removeValue(forKey: window)?.cancel()
        rebuildAgain.removeValue(forKey: window)
        latestDigest.removeValue(forKey: window)
        evict()
        updateTimeObservers()
    }

    private func isSubscribed(_ window: HistoryWindow) -> Bool {
        subscribers.values.contains { $0.window == window }
    }

    /// Starts the window's one observation, if it is visible and has none.
    private func activate(_ window: HistoryWindow) {
        guard isVisible, observations[window] == nil, isSubscribed(window) else { return }
        let backend = self.backend
        observations[window] = Task { [weak self] in
            let scope = await backend.scope(of: window)
            guard !Task.isCancelled else { return }
            for await digest in backend.digests(scope) {
                guard !Task.isCancelled, let self else { return }
                self.digestArrived(window, digest)
            }
        }
    }

    private func digestArrived(_ window: HistoryWindow, _ digest: HistoryDigest) {
        touch(window)
        latestDigest[window] = digest
        guard var entry = cache[window], let built = entry.built, entry.digest == digest, !entry.stale else {
            requestBuild(window, digest: digest)
            return
        }
        entry.unverified = false
        cache[window] = entry
        // Unchanged. Today's page also depends on the clock: rebuilt on its tick, not here —
        // except when the screen comes back after longer than a tick.
        if built.includesToday, now() - entry.builtAtMs >= tuning.todayTickMs {
            requestBuild(window, digest: digest)
        }
    }

    // MARK: - Building

    private func requestBuild(_ window: HistoryWindow, digest: HistoryDigest?) {
        guard isVisible else { return }
        if builds[window] != nil {
            rebuildAgain[window] = .some(digest)
            return
        }
        // Coalesce: a window with today in it, while recording, rebuilds at most once per
        // `todayCoalesceMs`, any other at most once per `minimumRebuildIntervalMs`; changes
        // inside the interval are picked up by one build at its end.
        if let entry = cache[window], let built = entry.built {
            let interval = live.isLive && built.includesToday ? tuning.todayCoalesceMs : tuning.minimumRebuildIntervalMs
            let wait = entry.builtAtMs + interval - now()
            if wait > 0 {
                guard deferred[window] == nil else { return }
                deferred[window] = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(wait))
                    guard !Task.isCancelled, let self else { return }
                    self.deferred[window] = nil
                    // The newest digest the observation delivered while this waited.
                    self.startBuild(window, digest: self.latestDigest[window] ?? self.cache[window]?.digest)
                }
                return
            }
        }
        startBuild(window, digest: digest)
    }

    /// `digest` nil means "read it now": a deferred rebuild does not know the latest one.
    private func startBuild(_ window: HistoryWindow, digest: HistoryDigest?) {
        guard builds[window] == nil else {
            rebuildAgain[window] = .some(digest)
            return
        }
        live = liveState()
        let startedAt = now()
        let isLive = live.isLive
        let backend = self.backend
        let signposter = HistoryPerformance.signposter
        builds[window] = Task { [weak self] in
            // Off the main actor: the main actor only assigns the result (plan 7.13).
            let result = await Task.detached(priority: .userInitiated) { () -> (HistoryDigest?, HistoryBuilt?, Duration) in
                let state = signposter.beginInterval("history build")
                defer { signposter.endInterval("history build", state) }
                let clock = ContinuousClock()
                var resolved = digest
                var built: HistoryBuilt?
                let elapsed = await clock.measure {
                    if resolved == nil { resolved = await backend.digest(backend.scope(of: window)) }
                    built = await backend.build(window, nowMs: startedAt, isLive: isLive)
                }
                return (resolved, built, elapsed)
            }.value
            self?.buildFinished(window, digest: result.0, built: result.1, startedAt: startedAt, elapsed: result.2)
        }
    }

    private func buildFinished(
        _ window: HistoryWindow, digest: HistoryDigest?, built: HistoryBuilt?, startedAt: Int64, elapsed: Duration
    ) {
        builds[window] = nil
        var published = 0
        defer {
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            log.debug(
                "history: built \(String(describing: window), privacy: .public) in \(ms, format: .fixed(precision: 1)) ms, published to \(published)")
        }
        if let built {
            var entry = cache[window] ?? Entry()
            entry.digest = digest
            entry.built = built
            entry.builtAtMs = startedAt
            entry.stale = false
            entry.unverified = false
            cache[window] = entry
            touch(window)
            // Published only where it differs from what the subscriber already has.
            if isVisible {
                for subscriber in subscribers.values where subscriber.window == window {
                    if subscriber.offer(built) { published += 1 }
                }
            }
            evict()
            updateTimeObservers()
        }
        if let again = rebuildAgain.removeValue(forKey: window), isVisible, observations[window] != nil {
            if again != cache[window]?.digest || again == nil { requestBuild(window, digest: again) }
        }
    }

    private func prefetchOne(_ window: HistoryWindow) async {
        let backend = self.backend
        let startedAt = now()
        let isLive = live.isLive
        let result = await Task.detached(priority: .utility) { () -> (HistoryDigest?, HistoryBuilt?) in
            let digest = await backend.digest(backend.scope(of: window))
            return (digest, await backend.build(window, nowMs: startedAt, isLive: isLive))
        }.value
        guard !Task.isCancelled, isVisible, let built = result.1 else { return }
        // A subscriber may have arrived while this ran; its own build is then the newer one.
        if let entry = cache[window], entry.built != nil, !entry.stale { return }
        cache[window] = Entry(digest: result.0, built: built, builtAtMs: startedAt)
        touch(window)
        evict()
    }

    // MARK: - Today: the clock and the live line

    /// Today's tick and the live-state observation run only while a visible page includes today.
    private func updateTimeObservers() {
        let todayWindows = Set(subscribers.values.map(\.window)).filter { cache[$0]?.built?.includesToday == true }
        let needed = isVisible && !todayWindows.isEmpty
        guard needed else {
            todayTick?.cancel()
            todayTick = nil
            liveTask?.cancel()
            liveTask = nil
            return
        }
        if todayTick == nil {
            let interval = tuning.todayTickMs
            todayTick = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(interval))
                    guard !Task.isCancelled, let self else { return }
                    for window in Set(self.subscribers.values.map(\.window))
                    where self.cache[window]?.built?.includesToday == true {
                        self.requestBuild(window, digest: self.cache[window]?.digest)
                    }
                }
            }
        }
        if liveTask == nil {
            let states = liveStates()
            liveTask = Task { [weak self] in
                for await state in states {
                    guard !Task.isCancelled, let self else { return }
                    self.liveChanged(state)
                }
            }
        }
    }

    private func liveChanged(_ state: HistoryLiveState) {
        guard state != live else { return }
        let wasLive = live.isLive
        live = state
        for window in Set(subscribers.values.map(\.window)) {
            guard let entry = cache[window], let built = entry.built, built.includesToday else { continue }
            if wasLive != state.isLive {
                // Recording started or stopped: the timeline's end changes shape.
                requestBuild(window, digest: entry.digest)
            } else {
                // Only the line moved: the same page, re-offered (no rebuild).
                for subscriber in subscribers.values where subscriber.window == window { _ = subscriber.offer(built) }
            }
        }
    }

    // MARK: - Pages

    private func page(_ build: HistoryReader.DayBuild) -> HistoryDayPage {
        let hasLiveBlock = build.day.items.contains { if case .live = $0 { return true } else { return false } }
        return HistoryDayPage(
            day: build.day, brief: build.brief, followUpTotal: build.followUpTotal,
            followUpOpen: build.followUpOpen,
            // No chapter stage yet: the conversation cards are what History has, and nothing
            // says topics are on their way (plan 5.8).
            topics: .off,
            liveLine: hasLiveBlock ? live.line : nil)
    }

    // MARK: - The cache

    private func touch(_ window: HistoryWindow) {
        useCounter += 1
        cache[window]?.lastUse = useCounter
    }

    /// Least recently used first, never a window someone is subscribed to.
    private func evict() {
        func trim(_ matching: (HistoryWindow) -> Bool, to size: Int) {
            let candidates = cache.filter { matching($0.key) && !isSubscribed($0.key) }
                .sorted { $0.value.lastUse < $1.value.lastUse }
            let excess = cache.keys.filter(matching).count - size
            guard excess > 0 else { return }
            for (window, _) in candidates.prefix(excess) { cache.removeValue(forKey: window) }
        }
        trim(\.isDay, to: tuning.dayCacheSize)
        trim({ if case .week = $0 { return true } else { return false } }, to: tuning.periodCacheSize)
        trim({ if case .month = $0 { return true } else { return false } }, to: tuning.periodCacheSize)
    }
}

// MARK: - The live backend

/// `HistoryLiveBackend` over the real library: `HistoryReader` for builds, `HistoryDigest` for
/// the observation.
struct ReaderHistoryBackend: HistoryLiveBackend {
    let reader: HistoryReader
    let database: AppDatabase

    func bounds(nowMs: Int64) async -> HistoryBounds {
        await reader.bounds(nowMs: nowMs)
    }

    func scope(of window: HistoryWindow) async -> HistoryDigestScope {
        let library = await reader.library()
        switch window {
        case .day(let key):
            return await reader.dayScope(key, library)
        case .week(let first, let last):
            return await reader.periodScope(
                days: HistoryCalendar.days(in: first...last),
                briefKeys: HistoryReader.weekBriefKeys(firstDateKey: first), library)
        case .month(let first, let firstWeekday):
            return await reader.periodScope(
                days: HistoryReader.monthDays(containing: first, firstWeekday: firstWeekday),
                briefKeys: HistoryReader.monthBriefKeys(containing: first, firstWeekday: firstWeekday),
                library)
        }
    }

    func digest(_ scope: HistoryDigestScope) async -> HistoryDigest? {
        try? await HistoryDigest.read(database, scope: scope)
    }

    func digests(_ scope: HistoryDigestScope) -> AsyncStream<HistoryDigest> {
        HistoryDigest.observe(database, scope: scope)
    }

    func tagHits(tag: String) async -> [HistoryReader.TagHit] {
        let library = await reader.library()
        return (try? await reader.tagHits(tag: tag, library)) ?? []
    }

    func build(_ window: HistoryWindow, nowMs: Int64, isLive: Bool) async -> HistoryBuilt? {
        let library = await reader.library()
        do {
            switch window {
            case .day(let key):
                let today = await reader.todayKey(library, nowMs: nowMs)
                return .day(try await reader.day(key, library, nowMs: nowMs, isToday: key == today, isLive: isLive))
            case .week(let first, let last):
                return .week(
                    try await reader.week(firstDateKey: first, lastDateKey: last, library, nowMs: nowMs, isLive: isLive))
            case .month(let first, let firstWeekday):
                return .month(
                    try await reader.month(
                        containing: first, firstWeekday: firstWeekday, library, nowMs: nowMs, isLive: isLive))
            }
        } catch {
            return nil
        }
    }
}
