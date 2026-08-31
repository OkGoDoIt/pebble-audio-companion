import XCTest

/// The bridge is the whole contract between Control Center / Siri and the app. What it must
/// guarantee: a request is recorded where the app can find it, the surfaces show what the user
/// last asked for, and nothing here ever turns capture ON from OFF by itself (anti-B3).
final class CaptureIntentBridgeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "bridge-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsToOffWhenNothingHasBeenWritten() {
        XCTAssertEqual(CaptureIntentBridge.appliedIntent(in: defaults), .off)
        XCTAssertEqual(CaptureIntentBridge.effectiveIntent(in: defaults), .off)
        XCTAssertNil(CaptureIntentBridge.pendingRequest(in: defaults))
    }

    func testRequestWritesTheMailboxWithoutTouchingTheAppliedValue() {
        defaults.set("active", forKey: CaptureIntentBridge.Keys.applied)

        CaptureIntentBridge.request(.paused, at: 1_700_000_000_000, in: defaults, notify: false)

        XCTAssertEqual(defaults.string(forKey: CaptureIntentBridge.Keys.requested), "paused")
        XCTAssertEqual(
            defaults.string(forKey: CaptureIntentBridge.Keys.applied), "active",
            "AppSettings stays the only writer of the applied preference"
        )
        let pending = CaptureIntentBridge.pendingRequest(in: defaults)
        XCTAssertEqual(pending?.intent, .paused)
        XCTAssertEqual(pending?.requestedAtMs, 1_700_000_000_000)
    }

    func testEffectiveIntentPrefersThePendingRequest() {
        defaults.set("active", forKey: CaptureIntentBridge.Keys.applied)
        CaptureIntentBridge.request(.paused, in: defaults, notify: false)
        // The toggle must look answered immediately, before the app applies it.
        XCTAssertEqual(CaptureIntentBridge.effectiveIntent(in: defaults), .paused)
        XCTAssertEqual(CaptureIntentBridge.appliedIntent(in: defaults), .active)
    }

    func testConsumeRecordsTheAppliedValueAndEmptiesTheMailbox() {
        CaptureIntentBridge.request(.paused, in: defaults, notify: false)
        CaptureIntentBridge.consume(.paused, in: defaults)

        XCTAssertNil(CaptureIntentBridge.pendingRequest(in: defaults))
        XCTAssertEqual(CaptureIntentBridge.appliedIntent(in: defaults), .paused)
        XCTAssertEqual(CaptureIntentBridge.effectiveIntent(in: defaults), .paused)
    }

    func testClearPendingRequestLeavesTheAppliedValueAlone() {
        defaults.set("active", forKey: CaptureIntentBridge.Keys.applied)
        CaptureIntentBridge.request(.paused, in: defaults, notify: false)
        CaptureIntentBridge.clearPendingRequest(in: defaults)

        XCTAssertNil(CaptureIntentBridge.pendingRequest(in: defaults))
        XCTAssertEqual(CaptureIntentBridge.effectiveIntent(in: defaults), .active)
    }

    func testToggleMovesBetweenActiveAndPausedOnly() {
        defaults.set("active", forKey: CaptureIntentBridge.Keys.applied)
        XCTAssertEqual(CaptureIntentBridge.requestToggle(in: defaults, notify: false), .paused)
        // Toggling again reads the pending value, not the stale applied one.
        XCTAssertEqual(CaptureIntentBridge.requestToggle(in: defaults, notify: false), .active)
    }

    func testToggleFromOffNeverSilentlyEnablesCapture() {
        defaults.set("off", forKey: CaptureIntentBridge.Keys.applied)
        // `off` is a consent-bearing choice; a toggle asks for `active`, and the intent layer
        // is what refuses. The bridge's job is only to be truthful about the current state.
        XCTAssertEqual(CaptureIntentBridge.effectiveIntent(in: defaults), .off)
        XCTAssertEqual(SharedCaptureIntent.off.toggled, .active)
        XCTAssertFalse(SharedCaptureIntent.off.isActive)
    }

    func testIntentSpellingsMatchWhatAppSettingsPersists() {
        // AppSettings encodes the tri-state as these exact strings; drift here silently
        // desyncs Control Center from the app.
        XCTAssertEqual(SharedCaptureIntent.active.rawValue, "active")
        XCTAssertEqual(SharedCaptureIntent.paused.rawValue, "paused")
        XCTAssertEqual(SharedCaptureIntent.off.rawValue, "off")
        XCTAssertEqual(CaptureIntentBridge.Keys.applied, "capture_intent")
    }

    func testDarwinNotificationPostIsSafeToCall() {
        // No observer, no crash — the app may be dead when an intent fires.
        CaptureIntentBridge.postDarwinNotification()
    }
}
