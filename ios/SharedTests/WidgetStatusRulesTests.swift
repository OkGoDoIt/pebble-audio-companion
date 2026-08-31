import XCTest

/// The widgets' status derivation. Everything a widget asserts about a microphone comes through
/// here, so this is where "honest when the data is missing or old" is actually enforced.
final class WidgetStatusRulesTests: XCTestCase {
    private let now: Int64 = 1_756_512_000_000

    private func snapshot(
        state: CoverageSnapshot.State,
        headline: String,
        dot: String = "active",
        ageMs: Int64 = 0,
        startedAtMs: Int64? = nil,
        liveTitle: String? = nil
    ) -> CoverageSnapshot {
        CoverageSnapshot(
            generatedAtMs: now - ageMs,
            dateKey: "2026-08-30",
            dayStartMs: now - 10 * 3_600_000,
            nowMs: now - ageMs,
            spans: [],
            totalRecordedMs: 0,
            totalMissingMs: 0,
            headline: headline,
            dot: dot,
            isRecording: state == .recording,
            state: state,
            currentStartedAtMs: startedAtMs,
            liveTitle: liveTitle
        )
    }

    private func rules(
        _ snapshot: CoverageSnapshot?,
        pending: SharedCaptureIntent? = nil,
        applied: SharedCaptureIntent
    ) -> WidgetStatusRules {
        WidgetStatusRules(snapshot: snapshot, pending: pending, applied: applied, nowMs: now)
    }

    // MARK: - Nothing written yet

    /// The state Roger's phone was actually in. It must say "not recording" rather than invent
    /// an empty day, and it must not offer to "Resume" something that was never running.
    func testNoSnapshotClaimsNothingAndOffersTheRightVerb() {
        let off = rules(nil, applied: .off)
        XCTAssertEqual(off.word, .notRecording)
        XCTAssertFalse(off.hasData)
        XCTAssertFalse(off.isRecording)
        XCTAssertFalse(off.offersPause)
        XCTAssertTrue(off.isOff)
        XCTAssertNil(off.startedAtMs)

        // Off and paused stay distinct even with no file at all: one resumes on its own, the
        // other does not, and the button word differs because of it.
        let paused = rules(nil, applied: .paused)
        XCTAssertEqual(paused.word, .paused)
        XCTAssertFalse(paused.offersPause)
        XCTAssertFalse(paused.isOff)
    }

    // MARK: - Staleness

    func testAStaleSnapshotNeverClaimsRecording() {
        let stale = snapshot(
            state: .recording, headline: "Recording",
            ageMs: CoverageSnapshot.staleAfterMs + 1, startedAtMs: now - 3_600_000
        )
        let derived = rules(stale, applied: .active)

        XCTAssertTrue(derived.isStale)
        XCTAssertFalse(derived.isRecording)
        // No timer: counting up from an hour-old start is the most confident-looking lie the
        // widget can tell.
        XCTAssertNil(derived.startedAtMs)
        // And the word goes into the past tense rather than reading as "on right now".
        XCTAssertEqual(derived.word, .lastSeen("Recording"))
        XCTAssertEqual(derived.asOfMs, stale.generatedAtMs)
    }

    func testAFreshSnapshotAssertsTheStateAndTheTimer() {
        let fresh = snapshot(
            state: .recording, headline: "Recording", ageMs: 60_000,
            startedAtMs: now - 900_000
        )
        let derived = rules(fresh, applied: .active)

        XCTAssertFalse(derived.isStale)
        XCTAssertTrue(derived.isRecording)
        XCTAssertEqual(derived.startedAtMs, now - 900_000)
        XCTAssertEqual(derived.word, .observed("Recording"))
        XCTAssertNil(derived.asOfMs)
        XCTAssertTrue(derived.offersPause)
    }

    /// A snapshot exactly on the boundary is still trusted; one millisecond past it is not.
    func testTheStalenessBoundaryIsExclusive() {
        let onEdge = snapshot(
            state: .recording, headline: "Recording", ageMs: CoverageSnapshot.staleAfterMs
        )
        XCTAssertFalse(rules(onEdge, applied: .active).isStale)
    }

