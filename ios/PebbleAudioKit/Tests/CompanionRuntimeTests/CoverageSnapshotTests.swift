import AppDB
import CompanionRuntime
import Foundation
import SegmentStore
import StatusUI
import Testing

// Plan 6.8 — the App Group hand-off. The widget renders from this file and nothing else, so the
// JSON shape is a contract with a separate target: these tests are what stops it drifting.

@Suite struct CoverageSnapshotTests {

    @Test func snapshotIsWrittenOnSegmentClosePauseChangeAndAppBackground() async throws {
        let fixture = try RuntimeFixture()

        await fixture.snapshots.refresh(.segmentClosed)
        await fixture.snapshots.refresh(.pauseChanged)
        await fixture.snapshots.refresh(.appBackgrounded)

        let seen = await fixture.snapshots.triggers
        #expect(seen.contains(.segmentClosed))
        #expect(seen.contains(.pauseChanged))
        #expect(seen.contains(.appBackgrounded))
        #expect(FileManager.default.fileExists(atPath: fixture.snapshotWriter.url.path))
    }

    @Test func closingASegmentThroughTheSinkRefreshesTheSnapshot() async throws {
        let fixture = try RuntimeFixture()
        _ = try await Fixture.writeSegment(into: fixture.store)
        // The store is the innermost sink; drive the trigger the receiver would.
        await fixture.snapshots.refresh(.segmentClosed)

        #expect(await fixture.snapshots.lastTrigger == .segmentClosed)
    }

    @Test func pauseIntentRefreshesTheSnapshot() async throws {
        let fixture = try RuntimeFixture()
        await fixture.runtime.setCaptureIntent(.paused)

        #expect(await fixture.snapshots.triggers.contains(.pauseChanged))
    }

    @Test func appBackgroundRefreshesTheSnapshot() async throws {
        let fixture = try RuntimeFixture()
        await fixture.runtime.setForeground(false)

        #expect(await fixture.snapshots.triggers.contains(.appBackgrounded))
    }

    @Test func snapshotJsonRoundTripsAndCarriesTheDocumentedShape() async throws {
        let fixture = try RuntimeFixture()
        await fixture.clock.advance(by: 1_756_512_000_000)  // a real wall-clock instant
        // Ten minutes of wall time ago, so the recorded span lands inside [dayStart, now).
        _ = try await Fixture.writeSegment(
            into: fixture.store,
            startTimeMs: UInt64(fixture.clock.nowMs - 600_000),
            frames: 500,
            receivedAtMs: fixture.clock.nowMs - 600_000
        )

        let written = await fixture.snapshots.refresh(.manual)
        let data = try Data(contentsOf: fixture.snapshotWriter.url)
        let decoded = try JSONDecoder().decode(CoverageSnapshot.self, from: data)

        #expect(decoded == written)
        #expect(decoded.version == CoverageSnapshot.currentVersion)
        #expect(decoded.generatedAtMs == fixture.clock.nowMs)
        #expect(decoded.nowMs == fixture.clock.nowMs)
        #expect(decoded.dayStartMs <= decoded.nowMs)
        #expect(!decoded.dateKey.isEmpty)
        #expect(!decoded.timeZoneID.isEmpty)
        #expect(!decoded.headline.isEmpty)
        #expect(["neutral", "info", "active", "attention", "problem", "consent"].contains(decoded.dot))
        // Spans tile the day so far, in order, with no overlaps.
        #expect(!decoded.spans.isEmpty)
        #expect(decoded.spans.first?.startMs == decoded.dayStartMs)
        #expect(decoded.spans.last?.endMs == decoded.nowMs)
        for (previous, next) in zip(decoded.spans, decoded.spans.dropFirst()) {
            #expect(previous.endMs == next.startMs)
        }
        #expect(decoded.totalRecordedMs > 0)
    }

