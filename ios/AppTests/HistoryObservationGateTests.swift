import AppDB
import CompanionRuntime
import Foundation
import GRDB
import Testing

// The two battery rules, measured on `LiveHistory` itself (CLAUDE.md; plan 7.10, 7.13):
//
// - a refresh that changes nothing publishes nothing: the pipeline's regroup rewrites every
//   conversation row each pass, identically for a past day, and that must cost no build and no
//   publish;
// - a screen's data source does nothing while its screen is off screen: a write while hidden
//   costs no query and no build, and coming back yields once — only if something changed.
//
// The observation is the real one (`HistoryDigest.observe` over a scratch database); only the
// build is a stand-in, which reads the conversations' titles so a real change is visible in
// what it returns, and counts itself.

private let dayStart: Int64 = 1_790_000_000_000
private let window: Range<Int64> = dayStart..<(dayStart + 86_400_000)
private let pastDay = "2026-09-21"
private let today = "2026-09-22"

/// A thread-safe counter.
final class GateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class GateBackend: HistoryLiveBackend, @unchecked Sendable {
    let database: AppDatabase
    let builds = GateCounter()
    let fetches = GateCounter()

    init() throws {
        database = try AppDatabase.inMemory()
    }

    func seed() async throws {
        try await database.writer.write { db in
            for (index, id) in ["c1", "c2"].enumerated() {
                let start = dayStart + Int64(index) * 3_600_000
                try db.execute(
                    sql: "INSERT INTO conversations (id, startMs, endMs, timezone, state) VALUES (?, ?, ?, 'UTC', 'closed')",
                    arguments: [id, start, start + 1_800_000])
                try db.execute(
                    sql: """
                        INSERT INTO conversation_segments (conversationId, segmentId, ordinal, transcriptionState)
                        VALUES (?, ?, 0, 'Complete')
                        """,
                    arguments: [id, "seg-\(id)"])
                try db.execute(
                    sql: "INSERT INTO annotations (conversationId, title) VALUES (?, ?)", arguments: [id, "Title \(id)"])
            }
        }
    }

    /// `ConversationGrouper.apply`'s shape: every conversation and member row deleted and
    /// written back, identically.
    func regroupIdentically() async throws {
        try await database.writer.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM conversations")
            let members = try Row.fetchAll(db, sql: "SELECT * FROM conversation_segments")
            try db.execute(sql: "DELETE FROM conversation_segments")
            try db.execute(sql: "DELETE FROM conversations")
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO conversations (id, startMs, endMs, timezone, state) VALUES (?, ?, ?, ?, ?)",
                    arguments: [row["id"], row["startMs"], row["endMs"], row["timezone"], row["state"]])
            }
            for row in members {
                try db.execute(
                    sql: """
                        INSERT INTO conversation_segments (conversationId, segmentId, ordinal, transcriptionState)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [row["conversationId"], row["segmentId"], row["ordinal"], row["transcriptionState"]])
            }
        }
    }

    func execute(_ sql: String) async throws {
        try await database.writer.write { try $0.execute(sql: sql) }
    }

    // MARK: HistoryLiveBackend

    func bounds(nowMs: Int64) async -> HistoryBounds {
        HistoryBounds(firstDateKey: pastDay, todayDateKey: today, recordedDays: [pastDay, today])
    }

    func scope(of window: HistoryWindow) async -> HistoryDigestScope {
        HistoryDigestScope(window: GateTestsWindow.range, segmentIds: ["seg-c1", "seg-c2"], recapDateKeys: [], includeTags: false)
    }

    func digest(_ scope: HistoryDigestScope) async -> HistoryDigest? {
        fetches.bump()
        return try? await HistoryDigest.read(database, scope: scope)
    }

    func digests(_ scope: HistoryDigestScope) -> AsyncStream<HistoryDigest> {
        let fetches = self.fetches
        return HistoryDigest.observe(database, scope: scope, onFetch: { fetches.bump() })
    }

    func build(_ window: HistoryWindow, nowMs: Int64, isLive: Bool) async -> HistoryBuilt? {
        builds.bump()
        guard case .day(let key) = window else { return nil }
        let blocks: [HistoryChapterBlock] = (try? await database.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT c.id AS id, c.startMs AS startMs, c.endMs AS endMs, a.title AS title
                    FROM conversations c LEFT JOIN annotations a ON a.conversationId = c.id ORDER BY c.startMs
                    """
            ).map { row in
                HistoryChapterBlock(
                    id: row["id"], startMs: row["startMs"], endMs: row["endMs"], zoneID: "UTC",
                    source: .conversation, title: row["title"], summary: nil)
            }
        }) ?? []
        var items: [HistoryItem] = blocks.map { .chapter($0) }
        let isToday = key == today
        if isToday, isLive {
            let end = (items.last?.endMs ?? dayStart)
            items.append(.live(HistoryLiveBlock(startMs: end, endMs: max(end, nowMs), zoneID: "UTC")))
        }
        let day = HistoryDay(
            dateKey: key, zoneID: "UTC", isToday: isToday, hasRecordings: true, leadingEdge: nil, items: items,
            trailingEdge: nil)
        return .day(HistoryReader.DayBuild(day: day, brief: nil, followUpTotal: 0, followUpOpen: 0))
    }
}