    func testABlankHeadlineFallsBackToThePreferenceRatherThanAnEmptyRow() {
        let blank = snapshot(state: .notRecording, headline: "   ")
        XCTAssertEqual(rules(blank, applied: .paused).word, .paused)
        XCTAssertEqual(rules(blank, applied: .off).word, .notRecording)
    }

    // MARK: - A v1 file from an app that has not been updated

    func testAV1SnapshotIsNotTreatedAsIdle() {
        // `state` absent, `isRecording` true — the widget must trust the flag it does have.
        let json = """
            {"version":1,"generatedAtMs":\(now),"dateKey":"2026-08-30","dayStartMs":\(now - 3_600_000),
             "nowMs":\(now),"spans":[],"totalRecordedMs":0,"totalMissingMs":0,
             "headline":"Recording","dot":"active","isRecording":true}
            """
        let decoded = CoverageSnapshot.load(from: Data(json.utf8))
        let derived = rules(decoded, applied: .active)

        XCTAssertTrue(derived.isRecording)
        XCTAssertEqual(derived.word, .observed("Recording"))
        // v1 carries no start instant, so there is no timer to show — and none is invented.
        XCTAssertNil(derived.startedAtMs)
    }

    // MARK: - Unconfirmed requests

    func testAnUnconfirmedRequestWinsTheWordAndTheButton() {
        let idle = snapshot(state: .notRecording, headline: "Not recording", dot: "neutral")
        let resuming = rules(idle, pending: .active, applied: .off)
        XCTAssertEqual(resuming.word, .resuming)
        XCTAssertTrue(resuming.offersPause)
        // The request is to start, so the button is no longer offering "Start Recording".
        XCTAssertFalse(resuming.isOff)

        let live = snapshot(state: .recording, headline: "Recording")
        let pausing = rules(live, pending: .paused, applied: .active)
        XCTAssertEqual(pausing.word, .pausing)
        XCTAssertFalse(pausing.offersPause)
        XCTAssertFalse(pausing.isOff)
    }

    /// A request that agrees with what the snapshot already says is not "…ing" — the app has
    /// nothing left to confirm, so the widget states it plainly.
    func testARequestThatMatchesTheObservedStateReadsAsThatState() {
        let live = snapshot(state: .recording, headline: "Recording")
        XCTAssertEqual(rules(live, pending: .active, applied: .active).word, .observed("Recording"))
    }

    // MARK: - Preference vs observation

    /// The two can legitimately disagree — a watch-side stop, a preference not applied yet. A
    /// fresh snapshot that says capture IS running wins the button, because "Recording" above a
    /// "Resume" button is incoherent whichever half is right.
    func testAFreshRecordingSnapshotOffersPauseEvenWhenThePreferenceSaysOtherwise() {
        let live = snapshot(state: .recording, headline: "Recording")
        let derived = rules(live, applied: .paused)

        XCTAssertTrue(derived.offersPause)
        XCTAssertFalse(derived.isOff)
    }

    /// …and when the snapshot is stale, the preference wins, because an intent writes it
    /// synchronously and it is therefore the fresher of the two.
    func testAStalePreferenceStillDrivesTheButton() {
        let stale = snapshot(
            state: .recording, headline: "Recording", ageMs: CoverageSnapshot.staleAfterMs + 1
        )
        XCTAssertTrue(rules(stale, applied: .active).offersPause)

        let offNow = rules(stale, applied: .off)
        XCTAssertFalse(offNow.offersPause)
        XCTAssertTrue(offNow.isOff)
    }

    // MARK: - Off is never described as paused

    func testOffIsDistinctFromPausedAndFromNotConnected() {
        let cases: [(CoverageSnapshot.State, String, SharedCaptureIntent, Bool)] = [
            (.notRecording, "Not recording", .off, true),
            (.paused, "Paused", .paused, false),
            (.reconnecting, "Reconnecting", .active, false),
            (.connecting, "Connecting", .active, false),
            (.bluetoothOff, "Bluetooth is off", .active, false),
        ]
        for (state, headline, applied, expectedOff) in cases {
            let derived = rules(snapshot(state: state, headline: headline), applied: applied)
            XCTAssertEqual(
                derived.isOff, expectedOff,
                "\(state) with intent \(applied) should\(expectedOff ? "" : " not") read as off")
            XCTAssertFalse(derived.isRecording, "\(state) is not recording")
        }
    }
}