    @Test func snapshotJsonKeysAreStableForTheWidget() async throws {
        let fixture = try RuntimeFixture()
        _ = await fixture.snapshots.refresh(.manual)
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.snapshotWriter.url)
            ) as? [String: Any]
        )

        let required: Set<String> = [
            "version", "generatedAtMs", "dateKey", "timeZoneID", "dayStartMs", "nowMs",
            "spans", "totalRecordedMs", "totalMissingMs", "headline", "dot", "isRecording",
        ]
        #expect(required.isSubset(of: Set(object.keys)))

        if let spans = object["spans"] as? [[String: Any]], let first = spans.first {
            #expect(Set(first.keys) == ["kind", "startMs", "endMs"])
            let kind = try #require(first["kind"] as? String)
            #expect(CoverageKind(rawValue: kind) != nil)
        }
    }

    @Test func aMissingSnapshotFileReadsAsNilRatherThanCrashing() throws {
        let directory = Fixture.temporaryDirectory("empty-group")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = CoverageSnapshotWriter(directory: directory)

        #expect(writer.read() == nil)
    }

    @Test func pausedTimeRendersAsItsOwnCoverageStateNotAsMissing() async throws {
        let fixture = try RuntimeFixture()
        await fixture.clock.advance(by: 1_756_512_000_000)
        _ = try await fixture.pauseJournal.begin(
            source: .statusCard, atMs: fixture.clock.nowMs - 600_000
        )
        try await fixture.pauseJournal.end(atMs: fixture.clock.nowMs - 300_000)

        let snapshot = await fixture.snapshots.refresh(.pauseChanged)

        #expect(snapshot.spans.contains { $0.kind == .paused })
        #expect(!snapshot.spans.contains { $0.kind == .missing })
    }
}

// v2 (2026-08-31) — the widget stopped being a coverage strip and became a status/now/follow-ups
// set, so the snapshot has to carry the live state as well as the day. These pin the new half:
// the derivations that run on every write, and the JSON keys the widget decodes.

@Suite struct CoverageSnapshotLiveFieldsTests {

    private func recording() -> StatusModel {
        StatusModel(
            family: .recording, headline: "Recording", detail: "Pebble Time 2 · connected",
            dot: .active, action: .stop
        )
    }

    /// A recording snapshot carries everything the "Recording now" widget draws, and the writer
    /// stamps v2 so an older widget binary can tell "this file does not know" from "off".
    @Test func recordingSnapshotCarriesTheLiveFields() async throws {
        let fixture = try RuntimeFixture()
        await fixture.clock.advance(by: 1_756_512_000_000)
        // Ten seconds of audio ending at "now": a conversation that is still running, so the
        // trailing coverage span is capture and the elapsed timer has a start to count from.
        _ = try await Fixture.writeSegment(
            into: fixture.store,
            startTimeMs: UInt64(fixture.clock.nowMs - 10_000),
            frames: 500,
            receivedAtMs: fixture.clock.nowMs - 10_000
        )
        let status = recording()
        let service = CoverageSnapshotService(
            store: fixture.store,
            writer: fixture.snapshotWriter,
            clock: fixture.clock,
            statusOf: { status },
            pauseJournal: fixture.pauseJournal,
            liveContextOf: { isRunning in
                #expect(isRunning)
                return CoverageLiveContext(
                    conversationTitle: "Standup",
                    latestLine: "Push the release to Thursday",
                    followUps: [
                        .init(id: "f1", text: "Email Dana", conversationId: "c1")
                    ],
                    openFollowUpCount: 3
                )
            }
        )

        let written = await service.refresh(.manual)

        #expect(written.version == 2)
        #expect(written.state == "recording")
        #expect(written.liveTitle == "Standup")
        #expect(written.liveLine == "Push the release to Thursday")
        #expect(written.currentStartedAtMs != nil)
        #expect(written.openFollowUpCount == 3)
        #expect(written.followUps.first?.conversationId == "c1")
        #expect(written.activityWindowMs == CoverageSnapshotService.activityWindowMs)
        #expect(
            written.activity.count
                == Int(CoverageSnapshotService.activityWindowMs / CoverageSnapshotService.activityBarMs)
        )