private enum GateTestsWindow {
    static let range = window
}

/// Collects what a stream publishes.
@MainActor
private final class Collector<Element: Sendable> {
    private(set) var values: [Element] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        task = Task { @MainActor [weak self] in
            for await value in stream { self?.values.append(value) }
        }
    }

    func cancel() { task?.cancel() }
}

/// Waits for a condition, polling; false when it did not hold within `timeout`.
@MainActor
private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Lets whatever a write set in motion run to the end.
private func settle(_ duration: Duration = .milliseconds(300)) async {
    try? await Task.sleep(for: duration)
}

@MainActor
@Suite("History: the content and visibility gates", .serialized)
struct HistoryObservationGateTests {
    private func source(
        _ backend: GateBackend, now: @escaping @MainActor () -> Int64 = { dayStart + 43_200_000 },
        live: HistoryLiveState = HistoryLiveState(), tuning: LiveHistory.Tuning = LiveHistory.Tuning()
    ) -> LiveHistory {
        LiveHistory(backend: backend, now: now, liveState: { live }, tuning: tuning)
    }

    @Test("a regroup that rewrites every conversation identically builds nothing and publishes nothing")
    func identicalRegroupIsSilent() async throws {
        let backend = try GateBackend()
        try await backend.seed()
        let history = source(backend)
        let pages = Collector(history.day(pastDay))
        #expect(await eventually { pages.values.count == 1 })
        #expect(backend.builds.value == 1)

        let fetchesBefore = backend.fetches.value
        for _ in 0..<5 { try await backend.regroupIdentically() }
        // The observation ran (it cannot know in advance), and stopped at the digest.
        #expect(await eventually { backend.fetches.value >= fetchesBefore + 5 })
        await settle()
        #expect(backend.builds.value == 1)
        #expect(pages.values.count == 1)
        #expect(history.publishCount == 1)
        pages.cancel()
    }

    @Test("a real change rebuilds and publishes exactly once")
    func realChangePublishesOnce() async throws {
        let backend = try GateBackend()
        try await backend.seed()
        let history = source(backend)
        let pages = Collector(history.day(pastDay))
        #expect(await eventually { pages.values.count == 1 })

        try await backend.execute("UPDATE annotations SET title = 'Garden planning' WHERE conversationId = 'c1'")
        #expect(await eventually { pages.values.count == 2 })
        await settle()
        #expect(pages.values.count == 2)
        #expect(backend.builds.value == 2)
        let titles = pages.values.last!.day.items.compactMap { item -> String? in
            if case .chapter(let block) = item { return block.title } else { return nil }
        }
        #expect(titles == ["Garden planning", "Title c2"])

        // A change the page does not draw (a later conversation end outside the window moves
        // nothing; here: a rebuilt identical value) publishes nothing even when it rebuilds.
        try await backend.execute("INSERT INTO transcription_tasks (segmentId, state, createdAtMs, updatedAtMs) VALUES ('seg-c1', 'Complete', 0, 0)")
        #expect(await eventually { backend.builds.value == 3 })
        await settle()
        #expect(pages.values.count == 2)
        pages.cancel()
    }

    @Test("while hidden a write costs no query and no build; back on screen it yields once")
    func hiddenWritesCostNothing() async throws {
        let backend = try GateBackend()
        try await backend.seed()
        let history = source(backend)
        let pages = Collector(history.day(pastDay))
        #expect(await eventually { pages.values.count == 1 })
        await settle(.milliseconds(100))

        history.setVisible(false)
        await settle(.milliseconds(50))
        let fetches = backend.fetches.value
        let builds = backend.builds.value
        try await backend.execute("UPDATE annotations SET title = 'Changed while away' WHERE conversationId = 'c2'")
        try await backend.regroupIdentically()
        await settle()
        #expect(backend.fetches.value == fetches, "the observation was not cancelled")
        #expect(backend.builds.value == builds)
        #expect(pages.values.count == 1)

        history.setVisible(true)
        #expect(await eventually { pages.values.count == 2 })
        await settle()
        // One fetch on the way back (the observation's first value), one build, one publish.
        #expect(backend.fetches.value == fetches + 1)
        #expect(backend.builds.value == builds + 1)
        #expect(pages.values.count == 2)
        pages.cancel()
    }

