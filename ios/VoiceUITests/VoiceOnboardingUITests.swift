import XCTest

/// Explicit simulator smoke test; its separate scheme keeps model downloads out of unit tests.
/// Exercises the real composition, model installer, persistence and production views.
final class VoiceOnboardingUITests: XCTestCase {
    @MainActor func testRejectedMusePairingOffersReconnect() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.audiocompanion.app.dev")
        app.launchArguments = ["-onboarding.skip", "-route", "settings", "-muse.preview", "reconnect"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Reconnect Muse")).firstMatch
        for _ in 0..<4 {
            if row.exists && row.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(row.isHittable)
        row.tap()
        let reconnect = app.buttons["Reconnect Muse"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 10))
        XCTAssertTrue(reconnect.isEnabled && reconnect.isHittable)
        XCTAssertTrue(app.staticTexts["Muse no longer accepts this sign-in. Pair again to reconnect your watch."].exists)
        XCTAssertFalse(app.staticTexts["Paired with Muse"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Muse reconnect after rejected sign-in"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor func testOptionalSetupAndLocalModelInstallation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.audiocompanion.app.dev")
        app.launchArguments = ["-onboarding.skip", "-route", "settings/voices"]
        app.launch()
        let recognition = app.switches["Recognize voices"]
        XCTAssertTrue(recognition.waitForExistence(timeout: 20))
        if recognition.value as? String == "1" { recognition.tap() }
        XCTAssertEqual(recognition.value as? String, "0")
        app.buttons["Set up your voice"].tap()
        let prepare = app.buttons["Prepare voice recognition"]
        let name = app.textFields["Your name"]
        if prepare.waitForExistence(timeout: 3) { prepare.tap() }
        XCTAssertTrue(name.waitForExistence(timeout: 90), "Public voice models should install or already be cached")
        name.tap()
        name.typeText("Voice Test\n")
        let watchSample = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Quiet room")).firstMatch
        XCTAssertTrue(watchSample.waitForExistence(timeout: 5))
        watchSample.tap()
        XCTAssertTrue(app.buttons["Start listening"].isEnabled)
        XCTAssertTrue(app.buttons["Start listening"].isHittable)
        app.buttons["Back"].tap()
        let phoneSample = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Phone microphone")).firstMatch
        XCTAssertTrue(phoneSample.waitForExistence(timeout: 5))
        phoneSample.tap()
        XCTAssertTrue(app.buttons["Record a sample"].isEnabled)
        XCTAssertTrue(app.buttons["Record a sample"].isHittable)
        let setup = XCTAttachment(screenshot: app.screenshot())
        setup.name = "Voice setup before recording"; setup.lifetime = .keepAlways; add(setup)
        app.buttons["Back"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(recognition.waitForExistence(timeout: 5))
        XCTAssertEqual(recognition.value as? String, "0", "Preparing or cancelling enrollment must not enable recognition")
        recognition.tap()
        let enabled = NSPredicate(format: "value == '1'")
        expectation(for: enabled, evaluatedWith: recognition)
        waitForExpectations(timeout: 15)
        app.terminate()
        app.launch()
        XCTAssertTrue(recognition.waitForExistence(timeout: 20))
        XCTAssertEqual(recognition.value as? String, "1", "Explicit mode should survive relaunch")
        recognition.tap()
        XCTAssertEqual(recognition.value as? String, "0")
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "People and voices disabled"; settings.lifetime = .keepAlways; add(settings)
    }
}