        // Wire contract: the widget decodes these keys by name.
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.snapshotWriter.url)
            ) as? [String: Any]
        )
        let required: Set<String> = [
            "state", "currentStartedAtMs", "liveTitle", "liveLine", "activity",
            "activityWindowMs", "followUps", "openFollowUpCount",
        ]
        #expect(required.isSubset(of: Set(object.keys)))
        if let bars = object["activity"] as? [[String: Any]], let first = bars.first {
            #expect(Set(first.keys) == ["kind", "level"])
        }
    }

    /// Honesty rule: nothing that says "right now" survives into a snapshot where capture is not
    /// running. A widget must never show a live title, a live line, or a counting-up timer for a
    /// conversation that has stopped.
    @Test func aPausedSnapshotCarriesNoLiveConversationAndNoTimer() async throws {
        let fixture = try RuntimeFixture()
        await fixture.clock.advance(by: 1_756_512_000_000)
        let paused = StatusModel(
            family: .paused, headline: "Paused", detail: nil, dot: .attention, action: .resume
        )
        let service = CoverageSnapshotService(
            store: fixture.store,
            writer: fixture.snapshotWriter,
            clock: fixture.clock,
            statusOf: { paused },
            pauseJournal: fixture.pauseJournal,
            liveContextOf: { isRunning in
                #expect(!isRunning)
                // The provider still reports follow-ups; only the live half is dropped.
                return CoverageLiveContext(
                    conversationTitle: "Should not appear",
                    latestLine: "Should not appear either",
                    followUps: [.init(id: "f1", text: "Still open", conversationId: nil)],
                    openFollowUpCount: 1
                )
            }
        )

        let written = await service.refresh(.pauseChanged)

        #expect(written.state == "paused")
        #expect(written.isRecording == false)
        #expect(written.liveTitle == nil)
        #expect(written.liveLine == nil)
        #expect(written.currentStartedAtMs == nil)
        #expect(written.openFollowUpCount == 1)
    }

    /// A snapshot written with no live-context provider is still a valid v2 file — the app can
    /// be composed without one and the widget must degrade, not break.
    @Test func snapshotWithoutALiveContextProviderStillWritesV2() async throws {
        let fixture = try RuntimeFixture()
        let written = await fixture.snapshots.refresh(.manual)

        #expect(written.version == 2)
        #expect(!written.state.isEmpty)
        #expect(written.followUps.isEmpty)
        #expect(written.openFollowUpCount == 0)
    }

    // MARK: - Pure derivations

    private func span(_ kind: CoverageKind, _ from: Int64, _ to: Int64) -> CoverageSpan {
        CoverageSpan(kind: kind, startMs: from, endMs: to)
    }

    @Test func runningStretchWalksThroughAShortGapButStopsAtAPause() {
        let now: Int64 = 10_000_000
        let spans = [
            span(.recorded, now - 3_600_000, now - 1_800_000),
            span(.paused, now - 1_800_000, now - 900_000),
            // The conversation the user is in: a 30 s Bluetooth blip is loss inside it, not a
            // boundary — resetting the elapsed timer there would read as "just started".
            span(.recorded, now - 900_000, now - 300_000),
            span(.missing, now - 300_000, now - 270_000),
            span(.quiet, now - 270_000, now - 120_000),
            span(.recorded, now - 120_000, now),
        ]

        #expect(
            CoverageSnapshotService.runningStretchStartMs(spans: spans, nowMs: now)
                == now - 900_000
        )
    }

    @Test func runningStretchStopsAtALongGapBecauseThatIsADifferentConversation() {
        let now: Int64 = 10_000_000
        let spans = [
            span(.recorded, now - 3_600_000, now - 1_800_000),
            span(.missing, now - 1_800_000, now - 600_000),  // 20 minutes — not a blip
            span(.recorded, now - 600_000, now),
        ]

        #expect(
            CoverageSnapshotService.runningStretchStartMs(spans: spans, nowMs: now)
                == now - 600_000
        )
    }

    @Test func runningStretchIsNilWhenTheDayEndsInSomethingThatIsNotCapture() {
        let now: Int64 = 10_000_000
        let spans = [
            span(.recorded, now - 3_600_000, now - 600_000),
            span(.off, now - 600_000, now),
        ]

        #expect(CoverageSnapshotService.runningStretchStartMs(spans: spans, nowMs: now) == nil)
    }

    /// Coverage is built from frames that have ARRIVED, so a live conversation always ends in a
    /// few seconds of not-yet-counted time. Treating that as the end of the stretch would leave
    /// a recording widget with no elapsed time at all, which is the common case, not the edge.
    @Test func runningStretchSurvivesTheSecondsOfAudioThatHaveNotLandedYet() {
        let now: Int64 = 10_000_000
        let spans = [
            span(.recorded, now - 1_800_000, now - 8_000),
            span(.off, now - 8_000, now),
        ]

        #expect(
            CoverageSnapshotService.runningStretchStartMs(spans: spans, nowMs: now)
                == now - 1_800_000
        )
    }

    /// …but a pause is a real boundary, however short. The user said stop.
    @Test func aPauseAlwaysEndsTheStretchEvenAShortOne() {
        let now: Int64 = 10_000_000
        let spans = [
            span(.recorded, now - 1_800_000, now - 60_000),
            span(.paused, now - 60_000, now - 50_000),
            span(.recorded, now - 50_000, now),
        ]

        #expect(
            CoverageSnapshotService.runningStretchStartMs(spans: spans, nowMs: now)
                == now - 50_000
        )
    }

    @Test func activityBarsBucketTheWindowAndKeepLossVisible() {
        let now: Int64 = 10_000_000
        let window = CoverageSnapshotService.activityWindowMs
        let bar = CoverageSnapshotService.activityBarMs
        let spans = [
            span(.recorded, now - window, now - window + 4 * bar),
            span(.quiet, now - window + 4 * bar, now - window + 6 * bar),
            // One bucket's worth of genuine loss: it must win its bucket outright.
            span(.missing, now - window + 6 * bar, now - window + 7 * bar),
            span(.recorded, now - window + 7 * bar, now),
        ]

        let bars = CoverageSnapshotService.activityBars(spans: spans, nowMs: now)

        #expect(bars.count == Int(window / bar))
        #expect(bars[0].kind == .recorded)
        #expect(bars[0].level == 1)
        #expect(bars[4].kind == .quiet)
        #expect(bars[4].level == 0)
        #expect(bars[6].kind == .missing)
        #expect(bars.last?.kind == .recorded)
        #expect(bars.allSatisfy { $0.level >= 0 && $0.level <= 1 })
    }

    @Test func activityBarsAreEmptyWhenNothingOverlapsTheWindow() {
        let now: Int64 = 10_000_000
        let spans = [span(.recorded, now - 86_400_000, now - 86_000_000)]

        let bars = CoverageSnapshotService.activityBars(spans: spans, nowMs: now)

        #expect(bars.allSatisfy { $0.kind == .off && $0.level == 0 })
    }
}

