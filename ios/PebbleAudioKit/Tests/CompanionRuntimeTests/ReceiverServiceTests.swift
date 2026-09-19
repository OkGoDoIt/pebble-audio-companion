import AppDB
import CompanionRuntime
import Foundation
import Receiver
import SegmentStore
import Testing
import WireProtocol

// The capture-intent tri-state (plan 6.1), the one-shot watch prompt, and the Stop→Start race.
//
// The link here never connects, so `requestPause`/`requestResume` return false (no ack) — which
// is exactly the case the pause journal must NOT write a row for: coverage may never claim a
// pause the watch never took.

@Suite struct ReceiverServiceTests {

    @Test func watchEnableRequestIsArmedOnceAndConsumedOnce() async throws {
        let fixture = try RuntimeFixture()
        #expect(!fixture.receiver.isWatchEnableRequestArmed)

        await fixture.receiver.armWatchEnableRequest()
        #expect(fixture.receiver.isWatchEnableRequestArmed)

        // Only an explicit Start/Settings tap arms it; a plain start does not.
        await fixture.receiver.stop()
        #expect(!fixture.receiver.isWatchEnableRequestArmed)

        await fixture.receiver.start()
        #expect(!fixture.receiver.isWatchEnableRequestArmed)
    }

    @Test func startCaptureArmsTheWatchPromptButForegroundEntryDoesNot() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(captureIntent: .off)
        )
        await fixture.runtime.setForeground(false)
        await fixture.runtime.setForeground(true)
        #expect(!fixture.receiver.isWatchEnableRequestArmed)

        await fixture.runtime.startCapture()
        #expect(fixture.runtime.captureIntent == .active)
    }

    /// The reported deadlock, met by the user's own instinctive gesture. Foreground entry already
    /// asked the watch what it was doing; the answer just went nowhere. When the watch says it is
    /// recording and this app holds no stream, that answer has to act — otherwise "leave the app
    /// and come back" helps only by coincidence, which is exactly what was reported.
    @Test func foregroundEntryRebuildsALinkTheWatchIsRecordingIntoAVoid() async throws {
        let fixture = try RuntimeFixture()
        // Authorized with no stream, and the fake watch's Info says it is streaming.
        fixture.receiver.state.value = .authorized

        await fixture.runtime.setForeground(false)
        await fixture.runtime.setForeground(true)

        #expect(fixture.link.resyncCount == 1)
    }

    /// ...and leaves a healthy stream alone. A link that is working must never be rebuilt by the
    /// act of looking at the app.
    @Test func foregroundEntryLeavesAStreamWeAreReceivingAlone() async throws {
        let fixture = try RuntimeFixture()
        fixture.receiver.state.value = .streaming(streamId: 7)

        await fixture.runtime.setForeground(false)
        await fixture.runtime.setForeground(true)

        #expect(fixture.link.resyncCount == 0)
    }

    // The watch turned background audio off by itself (a fault-loop stand-down) at 20:01 on
    // 2026-09-09 and the app sat in denied(3) for two hours, retrying an authorization that can
    // never succeed and telling nobody. Once per entry into that state, the person is told.
    @Test func theWatchTurningItselfOffWhileRecordingIsWantedIsAnnouncedOnce() async throws {
        let fixture = try RuntimeFixture(settings: RuntimeSettingsSnapshot(captureIntent: .active))
        await fixture.receiver.start()
        fixture.receiver.state.value = .streaming(streamId: 7)
        #expect(fixture.lossNotifier.watchOffNotices == 0)

        fixture.receiver.state.value = .denied(statusRaw: Int(AuthStatus.deniedDisabled.rawValue))
        #expect(await waitUntil { fixture.lossNotifier.watchOffNotices == 1 })

        // The session keeps re-trying: authorizing -> denied again is the same fact, not news.
        fixture.receiver.state.value = .authorizing
        fixture.receiver.state.value = .denied(statusRaw: Int(AuthStatus.deniedDisabled.rawValue))
        #expect(!(await waitUntil { fixture.lossNotifier.watchOffNotices > 1 }))

        // Recording came back and the watch went off again: that is news.
        fixture.receiver.state.value = .streaming(streamId: 8)
        try await Task.sleep(nanoseconds: 50_000_000)
        fixture.receiver.state.value = .denied(statusRaw: Int(AuthStatus.deniedDisabled.rawValue))
        #expect(await waitUntil { fixture.lossNotifier.watchOffNotices == 2 })

        // A mismatch denial is a different problem and says nothing about the watch's switch.
        fixture.receiver.state.value = .streaming(streamId: 9)
        try await Task.sleep(nanoseconds: 50_000_000)
        fixture.receiver.state.value = .denied(statusRaw: Int(AuthStatus.deniedMismatch.rawValue))
        #expect(!(await waitUntil { fixture.lossNotifier.watchOffNotices > 2 }))
        await fixture.receiver.stop()
    }

    @Test func armingWhileDeniedDisabledResyncsTheLink() async throws {
        let fixture = try RuntimeFixture()
        // The watch refused because Background Audio is off there: without a resync the new
        // enable request is never even seen.
        fixture.receiver.state.value = .denied(statusRaw: Int(AuthStatus.deniedDisabled.rawValue))

        await fixture.receiver.armWatchEnableRequest()

        #expect(fixture.link.resyncCount == 1)
    }

    @Test func armingWhileMerelyDisconnectedDoesNotResync() async throws {
        let fixture = try RuntimeFixture()
        await fixture.receiver.armWatchEnableRequest()
        #expect(fixture.link.resyncCount == 0)
    }

    @Test func startIsIdempotent() async throws {
        let fixture = try RuntimeFixture()
        await fixture.receiver.start()
        await fixture.receiver.start()
        await fixture.receiver.start()
        #expect(fixture.receiver.isRunning)
        await fixture.receiver.stop()
        #expect(!fixture.receiver.isRunning)
    }

    @Test func stopReceivingPausesFirstThenTearsDownAndDisconnects() async throws {
        let fixture = try RuntimeFixture()
        await fixture.receiver.start()
        // Intent is already off by the time Stop reaches the receiver (the caller flips it
        // first), so no resume race applies.
        await fixture.receiver.applyCaptureIntent(.off)

        #expect(!fixture.receiver.isRunning)
        #expect(fixture.link.disconnectCount == 1)
    }

    @Test func stopReceivingKeepsTheSessionWhenTheUserRestartsMidFlight() async throws {
        let fixture = try RuntimeFixture()
        await fixture.receiver.start()
        // The race: intent flips back to .active while the pause request is in flight. Tearing
        // down here would strand the restart — a dead session with the intent on.
        await fixture.receiver.applyCaptureIntent(.active)
        await fixture.receiver.stopReceiving()

        #expect(fixture.receiver.isRunning, "a live session must survive a Stop→Start race")
        #expect(fixture.link.disconnectCount == 0)
    }

    // MARK: - Pause journal (plan 6.1)

    @Test func anUnacknowledgedPauseWritesNoJournalRow() async throws {
        let fixture = try RuntimeFixture()
        await fixture.receiver.start()

        await fixture.receiver.applyCaptureIntent(.paused)

        #expect(fixture.receiver.captureIntent == .paused)
        let open = try await fixture.pauseJournal.openInterval()
        #expect(open == nil, "coverage must never claim a pause the watch never acked")
    }

    @Test func anAckedPauseBeginsAJournalRowAndResumeEndsIt() async throws {
        let fixture = try RuntimeFixture()
        let clock = fixture.clock
        let journal = fixture.pauseJournal

        // The ack path is exercised directly: the journal is the contract, not the BLE write.
        _ = try await journal.begin(source: .statusCard, atMs: clock.nowMs)
        let open = try await journal.openInterval()
        #expect(open?.endMs == nil)
        #expect(open?.source == PauseSource.statusCard.rawValue)

        await clock.advance(by: 120_000)
        try await journal.end(atMs: clock.nowMs)

        #expect(try await journal.openInterval() == nil)
        let all = try await journal.all()
        #expect(all.count == 1)
        #expect(all[0].endMs == 120_000)
    }

    @Test func pauseIntervalsAreIdempotentSoADoubleAckNeverStacks() async throws {
        let fixture = try RuntimeFixture()
        let journal = fixture.pauseJournal

        _ = try await journal.begin(source: .statusCard, atMs: 0)
        _ = try await journal.begin(source: .liveScreen, atMs: 500)

        #expect(try await journal.all().count == 1)
    }

    @Test func goingOffFromPausedClosesTheOpenInterval() async throws {
        let fixture = try RuntimeFixture()
        await fixture.receiver.start()
        _ = try await fixture.pauseJournal.begin(source: .statusCard, atMs: 0)
        // Reach `.paused` without an ack so the transition to `.off` is the thing under test.
        await fixture.receiver.applyCaptureIntent(.paused)
        await fixture.clock.advance(by: 30_000)

        await fixture.receiver.applyCaptureIntent(.off)

        let open = try await fixture.pauseJournal.openInterval()
        #expect(open == nil, "'off' is its own coverage state, not an endless pause")
    }

    @Test func captureIntentTransitionsAreRecordedOnTheRuntime() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(captureIntent: .off)
        )
        await fixture.runtime.setCaptureIntent(.active)
        #expect(fixture.runtime.captureIntent == .active)

        await fixture.runtime.setCaptureIntent(.paused, source: .intent)
        #expect(fixture.runtime.captureIntent == .paused)

        await fixture.runtime.setCaptureIntent(.off)
        #expect(fixture.runtime.captureIntent == .off)
    }

    /// The recorder names the surface behind every transition. Without this, a recording that
    /// stops reads identically whether a switch was flipped or the app stopped on its own
    /// (2026-09-19 12:17:27), and those need opposite fixes.
    @Test func everyIntentTransitionNamesItsSurfaceInTheLog() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(captureIntent: .off)
        )
        await fixture.runtime.applyExternalCaptureIntent(.active, source: .settingsSwitch)
        await fixture.runtime.setCaptureIntent(.paused, source: .intent)
        await fixture.runtime.setCaptureIntent(.paused, source: .liveScreen)  // no change: silent
        await fixture.runtime.applyExternalCaptureIntent(.off, source: .forgetWatch)

        let transitions = fixture.receiverLog.lines.filter { $0.hasPrefix("capture intent ") }
        #expect(
            transitions == [
                "capture intent off -> active, asked by Settings switch",
                "capture intent active -> paused, asked by Control Center / widget / Siri",
                "capture intent paused -> off, asked by Forget Watch",
            ])
    }

    // MARK: - The Settings "Background audio" master switch

    // The switch wrote `AppSettings.captureIntent` and nothing else, which made it lie in both
    // directions: ON left the watch uncontacted while every surface said "Recording", and OFF
    // left the receiver running on someone who had just switched recording off. It now calls
    // `applyExternalCaptureIntent` — the same entry point Control Center uses — so these two
    // tests are the contract that switch depends on.

    @Test func theMasterSwitchOnArmsTheWatchPromptAndDialsTheLink() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(captureIntent: .off)
        )

        await fixture.runtime.applyExternalCaptureIntent(.active)

        #expect(fixture.receiver.isWatchEnableRequestArmed, "ON must ask the watch, once")
        #expect(fixture.link.resyncCount == 1, "an intent nothing dials never reaches the watch")
        #expect(fixture.runtime.captureIntent == .active)
    }

    @Test func theMasterSwitchOffStopsReceivingAndEndsAnyPause() async throws {
        let fixture = try RuntimeFixture(
            settings: RuntimeSettingsSnapshot(captureIntent: .paused)
        )
        await fixture.receiver.start()
        _ = try await fixture.pauseJournal.begin(source: .statusCard, atMs: 0)
        await fixture.clock.advance(by: 30_000)

        await fixture.runtime.applyExternalCaptureIntent(.off)

        #expect(fixture.runtime.captureIntent == .off)
        #expect(!fixture.receiver.isRunning, "OFF must stop the receiver, not just the preference")
        #expect(fixture.link.disconnectCount == 1)
        // Left open, coverage would render every hour after "off" as an endless pause.
        #expect(try await fixture.pauseJournal.openInterval() == nil)
    }

    @Test func revokingLocallyClearsTheResumeStateAndDropsTheLink() async throws {
        let fixture = try RuntimeFixture()
        let resumeStore = FileReceiverResumeStore(root: fixture.root)
        await resumeStore.save(
            ReceiverResumeState(lastStreamId: 7, lastContiguousSequence: 3, lastSampleIndex: 960)
        )
        await fixture.receiver.start()

        await fixture.receiver.revokeReceiverLocally()

        #expect(await resumeStore.load() == nil)
        #expect(!fixture.receiver.isRunning)
        #expect(fixture.link.disconnectCount == 1)
    }
}
