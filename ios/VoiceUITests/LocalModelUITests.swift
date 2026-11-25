import XCTest

/// On this iPhone, driven by hand: get a model, cancel it, let it finish, switch back, remove it.
final class LocalModelUITests: XCTestCase {
    @MainActor private func open(_ state: String? = nil, large: Bool = false, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.audiocompanion.app.dev")
        app.launchArguments = ["-demo-data", "-onboarding.skip", "-route", "settings/transcription"]
        if let state { app.launchArguments += ["-localmodel.state", state] }
        if large {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
            ]
        }
        XCUIDevice.shared.appearance = dark ? .dark : .light
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "On this iPhone")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.navigationBars["On this iPhone"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func waitSelected(_ row: XCUIElement, timeout: TimeInterval = 6) {
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: row)
        wait(for: [selected], timeout: timeout)
    }

    @MainActor func testGetCancelFinishSwitchAndRemove() throws {
        continueAfterFailure = false
        let app = open()
        let pebble = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Pebble,")).firstMatch
        let apple = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Apple Speech,")).firstMatch
        XCTAssertTrue(apple.isSelected)
        capture(app, "two-choices")

        app.buttons["Get Pebble"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 4))
        XCTAssertTrue(apple.isSelected, "Apple Speech stays in use while the model downloads")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Get Pebble"].waitForExistence(timeout: 4))

        app.buttons["Get Pebble"].tap()
        waitSelected(pebble, timeout: 30)
        XCTAssertFalse(apple.isSelected)
        capture(app, "installed")

        apple.tap()
        waitSelected(apple)
        pebble.tap()
        waitSelected(pebble)

        pebble.press(forDuration: 1.2)
        let remove = app.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 6))
        capture(app, "menu")
        remove.tap()
        XCTAssertTrue(app.staticTexts["Remove Pebble?"].waitForExistence(timeout: 4))
        capture(app, "remove")
        app.buttons.matching(identifier: "Remove").allElementsBoundByIndex.last?.tap()
        XCTAssertTrue(app.buttons["Get Pebble"].waitForExistence(timeout: 4))
        XCTAssertTrue(apple.isSelected, "removing the engine in use leaves Apple Speech")
    }

    @MainActor func testEveryStateIsReadable() throws {
        for state in ["downloading", "preparing", "installed", "wifi", "failed", "space"] {
            capture(open(state), "state-\(state)")
        }
        capture(open("space", large: true), "large-space")
        capture(open(large: true), "large-two-choices")
        capture(open(dark: true), "dark-two-choices")
        XCUIDevice.shared.appearance = .light
    }
}