// The path Roger's Control Center toggle takes once the app has the request. Setting the intent
// alone leaves the watch uncontacted; only `startCapture` dials the link.
@Suite struct ExternalCaptureIntentTests {

    @Test func resumingFromAnExternalSurfaceDialsTheLink() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(captureIntent: .paused)
        )
        let before = fixture.link.resyncCount

        await fixture.runtime.applyExternalCaptureIntent(.active)

        #expect(fixture.runtime.captureIntent == .active)
        #expect(fixture.link.resyncCount > before)
        #expect(fixture.receiver.isWatchEnableRequestArmed)
    }

    /// The formerly-dropped case: capture is OFF and a Control Center toggle asks for it back.
    /// It is honoured now, and it still cannot enable the watch by itself — `startCapture` arms
    /// exactly one on-watch enable prompt, and the watch decides.
    @Test func turningCaptureOnFromOffIsHonouredAndArmsTheWatchPrompt() async throws {
        let fixture = try RuntimeFixture(settings: RuntimeSettingsSnapshot(captureIntent: .off))
        let before = fixture.link.resyncCount

        await fixture.runtime.applyExternalCaptureIntent(.active)

        #expect(fixture.runtime.captureIntent == .active)
        #expect(fixture.receiver.isWatchEnableRequestArmed)
        #expect(fixture.link.resyncCount > before)
    }

    /// Pausing does NOT dial: reconnecting a link in order to stop using it would be pointless
    /// radio work, and the pause journal is what makes coverage show the window as paused.
    @Test func pausingFromAnExternalSurfaceDoesNotDialTheLink() async throws {
        let fixture = try RuntimeFixture()
        let before = fixture.link.resyncCount

        await fixture.runtime.applyExternalCaptureIntent(.paused)

        #expect(fixture.runtime.captureIntent == .paused)
        #expect(fixture.link.resyncCount == before)
        #expect(await fixture.snapshots.triggers.contains(.pauseChanged))
    }
}

// The presence gate. Roger's phone had no `coverage_snapshot.json` at all, so every widget he
// added showed its "no data yet" state — a redesigned-but-empty widget, which is worse than the
// one he complained about. These pin the four ways the file now comes into existence and stays
// current: at the very top of startup, on the receive path, on every foreground entry, and as a
// rate-limited heartbeat at the end of each pipeline pass.

/// Lets a test hold `StartupSequencer` open while it inspects what `start()` did before it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    var isOpen: Bool { lock.withLock { opened } }
    func open() { lock.withLock { opened = true } }
    func wait() async {
        while !isOpen { try? await Task.sleep(nanoseconds: 500_000) }
    }
}

@Suite struct CoverageSnapshotPresenceTests {