    @Test("back on screen with nothing changed: one read, no build, no publish")
    func unchangedReturnIsSilent() async throws {
        let backend = try GateBackend()
        try await backend.seed()
        let history = source(backend)
        let pages = Collector(history.day(pastDay))
        #expect(await eventually { pages.values.count == 1 })
        await settle(.milliseconds(100))

        history.setVisible(false)
        let fetches = backend.fetches.value
        history.setVisible(true)
        #expect(await eventually { backend.fetches.value == fetches + 1 })
        await settle()
        #expect(backend.builds.value == 1)
        #expect(pages.values.count == 1)
        #expect(history.publishCount == 1)
        pages.cancel()
    }

    @Test("today while recording rebuilds at most once per coalescing interval")
    func todayCoalesces() async throws {
        let backend = try GateBackend()
        try await backend.seed()
        var tuning = LiveHistory.Tuning()
        tuning.todayCoalesceMs = 600
        tuning.todayTickMs = 60_000
        let clock = ContinuousClock()
        let origin = clock.now
        let history = source(
            backend,
            now: {
                let elapsed = clock.now - origin
                return dayStart + 43_200_000 + elapsed.components.seconds * 1000
                    + elapsed.components.attoseconds / 1_000_000_000_000_000
            },
            live: HistoryLiveState(isLive: true, line: "“…see you there”"), tuning: tuning)
        let pages = Collector(history.day(today))
        #expect(await eventually { pages.values.count == 1 })
        #expect(pages.values[0].liveLine == "“…see you there”")
        #expect(backend.builds.value == 1)

        // A pipeline pass every 50 ms for 400 ms, each moving the live conversation's end.
        for step in 1...8 {
            try await backend.execute("UPDATE conversations SET endMs = endMs + \(step) WHERE id = 'c2'")
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(backend.builds.value == 1, "rebuilt inside the coalescing interval")
        // One build at the end of the interval picks up the newest state.
        #expect(await eventually(.seconds(2)) { backend.builds.value == 2 })
        await settle(.milliseconds(700))
        #expect(backend.builds.value == 2)
        #expect(pages.values.count == 2)
        pages.cancel()
    }

    @Test("a burst of real changes to a past day is one rebuild, not one per write")
    func burstsCollapse() async throws {
        let backend = try GateBackend()
        try await backend.seed()
        let history = source(backend)
        let pages = Collector(history.day(pastDay))
        #expect(await eventually { pages.values.count == 1 })

        // A catch-up pass writing the day's rows one by one, every 50 ms.
        for step in 1...10 {
            try await backend.execute("UPDATE annotations SET title = 'Step \(step)' WHERE conversationId = 'c1'")
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await eventually { backend.builds.value == 2 })
        await settle(.milliseconds(2_500))
        #expect(backend.builds.value == 2)
        #expect(pages.values.count == 2)
        let title = pages.values.last!.day.items.compactMap { item -> String? in
            if case .chapter(let block) = item { return block.title } else { return nil }
        }.first
        #expect(title == "Step 10")
        pages.cancel()
    }

    @Test("a pending delete of a conversation in the window rebuilds the visible page")
    func pendingDeleteRebuilds() async throws {
        let backend = try GateBackend()
        try await backend.seed()
        let history = source(backend)
        let pages = Collector(history.day(pastDay))
        #expect(await eventually { pages.values.count == 1 })
        await settle(.milliseconds(100))

        history.pendingDeletesChanged(conversationId: "not-here")
        await settle()
        #expect(backend.builds.value == 1)

        history.pendingDeletesChanged(conversationId: "c1")
        #expect(await eventually { backend.builds.value == 2 })
        pages.cancel()
    }

    @Test("prefetch builds once without observing, and a later subscription reuses it")
    func prefetchDoesNotObserve() async throws {
        let backend = try GateBackend()
        try await backend.seed()
        let history = source(backend)
        history.prefetch(days: [pastDay])
        #expect(await eventually { backend.builds.value == 1 })
        let fetches = backend.fetches.value
        try await backend.execute("UPDATE annotations SET title = 'Unobserved' WHERE conversationId = 'c1'")
        await settle()
        #expect(backend.fetches.value == fetches, "a prefetched day is observed")
        #expect(backend.builds.value == 1)

        // Subscribing shows the prefetched page at once, then the observation finds the change.
        let pages = Collector(history.day(pastDay))
        #expect(await eventually { pages.values.count == 2 })
        #expect(backend.builds.value == 2)
        pages.cancel()
    }
}