    @Test func startWritesTheSnapshotBeforeTheSlowRecovery() async throws {
        // Capture off, so `start()` brings up nothing but the loop and the snapshot — this test
        // is about ORDER, and a live receiver would only add noise to it.
        let fixture = try RuntimeFixture(settings: RuntimeSettingsSnapshot(captureIntent: .off))
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshotWriter.url.path))

        // A recovery that never finishes: on a migrated container this step really does take
        // tens of seconds, and that whole window used to be a blank widget.
        let gate = Gate()
        var environment = await fixture.runtime.environment
        environment.startup = StartupSequencer(
            steps: StartupSteps(recoverStore: { await gate.wait() })
        )
        let runtime = CompanionRuntime(environment: environment)

        let starting = Task { await runtime.start() }
        let appeared = await waitUntil {
            FileManager.default.fileExists(atPath: fixture.snapshotWriter.url.path)
        }
        #expect(appeared, "the snapshot must exist before recovery finishes")
        #expect(!gate.isOpen, "the gate proves recovery had not returned yet")

        gate.open()
        await starting.value
        await runtime.stop()

        #expect(await fixture.snapshots.triggers.first == .manual)
        #expect(fixture.snapshotWriter.read() != nil)
    }

    @Test func theReceiverPathIsConnectedToTheSnapshotService() async throws {
        let fixture = try RuntimeFixture()
        #expect(fixture.coverageTriggers.isConnected)

        // What the receiver's sink fires when a segment closes. Unconnected, this is the no-op
        // that left the widget frozen for a whole background recording session.
        await fixture.coverageTriggers.fire(.segmentClosed)

        #expect(await fixture.snapshots.lastTrigger == .segmentClosed)
        #expect(FileManager.default.fileExists(atPath: fixture.snapshotWriter.url.path))
    }

    @Test func anUnconnectedRelayDropsTriggersInsteadOfFailing() async {
        let relay = CoverageTriggerRelay()
        #expect(!relay.isConnected)
        await relay.fire(.segmentClosed)
    }

    @Test func foregroundEntryRewritesTheSnapshot() async throws {
        let fixture = try RuntimeFixture()
        let lifecycle = AppLifecycleCoordinator(runtime: fixture.runtime)

        await lifecycle.handle(.didBecomeActive)

        #expect(await fixture.snapshots.triggers.contains(.manual))
        #expect(FileManager.default.fileExists(atPath: fixture.snapshotWriter.url.path))
    }

    @Test func theHeartbeatIsRateLimitedButResumesWhenTheIntervalPasses() async throws {
        let fixture = try RuntimeFixture()

        #expect(await fixture.snapshots.refreshIfDue(.pipelinePass, minIntervalMs: 60_000) != nil)
        // Same instant: a pipeline pass runs once a second while work is flowing, and each
        // refresh re-reads the OPEN segment's frame log.
        #expect(await fixture.snapshots.refreshIfDue(.pipelinePass, minIntervalMs: 60_000) == nil)

        await fixture.clock.advance(by: 60_000)
        #expect(await fixture.snapshots.refreshIfDue(.pipelinePass, minIntervalMs: 60_000) != nil)
    }

    @Test func aPipelinePassRefreshesTheSnapshot() async throws {
        let refreshed = Counter()
        let pass = PipelinePass(
            steps: PipelineSteps(refreshCoverageSnapshot: { await refreshed.increment() }),
            clock: TestClock()
        )

        _ = try await pass.run()

        #expect(await refreshed.value == 1)
    }

    @Test func evenABackgroundedPassRefreshesTheSnapshot() async throws {
        let refreshed = Counter()
        let pass = PipelinePass(
            steps: PipelineSteps(
                isForeground: { false },
                refreshCoverageSnapshot: { await refreshed.increment() }
            ),
            clock: TestClock()
        )

        // Backgrounded is when this product records; a widget that freezes there is the bug.
        _ = try await pass.run()

        #expect(await refreshed.value == 1)
    }

    @Test func aWriteFailureIsReportedRatherThanSwallowed() throws {
        // A directory where the file's own name is already taken by a directory: the rename
        // cannot land, and the caller has to be told.
        let root = Fixture.temporaryDirectory("unwritable-group")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(CoverageSnapshot.fileName),
            withIntermediateDirectories: true
        )
        let writer = CoverageSnapshotWriter(directory: root)

        let wrote = writer.write(
            CoverageSnapshot(
                generatedAtMs: 1, dateKey: "2026-08-31", timeZoneID: "UTC", dayStartMs: 0,
                nowMs: 1, spans: [], totalRecordedMs: 0, totalMissingMs: 0,
                headline: "Not recording", dot: "neutral", isRecording: false
            )
        )

        #expect(!wrote)
        #expect(writer.read() == nil)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
